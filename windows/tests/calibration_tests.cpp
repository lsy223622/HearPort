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
  std::cout << "calibration codec and budgets passed\n";
}
