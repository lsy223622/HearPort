#include <cassert>
#include <cstddef>
#include <span>

#include "hearport/wire/control_message.h"

int main() {
  using hearport::AuthMode;
  using hearport::wire::ControlEnvelope;
  using hearport::wire::ControlMessageType;

  ControlEnvelope connect;
  connect.type = ControlMessageType::connect_request;
  connect.auth_mode = AuthMode::pair;
  const auto connect_bytes = hearport::wire::EncodeControlEnvelope(connect);
  assert(connect_bytes.size() == 4);
  assert(std::to_integer<unsigned int>(connect_bytes[0]) == 0x0a);
  assert(std::to_integer<unsigned int>(connect_bytes[1]) == 0x02);
  assert(std::to_integer<unsigned int>(connect_bytes[2]) == 0x08);
  assert(std::to_integer<unsigned int>(connect_bytes[3]) == 0x02);
  const auto decoded_connect = hearport::wire::DecodeControlEnvelope(connect_bytes);
  assert(decoded_connect.has_value());
  assert(decoded_connect->type == ControlMessageType::connect_request);
  assert(decoded_connect->auth_mode == AuthMode::pair);

  ControlEnvelope ack;
  ack.type = ControlMessageType::start_stream_ack;
  ack.stream_id = 7;
  const auto ack_bytes = hearport::wire::EncodeControlEnvelope(ack);
  assert(ack_bytes.size() == 5);
  assert(std::to_integer<unsigned int>(ack_bytes[0]) == 0xfa);
  assert(std::to_integer<unsigned int>(ack_bytes[1]) == 0x01);
  assert(std::to_integer<unsigned int>(ack_bytes[2]) == 0x02);
  assert(std::to_integer<unsigned int>(ack_bytes[3]) == 0x08);
  assert(std::to_integer<unsigned int>(ack_bytes[4]) == 0x07);
  assert(hearport::wire::DecodeControlEnvelope(ack_bytes)->stream_id == 7);

  auto malformed = ack_bytes;
  malformed.push_back(std::byte{0});
  assert(!hearport::wire::DecodeControlEnvelope(malformed).has_value());
  return 0;
}
