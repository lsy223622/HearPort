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

  const auto with_unknown = std::vector<std::byte>{
      std::byte{0x10}, std::byte{0x01}, connect_bytes[0], connect_bytes[1],
      connect_bytes[2], connect_bytes[3]};
  const auto decoded_with_unknown =
      hearport::wire::DecodeControlEnvelope(with_unknown);
  assert(decoded_with_unknown.has_value());
  assert(decoded_with_unknown->auth_mode == AuthMode::pair);

  const auto duplicate_scalar = std::vector<std::byte>{
      std::byte{0x0a}, std::byte{0x04}, std::byte{0x08}, std::byte{0x01},
      std::byte{0x08}, std::byte{0x02}};
  const auto decoded_duplicate =
      hearport::wire::DecodeControlEnvelope(duplicate_scalar);
  assert(decoded_duplicate.has_value());
  assert(decoded_duplicate->auth_mode == AuthMode::pair);

  const auto wrong_wire_after_valid = std::vector<std::byte>{
      std::byte{0x0a}, std::byte{0x02}, std::byte{0x08}, std::byte{0x02},
      std::byte{0x09}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}};
  const auto decoded_wrong_wire =
      hearport::wire::DecodeControlEnvelope(wrong_wire_after_valid);
  assert(decoded_wrong_wire.has_value());
  assert(decoded_wrong_wire->auth_mode == AuthMode::pair);

  auto malformed = ack_bytes;
  malformed.push_back(std::byte{0});
  assert(!hearport::wire::DecodeControlEnvelope(malformed).has_value());
  return 0;
}
