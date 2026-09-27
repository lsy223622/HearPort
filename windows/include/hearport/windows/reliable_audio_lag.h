#pragma once

#include <chrono>
#include <cstdint>
#include <optional>

namespace hearport::windows {

class ReliableAudioLag {
 public:
  using Clock = std::chrono::steady_clock;

  void Begin(std::uint32_t stream_id, std::uint32_t generation,
             Clock::time_point now) noexcept {
    stream_id_ = stream_id;
    generation_ = generation;
    latest_produced_.reset();
    produced_count_ = 0;
    consecutive_lag_reports_ = 0;
    restart_pending_ = false;
    last_restart_ = now;
  }

  void Produced(std::uint32_t sequence) noexcept {
    if (generation_ == 0) return;
    latest_produced_ = sequence;
    ++produced_count_;
  }

  bool Observe(std::uint32_t stream_id, std::uint32_t generation,
               std::optional<std::uint32_t> latest_received,
               Clock::time_point now) noexcept {
    if (stream_id != stream_id_ || generation != generation_ ||
        restart_pending_ || !latest_produced_) {
      return false;
    }
    bool behind = produced_count_ > 80;
    if (latest_received) {
      const auto distance = *latest_produced_ - *latest_received;
      behind = distance < 0x80000000u && distance > 80;
    }
    consecutive_lag_reports_ = behind ? consecutive_lag_reports_ + 1 : 0;
    if (consecutive_lag_reports_ < 2 ||
        now - last_restart_ < std::chrono::milliseconds(500)) {
      return false;
    }
    restart_pending_ = true;
    return true;
  }

 private:
  std::uint32_t stream_id_ = 0;
  std::uint32_t generation_ = 0;
  std::optional<std::uint32_t> latest_produced_;
  std::uint64_t produced_count_ = 0;
  unsigned consecutive_lag_reports_ = 0;
  bool restart_pending_ = false;
  Clock::time_point last_restart_{};
};

}  // namespace hearport::windows
