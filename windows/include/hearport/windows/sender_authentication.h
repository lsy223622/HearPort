#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <mutex>

#include "hearport/security/pairing.h"
#include "hearport/security/remembered_auth.h"
#include "hearport/wire/control_message.h"
#include "hearport/windows/credential_store.h"
#include "hearport/windows/debug_report_store.h"
#include "hearport/windows/sender_service.h"

namespace hearport::windows {

class SenderAuthentication {
 public:
  SenderAuthentication(SenderService& service,
                       security::Bytes32 windows_spki_sha256,
                       ProtectedCredentialStore credential_store = {},
                       std::filesystem::path report_root =
                           "HearPort-diagnostics");

  SenderAuthentication(const SenderAuthentication&) = delete;
  SenderAuthentication& operator=(const SenderAuthentication&) = delete;

  // Pairing is intentionally closed until the local user explicitly opens it.
  // The returned PIN is for the host UI to display and is never persisted.
  bool OpenPairingWindow();
  std::string pairing_pin() const;

  bool HandleControlPayload(std::span<const std::byte> payload);
  void OnDebugSessionEnded(std::array<std::byte, 16> session_id,
                           std::uint32_t reason);
  void OnCaptureReset();
  void Reset() noexcept;

 private:
  enum class Flow {
    idle,
    remembered_challenge,
    pairing_wait_b,
    pairing_wait_confirm_b,
    waiting_receiver_ready,
    stream_ack,
    debug_stream_ack,
    debug_stream_active,
    awaiting_debug_report,
    debug_complete,
  };

  bool Send(const wire::ControlEnvelope& envelope);
  bool Fail(ErrorCode code, std::string_view message);
  bool HandleConnect(const wire::ControlEnvelope& envelope);
  bool HandlePairSpakeB(const wire::ControlEnvelope& envelope);
  bool HandlePairConfirmB(const wire::ControlEnvelope& envelope);
  bool HandleAuthResponse(const wire::ControlEnvelope& envelope);
  bool CompleteAuthentication(bool remember);
  bool HandleReceiverReady();
  bool HandleReportStart(const wire::ControlEnvelope& envelope);
  bool HandleReportChunk(const wire::ControlEnvelope& envelope);
  bool HandleReportEnd(const wire::ControlEnvelope& envelope);
  bool StartMediaStream(bool diagnostic = false);
  bool ChoosePairingPin();

  SenderService& service_;
  mutable std::mutex mutex_;
  security::Bytes32 windows_spki_sha256_{};
  ProtectedCredentialStore credential_store_;
  DebugReportStore report_store_;
  security::PairingWindow pairing_window_;
  std::array<std::byte, security::kPairingPinBytes> pairing_pin_{};
  security::Bytes32 pairing_scalar_{};
  bool pairing_pin_ready_ = false;
  bool authenticated_ = false;
  bool remember_pairing_ = false;
  bool peer_supports_diagnostics_ = false;
  bool report_upload_active_ = false;
  std::array<std::byte, 16> report_upload_session_id_{};
  std::array<std::byte, 16> debug_session_id_{};
  Flow flow_ = Flow::idle;
  std::optional<security::Spake2Session> spake_session_;
  std::optional<security::Spake2Result> spake_result_;
  std::optional<security::RememberedAuthVerifier> remembered_verifier_;
  std::uint32_t stream_id_ = 0;
};

}  // namespace hearport::windows
