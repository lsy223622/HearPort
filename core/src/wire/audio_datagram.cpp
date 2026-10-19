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

std::vector<std::byte> EncodeTimedAudioRecord(const TimedAudioRecord& record) {
  const auto kind = static_cast<std::uint16_t>(record.kind);
  const bool pcm = kind == 0;
  if (record.stream_id == 0 || record.generation == 0 || record.captured_at_ns == 0 ||
      record.frame_count == 0 || kind > 6 || record.payload.empty() ||
      record.payload.size() > 992 ||
      (record.source_frame > UINT64_MAX - record.frame_count) ||
      (pcm && (record.frame_count != 120 || record.payload.size() != 960)) ||
      (kind == 5 && record.frame_count != 120 && record.frame_count != 240 && record.frame_count != 480) ||
      (kind == 6 && (record.frame_count != 120 || record.payload.size() != 480))) {
    throw std::invalid_argument("invalid timed audio record");
  }
  std::vector<std::byte> bytes(32 + record.payload.size());
  WriteBigEndian32(record.stream_id, bytes.data());
  WriteBigEndian32(record.generation, bytes.data() + 4);
  WriteBigEndian32(record.sequence, bytes.data() + 8);
  bytes[12] = std::byte(record.frame_count >> 8);
  bytes[13] = std::byte(record.frame_count & 0xff);
  bytes[14] = std::byte(kind >> 8);
  bytes[15] = std::byte(kind & 0xff);
  WriteBigEndian32(static_cast<std::uint32_t>(record.captured_at_ns >> 32), bytes.data() + 16);
  WriteBigEndian32(static_cast<std::uint32_t>(record.captured_at_ns), bytes.data() + 20);
  WriteBigEndian32(static_cast<std::uint32_t>(record.source_frame >> 32), bytes.data() + 24);
  WriteBigEndian32(static_cast<std::uint32_t>(record.source_frame), bytes.data() + 28);
  std::copy(record.payload.begin(), record.payload.end(), bytes.begin() + 32);
  return bytes;
}

std::optional<TimedAudioRecord> DecodeTimedAudioRecord(std::span<const std::byte> bytes) {
  if (bytes.size() <= 32 || bytes.size() > 1024) return std::nullopt;
  TimedAudioRecord record;
  record.stream_id = ReadBigEndian32(bytes.data());
  record.generation = ReadBigEndian32(bytes.data() + 4);
  record.sequence = ReadBigEndian32(bytes.data() + 8);
  record.frame_count = (std::to_integer<unsigned>(bytes[12]) << 8) |
                       std::to_integer<unsigned>(bytes[13]);
  record.kind = static_cast<AudioRecordKind>((std::to_integer<unsigned>(bytes[14]) << 8) |
                                            std::to_integer<unsigned>(bytes[15]));
  record.captured_at_ns = (std::uint64_t(ReadBigEndian32(bytes.data() + 16)) << 32) |
                          ReadBigEndian32(bytes.data() + 20);
  record.source_frame = (std::uint64_t(ReadBigEndian32(bytes.data() + 24)) << 32) |
                        ReadBigEndian32(bytes.data() + 28);
  record.payload.assign(bytes.begin() + 32, bytes.end());
  const auto kind = static_cast<unsigned>(record.kind);
  const bool pcm = kind == 0;
  if (record.stream_id == 0 || record.generation == 0 || record.captured_at_ns == 0 ||
      record.frame_count == 0 || kind > 6 ||
      (record.source_frame > UINT64_MAX - record.frame_count) ||
      (pcm && (record.frame_count != 120 || record.payload.size() != 960)) ||
      (kind == 5 && record.frame_count != 120 && record.frame_count != 240 && record.frame_count != 480) ||
      (kind == 6 && (record.frame_count != 120 || record.payload.size() != 480))) return std::nullopt;
  return record;
}

}  // namespace hearport::wire
