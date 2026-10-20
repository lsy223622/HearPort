#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace hearport::windows {
struct CalibrationOptions { std::uint16_t seconds = 30, maximum_ms = 100; std::uint8_t goal = 0; };
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
struct CalibrationProgress {
  unsigned stage = 0, index = 0, count = 0, completed = 0, total = 0;
  unsigned completed_rounds = 0, elapsed_seconds = 0, remaining_seconds = 0;
  bool round_pending = false, round_started = false;
};
enum class CalibrationMessageKind : std::uint8_t { setup, round, ack, analyze, selection, progress, request, complete };
struct CalibrationMessage {
  std::uint8_t goal = 0, codec = 0;
  std::uint32_t bitrate = 0;
  std::uint16_t frames = 120;
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
  bool awaiting_selection() const { return options_.goal ? adaptive_waiting_ && !adaptive_done_ : completed_ == 4 && !selected_; }
  bool finished() const { return options_.goal ? adaptive_done_ : selected_ && completed_ == 4 + validation_.size(); }
  unsigned completed() const { return completed_; }
  unsigned total() const { return options_.goal ? 16 : selected_ ? 4 + static_cast<unsigned>(validation_.size()) : 10; }
  unsigned phase_completed() const { return options_.goal ? completed_ : selected_ ? completed_ - 4 : completed_; }
  unsigned phase_total() const { return options_.goal ? 16 : selected_ ? static_cast<unsigned>(validation_.size()) : 4; }
  unsigned analysis_completed() const { return analysis_completed_; }
  unsigned analysis_total() const { return analysis_total_; }
 private:
  std::uint32_t plan_id_;
  CalibrationOptions options_;
  std::uint16_t reserve_;
  unsigned completed_ = 0, analysis_completed_ = 0, analysis_total_ = 0;
  bool selected_ = false, acked_ = false;
  bool adaptive_waiting_ = true, adaptive_done_ = false;
  std::optional<CalibrationMessage> adaptive_next_;
  std::optional<CalibrationMessage> pending_;
  std::vector<CalibrationChoice> validation_;
};
}  // namespace hearport::windows
