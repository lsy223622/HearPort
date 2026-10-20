#pragma once
#include <cstdint>
#include <optional>
#include <vector>
#include "hearport/wire/audio_datagram.h"

namespace hearport::windows {
class LiveAudioEncoder {
 public:
  ~LiveAudioEncoder();
  bool Configure(std::uint32_t bitrate, std::uint32_t frames);
  std::uint32_t lookahead() const noexcept { return lookahead_; }
  std::optional<wire::TimedAudioRecord> Push(const wire::AudioDatagram& packet,
      std::uint64_t captured, std::uint64_t source_frame, std::uint32_t generation);
 private:
  void* encoder_ = nullptr;
  std::uint32_t frames_ = 0, lookahead_ = 0, expected_ = 0;
  wire::TimedAudioRecord pending_;
  std::vector<float> samples_;
};
}
