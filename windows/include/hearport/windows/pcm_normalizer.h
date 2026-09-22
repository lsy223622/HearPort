#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace hearport::windows {

enum class SampleFormat {
  float32_le,
  int16_le,
  int24_le,
  int32_le,
};

struct PcmFormat {
  std::uint32_t sample_rate_hz = 48000;
  std::uint16_t channels = 2;
  SampleFormat sample_format = SampleFormat::float32_le;
};

class PcmNormalizer {
 public:
  explicit PcmNormalizer(PcmFormat source_format);

  // Returns canonical interleaved stereo Float32 samples at 48 kHz.
  std::vector<float> Convert(std::span<const std::byte> source_bytes);

  const PcmFormat& source_format() const noexcept { return source_format_; }

 private:
  PcmFormat source_format_;
  double source_position_ = 0.0;
  std::array<float, 2> previous_frame_{};
  bool has_previous_frame_ = false;
};

}  // namespace hearport::windows
