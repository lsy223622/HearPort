#include "hearport/wire/control_message.h"
#include "hearport/wire/control_framing.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace hearport::wire {
namespace {

constexpr std::size_t kMaxPayload = kControlMessageMaxBytes;

std::uint8_t ByteValue(std::byte value) noexcept {
  return std::to_integer<std::uint8_t>(value);
}

void AppendVarint(std::uint32_t value, std::vector<std::byte>& output) {
  while (value >= 0x80u) {
    output.push_back(std::byte{static_cast<unsigned char>(value | 0x80u)});
    value >>= 7;
  }
  output.push_back(std::byte{static_cast<unsigned char>(value)});
}

void AppendTag(std::uint32_t field,
               std::uint8_t wire_type,
               std::vector<std::byte>& output) {
  AppendVarint((field << 3) | wire_type, output);
}

void AppendBytes(std::uint32_t field,
                 std::span<const std::byte> value,
                 std::vector<std::byte>& output) {
  AppendTag(field, 2, output);
  if (value.size() > std::numeric_limits<std::uint32_t>::max()) {
    throw std::invalid_argument("protobuf bytes field is too large");
  }
  AppendVarint(static_cast<std::uint32_t>(value.size()), output);
  output.insert(output.end(), value.begin(), value.end());
}

void AppendString(std::uint32_t field,
                  const std::string& value,
                  std::vector<std::byte>& output) {
  AppendBytes(field,
              std::span<const std::byte>(
                  reinterpret_cast<const std::byte*>(value.data()),
                  value.size()),
              output);
}

class Reader {
 public:
  explicit Reader(std::span<const std::byte> bytes) : bytes_(bytes) {}

  bool ReadVarint(std::uint32_t& value) noexcept {
    value = 0;
    for (std::size_t index = 0; index < 5; ++index) {
      if (offset_ == bytes_.size()) {
        return false;
      }
      const auto byte = ByteValue(bytes_[offset_++]);
      if (index == 4 && byte > 0x0fu) {
        return false;
      }
      value |= static_cast<std::uint32_t>(byte & 0x7fu) << (index * 7);
      if ((byte & 0x80u) == 0) {
        return true;
      }
    }
    return false;
  }

  bool ReadTag(std::uint32_t& field, std::uint8_t& wire_type) noexcept {
    std::uint32_t tag = 0;
    if (!ReadVarint(tag) || tag == 0 || (tag >> 3) == 0 ||
        (tag >> 3) > 0x1fffffff) {
      return false;
    }
    field = tag >> 3;
    wire_type = static_cast<std::uint8_t>(tag & 0x07u);
    return wire_type <= 5;
  }

  bool Skip(std::uint8_t wire_type) noexcept {
    switch (wire_type) {
      case 0: {
        std::uint32_t value = 0;
        return ReadVarint(value);
      }
      case 1:
        if (bytes_.size() - offset_ < 8) return false;
        offset_ += 8;
        return true;
      case 2: {
        std::vector<std::byte> ignored;
        return ReadBytes(ignored);
      }
      case 3:
        for (;;) {
          if (AtEnd()) return false;
          std::uint32_t field = 0;
          std::uint8_t nested_wire_type = 0;
          if (!ReadTag(field, nested_wire_type)) return false;
          if (nested_wire_type == 4) return true;
          if (!Skip(nested_wire_type)) return false;
        }
      case 5:
        if (bytes_.size() - offset_ < 4) return false;
        offset_ += 4;
        return true;
      default:
        return false;
    }
  }

  bool ReadBytes(std::vector<std::byte>& value) noexcept {
    std::uint32_t length = 0;
    if (!ReadVarint(length) || length > kMaxPayload ||
        length > bytes_.size() - offset_) {
      return false;
    }
    value.assign(bytes_.begin() + static_cast<std::ptrdiff_t>(offset_),
                 bytes_.begin() +
                     static_cast<std::ptrdiff_t>(offset_ + length));
    offset_ += length;
    return true;
  }

