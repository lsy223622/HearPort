#include <array>
#include <cassert>
#include <cstddef>
#include <iostream>
#include <string>
#include <string_view>

#include "hearport/windows/debug_session_trace.h"
#include "hearport/wire/audio_datagram.h"

#undef assert
#define assert(condition)                                      \
  do {                                                          \
    if (!(condition)) {                                         \
      std::cerr << "assertion failed: " #condition << '\n';      \
      return 1;                                                  \
    }                                                           \
  } while (false)

using hearport::windows::DebugSendState;
using hearport::windows::DebugSessionTrace;

int main() {
  const std::array<std::byte, 16> session_id = {
      std::byte{0x01}, std::byte{0x02}, std::byte{0x03}, std::byte{0x04},
      std::byte{0x05}, std::byte{0x06}, std::byte{0x07}, std::byte{0x08},
      std::byte{0x09}, std::byte{0x0a}, std::byte{0x0b}, std::byte{0x0c},
      std::byte{0x0d}, std::byte{0x0e}, std::byte{0x0f}, std::byte{0x10}};
  DebugSessionTrace trace(2);
  assert(trace.Begin(session_id, 77));
  assert(trace.RecordPacket(0, 100, 110, 120, true));
  assert(!trace.RecordSendState(77, 0, DebugSendState::sent, 130));
  assert(trace.RecordSendState(77, 0, DebugSendState::acknowledged, 140));
  assert(trace.RecordPacket(1, 200, 210, 220, false));
  assert(!trace.RecordPacket(2, 300, 310, 320, false));
  assert(trace.dropped_records() == 1);

  const auto report = trace.Finish("duration_expired");
  assert(report.find("\"session_id\":\"0102030405060708090a0b0c0d0e0f10\"") !=
         std::string::npos);
  assert(report.find("\"stream_id\":77") != std::string::npos);
  assert(report.find("\"sequence\":0") != std::string::npos);
  assert(report.find("\"captured_at_ns\":100") != std::string::npos);
  assert(report.find("\"queued_at_ns\":110") != std::string::npos);
  assert(report.find("\"send_at_ns\":120") != std::string::npos);
  assert(report.find("\"send_accepted\":true") != std::string::npos);
  assert(report.find("\"send_state\":\"acknowledged\"") != std::string::npos);
  assert(report.find("\"send_state_at_ns\":140") != std::string::npos);
  assert(report.find("\"dropped_records\":1") != std::string::npos);
  assert(report.find("pcm") == std::string::npos);
  assert(!trace.IsActive());
  assert(hearport::windows::DebugSendStateName(DebugSendState::lost_suspect) ==
         "lost_suspect");
  assert(hearport::windows::DebugSendStateName(DebugSendState::canceled) ==
         "canceled");

  hearport::wire::AudioDatagram identity_packet{};
  identity_packet.stream_id = 0x01020304u;
  identity_packet.sequence = 0x00012345u;
  const auto identity_bytes =
      hearport::wire::EncodeAudioDatagram(identity_packet);
  const auto identity =
      hearport::wire::DecodeAudioDatagram(identity_bytes);
  assert(identity.has_value());

  DebugSessionTrace callback_before_packet(
      DebugSessionTrace::kMaximumPackets);
  assert(callback_before_packet.Begin(session_id, identity->stream_id));
  assert(callback_before_packet.RecordSendState(
      identity->stream_id, identity->sequence,
      DebugSendState::acknowledged, 40));
  assert(callback_before_packet.RecordPacket(
      identity->sequence, 10, 20, 30, true));
  const auto identity_report = callback_before_packet.Finish("test");
  assert(identity_report.find("\"stream_id\":16909060") !=
         std::string::npos);
  assert(identity_report.find("\"sequence\":74565") !=
         std::string::npos);
  assert(identity_report.find("\"send_state\":\"acknowledged\"") !=
         std::string::npos);

  DebugSessionTrace maximum(DebugSessionTrace::kMaximumPackets);
  assert(maximum.Begin(session_id, 88));
  assert(maximum.RecordPacket(0, 1, 2, 3, true));
  assert(maximum.Finish("test").find("\"record_count\":1") !=
         std::string::npos);
  return 0;
}
