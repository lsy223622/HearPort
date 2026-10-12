#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

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

enum class AudioRecordKind : std::uint16_t { audio, fec, retransmission, repeated, probe };

struct TimedAudioRecord {
  std::uint32_t stream_id = 0;
  std::uint32_t generation = 0;
  std::uint32_t sequence = 0;
  std::uint16_t frame_count = 120;
  AudioRecordKind kind = AudioRecordKind::audio;
  std::uint64_t captured_at_ns = 0;
  std::uint64_t source_frame = 0;
  std::vector<std::byte> payload;
};

std::vector<std::byte> EncodeTimedAudioRecord(const TimedAudioRecord& record);
std::optional<TimedAudioRecord> DecodeTimedAudioRecord(std::span<const std::byte> bytes);

}  // namespace hearport::wire
