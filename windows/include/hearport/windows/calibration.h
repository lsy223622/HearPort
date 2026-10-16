#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace hearport::windows {
struct CalibrationOptions { std::uint16_t seconds = 30, maximum_ms = 100; };
struct CalibrationBudget {
  std::uint16_t target_ms = 0, maximum_ms = 0;
  bool operator==(const CalibrationBudget&) const = default;
};
struct CalibrationChoice {
  std::uint8_t profile_mask = 0;
  bool reliable = false;
  CalibrationBudget budget;
  std::uint16_t output_reserve_ms = 0;
};
enum class CalibrationMessageKind : std::uint8_t { setup, round, ack, analyze, selection, progress };
struct CalibrationMessage {
  CalibrationMessageKind kind = CalibrationMessageKind::setup;
  std::uint32_t plan_id = 0;
  std::uint8_t phase = 0, index = 0, count = 0, profile_mask = 0;
  bool reliable = false;
  std::uint16_t seconds = 30, output_reserve_ms = 0, completed = 0, total = 0;
  CalibrationBudget budget;
  std::uint32_t first_sequence = 0, generation = 0;
  std::uint64_t first_source_frame = 0;
  std::vector<CalibrationChoice> choices;
};
std::vector<CalibrationBudget> MakeCalibrationBudgets(std::uint16_t maximum_ms,
                                                    std::uint16_t output_reserve_ms);
std::vector<std::byte> EncodeCalibrationMessage(const CalibrationMessage& message);
std::optional<CalibrationMessage> DecodeCalibrationMessage(std::span<const std::byte> bytes) noexcept;
}  // namespace hearport::windows