  bool ReadString(std::string& value) noexcept {
    std::vector<std::byte> bytes;
    if (!ReadBytes(bytes)) {
      return false;
    }
    value.resize(bytes.size());
    std::transform(bytes.begin(), bytes.end(), value.begin(), ByteValue);
    return true;
  }

  bool AtEnd() const noexcept { return offset_ == bytes_.size(); }

 private:
  std::span<const std::byte> bytes_;
  std::size_t offset_ = 0;
};

bool ExactLength(const std::vector<std::byte>& value, std::size_t length) {
  return value.size() == length;
}

bool ValidateEnvelope(const ControlEnvelope& envelope) noexcept {
  switch (envelope.type) {
    case ControlMessageType::connect_request:
      return IsValidAuthMode(envelope.auth_mode) &&
             ((envelope.auth_mode == AuthMode::remembered &&
               ExactLength(envelope.bytes1, 16)) ||
              (envelope.auth_mode != AuthMode::remembered &&
               envelope.bytes1.empty())) &&
             envelope.bytes2.empty() && envelope.error_message.empty() &&
             envelope.stream_id == 0;
    case ControlMessageType::session_ready:
      return envelope.auth_mode == AuthMode::unspecified &&
             envelope.error_code == ErrorCode::unspecified &&
             envelope.error_message.empty() && envelope.bytes1.empty() &&
             envelope.bytes2.empty() && envelope.stream_id == 0;
    case ControlMessageType::error:
      return IsValidErrorCode(envelope.error_code) &&
             envelope.auth_mode == AuthMode::unspecified &&
             envelope.bytes1.empty() && envelope.bytes2.empty() &&
             envelope.stream_id == 0;
    case ControlMessageType::pair_spake_a:
    case ControlMessageType::pair_spake_b:
      return ExactLength(envelope.bytes1, 65) && envelope.bytes2.empty() &&
             envelope.stream_id == 0;
    case ControlMessageType::pair_confirm_a:
    case ControlMessageType::pair_confirm_b:
      return ExactLength(envelope.bytes1, 32) && envelope.bytes2.empty() &&
             envelope.stream_id == 0;
    case ControlMessageType::pair_credential:
      return ExactLength(envelope.bytes1, 16) &&
             ExactLength(envelope.bytes2, 32) && envelope.stream_id == 0;
    case ControlMessageType::auth_challenge:
      return ExactLength(envelope.bytes1, 32) && envelope.bytes2.empty() &&
             envelope.stream_id == 0;
    case ControlMessageType::auth_response:
      return ExactLength(envelope.bytes1, 16) &&
             ExactLength(envelope.bytes2, 32) && envelope.stream_id == 0;
    case ControlMessageType::start_stream:
    case ControlMessageType::start_stream_ack:
      return envelope.stream_id != 0 && envelope.auth_mode == AuthMode::unspecified &&
             envelope.error_code == ErrorCode::unspecified &&
             envelope.error_message.empty() && envelope.bytes1.empty() &&
             envelope.bytes2.empty();
  }
  return false;
}

bool ParseConnect(std::span<const std::byte> bytes,
                  ControlEnvelope& envelope) noexcept {
  Reader reader(bytes);
  bool auth_seen = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return false;
    if (field == 1 && wire_type == 0) {
      std::uint32_t value = 0;
      if (!reader.ReadVarint(value)) return false;
      envelope.auth_mode = value <= 3 ? static_cast<AuthMode>(value)
                                      : AuthMode::unspecified;
      auth_seen = true;
    } else if (field == 2 && wire_type == 2) {
      if (!reader.ReadBytes(envelope.bytes1)) return false;
    } else if (!reader.Skip(wire_type)) {
      return false;
    }
  }
  return auth_seen;
}

