#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
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

struct SenderPairingState {
  mutable std::mutex mutex;
  security::PairingWindow window;
  std::array<std::byte, security::kPairingPinBytes> pin{};
  security::Bytes32 scalar{};
  bool ready = false;
  std::uint64_t epoch = 0;
};

class SenderAuthentication {
 public:
  SenderAuthentication(SenderService& service,
                       security::Bytes32 windows_spki_sha256,
                       ProtectedCredentialStore credential_store = {},
                       std::filesystem::path report_root =
                           "HearPort-diagnostics",
                       std::shared_ptr<SenderPairingState> pairing = {});

  SenderAuthentication(const SenderAuthentication&) = delete;
  SenderAuthentication& operator=(const SenderAuthentication&) = delete;

  // Pairing is intentionally closed until the local user explicitly opens it.
  // The returned PIN is for the host UI to display and is never persisted.
  bool OpenPairingWindow();
  std::string pairing_pin() const;
  void SetConnectionHandler(std::function<void(bool, bool)> handler);
  void SetCalibrationRequestHandler(std::function<void(CalibrationOptions)> handler);

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
  std::shared_ptr<SenderPairingState> pairing_;
  std::uint64_t pairing_epoch_ = 0;
  std::string peer_identity_;
  bool authenticated_ = false;
  std::function<void(bool, bool)> connection_handler_;
  std::function<void(CalibrationOptions)> calibration_request_handler_;
  bool calibration_request_pending_ = false;
  bool remember_pairing_ = false;
  bool peer_supports_diagnostics_ = false;
  bool peer_supports_network_probe_ = false;
  bool peer_wants_reliable_ = false;
  bool peer_coordinated_audio_ = false;
  bool peer_supports_music_test_ = false;
  bool peer_supports_compression_ = false;
  bool peer_supports_live_compression_ = false;
  bool peer_supports_calibration_ = false;
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
