#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <span>

#include "hearport/wire/audio_datagram.h"

namespace hearport::windows {

class AudioPacketizer {
 public:
  using PacketHandler =
      std::function<void(const wire::AudioDatagram& packet)>;

  explicit AudioPacketizer(std::uint32_t stream_id);

  void Push(std::span<const float> interleaved_stereo,
            const PacketHandler& handler);
  void Reset(std::uint32_t stream_id);
  std::size_t buffered_frames() const noexcept {
    return buffered_samples_ / 2;
  }
  std::uint32_t next_sequence() const noexcept { return sequence_; }

 private:
  static constexpr std::size_t kSamplesPerPacket = 120 * 2;
  std::uint32_t stream_id_;
  std::uint32_t sequence_ = 0;
  std::array<float, kSamplesPerPacket> pending_{};
  std::size_t buffered_samples_ = 0;
};

}  // namespace hearport::windows
