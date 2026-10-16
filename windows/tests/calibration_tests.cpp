#include <iostream>
#include "hearport/windows/calibration.h"

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
  if (!exchange.awaiting_selection()) return 14;
  auto impossible = selection; impossible.choices[0].budget = {55,100};
  if (exchange.Handle(impossible)) return 15;
  if (!exchange.Handle(selection)) return 16;
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
  std::cout << "calibration codec and budgets passed\n";
}
