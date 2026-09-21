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
  return 0;
}
