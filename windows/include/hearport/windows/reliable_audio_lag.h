#pragma once

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdint>
#include <optional>
#include <deque>
#include <vector>
#include <utility>
#include "hearport/wire/audio_datagram.h"

namespace hearport::windows {

class ReliableAudioLag {
 public:
  using Clock = std::chrono::steady_clock;

  struct ReplayBudget {
    double bytes_per_second = 0;
    std::uint64_t delivery_delay_ns = 0;
    std::size_t reserved_bytes = 0;
  };

  void Begin(std::uint32_t stream_id, std::uint32_t generation,
             Clock::time_point now,
             std::optional<std::chrono::milliseconds> maximum_lag = std::nullopt) noexcept {
    stream_id_ = stream_id;
    generation_ = generation;
    latest_produced_.reset();
    produced_count_ = 0;
    consecutive_lag_reports_ = 0;
    restart_pending_ = false;
    last_restart_ = now;
    maximum_lag_ = maximum_lag.value_or(std::chrono::milliseconds(400));
    bounded_ = maximum_lag.has_value();
    latest_source_.reset();
    frame_count_ = 120;
    fresh_records_.clear();
    previous_played_.reset();
    previous_feedback_ns_ = 0;
    consumption_frames_per_ns_ = 0;
  }

  void Produced(std::uint32_t sequence, std::optional<std::uint64_t> source_end = std::nullopt,
                std::uint16_t frame_count = 120) noexcept {
    if (generation_ == 0) return;
    latest_produced_ = sequence;
    latest_source_ = source_end;
    frame_count_ = frame_count;
    ++produced_count_;
  }

  bool Observe(std::uint32_t stream_id, std::uint32_t generation,
               std::optional<std::uint32_t> latest_received,
               Clock::time_point now,
               std::chrono::milliseconds feedback_age = std::chrono::milliseconds(0),
               std::optional<std::uint64_t> played_source = std::nullopt) noexcept {
    if (stream_id != stream_id_ || generation != generation_ ||
        restart_pending_ || !latest_produced_) {
      return false;
    }
    if (feedback_age > maximum_lag_ / 2) return false;
    const auto snapshot_lag_limit = maximum_lag_ + feedback_age;
    const auto lag_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(snapshot_lag_limit).count();
    bool behind = produced_count_ * frame_count_ * 1'000'000'000ull / 48000 > static_cast<std::uint64_t>(lag_ns);
    if (latest_received) {
      const auto distance = *latest_produced_ - *latest_received;
      behind = distance < 0x80000000u &&
               std::uint64_t(distance) * frame_count_ * 1'000'000'000ull / 48000 > static_cast<std::uint64_t>(lag_ns);
    }
    if (!latest_received && played_source && latest_source_) {
      behind = *latest_source_ > *played_source &&
               (*latest_source_ - *played_source) / 48 > static_cast<std::uint64_t>(snapshot_lag_limit.count());
    }
    consecutive_lag_reports_ = behind ? consecutive_lag_reports_ + 1 : 0;
    if (!behind || (!bounded_ && (consecutive_lag_reports_ < 2 ||
        now - last_restart_ < std::chrono::milliseconds(500)))) {
      return false;
    }
    restart_pending_ = true;
    return true;
  }

  void Retain(const wire::TimedAudioRecord& record, std::uint64_t now) {
    const auto allowance = static_cast<std::uint64_t>(maximum_lag_.count()) * 1'000'000;
    while (!fresh_records_.empty() && now >= fresh_records_.front().captured_at_ns &&
           now - fresh_records_.front().captured_at_ns >= allowance) fresh_records_.pop_front();
    if (record.stream_id == stream_id_ && record.generation == generation_ &&
        now >= record.captured_at_ns && now - record.captured_at_ns < allowance) {
      fresh_records_.push_back(record);
    }
  }

