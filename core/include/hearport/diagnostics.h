#pragma once

#include <cstdint>

namespace hearport {

struct RealtimeDiagnostics {
  std::uint32_t stream_id = 0;
  std::uint32_t expected_sequence = 0;
  std::uint64_t duplicate = 0;
  std::uint64_t loss = 0;
  std::uint64_t late = 0;
  std::uint64_t underrun = 0;
  std::uint64_t overflow = 0;
  std::uint64_t jitter_fill_packets = 0;
  std::uint64_t render_fill_frames = 0;
  double resampler_ratio = 1.0;
  bool silent_rebuffer = false;
};

}  // namespace hearport
