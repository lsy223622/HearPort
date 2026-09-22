#include "hearport/windows/pcm_normalizer.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <stdexcept>

namespace hearport::windows {
namespace {

std::size_t BytesPerSample(SampleFormat format) {
  switch (format) {
    case SampleFormat::float32_le:
    case SampleFormat::int32_le:
      return 4;
    case SampleFormat::int16_le:
      return 2;
    case SampleFormat::int24_le:
      return 3;
  }
  throw std::invalid_argument("unsupported PCM sample format");
}

std::uint32_t ReadLittleEndian32(const std::byte* bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

float DecodeSample(const std::byte* bytes, SampleFormat format) {
  switch (format) {
    case SampleFormat::float32_le:
      return std::bit_cast<float>(ReadLittleEndian32(bytes));
    case SampleFormat::int16_le: {
      const auto raw = static_cast<std::int16_t>(
          static_cast<std::uint16_t>(bytes[0]) |
          (static_cast<std::uint16_t>(bytes[1]) << 8));
      return static_cast<float>(raw) / 32768.0f;
    }
    case SampleFormat::int24_le: {
      std::int32_t raw = static_cast<std::int32_t>(bytes[0]) |
                         (static_cast<std::int32_t>(bytes[1]) << 8) |
                         (static_cast<std::int32_t>(bytes[2]) << 16);
      if ((raw & 0x800000) != 0) {
        raw |= ~0xffffff;
      }
      return static_cast<float>(raw) / 8388608.0f;
    }
    case SampleFormat::int32_le: {
      const auto raw = static_cast<std::int32_t>(ReadLittleEndian32(bytes));
      return static_cast<float>(raw) / 2147483648.0f;
    }
  }
  throw std::invalid_argument("unsupported PCM sample format");
}

}  // namespace

PcmNormalizer::PcmNormalizer(PcmFormat source_format)
    : source_format_(source_format) {
  if (source_format_.sample_rate_hz == 0 || source_format_.channels == 0) {
    throw std::invalid_argument("invalid source PCM format");
  }
}

std::vector<float> PcmNormalizer::Convert(
    std::span<const std::byte> source_bytes) {
  const auto bytes_per_sample = BytesPerSample(source_format_.sample_format);
  const auto bytes_per_frame = bytes_per_sample * source_format_.channels;
  if (source_bytes.size() % bytes_per_frame != 0) {
    throw std::invalid_argument("PCM input does not contain complete frames");
  }

  const auto source_frames = source_bytes.size() / bytes_per_frame;
  std::vector<float> stereo;
  stereo.reserve(source_frames * 2);
  for (std::size_t frame = 0; frame < source_frames; ++frame) {
    const auto* frame_bytes = source_bytes.data() + frame * bytes_per_frame;
    const auto left = DecodeSample(frame_bytes, source_format_.sample_format);
    const auto right = source_format_.channels == 1
                           ? left
                           : DecodeSample(frame_bytes + bytes_per_sample,
                                          source_format_.sample_format);
    stereo.push_back(left);
    stereo.push_back(right);
  }

  if (source_frames == 0) {
    return stereo;
  }

  if (source_format_.sample_rate_hz == 48000) {
    previous_frame_[0] = stereo[stereo.size() - 2];
    previous_frame_[1] = stereo[stereo.size() - 1];
    has_previous_frame_ = true;
    source_position_ = 0.0;
    return stereo;
  }

  const auto step = static_cast<double>(source_format_.sample_rate_hz) / 48000.0;
  constexpr double kExactFraction = 1e-9;

  std::vector<float> resampled;
  resampled.reserve(static_cast<std::size_t>(std::ceil(
                        (static_cast<double>(source_frames) + 1.0) / step)) *
                    2);
  auto position = source_position_;
  while (position < static_cast<double>(source_frames - 1) ||
         std::abs(position - static_cast<double>(source_frames - 1)) <
             kExactFraction) {
    const auto lower_index = static_cast<std::int64_t>(std::floor(position));
    const auto fraction = static_cast<float>(position - lower_index);
    for (std::size_t channel = 0; channel < 2; ++channel) {
      const auto left = lower_index < 0
                            ? (has_previous_frame_ ? previous_frame_[channel]
                                                   : stereo[channel])
                            : stereo[static_cast<std::size_t>(lower_index) * 2 +
                                     channel];
      const auto upper_index = lower_index + 1;
      const auto right = upper_index < 0 ||
                                 upper_index >=
                                     static_cast<std::int64_t>(source_frames)
                             ? left
                             : stereo[static_cast<std::size_t>(upper_index) * 2 +
                                      channel];
      resampled.push_back(left + (right - left) * fraction);
    }
    position += step;
  }
  source_position_ = position - static_cast<double>(source_frames);
  previous_frame_[0] = stereo[stereo.size() - 2];
  previous_frame_[1] = stereo[stereo.size() - 1];
  has_previous_frame_ = true;
  return resampled;
}

}  // namespace hearport::windows
