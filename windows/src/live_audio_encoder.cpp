#include "hearport/windows/live_audio_encoder.h"
#include "HearPortOpusBridge.h"
#include <bit>
#include <stdexcept>

namespace hearport::windows {
LiveAudioEncoder::~LiveAudioEncoder() { if (encoder_) hp_opus_encoder_destroy(encoder_); }

bool LiveAudioEncoder::Configure(std::uint32_t bitrate, std::uint32_t frames) {
  if (bitrate != 0 && ((bitrate != 192000 && bitrate != 256000) ||
      (frames != 120 && frames != 240 && frames != 480))) return false;
  int error = 0;
  void* replacement = bitrate ? hp_opus_encoder_create(static_cast<int>(bitrate), &error) : nullptr;
  if (bitrate && !replacement) return false;
  if (encoder_) hp_opus_encoder_destroy(encoder_);
  encoder_ = replacement; frames_ = frames;
  lookahead_ = encoder_ ? hp_opus_lookahead(encoder_) : 0;
  samples_.clear(); samples_.reserve(frames * 2);
  return true;
}

std::optional<wire::TimedAudioRecord> LiveAudioEncoder::Push(const wire::AudioDatagram& packet,
    std::uint64_t captured, std::uint64_t source_frame, std::uint32_t generation) {
  if (!encoder_) return std::nullopt;
  if (!samples_.empty() && (packet.sequence != expected_ ||
      packet.stream_id != pending_.stream_id || generation != pending_.generation)) samples_.clear();
  if (!samples_.empty()) {
    const auto expected_capture = pending_.captured_at_ns +
        (std::uint64_t(lookahead_) + samples_.size() / 2) * 1'000'000'000 / 48'000;
    if (captured > expected_capture + 5'000'000 || captured + 5'000'000 < expected_capture)
      samples_.clear();
  }
  if (samples_.empty()) {
    if (packet.sequence % (frames_ / 120) != 0) return std::nullopt;
    pending_ = {};
    pending_.stream_id = packet.stream_id; pending_.generation = generation;
    pending_.sequence = packet.sequence; pending_.source_frame = source_frame;
    pending_.frame_count = static_cast<std::uint16_t>(frames_);
    pending_.kind = wire::AudioRecordKind::opus;
    const auto delay = std::uint64_t(lookahead_) * 1'000'000'000 / 48'000;
    pending_.captured_at_ns = captured > delay ? captured - delay : 0;
  }
  for (std::size_t offset = 0; offset < packet.pcm.size(); offset += 4) {
    std::uint32_t bits = 0;
    for (unsigned byte = 0; byte < 4; ++byte)
      bits |= std::to_integer<std::uint32_t>(packet.pcm[offset + byte]) << (byte * 8);
    samples_.push_back(std::bit_cast<float>(bits));
  }
  expected_ = packet.sequence + 1;
  if (samples_.size() != frames_ * 2) return std::nullopt;
  pending_.payload.resize(960);
  const auto bytes = hp_opus_encode(encoder_, samples_.data(), frames_,
      reinterpret_cast<unsigned char*>(pending_.payload.data()), static_cast<int>(pending_.payload.size()));
  samples_.clear();
  if (bytes <= 0) throw std::runtime_error("live Opus encode failed");
  pending_.payload.resize(bytes);
  return pending_;
}
}
