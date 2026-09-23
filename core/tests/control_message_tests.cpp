#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <span>
#include <vector>

#include "hearport/wire/control_message.h"

namespace {

void AppendVarint(std::uint32_t value, std::vector<std::byte>& output) {
  while (value >= 0x80u) {
    output.push_back(std::byte{static_cast<unsigned char>((value & 0x7fu) | 0x80u)});
    value >>= 7;
  }
  output.push_back(std::byte{static_cast<unsigned char>(value)});
}

void Append(std::span<const std::byte> bytes, std::vector<std::byte>& output) {
  output.insert(output.end(), bytes.begin(), bytes.end());
}

std::vector<std::byte> VarintField(std::uint32_t field, std::uint32_t value) {
  std::vector<std::byte> output;
  AppendVarint((field << 3) | 0u, output);
  AppendVarint(value, output);
  return output;
}

std::vector<std::byte> BytesField(std::uint32_t field,
                                  std::span<const std::byte> bytes) {
  std::vector<std::byte> output;
  AppendVarint((field << 3) | 2u, output);
  AppendVarint(static_cast<std::uint32_t>(bytes.size()), output);
  Append(bytes, output);
  return output;
}

std::vector<std::byte> Envelope(std::uint32_t field,
                                std::span<const std::byte> body) {
  return BytesField(field, body);
}

std::vector<std::byte> Join(std::initializer_list<std::vector<std::byte>> fields) {
  std::vector<std::byte> output;
  for (const auto& field : fields) Append(field, output);
  return output;
}

void Require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "test failure: " << message << '\n';
    std::exit(EXIT_FAILURE);
  }
}

}  // namespace

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

  const auto session_id = std::vector<std::byte>(16, std::byte{0x11});
  const auto connect_features =
      Envelope(1, Join({VarintField(1, 2), VarintField(3, 1)}));
  const auto session_ready_features = Envelope(2, VarintField(1, 1));
  const auto receiver_ready = Envelope(32, {});
  const auto diagnostics_start = Envelope(
      33, Join({BytesField(1, session_id), VarintField(2, 7), VarintField(3, 60)}));
  const auto diagnostics_end = Envelope(
      34, Join({BytesField(1, session_id), VarintField(2, 1)}));
  const auto report_start = Envelope(
      35, Join({BytesField(1, session_id), VarintField(2, 1),
                VarintField(3, 123), VarintField(4, 2)}));
  const auto report_chunk = Envelope(
      36, Join({BytesField(1, session_id), VarintField(2, 0),
                BytesField(3, std::vector<std::byte>{std::byte{'a'},
                                                    std::byte{'b'},
                                                    std::byte{'c'}})}));
  const auto report_end = Envelope(37, BytesField(1, session_id));
  const auto report_received = Envelope(38, BytesField(1, session_id));
  const std::vector<std::vector<std::byte>> new_messages{
      receiver_ready, diagnostics_start, diagnostics_end, report_start,
      report_chunk, report_end, report_received};
  for (const auto& message : new_messages) {
    const auto decoded = hearport::wire::DecodeControlEnvelope(message);
    Require(decoded.has_value(), "new diagnostic control message decodes");
    Require(hearport::wire::EncodeControlEnvelope(*decoded) == message,
            "diagnostic control message round-trips byte-for-byte");
  }
  const auto decoded_connect_features =
      hearport::wire::DecodeControlEnvelope(connect_features);
  Require(decoded_connect_features.has_value(), "ConnectRequest features decode");
  Require(hearport::wire::EncodeControlEnvelope(*decoded_connect_features) ==
              connect_features,
          "ConnectRequest features round-trip");
  const auto decoded_ready_features =
      hearport::wire::DecodeControlEnvelope(session_ready_features);
  Require(decoded_ready_features.has_value(), "SessionReady features decode");
  Require(hearport::wire::EncodeControlEnvelope(*decoded_ready_features) ==
              session_ready_features,
          "SessionReady features round-trip");

  const auto invalid_session = Envelope(
      33, Join({BytesField(1, std::span<const std::byte>(session_id).first(15)),
                VarintField(2, 7), VarintField(3, 60)}));
  Require(!hearport::wire::DecodeControlEnvelope(invalid_session).has_value(),
          "session IDs with invalid length are rejected");

  std::vector<std::byte> maximum_chunk(60 * 1024, std::byte{0xa5});
  const auto maximum_chunk_message = Envelope(
      36, Join({BytesField(1, session_id), VarintField(2, 0),
                BytesField(3, maximum_chunk)}));
  const auto decoded_maximum_chunk =
      hearport::wire::DecodeControlEnvelope(maximum_chunk_message);
  Require(decoded_maximum_chunk.has_value(), "60 KiB report chunk is accepted");
  Require(hearport::wire::EncodeControlEnvelope(*decoded_maximum_chunk) ==
              maximum_chunk_message,
          "maximum report chunk round-trips");

  maximum_chunk.push_back(std::byte{0xa5});
  const auto oversized_chunk_message = Envelope(
      36, Join({BytesField(1, session_id), VarintField(2, 0),
                BytesField(3, maximum_chunk)}));
  Require(!hearport::wire::DecodeControlEnvelope(oversized_chunk_message).has_value(),
          "report chunks larger than 60 KiB are rejected");
  return 0;
}
