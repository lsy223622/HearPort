#include "hearport/wire/audio_datagram.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
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

unsigned AdaptiveSamples(std::uint32_t rate, std::uint64_t source_frame) {
  const auto block = static_cast<unsigned>((source_frame / 120) % 400);
  return (block + 1) * rate / 400 - block * rate / 400;
}

bool ValidAdaptive(std::span<const std::byte> payload, unsigned frames, std::uint64_t source) {
  if (frames != 120 || payload.size() < 3) return false;
  const auto rate = (std::to_integer<unsigned>(payload[0]) << 8) |
                    std::to_integer<unsigned>(payload[1]);
  const auto bits = std::to_integer<unsigned>(payload[2]);
  return rate >= 8000 && rate <= 48000 && bits >= 8 && bits <= 32 &&
         payload.size() == 3 + AdaptiveSamples(rate, source) * 2 * ((bits + 7) / 8);
}

}  // namespace

std::vector<std::byte> EncodeAdaptivePcm(const AudioDatagram& packet, std::uint64_t source_frame,
                                         std::uint32_t rate, unsigned bits) {
  if (rate < 8000 || rate > 48000 || bits < 8 || bits > 32)
    throw std::invalid_argument("invalid PCM format");
  const unsigned width = (bits + 7) / 8;
  const auto count = AdaptiveSamples(rate, source_frame);
  std::array<float, 240> input{};
  std::memcpy(input.data(), packet.pcm.data(), packet.pcm.size());
  std::vector<std::byte> output{std::byte(rate >> 8), std::byte(rate & 255), std::byte(bits)};
  output.reserve(3 + count * 2 * width);
  for (unsigned frame = 0; frame < count; ++frame) {
    const unsigned start = frame * 120;
    const unsigned end = start + 120;
    for (unsigned channel = 0; channel < 2; ++channel) {
      double sum = 0;
      // Average the covered input interval before reducing the sample rate.
      for (unsigned i = start / count; i < (end + count - 1) / count; ++i) {
        const auto weight = std::min(end, (i + 1) * count) - std::max(start, i * count);
        sum += input[2 * i + channel] * weight;
      }
      const auto sample = std::isfinite(sum) ? sum / 120 : 0;
      std::uint32_t value;
      if (bits == 32) {
        value = std::bit_cast<std::uint32_t>(static_cast<float>(sample));
      } else {
        const int scale = 1 << (bits - 1);
        const auto integer = std::clamp(std::lround(std::clamp(sample, -1.0, 1.0) * scale),
                                        static_cast<long>(-scale), static_cast<long>(scale - 1));
        value = static_cast<std::uint32_t>(integer);
      }
      for (unsigned byte = 0; byte < width; ++byte)
        output.push_back(std::byte((value >> (byte * 8)) & 255));
    }
  }
  return output;
}

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
      record.frame_count == 0 || kind > 7 || record.payload.empty() ||
      record.payload.size() > 992 ||
      (record.source_frame > UINT64_MAX - record.frame_count) ||
      (pcm && (record.frame_count != 120 || record.payload.size() != 960)) ||
      (kind == 5 && record.frame_count != 120 && record.frame_count != 240 && record.frame_count != 480) ||
      (kind == 6 && (record.frame_count != 120 || record.payload.size() != 480)) ||
      (kind == 7 && !ValidAdaptive(record.payload, record.frame_count, record.source_frame))) {
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
      record.frame_count == 0 || kind > 7 ||
      (record.source_frame > UINT64_MAX - record.frame_count) ||
      (pcm && (record.frame_count != 120 || record.payload.size() != 960)) ||
      (kind == 5 && record.frame_count != 120 && record.frame_count != 240 && record.frame_count != 480) ||
      (kind == 6 && (record.frame_count != 120 || record.payload.size() != 480)) ||
      (kind == 7 && !ValidAdaptive(record.payload, record.frame_count, record.source_frame))) return std::nullopt;
  return record;
}

}  // namespace hearport::wire
