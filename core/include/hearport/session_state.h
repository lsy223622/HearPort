#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

#include "hearport/control_messages.h"
#include "hearport/wire/audio_datagram.h"

namespace hearport {

enum class SessionPhase {
  awaiting_connect,
  authenticating,
  ready,
  pending_stream,
  active,
  closed,
};

enum class AudioDisposition {
  accepted,
  pending_audio_discarded,
  old_stream_discarded,
  protocol_error,
};

class SessionState {
 public:
  void Reset() noexcept;
  bool ReceiveConnect(AuthMode mode,
                      std::span<const std::byte> peer_id) noexcept;
  bool MarkAuthenticated() noexcept;
  bool BeginStream(std::uint32_t stream_id) noexcept;
  AudioDisposition AckWritten(std::uint32_t stream_id) noexcept;
  bool EndStream(std::uint32_t stream_id) noexcept;
  AudioDisposition AcceptAudio(const wire::AudioDatagram& packet) const noexcept;
  bool ResetStream(std::uint32_t stream_id) noexcept;

  SessionPhase phase() const noexcept { return phase_; }
  AuthMode auth_mode() const noexcept { return auth_mode_; }
  std::optional<std::uint32_t> pending_stream_id() const noexcept {
    return pending_stream_id_;
  }
  std::optional<std::uint32_t> active_stream_id() const noexcept {
    return active_stream_id_;
  }

 private:
  SessionPhase phase_ = SessionPhase::awaiting_connect;
  AuthMode auth_mode_ = AuthMode::unspecified;
  std::optional<std::uint32_t> pending_stream_id_;
  std::optional<std::uint32_t> active_stream_id_;
};

}  // namespace hearport
