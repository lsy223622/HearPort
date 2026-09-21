#include "hearport/wire/audio_datagram.h"

#include <algorithm>
#include <cstdint>
#include <stdexcept>

namespace hearport::wire {
namespace {

void WriteBigEndian32(std::uint32_t value, std::byte* output) {
  output[0] = std::byte{static_cast<unsigned char>((value >> 24) & 0xffu)};
  output[1] = std::byte{static_cast<unsigned char>((value >> 16) & 0xffu)};
  output[2] = std::byte{static_cast<unsigned char>((value >> 8) & 0xffu)};
  output[3] = std::byte{static_cast<unsigned char>(value & 0xffu)};
}

std::uint32_t ReadBigEndian32(const std::byte* input) {
  return (static_cast<std::uint32_t>(input[0]) << 24) |
         (static_cast<std::uint32_t>(input[1]) << 16) |
         (static_cast<std::uint32_t>(input[2]) << 8) |
         static_cast<std::uint32_t>(input[3]);
}

}  // namespace

EncodedAudioDatagram EncodeAudioDatagram(const AudioDatagram& packet) {
  if (packet.stream_id == 0) {
    throw std::invalid_argument("stream_id must be non-zero");
  }

  EncodedAudioDatagram encoded{};
  WriteBigEndian32(packet.stream_id, encoded.data());
  WriteBigEndian32(packet.sequence, encoded.data() + 4);
  std::copy(packet.pcm.begin(), packet.pcm.end(), encoded.begin() + 8);
  return encoded;
}

std::optional<AudioDatagram> DecodeAudioDatagram(
    std::span<const std::byte> bytes) {
  if (bytes.size() != kAudioDatagramBytes) {
    return std::nullopt;
  }

  AudioDatagram packet{};
  packet.stream_id = ReadBigEndian32(bytes.data());
  packet.sequence = ReadBigEndian32(bytes.data() + 4);
  if (packet.stream_id == 0) {
    return std::nullopt;
  }
  std::copy(bytes.begin() + 8, bytes.end(), packet.pcm.begin());
  return packet;
}

}  // namespace hearport::wire
