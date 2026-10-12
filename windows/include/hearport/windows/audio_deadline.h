#pragma once
#include <algorithm>
#include <cstdint>

namespace hearport::windows {
class AudioDeadline {
 public:
  AudioDeadline(std::uint32_t maximum_ms, std::uint32_t output_ms) noexcept
      : allowance_ns_(std::uint64_t(maximum_ms > output_ms ? maximum_ms - output_ms : 0) *
                      1'000'000) {}

  std::uint64_t RemainingNanoseconds(std::uint64_t captured_at,
                                     std::uint64_t now) const noexcept {
    const auto elapsed = now >= captured_at ? now - captured_at : 0;
    return elapsed >= allowance_ns_ ? 0 : allowance_ns_ - elapsed;
  }
  bool Expired(std::uint64_t captured_at, std::uint64_t now) const noexcept {
    return RemainingNanoseconds(captured_at, now) == 0;
  }

 private:
  std::uint64_t allowance_ns_;
};
}
