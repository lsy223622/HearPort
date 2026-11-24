#pragma once
#include <cstdint>
#include <optional>
#include <vector>
#include "hearport/wire/audio_datagram.h"

namespace hearport::windows {
class LiveAudioEncoder {
 public:
  LiveAudioEncoder() = default;
  ~LiveAudioEncoder();
  LiveAudioEncoder(const LiveAudioEncoder&) = delete;
  LiveAudioEncoder& operator=(const LiveAudioEncoder&) = delete;
  LiveAudioEncoder(LiveAudioEncoder&& other) noexcept;
  LiveAudioEncoder& operator=(LiveAudioEncoder&& other) noexcept;
  bool Configure(std::uint32_t bitrate, std::uint32_t frames);
  std::uint32_t lookahead() const noexcept { return lookahead_; }
  std::int64_t first_queued_at_ns() const noexcept { return first_queued_at_ns_; }
  std::optional<wire::TimedAudioRecord> Push(const wire::AudioDatagram& packet,
      std::uint64_t captured, std::uint64_t source_frame, std::uint32_t generation,
      std::int64_t queued_at_ns);
 private:
  void* encoder_ = nullptr;
  std::uint32_t frames_ = 0, lookahead_ = 0, expected_ = 0;
  wire::TimedAudioRecord pending_;
  std::int64_t first_queued_at_ns_ = 0;
  std::vector<float> samples_;
};
}
