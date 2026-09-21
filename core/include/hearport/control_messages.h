#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace hearport {

enum class AuthMode : std::uint8_t {
  unspecified = 0,
  remembered = 1,
  pair = 2,
  one_time = 3,
};

enum class ErrorCode : std::uint8_t {
  unspecified = 0,
  protocol = 1,
  datagram_unsupported = 2,
  auth_failed = 3,
  pairing_closed = 4,
  stream_state = 5,
  audio_unavailable = 6,
  internal = 7,
};

bool IsValidAuthMode(AuthMode mode) noexcept;
bool IsValidErrorCode(ErrorCode code) noexcept;
bool ValidateConnectRequest(AuthMode mode,
                            std::span<const std::byte> peer_id) noexcept;

}  // namespace hearport
