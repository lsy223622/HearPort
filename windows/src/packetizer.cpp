#include "hearport/windows/packetizer.h"

#include <algorithm>
#include <bit>
#include <cstdint>
#include <stdexcept>

namespace hearport::windows {
namespace {

void WriteLittleEndian32(std::uint32_t value, std::byte* bytes) {
  bytes[0] = std::byte{static_cast<unsigned char>(value & 0xffu)};
  bytes[1] = std::byte{static_cast<unsigned char>((value >> 8) & 0xffu)};
  bytes[2] = std::byte{static_cast<unsigned char>((value >> 16) & 0xffu)};
  bytes[3] = std::byte{static_cast<unsigned char>((value >> 24) & 0xffu)};
}

}  // namespace

AudioPacketizer::AudioPacketizer(std::uint32_t stream_id) : stream_id_(stream_id) {
  if (stream_id_ == 0) {
    throw std::invalid_argument("stream_id must be non-zero");
  }
}

void AudioPacketizer::Push(std::span<const float> interleaved_stereo,
                           const PacketHandler& handler) {
  if (interleaved_stereo.size() % 2 != 0) {
    throw std::invalid_argument("packetizer input must contain stereo frames");
  }

  std::size_t offset = 0;
  while (offset < interleaved_stereo.size()) {
    const auto copy_count = std::min(kSamplesPerPacket - buffered_samples_,
                                     interleaved_stereo.size() - offset);
    std::copy_n(interleaved_stereo.begin() +
                    static_cast<std::ptrdiff_t>(offset),
                copy_count, pending_.begin() +
                                static_cast<std::ptrdiff_t>(buffered_samples_));
    offset += copy_count;
    buffered_samples_ += copy_count;
    if (buffered_samples_ < kSamplesPerPacket) {
      continue;
    }

    wire::AudioDatagram packet{};
    packet.stream_id = stream_id_;
    packet.sequence = sequence_++;
    for (std::size_t sample = 0; sample < kSamplesPerPacket; ++sample) {
      WriteLittleEndian32(std::bit_cast<std::uint32_t>(pending_[sample]),
                          packet.pcm.data() + sample * sizeof(float));
    }
    handler(packet);
    buffered_samples_ = 0;
  }
}

void AudioPacketizer::Reset(std::uint32_t stream_id) {
  if (stream_id == 0) {
    throw std::invalid_argument("stream_id must be non-zero");
  }
  stream_id_ = stream_id;
  sequence_ = 0;
  buffered_samples_ = 0;
}

}  // namespace hearport::windows
