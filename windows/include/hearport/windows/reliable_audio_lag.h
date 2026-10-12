#pragma once

#include <chrono>
#include <cstdint>
#include <optional>

namespace hearport::windows {

class ReliableAudioLag {
 public:
  using Clock = std::chrono::steady_clock;

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
    const auto lag_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(maximum_lag_).count();
    bool behind = produced_count_ * frame_count_ * 1'000'000'000ull / 48000 > static_cast<std::uint64_t>(lag_ns);
    if (latest_received) {
      const auto distance = *latest_produced_ - *latest_received;
      behind = distance < 0x80000000u &&
               std::uint64_t(distance) * frame_count_ * 1'000'000'000ull / 48000 > static_cast<std::uint64_t>(lag_ns);
    }
    if (played_source && latest_source_) {
      behind = *latest_source_ > *played_source &&
               (*latest_source_ - *played_source) / 48 > static_cast<std::uint64_t>(maximum_lag_.count());
    }
    consecutive_lag_reports_ = behind ? consecutive_lag_reports_ + 1 : 0;
    if (!behind || (!bounded_ && (consecutive_lag_reports_ < 2 ||
        now - last_restart_ < std::chrono::milliseconds(500)))) {
      return false;
    }
    restart_pending_ = true;
    return true;
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
};

}  // namespace hearport::windows