bool ParseError(std::span<const std::byte> bytes,
                ControlEnvelope& envelope) noexcept {
  Reader reader(bytes);
  bool code_seen = false;
  bool message_seen = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return false;
    if (field == 1 && wire_type == 0) {
      std::uint32_t value = 0;
      if (!reader.ReadVarint(value)) return false;
      envelope.error_code = value <= 7 ? static_cast<ErrorCode>(value)
                                       : ErrorCode::unspecified;
      code_seen = true;
    } else if (field == 2 && wire_type == 2) {
      if (!reader.ReadString(envelope.error_message)) return false;
      message_seen = true;
    } else if (!reader.Skip(wire_type)) {
      return false;
    }
  }
  return code_seen;
}

bool ParseBytes1(std::span<const std::byte> bytes,
                 ControlEnvelope& envelope) noexcept {
  Reader reader(bytes);
  bool value_seen = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return false;
    if (field == 1 && wire_type == 2) {
      if (!reader.ReadBytes(envelope.bytes1)) return false;
      value_seen = true;
    } else if (!reader.Skip(wire_type)) {
      return false;
    }
  }
  return value_seen;
}

bool ParseCredential(std::span<const std::byte> bytes,
                     ControlEnvelope& envelope) noexcept {
  Reader reader(bytes);
  bool first_seen = false;
  bool second_seen = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return false;
    if (field == 1 && wire_type == 2) {
      if (!reader.ReadBytes(envelope.bytes1)) return false;
      first_seen = true;
    } else if (field == 2 && wire_type == 2) {
      if (!reader.ReadBytes(envelope.bytes2)) return false;
      second_seen = true;
    } else if (!reader.Skip(wire_type)) {
      return false;
    }
  }
  return first_seen && second_seen;
}

bool ParseStream(std::span<const std::byte> bytes,
                 ControlEnvelope& envelope) noexcept {
  Reader reader(bytes);
  bool value_seen = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return false;
    if (field == 1 && wire_type == 0) {
      if (!reader.ReadVarint(envelope.stream_id)) return false;
      value_seen = true;
    } else if (!reader.Skip(wire_type)) {
      return false;
    }
  }
  return value_seen;
}

}  // namespace

std::vector<std::byte> EncodeControlEnvelope(const ControlEnvelope& envelope) {
  if (!ValidateEnvelope(envelope)) {
    throw std::invalid_argument("invalid HearPort control envelope");
  }
  std::vector<std::byte> submessage;
  switch (envelope.type) {
    case ControlMessageType::connect_request:
      AppendTag(1, 0, submessage);
      AppendVarint(static_cast<std::uint32_t>(envelope.auth_mode), submessage);
      if (!envelope.bytes1.empty()) AppendBytes(2, envelope.bytes1, submessage);
      break;
    case ControlMessageType::session_ready:
      break;
    case ControlMessageType::error:
      AppendTag(1, 0, submessage);
      AppendVarint(static_cast<std::uint32_t>(envelope.error_code), submessage);
      if (!envelope.error_message.empty())
        AppendString(2, envelope.error_message, submessage);
      break;
    case ControlMessageType::pair_spake_a:
    case ControlMessageType::pair_spake_b:
    case ControlMessageType::pair_confirm_a:
    case ControlMessageType::pair_confirm_b:
    case ControlMessageType::auth_challenge:
      AppendBytes(1, envelope.bytes1, submessage);
      break;
    case ControlMessageType::pair_credential:
      AppendBytes(1, envelope.bytes1, submessage);
      AppendBytes(2, envelope.bytes2, submessage);
      break;
    case ControlMessageType::auth_response:
      AppendBytes(1, envelope.bytes1, submessage);
      AppendBytes(2, envelope.bytes2, submessage);
      break;
    case ControlMessageType::start_stream:
    case ControlMessageType::start_stream_ack:
      AppendTag(1, 0, submessage);
      AppendVarint(envelope.stream_id, submessage);
      break;
  }

  const std::uint32_t envelope_field = [&] {
    switch (envelope.type) {
      case ControlMessageType::connect_request: return 1u;
      case ControlMessageType::session_ready: return 2u;
      case ControlMessageType::error: return 3u;
      case ControlMessageType::pair_spake_a: return 10u;
      case ControlMessageType::pair_spake_b: return 11u;
      case ControlMessageType::pair_confirm_a: return 12u;
      case ControlMessageType::pair_confirm_b: return 13u;
      case ControlMessageType::pair_credential: return 14u;
      case ControlMessageType::auth_challenge: return 20u;
      case ControlMessageType::auth_response: return 21u;
      case ControlMessageType::start_stream: return 30u;
      case ControlMessageType::start_stream_ack: return 31u;
    }
    return 0u;
  }();

  std::vector<std::byte> output;
  AppendBytes(envelope_field, submessage, output);
  if (output.size() > kMaxPayload) {
    throw std::invalid_argument("serialized control envelope is too large");
  }
  return output;
}

