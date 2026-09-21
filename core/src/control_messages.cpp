#include "hearport/control_messages.h"

namespace hearport {

bool IsValidAuthMode(AuthMode mode) noexcept {
  return mode == AuthMode::remembered || mode == AuthMode::pair ||
         mode == AuthMode::one_time;
}

bool IsValidErrorCode(ErrorCode code) noexcept {
  return code == ErrorCode::protocol ||
         code == ErrorCode::datagram_unsupported ||
         code == ErrorCode::auth_failed || code == ErrorCode::pairing_closed ||
         code == ErrorCode::stream_state ||
         code == ErrorCode::audio_unavailable || code == ErrorCode::internal;
}

bool ValidateConnectRequest(AuthMode mode,
                            std::span<const std::byte> peer_id) noexcept {
  if (!IsValidAuthMode(mode)) {
    return false;
  }
  if (mode == AuthMode::remembered) {
    return peer_id.size() == 16;
  }
  return peer_id.empty();
}

}  // namespace hearport
