#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "hearport/control_messages.h"

namespace hearport::wire {

enum class ControlMessageType : std::uint8_t {
  connect_request,
  session_ready,
  error,
  pair_spake_a,
  pair_spake_b,
  pair_confirm_a,
  pair_confirm_b,
  pair_credential,
  auth_challenge,
  auth_response,
  start_stream,
  start_stream_ack,
  receiver_ready,
  diagnostics_start,
  diagnostics_end,
  diagnostics_report_start,
  diagnostics_report_chunk,
  diagnostics_report_end,
  diagnostics_report_received,
};

inline constexpr std::uint32_t kFeatureDiagnosticsUpload = 1u;
inline constexpr std::size_t kDiagnosticReportChunkMaxBytes = 60u * 1024u;

// This is the small, schema-shaped value used at the platform boundary. The
// bytes fields map to the bytes fields of the canonical ControlEnvelope; the
// codec rejects a field layout that is not valid for the selected oneof case.
struct ControlEnvelope {
  ControlMessageType type = ControlMessageType::session_ready;
  AuthMode auth_mode = AuthMode::unspecified;
  ErrorCode error_code = ErrorCode::unspecified;
  std::string error_message;
  std::vector<std::byte> bytes1;
  std::vector<std::byte> bytes2;
  std::uint32_t stream_id = 0;
  std::uint32_t feature_bits = 0;
  std::uint32_t duration_seconds = 0;
  std::uint32_t reason = 0;
  std::uint32_t format_version = 0;
  std::uint32_t total_bytes = 0;
  std::uint32_t chunk_count = 0;
  std::uint32_t chunk_index = 0;
};

std::vector<std::byte> EncodeControlEnvelope(const ControlEnvelope& envelope);
std::optional<ControlEnvelope> DecodeControlEnvelope(
    std::span<const std::byte> payload) noexcept;

}  // namespace hearport::wire