  bool ConfirmReceived(std::uint32_t stream_id, std::uint32_t generation,
                       std::optional<std::uint32_t> latest_received,
                       std::optional<std::uint64_t> played_source,
                       std::uint64_t feedback_at_ns = 0) {
    if (stream_id != stream_id_ || generation != generation_) return false;
    if (feedback_at_ns != 0 && feedback_at_ns <= previous_feedback_ns_) return false;
    consumption_frames_per_ns_ = 0;
    if (played_source && previous_played_ && previous_feedback_ns_ != 0 &&
        feedback_at_ns > previous_feedback_ns_ && *played_source >= *previous_played_) {
      const auto interval = feedback_at_ns - previous_feedback_ns_;
      const double rate = double(*played_source - *previous_played_) / double(interval);
      if (interval <= std::uint64_t(maximum_lag_.count()) * 1'000'000 &&
          rate <= 48'000.0 * 1.05 / 1e9) consumption_frames_per_ns_ = rate;
    }
    previous_played_ = played_source;
    previous_feedback_ns_ = feedback_at_ns;
    while (!fresh_records_.empty()) {
      const auto& record = fresh_records_.front();
      const bool delivered = latest_received && (*latest_received - record.sequence) < 0x80000000u;
      const bool consumed = played_source && record.source_frame + record.frame_count <= *played_source;
      if (!delivered && !consumed) break;
      fresh_records_.pop_front();
    }
    return true;
  }

  std::vector<wire::TimedAudioRecord> ReplayFresh(std::uint32_t generation, std::uint64_t now,
      std::optional<std::uint32_t> latest_received,
      std::optional<std::uint64_t> played_source) const {
    std::vector<wire::TimedAudioRecord> result;
    const auto allowance = static_cast<std::uint64_t>(maximum_lag_.count()) * 1'000'000;
    for (auto record : fresh_records_) {
      if (now < record.captured_at_ns || now - record.captured_at_ns >= allowance ||
          (latest_received && (*latest_received - record.sequence) < 0x80000000u) ||
          (played_source && record.source_frame + record.frame_count <= *played_source)) continue;
      record.generation = generation;
      if (record.kind != wire::AudioRecordKind::audio) record.kind = wire::AudioRecordKind::retransmission;
      result.push_back(std::move(record));
    }
    return result;
  }

  std::vector<wire::TimedAudioRecord> ReplayForDelivery(std::uint32_t generation,
      std::uint64_t now, std::optional<std::uint32_t> latest_received,
      std::optional<std::uint64_t> played_source, const ReplayBudget& budget) const {
    const auto allowance = std::uint64_t(maximum_lag_.count()) * 1'000'000;
    if (!std::isfinite(budget.bytes_per_second) || budget.bytes_per_second <= 0 ||
        budget.delivery_delay_ns >= allowance) return {};
    auto candidates = ReplayFresh(generation, now, latest_received, played_source);
    double live_bytes_per_second = 0;
    for (const auto& record : candidates) {
      if (record.frame_count == 0) return {};
      live_bytes_per_second = std::max(live_bytes_per_second,
          double(record.payload.size() + 34) * 48'000 / record.frame_count);
    }
    const double spare = std::max(0.0, budget.bytes_per_second - live_bytes_per_second);
    double remaining = std::max(0.0, spare * double(allowance - budget.delivery_delay_ns) / 1e9 -
                                    double(budget.reserved_bytes));
    auto first = candidates.size();
    while (first > 0) {
      const auto bytes = candidates[first - 1].payload.size() + 34;
      if (double(bytes) > remaining) break;
      remaining -= double(bytes); --first;
    }
    std::vector<wire::TimedAudioRecord> result;
    auto arrival = now + budget.delivery_delay_ns;
    for (auto index = first; index < candidates.size(); ++index) {
      const auto& record = candidates[index];
      const auto service = static_cast<std::uint64_t>(std::ceil(
          double(record.payload.size() + 34) * 1e9 / budget.bytes_per_second));
      const auto delivered = arrival + service;
      if (delivered < record.captured_at_ns || delivered - record.captured_at_ns >= allowance) continue;
      if (played_source && previous_feedback_ns_ != 0 && delivered >= previous_feedback_ns_ &&
          double(record.source_frame + record.frame_count) <= double(*played_source) +
              double(delivered - previous_feedback_ns_) * consumption_frames_per_ns_) continue;
      result.push_back(record);
      arrival = delivered;
    }
    return result;
  }

  std::optional<std::uint32_t> latest_produced() const noexcept {
    return latest_produced_;
  }

 private:
  std::uint32_t stream_id_ = 0;
  std::uint32_t generation_ = 0;
  std::optional<std::uint32_t> latest_produced_;
  std::uint64_t produced_count_ = 0;
  unsigned consecutive_lag_reports_ = 0;
  bool restart_pending_ = false;
  Clock::time_point last_restart_{};
  std::chrono::milliseconds maximum_lag_{400};
  bool bounded_ = false;
  std::optional<std::uint64_t> latest_source_;
  std::uint16_t frame_count_ = 120;
  std::deque<wire::TimedAudioRecord> fresh_records_;
  std::optional<std::uint64_t> previous_played_;
  std::uint64_t previous_feedback_ns_ = 0;
  double consumption_frames_per_ns_ = 0;
};

}  // namespace hearport::windows
