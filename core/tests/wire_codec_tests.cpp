#include <array>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <cstdlib>
#include <span>
#include <vector>

#include "hearport/wire/audio_datagram.h"
#include "hearport/wire/control_framing.h"

int main() {
  const std::array<std::byte, 3> message{
      std::byte{'a'}, std::byte{'b'}, std::byte{'c'}};
  const auto framed = hearport::wire::EncodeControlFrame(message);
  assert(framed.size() == 7);
  assert(framed[0] == std::byte{0});
  assert(framed[3] == std::byte{3});

  hearport::wire::ControlFrameDecoder decoder;
  std::vector<std::vector<std::byte>> messages;
  assert(decoder.Push(std::span(framed).subspan(0, 2), messages));
  assert(messages.empty());
  assert(decoder.Push(std::span(framed).subspan(2), messages));
  assert(messages.size() == 1);
  assert(messages.front().size() == 3);

  hearport::wire::AudioDatagram packet{};
  packet.stream_id = 17;
  packet.sequence = 0xffffffffu;
  const auto encoded = hearport::wire::EncodeAudioDatagram(packet);
  assert(encoded.size() == 968);
  const auto decoded = hearport::wire::DecodeAudioDatagram(encoded);
  assert(decoded.has_value());
  assert(decoded->stream_id == 17);
  assert(decoded->sequence == 0xffffffffu);
  hearport::wire::TimedAudioRecord timed;
  timed.stream_id = 17;
  timed.generation = 2;
  timed.sequence = 0xffffffffu;
  timed.frame_count = 120;
  timed.captured_at_ns = 0x0102030405060708ull;
  timed.source_frame = 0x100000000ull;
  timed.payload.assign(960, std::byte{0x55});
  const auto timestamped = hearport::wire::EncodeTimedAudioRecord(timed);
  assert(timestamped.size() == 992);
  assert(timestamped[15] == std::byte{0});
  assert(timestamped[16] == std::byte{1});
  assert(timestamped[23] == std::byte{8});
  const auto restored = hearport::wire::DecodeTimedAudioRecord(timestamped);
  assert(restored && restored->captured_at_ns == timed.captured_at_ns);
  assert(restored->source_frame == 0x100000000ull && restored->payload == timed.payload);
  assert(!hearport::wire::DecodeTimedAudioRecord(std::span(timestamped).first(31)));
  auto broken = timestamped;
  broken[7] = std::byte{0};
  assert(!hearport::wire::DecodeTimedAudioRecord(broken));
  timed.kind = static_cast<hearport::wire::AudioRecordKind>(5);
  timed.frame_count = 480;
  timed.payload.assign(320, std::byte{0x44});
  const auto opus = hearport::wire::EncodeTimedAudioRecord(timed);
  assert(opus.size() == 352);
  assert(hearport::wire::DecodeTimedAudioRecord(opus)->frame_count == 480);
  auto invalid_opus = opus;
  invalid_opus[13] = std::byte{121};
  assert(!hearport::wire::DecodeTimedAudioRecord(invalid_opus));
  timed.kind = static_cast<hearport::wire::AudioRecordKind>(6);
  timed.frame_count = 120;
  timed.payload.assign(480, std::byte{0x33});
  assert(hearport::wire::DecodeTimedAudioRecord(hearport::wire::EncodeTimedAudioRecord(timed)));
  // 44.1 kHz starts with three blocks of 110 samples, then a block of 111.
  std::array<float, 240> samples;
  samples.fill(-0.5f);
  std::memcpy(packet.pcm.data(), samples.data(), packet.pcm.size());
  timed.kind = hearport::wire::AudioRecordKind::adaptive_pcm;
  unsigned total_samples = 0;
  for (unsigned block = 0; block < 400; ++block) {
    timed.source_frame = block * 120;
    timed.payload = hearport::wire::EncodeAdaptivePcm(packet, timed.source_frame, 44100, 24);
    total_samples += static_cast<unsigned>((timed.payload.size() - 3) / 6);
    const auto wire = hearport::wire::EncodeTimedAudioRecord(timed);
    const auto roundtrip = hearport::wire::DecodeTimedAudioRecord(wire);
    if (!roundtrip || roundtrip->payload != timed.payload || roundtrip->frame_count != 120 ||
        timed.payload[3] != std::byte{0} || timed.payload[4] != std::byte{0} ||
        timed.payload[5] != std::byte{0xc0} ||
        hearport::wire::DecodeTimedAudioRecord(std::span(wire).first(wire.size() - 1))) std::abort();
  }
  if (total_samples != 44100 ||
      hearport::wire::EncodeAdaptivePcm(packet, 0, 48000, 16).size() != 483) std::abort();
  return 0;
}
