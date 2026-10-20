#include <algorithm>
#include <iostream>
#include "hearport/windows/calibration.h"
#include "hearport/windows/sender_authentication.h"

int main() {
  using namespace hearport::windows;
  const auto budgets = MakeCalibrationBudgets(95, 11);
  if (budgets.empty() || budgets.back().maximum_ms != 95 || !MakeCalibrationBudgets(20, 20).empty()) return 1;
  for (const auto& budget : budgets) {
    if (budget.target_ms % 5 || budget.target_ms <= 11 || budget.target_ms + 5 > budget.maximum_ms) return 2;
  }
  CalibrationMessage setup;
  setup.kind = CalibrationMessageKind::setup;
  setup.plan_id = 0x01020304;
  setup.seconds = 30;
  setup.budget.maximum_ms = 100;
  const std::vector<std::byte> fixture{std::byte{4}, std::byte{0}, std::byte{1}, std::byte{2},
      std::byte{3}, std::byte{4}, std::byte{0}, std::byte{30}, std::byte{0}, std::byte{100}};
  if (EncodeCalibrationMessage(setup) != fixture) return 3;
  if (!DecodeCalibrationMessage(fixture)) return 4;
  auto invalid = fixture;
  invalid.push_back(std::byte{0});
  if (DecodeCalibrationMessage(invalid)) return 5;
  for (std::size_t size = 0; size < fixture.size(); ++size) {
    if (DecodeCalibrationMessage(std::span(fixture).first(size))) return 6;
  }
  CalibrationMessage round;
  round.kind = CalibrationMessageKind::round; round.plan_id = 7;
  round.phase = 1; round.index = 1; round.count = 2; round.profile_mask = 7;
  round.seconds = 30; round.reliable = true; round.budget = {50, 100};
  round.output_reserve_ms = 11; round.generation = 1; round.first_sequence = 12000;
  round.first_source_frame = 1'440'000;
  const auto encoded = EncodeCalibrationMessage(round);
  const auto parsed = DecodeCalibrationMessage(encoded);
  if (!parsed || parsed->first_source_frame != round.first_source_frame || parsed->profile_mask != 7) return 7;
  invalid = encoded; invalid[12] = std::byte{1};
  if (DecodeCalibrationMessage(invalid)) return 8;
  CalibrationMessage selection;
  selection.kind = CalibrationMessageKind::selection; selection.plan_id = 7;
  selection.choices = {{7, true, {50, 100}, 11}};
  if (DecodeCalibrationMessage(EncodeCalibrationMessage(selection))->choices.size() != 1) return 9;
  CalibrationExchange exchange(7, {30,100}, 11);
  if (exchange.phase_completed() != 0 || exchange.phase_total() != 4) return 40;
  CalibrationMessage wrong;
  wrong.kind = CalibrationMessageKind::ack; wrong.plan_id = 8; wrong.index = 1;
  if (exchange.Handle(wrong)) return 10;
  for (unsigned i = 1; i <= 4; ++i) {
    const auto step = exchange.NextRound(i);
    if (!step || step->index != i || step->budget.maximum_ms != 100) return 11;
    if (exchange.CompleteRound()) return 12;
    auto ack = wrong; ack.plan_id = 7; ack.index = static_cast<std::uint8_t>(i);
    if (!exchange.Handle(ack) || !exchange.CompleteRound()) return 13;
  }
  if (!exchange.awaiting_selection() || exchange.phase_completed() != 4 || exchange.phase_total() != 4) return 14;
  auto impossible = selection; impossible.choices[0].budget = {55,100};
  if (exchange.Handle(impossible)) return 15;
  if (!exchange.Handle(selection) || exchange.phase_completed() != 0 || exchange.phase_total() != 2) return 16;
  for (unsigned i = 5; i <= 6; ++i) {
    const auto step = exchange.NextRound(i);
    if (!step || step->phase != 1 || step->profile_mask != 7 || step->budget != CalibrationBudget{50,100}) return 17;
    auto ack = wrong; ack.plan_id = 7; ack.phase = 1; ack.index = static_cast<std::uint8_t>(i);
    if (!exchange.Handle(ack) || !exchange.CompleteRound()) return 18;
  }
  if (!exchange.finished()) return 19;
  if (ParseCalibrationReport("calibration_summary_v1\nunknown\n1\n")) return 20;
  const std::string summary = "calibration_summary_v1\nversion\tplan_id\tcomplete\tseconds\tceiling_ms\tprofile\treliable\ttarget_ms\tmaximum_ms\treserve_ms\tmet_goal\tstatus\tage_p95_ms\tgap_ratio\tlongest_gap_ms\n";
  const auto result = ParseCalibrationReport(summary +
      "1\t7\t1\t30\t100\t1\t0\t50\t100\t11\t1\tobserved\t60\t0\t0\n" +
      "1\t7\t1\t30\t100\t2\t0\t50\t100\t11\t1\tobserved\t60\t0\t0\n" +
      "1\t7\t1\t30\t100\t4\t0\t50\t100\t11\t1\tobserved\t60\t0\t0\n");
  if (!result || result->complete || result->profiles.size() != 3) return 21;
  if (ParseCalibrationReport(summary + "2\t7\t1\t30\t100\t1\t0\t50\t100\t11\t1\tobserved\t60\t0\t0\n")) return 22;
  CalibrationMessage request;
  request.kind = CalibrationMessageKind::request; request.plan_id = 0x01020304;
  request.seconds = 30; request.budget.maximum_ms = 300;
  const std::vector<std::byte> request_fixture{std::byte{4}, std::byte{6}, std::byte{1}, std::byte{2},
      std::byte{3}, std::byte{4}, std::byte{0}, std::byte{30}, std::byte{1}, std::byte{44}};
  if (EncodeCalibrationMessage(request) != request_fixture) return 23;
  const auto decoded_request = DecodeCalibrationMessage(request_fixture);
  if (!decoded_request || decoded_request->kind != CalibrationMessageKind::request ||
      decoded_request->seconds != 30 || decoded_request->budget.maximum_ms != 300) return 24;
  for (const auto seconds : {30,60,120}) for (const auto maximum : {20,2000}) {
    request.seconds = static_cast<std::uint16_t>(seconds);
    request.budget.maximum_ms = static_cast<std::uint16_t>(maximum);
    const auto decoded = DecodeCalibrationMessage(EncodeCalibrationMessage(request));
    if (!decoded || decoded->seconds != seconds || decoded->budget.maximum_ms != maximum) return 25;
  }
  for (const auto seconds : {0,29,31,65535}) {
    invalid = request_fixture; invalid[6] = std::byte(seconds >> 8); invalid[7] = std::byte(seconds & 255);
    if (DecodeCalibrationMessage(invalid)) return 26;
  }
  for (const auto maximum : {0,19,2001,65535}) {
    invalid = request_fixture; invalid[8] = std::byte(maximum >> 8); invalid[9] = std::byte(maximum & 255);
    if (DecodeCalibrationMessage(invalid)) return 27;
  }
  for (std::size_t size = 0; size < request_fixture.size(); ++size) {
    if (DecodeCalibrationMessage(std::span(request_fixture).first(size))) return 28;
  }
  invalid = request_fixture; invalid.push_back(std::byte{0});
  if (DecodeCalibrationMessage(invalid)) return 29;
  invalid = request_fixture; std::fill(invalid.begin() + 2, invalid.begin() + 6, std::byte{0});
  if (DecodeCalibrationMessage(invalid)) return 30;
  invalid = request_fixture; invalid[1] = std::byte{7};
  if (DecodeCalibrationMessage(invalid)) return 31;
  SenderService service(QuicServerOptions{});
  SenderAuthentication authentication(service, {});
  unsigned requested = 0;
  authentication.SetCalibrationRequestHandler([&](CalibrationOptions) { ++requested; });
  hearport::wire::ControlEnvelope envelope;
  envelope.type = hearport::wire::ControlMessageType::probe_manifest;
  envelope.stream_id = 0x01020304; envelope.bytes1 = request_fixture;
  if (authentication.HandleControlPayload(hearport::wire::EncodeControlEnvelope(envelope)) || requested) return 32;
  CalibrationMessage quick;
  quick.kind = CalibrationMessageKind::request; quick.plan_id = 0x01020304;
  quick.goal = 2; quick.seconds = 15; quick.budget.maximum_ms = 300;
  const std::vector<std::byte> quick_fixture{std::byte{5},std::byte{6},std::byte{1},std::byte{2},std::byte{3},std::byte{4},std::byte{2},std::byte{0},std::byte{15},std::byte{1},std::byte{44}};
  if (EncodeCalibrationMessage(quick) != quick_fixture || !DecodeCalibrationMessage(quick_fixture)) return 33;
  CalibrationExchange adaptive(7,{15,300,2},11);
  if (!adaptive.awaiting_selection() || adaptive.NextRound(1)) return 34;
  CalibrationMessage pick;
  pick.kind = CalibrationMessageKind::selection; pick.plan_id = 7; pick.goal = 2; pick.phase = 1;
  pick.codec = 1; pick.bitrate = 192000; pick.frames = 480;
  pick.choices = {{2,true,{90,150},11}};
  const std::vector<unsigned> selection_bytes{5,4,0,0,0,7,2,0,1,2,1,0,90,0,150,0,11,1,0,2,238,0,1,224,1};
  const auto encoded_pick = EncodeCalibrationMessage(pick);
  for (std::size_t i = 0; i < selection_bytes.size(); ++i) if (std::to_integer<unsigned>(encoded_pick.at(i)) != selection_bytes[i]) return 35;
  const auto decoded_pick = DecodeCalibrationMessage(encoded_pick);
  if (!decoded_pick || !adaptive.Handle(*decoded_pick)) return 36;
  const auto adaptive_round = adaptive.NextRound(3);
  if (!adaptive_round || adaptive_round->frames != 480 || adaptive_round->bitrate != 192000 ||
      adaptive_round->seconds != 30 || !adaptive_round->reliable || adaptive_round->phase != 1 ||
      adaptive_round->budget != CalibrationBudget{90,150} || !DecodeCalibrationMessage(EncodeCalibrationMessage(*adaptive_round))) return 37;
  CalibrationMessage quick_ack;
  quick_ack.kind = CalibrationMessageKind::ack; quick_ack.plan_id = 7; quick_ack.goal = 2; quick_ack.index = 1; quick_ack.phase = 1;
  if (!adaptive.Handle(quick_ack) || !adaptive.CompleteRound() || !adaptive.awaiting_selection()) return 38;
  pick.choices.clear();
  if (!adaptive.Handle(pick) || !adaptive.finished() || adaptive.NextRound(4)) return 39;
  for (std::size_t length = 0; length < encoded_pick.size(); ++length)
    if (DecodeCalibrationMessage(std::span(encoded_pick).first(length))) return 40;
  std::cout << "calibration codec and budgets passed\n";
}
