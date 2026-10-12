#include <array>
#include <atomic>
#include <cassert>
#include <cstddef>
#include <iostream>
#include <string>
#include <string_view>
#include <thread>

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
  assert(trace.RecordSendComplete(77, 0, false, 150));
  assert(trace.RecordPacket(1, 200, 210, 220, false,
                           hearport::windows::ProbeSendOutcome{
                               hearport::windows::ProbeSendStatus::pending_limit, 128, 0}));
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
  assert(report.find("\"send_status\":\"pending_limit\"") != std::string::npos);
  assert(report.find("\"pending_reliable_sends\":128") != std::string::npos);
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
  assert(callback_before_packet.RecordSendComplete(identity->stream_id,
                                                  identity->sequence, false, 50));
  assert(callback_before_packet.RecordPacket(
      identity->sequence, 10, 20, 30, true,
      hearport::windows::ProbeSendOutcome{hearport::windows::ProbeSendStatus::accepted, 1}));
  const auto identity_report = callback_before_packet.Finish("test");
  assert(identity_report.find("\"stream_id\":16909060") !=
         std::string::npos);
  assert(identity_report.find("\"sequence\":74565") !=
         std::string::npos);
  assert(identity_report.find("\"send_state\":\"acknowledged\"") !=
         std::string::npos);
  assert(identity_report.find("\"send_completed_at_ns\":50") != std::string::npos);

  DebugSessionTrace maximum(DebugSessionTrace::kMaximumPackets);
  assert(maximum.Begin(session_id, 88));
  assert(maximum.RecordPacket(0, 1, 2, 3, true));
  assert(maximum.Finish("test").find("\"record_count\":1") !=
         std::string::npos);

  constexpr std::size_t packets = 20'000;
  DebugSessionTrace concurrent(packets);
  assert(concurrent.Begin(session_id, 99));
  std::atomic<bool> start = false;
  std::atomic<std::size_t> recorded = 0;
  std::atomic<std::size_t> acknowledged = 0;
  std::array<std::thread, 4> writers;
  for (std::size_t worker = 0; worker < writers.size(); ++worker) {
    writers[worker] = std::thread([&, worker] {
      while (!start.load()) std::this_thread::yield();
      for (std::uint32_t sequence = worker % 2; sequence < packets; sequence += 2) {
        if (worker < 2) {
          if (concurrent.RecordPacket(sequence, 1, 2, 3, true)) ++recorded;
        } else {
          if (concurrent.RecordSendState(99, sequence,
                                        DebugSendState::acknowledged, 4)) ++acknowledged;
        }
      }
    });
  }
  start.store(true);
  for (auto& writer : writers) writer.join();
  assert(recorded == packets);
  assert(acknowledged == packets);
  assert(concurrent.dropped_records() == 0);
  const auto concurrent_report = concurrent.Finish("test");
  assert(concurrent_report.find("\"record_count\":20000") != std::string::npos);
  return 0;
}
