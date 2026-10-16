#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
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
struct CalibrationProgress { unsigned stage = 0, index = 0, count = 0, completed = 0, total = 0; };
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

struct CalibrationReportPoint {
  unsigned round = 0, profile = 0, sample_count = 0;
  bool reliable = false, valid = false, met_goal = false;
  CalibrationBudget budget;
  unsigned reserve_ms = 0;
  std::string status;
  std::optional<double> age_p95_ms;
  double gap_ratio = 1, longest_gap_ms = 0, source_gap_ratio = 1, output_gap_ratio = 1, startup_ms = 0;
};
struct CalibrationReport {
  unsigned plan_id = 0, seconds = 0, ceiling_ms = 0;
  bool complete = false;
  std::vector<CalibrationReportPoint> profiles, curve, validation;
};
std::optional<CalibrationReport> ParseCalibrationReport(std::string_view text);

class CalibrationExchange {
 public:
  CalibrationExchange(std::uint32_t plan_id, CalibrationOptions options, std::uint16_t reserve);
  std::optional<CalibrationMessage> NextRound(std::uint32_t generation);
  bool Handle(const CalibrationMessage& message);
  bool CompleteRound();
  bool awaiting_ack() const { return pending_.has_value() && !acked_; }
  bool awaiting_selection() const { return completed_ == 4 && !selected_; }
  bool finished() const { return selected_ && completed_ == 4 + validation_.size(); }
  unsigned completed() const { return completed_; }
  unsigned total() const { return selected_ ? 4 + static_cast<unsigned>(validation_.size()) : 10; }
  unsigned analysis_completed() const { return analysis_completed_; }
  unsigned analysis_total() const { return analysis_total_; }
 private:
  std::uint32_t plan_id_;
  CalibrationOptions options_;
  std::uint16_t reserve_;
  unsigned completed_ = 0, analysis_completed_ = 0, analysis_total_ = 0;
  bool selected_ = false, acked_ = false;
  std::optional<CalibrationMessage> pending_;
  std::vector<CalibrationChoice> validation_;
};
}  // namespace hearport::windows
