#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>

#include "hearport/wire/audio_datagram.h"

namespace hearport {

enum class PacketDisposition {
  accepted,
  duplicate,
  late,
  wrong_stream,
  overflow,
};

enum class PlaybackMode {
  buffering,
  playing,
  silent_rebuffer,
};

struct JitterStats {
  std::uint64_t duplicate = 0;
  std::uint64_t late = 0;
  std::uint64_t wrong_stream = 0;
  std::uint64_t loss = 0;
  std::uint64_t overflow = 0;
};

class JitterBuffer {
 public:
  JitterBuffer(std::uint32_t stream_id, std::size_t capacity_packets,
               std::size_t target_packets);

  PacketDisposition Insert(const wire::AudioDatagram& packet);
  std::optional<wire::AudioDatagram> ConsumeNext();
  std::array<std::byte, wire::kAudioPcmBytes> ConcealMissing();
  void EnterSilentRebuffer();
  void Reset(std::uint32_t stream_id);

  std::uint32_t stream_id() const noexcept { return stream_id_; }
  PlaybackMode mode() const noexcept { return mode_; }
  std::size_t fill_packets() const noexcept { return packets_.size(); }
  const JitterStats& stats() const noexcept { return stats_; }

 private:
  std::uint32_t stream_id_;
  std::size_t capacity_packets_;
  std::size_t target_packets_;
  PlaybackMode mode_ = PlaybackMode::buffering;
  JitterStats stats_{};
  std::map<std::uint32_t, wire::AudioDatagram> packets_;
  std::optional<std::uint32_t> expected_;
};

}  // namespace hearport