std::optional<ControlEnvelope> DecodeControlEnvelope(
    std::span<const std::byte> payload) noexcept {
  if (payload.empty() || payload.size() > kMaxPayload) return std::nullopt;
  Reader reader(payload);
  std::uint32_t selected_field = 0;
  std::vector<std::byte> selected_submessage;
  bool found = false;
  while (!reader.AtEnd()) {
    std::uint32_t field = 0;
    std::uint8_t wire_type = 0;
    if (!reader.ReadTag(field, wire_type)) return std::nullopt;
    const bool known_field =
        field == 1 || field == 2 || field == 3 || field == 10 ||
        field == 11 || field == 12 || field == 13 || field == 14 ||
        field == 20 || field == 21 || field == 30 || field == 31;
    if (!known_field || wire_type != 2) {
      if (!reader.Skip(wire_type)) return std::nullopt;
      continue;
    }
    if (!reader.ReadBytes(selected_submessage)) return std::nullopt;
    selected_field = field;
    found = true;
  }

  if (!found) return std::nullopt;
  ControlEnvelope envelope;
  bool parsed = false;
  switch (selected_field) {
    case 1:
      envelope.type = ControlMessageType::connect_request;
      parsed = ParseConnect(selected_submessage, envelope);
      break;
    case 2:
      envelope.type = ControlMessageType::session_ready;
      {
        Reader nested(selected_submessage);
        parsed = true;
        while (!nested.AtEnd()) {
          std::uint32_t nested_field = 0;
          std::uint8_t nested_wire_type = 0;
          if (!nested.ReadTag(nested_field, nested_wire_type) ||
              !nested.Skip(nested_wire_type)) {
            parsed = false;
            break;
          }
        }
      }
      break;
    case 3:
      envelope.type = ControlMessageType::error;
      parsed = ParseError(selected_submessage, envelope);
      break;
    case 10:
      envelope.type = ControlMessageType::pair_spake_a;
      parsed = ParseBytes1(selected_submessage, envelope);
      break;
    case 11:
      envelope.type = ControlMessageType::pair_spake_b;
      parsed = ParseBytes1(selected_submessage, envelope);
      break;
    case 12:
      envelope.type = ControlMessageType::pair_confirm_a;
      parsed = ParseBytes1(selected_submessage, envelope);
      break;
    case 13:
      envelope.type = ControlMessageType::pair_confirm_b;
      parsed = ParseBytes1(selected_submessage, envelope);
      break;
    case 14:
      envelope.type = ControlMessageType::pair_credential;
      parsed = ParseCredential(selected_submessage, envelope);
      break;
    case 20:
      envelope.type = ControlMessageType::auth_challenge;
      parsed = ParseBytes1(selected_submessage, envelope);
      break;
    case 21:
      envelope.type = ControlMessageType::auth_response;
      parsed = ParseCredential(selected_submessage, envelope);
      break;
    case 30:
      envelope.type = ControlMessageType::start_stream;
      parsed = ParseStream(selected_submessage, envelope);
      break;
    case 31:
      envelope.type = ControlMessageType::start_stream_ack;
      parsed = ParseStream(selected_submessage, envelope);
      break;
  }
  return parsed && ValidateEnvelope(envelope)
             ? std::optional{std::move(envelope)}
             : std::nullopt;
}

}  // namespace hearport::wire
