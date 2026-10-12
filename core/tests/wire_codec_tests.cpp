#include <array>
#include <cassert>
#include <cstddef>
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
  return 0;
}
