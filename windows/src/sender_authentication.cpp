#include "hearport/windows/sender_authentication.h"

#include <algorithm>
#include <charconv>
#include <limits>
#include <sstream>
#include <string_view>
#include <utility>

namespace hearport::windows {
namespace {

template <std::size_t N>
std::span<const std::byte> Span(const std::array<std::byte, N>& value) {
  return std::span<const std::byte>(value.data(), value.size());
}

template <std::size_t N>
std::span<std::byte> MutableSpan(std::array<std::byte, N>& value) {
  return std::span<std::byte>(value.data(), value.size());
}

std::uint32_t ReadU32(const std::array<std::byte, 4>& bytes) noexcept {
  return (static_cast<std::uint32_t>(bytes[0]) << 24) |
         (static_cast<std::uint32_t>(bytes[1]) << 16) |
         (static_cast<std::uint32_t>(bytes[2]) << 8) |
         static_cast<std::uint32_t>(bytes[3]);
}

}  // namespace

SenderAuthentication::SenderAuthentication(
    SenderService& service,
    security::Bytes32 windows_spki_sha256,
    ProtectedCredentialStore credential_store,
    std::filesystem::path report_root)
    : service_(service),
      windows_spki_sha256_(windows_spki_sha256),
      credential_store_(std::move(credential_store)),
      report_store_(std::move(report_root)) {}

bool SenderAuthentication::OpenPairingWindow() {
  std::lock_guard lock(mutex_);
  if (!security::Spake2Session::ProviderAvailable() || !ChoosePairingPin()) {
    return false;
  }
  pairing_window_.Open(security::PairingWindow::Clock::now());
  return pairing_pin_ready_ &&
         pairing_window_.IsOpen(security::PairingWindow::Clock::now());
}

std::string SenderAuthentication::pairing_pin() const {
  std::lock_guard lock(mutex_);
  if (!pairing_pin_ready_) return {};
  return std::string(reinterpret_cast<const char*>(pairing_pin_.data()),
                     pairing_pin_.size());
}

bool SenderAuthentication::ChoosePairingPin() {
  std::array<std::byte, 4> random{};
  constexpr std::uint32_t kLimit =
      std::numeric_limits<std::uint32_t>::max() -
      (std::numeric_limits<std::uint32_t>::max() % 1'000'000u);
  do {
    if (!security::RandomBytes(random)) return false;
  } while (ReadU32(random) >= kLimit);

  const auto numeric = ReadU32(random) % 1'000'000u;
  const auto pin_text = std::to_string(numeric);
  const auto first = 6 - pin_text.size();
  for (std::size_t index = 0; index < first; ++index) {
    pairing_pin_[index] = std::byte{'0'};
  }
  for (std::size_t index = 0; index < pin_text.size(); ++index) {
    pairing_pin_[first + index] = std::byte{static_cast<unsigned char>(
        pin_text[index])};
  }
  const auto scalar = security::PinToScalar(Span(pairing_pin_));
  if (!scalar.has_value()) return false;
  pairing_scalar_ = *scalar;
  pairing_pin_ready_ = true;
  return true;
}

bool SenderAuthentication::Send(const wire::ControlEnvelope& envelope) {
  try {
    const auto payload = wire::EncodeControlEnvelope(envelope);
    return service_.SendControlPayload(payload);
  } catch (...) {
    return false;
  }
}

bool SenderAuthentication::Fail(ErrorCode code, std::string_view message) {
  wire::ControlEnvelope error;
  error.type = wire::ControlMessageType::error;
  error.error_code = code;
  error.error_message = std::string(message);
  Send(error);
  return false;
}

bool SenderAuthentication::HandleConnect(
    const wire::ControlEnvelope& envelope) {
  if (flow_ != Flow::idle || authenticated_ ||
      !service_.ReceiveConnect(envelope.auth_mode, envelope.bytes1)) {
    return Fail(ErrorCode::protocol, "unexpected ConnectRequest");
  }
  peer_supports_diagnostics_ =
      (envelope.feature_bits & wire::kFeatureDiagnosticsUpload) != 0;

  if (envelope.auth_mode == AuthMode::remembered) {
    const auto credential = credential_store_.Load();
    if (!credential.has_value() ||
        !security::ConstantTimeEqual(
            Span(credential->windows_spki_sha256),
            Span(windows_spki_sha256_))) {
      return Fail(ErrorCode::auth_failed, "remembered peer is not trusted");
    }
    remembered_verifier_.emplace(*credential);
    const auto nonce = remembered_verifier_->IssueChallenge();
    if (!nonce.has_value()) {
      return Fail(ErrorCode::internal, "unable to create auth challenge");
    }
    wire::ControlEnvelope challenge;
    challenge.type = wire::ControlMessageType::auth_challenge;
    challenge.bytes1.assign(nonce->begin(), nonce->end());
    flow_ = Flow::remembered_challenge;
    return Send(challenge);
  }

  if (!pairing_pin_ready_ ||
      !pairing_window_.IsOpen(security::PairingWindow::Clock::now()) ||
      !security::Spake2Session::ProviderAvailable()) {
    return Fail(ErrorCode::pairing_closed, "pairing window is closed");
  }
  const auto identity_a = security::BuildWindowsIdentity(windows_spki_sha256_);
  const auto identity_b = security::BuildReceiverIdentity();
  spake_session_ = security::Spake2Session::Begin(
      security::Spake2Role::windows_party_a, pairing_scalar_, identity_a,
      identity_b);
  if (!spake_session_.has_value()) {
    return Fail(ErrorCode::auth_failed, "SPAKE2 setup failed");
  }
  remember_pairing_ = envelope.auth_mode == AuthMode::pair;
  wire::ControlEnvelope message;
  message.type = wire::ControlMessageType::pair_spake_a;
  message.bytes1.assign(spake_session_->public_point().begin(),
                        spake_session_->public_point().end());
  flow_ = Flow::pairing_wait_b;
  return Send(message);
}

bool SenderAuthentication::HandlePairSpakeB(
    const wire::ControlEnvelope& envelope) {
  if (flow_ != Flow::pairing_wait_b || !spake_session_.has_value()) {
    return Fail(ErrorCode::protocol, "unexpected PairSpakeB");
  }
  auto result = std::move(*spake_session_).Finish(envelope.bytes1);
  spake_session_.reset();
  if (!result.has_value()) {
    pairing_window_.RecordFailure(security::PairingWindow::Clock::now());
    return Fail(ErrorCode::auth_failed, "invalid SPAKE2 public point");
  }
  wire::ControlEnvelope confirmation;
  confirmation.type = wire::ControlMessageType::pair_confirm_a;
  confirmation.bytes1.assign(result->confirmation().begin(),
                            result->confirmation().end());
  spake_result_ = std::move(*result);
  flow_ = Flow::pairing_wait_confirm_b;
  return Send(confirmation);
}

bool SenderAuthentication::HandlePairConfirmB(
    const wire::ControlEnvelope& envelope) {
  if (flow_ != Flow::pairing_wait_confirm_b || !spake_result_.has_value() ||
      !spake_result_->VerifyPeerConfirmation(envelope.bytes1)) {
    pairing_window_.RecordFailure(security::PairingWindow::Clock::now());
    return Fail(ErrorCode::auth_failed, "SPAKE2 confirmation failed");
  }
  pairing_window_.Close();
  return CompleteAuthentication(remember_pairing_);
}

bool SenderAuthentication::HandleAuthResponse(
    const wire::ControlEnvelope& envelope) {
  if (flow_ != Flow::remembered_challenge || !remembered_verifier_.has_value() ||
      !remembered_verifier_->Verify(envelope.bytes1, envelope.bytes2)) {
    return Fail(ErrorCode::auth_failed, "remembered authentication failed");
  }
  return CompleteAuthentication(false);
}

bool SenderAuthentication::CompleteAuthentication(bool remember) {
  if (remember) {
    security::RememberedCredential credential;
    if (!security::RandomBytes(MutableSpan(credential.peer_id)) ||
        !security::RandomBytes(MutableSpan(credential.pair_secret))) {
      return Fail(ErrorCode::internal, "unable to create remembered credential");
    }
    credential.windows_spki_sha256 = windows_spki_sha256_;
    if (!credential_store_.Save(credential)) {
      return Fail(ErrorCode::internal, "unable to protect remembered credential");
    }
    wire::ControlEnvelope credential_message;
    credential_message.type = wire::ControlMessageType::pair_credential;
    credential_message.bytes1.assign(credential.peer_id.begin(),
                                     credential.peer_id.end());
    credential_message.bytes2.assign(credential.pair_secret.begin(),
                                     credential.pair_secret.end());
    if (!Send(credential_message)) return false;
  }
  if (!service_.MarkAuthenticated()) {
    return Fail(ErrorCode::protocol, "session authentication state rejected");
  }
  if (service_.debug_duration().has_value() && !peer_supports_diagnostics_) {
    service_.LogDiagnostic("debug_session_refused receiver_feature_missing=1");
    return Fail(ErrorCode::protocol,
                "Update HearPort on iPad to use timed diagnostics.");
  }
  wire::ControlEnvelope ready;
  ready.type = wire::ControlMessageType::session_ready;
  ready.feature_bits = peer_supports_diagnostics_
                           ? wire::kFeatureDiagnosticsUpload
                           : 0;
  if (!Send(ready)) return false;
  authenticated_ = true;
  if (peer_supports_diagnostics_) {
    flow_ = Flow::waiting_receiver_ready;
    return true;
  }
  return StartMediaStream();
}

bool SenderAuthentication::HandleReceiverReady() {
  if (flow_ == Flow::debug_complete) return true;
  if (flow_ != Flow::waiting_receiver_ready) {
    return Fail(ErrorCode::protocol, "unexpected ReceiverReady");
  }
  return StartMediaStream(service_.debug_duration().has_value());
}

bool SenderAuthentication::StartMediaStream(bool diagnostic) {
  std::array<std::byte, 4> random{};
  if (!security::RandomBytes(random)) return false;
  stream_id_ = ReadU32(random);
  if (stream_id_ == 0) stream_id_ = 1;
  if (diagnostic) {
    if (!security::RandomBytes(MutableSpan(debug_session_id_))) return false;
    if (!service_.BeginStream(stream_id_, Span(debug_session_id_))) return false;
    const auto duration = service_.debug_duration();
    if (!duration.has_value()) return false;
    wire::ControlEnvelope diagnostics_start;
    diagnostics_start.type = wire::ControlMessageType::diagnostics_start;
    diagnostics_start.bytes1.assign(debug_session_id_.begin(),
                                    debug_session_id_.end());
    diagnostics_start.stream_id = stream_id_;
    diagnostics_start.duration_seconds =
        static_cast<std::uint32_t>(duration->count());
    if (!Send(diagnostics_start)) return false;
  } else if (!service_.BeginStream(stream_id_)) {
    return false;
  }
  wire::ControlEnvelope start;
  start.type = wire::ControlMessageType::start_stream;
  start.stream_id = stream_id_;
  flow_ = diagnostic ? Flow::debug_stream_ack : Flow::stream_ack;
  return Send(start);
}

bool SenderAuthentication::HandleReportStart(
    const wire::ControlEnvelope& envelope) {
  if (report_upload_active_ ||
      (flow_ != Flow::waiting_receiver_ready &&
       flow_ != Flow::awaiting_debug_report)) {
    return Fail(ErrorCode::protocol, "unexpected diagnostic report start");
  }
  const auto result = report_store_.Begin(
      envelope.bytes1, envelope.format_version, envelope.total_bytes,
      envelope.chunk_count);
  if (result == DebugReportBeginResult::rejected) {
    return Fail(ErrorCode::protocol, "invalid diagnostic report metadata");
  }
  std::copy(envelope.bytes1.begin(), envelope.bytes1.end(),
            report_upload_session_id_.begin());
  report_upload_active_ = true;
  return true;
}

bool SenderAuthentication::HandleReportChunk(
    const wire::ControlEnvelope& envelope) {
  if (!report_upload_active_ || envelope.bytes1.size() !=
                                    report_upload_session_id_.size() ||
      !std::equal(envelope.bytes1.begin(), envelope.bytes1.end(),
                  report_upload_session_id_.begin()) ||
      !report_store_.WriteChunk(envelope.bytes1, envelope.chunk_index,
                                envelope.bytes2)) {
    return Fail(ErrorCode::protocol, "invalid diagnostic report chunk");
  }
  return true;
}

bool SenderAuthentication::HandleReportEnd(
    const wire::ControlEnvelope& envelope) {
  if (!report_upload_active_ || envelope.bytes1.size() !=
                                    report_upload_session_id_.size() ||
      !std::equal(envelope.bytes1.begin(), envelope.bytes1.end(),
                  report_upload_session_id_.begin()) ||
      !report_store_.Commit(envelope.bytes1)) {
    return Fail(ErrorCode::protocol, "incomplete diagnostic report");
  }

  const bool completing_debug =
      flow_ == Flow::awaiting_debug_report &&
      envelope.bytes1.size() == debug_session_id_.size() &&
      std::equal(envelope.bytes1.begin(), envelope.bytes1.end(),
                 debug_session_id_.begin());
  const auto report_directory = report_store_.SessionDirectory(envelope.bytes1);
  wire::ControlEnvelope received;
  received.type = wire::ControlMessageType::diagnostics_report_received;
  received.bytes1 = envelope.bytes1;
  report_upload_active_ = false;
  report_upload_session_id_.fill(std::byte{0});
  if (completing_debug) flow_ = Flow::debug_complete;
  std::ostringstream message;
  message << "ipad_diagnostic_report_committed path="
          << report_directory.string();
  service_.LogDiagnostic(message.str());
  if (!Send(received)) return false;
  if (completing_debug) {
    service_.MarkDebugReportCommitted(envelope.bytes1);
  }
  return true;
}

void SenderAuthentication::OnDebugSessionEnded(
    std::array<std::byte, 16> session_id, std::uint32_t reason) {
  std::lock_guard lock(mutex_);
  if (flow_ != Flow::debug_stream_active || session_id != debug_session_id_) {
    service_.LogDiagnostic("debug_session_end_control_skipped state_mismatch=1");
    return;
  }
  wire::ControlEnvelope end;
  end.type = wire::ControlMessageType::diagnostics_end;
  end.bytes1.assign(session_id.begin(), session_id.end());
  end.reason = reason;
  flow_ = Flow::awaiting_debug_report;
  if (!Send(end)) {
    service_.LogDiagnostic("debug_session_end_control_failed");
  }
}

bool SenderAuthentication::HandleControlPayload(
    std::span<const std::byte> payload) {
  std::lock_guard lock(mutex_);
  const auto envelope = wire::DecodeControlEnvelope(payload);
  if (!envelope.has_value()) {
    return Fail(ErrorCode::protocol, "malformed control envelope");
  }
  switch (envelope->type) {
    case wire::ControlMessageType::connect_request:
      return HandleConnect(*envelope);
    case wire::ControlMessageType::pair_spake_b:
      return HandlePairSpakeB(*envelope);
    case wire::ControlMessageType::pair_confirm_b:
      return HandlePairConfirmB(*envelope);
    case wire::ControlMessageType::auth_response:
      return HandleAuthResponse(*envelope);
    case wire::ControlMessageType::receiver_ready:
      return HandleReceiverReady();
    case wire::ControlMessageType::diagnostics_report_start:
      return HandleReportStart(*envelope);
    case wire::ControlMessageType::diagnostics_report_chunk:
      return HandleReportChunk(*envelope);
    case wire::ControlMessageType::diagnostics_report_end:
      return HandleReportEnd(*envelope);
    case wire::ControlMessageType::start_stream_ack:
      if ((flow_ != Flow::stream_ack && flow_ != Flow::debug_stream_ack) ||
          !service_.MarkStartStreamAckWritten(envelope->stream_id)) {
        return Fail(ErrorCode::stream_state, "unexpected StartStreamAck");
      }
      flow_ = flow_ == Flow::debug_stream_ack
                  ? Flow::debug_stream_active
                  : Flow::idle;
      return true;
    default:
      return Fail(ErrorCode::protocol, "unexpected control message");
  }
}

void SenderAuthentication::OnCaptureReset() {
  std::lock_guard lock(mutex_);
  if (authenticated_ && flow_ == Flow::idle) {
    (void)StartMediaStream();
  }
}

void SenderAuthentication::Reset() noexcept {
  std::lock_guard lock(mutex_);
  if (report_upload_active_) {
    report_store_.Abort(report_upload_session_id_);
  }
  flow_ = Flow::idle;
  authenticated_ = false;
  remember_pairing_ = false;
  peer_supports_diagnostics_ = false;
  report_upload_active_ = false;
  report_upload_session_id_.fill(std::byte{0});
  debug_session_id_.fill(std::byte{0});
  spake_session_.reset();
  spake_result_.reset();
  remembered_verifier_.reset();
  stream_id_ = 0;
}

}  // namespace hearport::windows
