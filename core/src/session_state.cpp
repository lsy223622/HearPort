#include "hearport/session_state.h"

namespace hearport {

bool SessionState::ReceiveConnect(AuthMode mode,
                                  std::span<const std::byte> peer_id) noexcept {
  if (phase_ != SessionPhase::awaiting_connect ||
      !ValidateConnectRequest(mode, peer_id)) {
    phase_ = SessionPhase::closed;
    return false;
  }
  auth_mode_ = mode;
  phase_ = SessionPhase::authenticating;
  return true;
}

bool SessionState::MarkAuthenticated() noexcept {
  if (phase_ != SessionPhase::authenticating) {
    return false;
  }
  phase_ = SessionPhase::ready;
  return true;
}

bool SessionState::BeginStream(std::uint32_t stream_id) noexcept {
  if (stream_id == 0 ||
      (phase_ != SessionPhase::ready && phase_ != SessionPhase::active)) {
    return false;
  }
  pending_stream_id_ = stream_id;
  active_stream_id_.reset();
  phase_ = SessionPhase::pending_stream;
  return true;
}

AudioDisposition SessionState::AckWritten(std::uint32_t stream_id) noexcept {
  if (phase_ != SessionPhase::pending_stream ||
      pending_stream_id_.value_or(0) != stream_id || stream_id == 0) {
    return AudioDisposition::protocol_error;
  }
  active_stream_id_ = stream_id;
  pending_stream_id_.reset();
  phase_ = SessionPhase::active;
  return AudioDisposition::accepted;
}

AudioDisposition SessionState::AcceptAudio(
    const wire::AudioDatagram& packet) const noexcept {
  if (phase_ == SessionPhase::pending_stream) {
    return AudioDisposition::pending_audio_discarded;
  }
  if (phase_ == SessionPhase::active &&
      active_stream_id_.value_or(0) == packet.stream_id) {
    return AudioDisposition::accepted;
  }
  return AudioDisposition::old_stream_discarded;
}

bool SessionState::ResetStream(std::uint32_t stream_id) noexcept {
  return BeginStream(stream_id);
}

}  // namespace hearport
