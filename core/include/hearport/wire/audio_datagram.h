#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace hearport::wire {

inline constexpr std::size_t kAudioHeaderBytes = 8;
inline constexpr std::size_t kAudioPcmBytes = 960;
inline constexpr std::size_t kAudioDatagramBytes =
    kAudioHeaderBytes + kAudioPcmBytes;

struct AudioDatagram {
  std::uint32_t stream_id = 0;
  std::uint32_t sequence = 0;
  std::array<std::byte, kAudioPcmBytes> pcm{};
};

using EncodedAudioDatagram = std::array<std::byte, kAudioDatagramBytes>;

EncodedAudioDatagram EncodeAudioDatagram(const AudioDatagram& packet);
std::optional<AudioDatagram> DecodeAudioDatagram(
    std::span<const std::byte> bytes);

}  // namespace hearport::wire
