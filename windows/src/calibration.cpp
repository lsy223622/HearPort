#include "hearport/windows/calibration.h"
#include <algorithm>
#include <array>
#include <stdexcept>

namespace hearport::windows {
namespace {
bool Seconds(unsigned value) { return value == 30 || value == 60 || value == 120; }
bool Budget(CalibrationBudget value, unsigned reserve) {
  return value.target_ms > reserve && value.maximum_ms <= 2000 &&
      unsigned(value.target_ms) + 5 <= value.maximum_ms;
}
void Put(std::vector<std::byte>& bytes, std::uint64_t value, unsigned size) {
  for (unsigned remaining = size; remaining; --remaining)
    bytes.push_back(std::byte((value >> ((remaining - 1) * 8)) & 255));
}
struct Reader {
  std::span<const std::byte> bytes;
  std::size_t at = 0;
  std::uint64_t get(unsigned size) {
    if (at + size > bytes.size()) throw std::invalid_argument("truncated calibration message");
    std::uint64_t value = 0;
    while (size--) value = (value << 8) | std::to_integer<unsigned>(bytes[at++]);
    return value;
  }
};
}

std::vector<CalibrationBudget> MakeCalibrationBudgets(std::uint16_t maximum, std::uint16_t reserve) {
  if (maximum > 2000 || maximum <= reserve) return {};
  std::vector<unsigned> caps{40,60,80,100,120,160,200,300,500,750,1000,1500,2000};
  caps.push_back(maximum);
  std::sort(caps.begin(), caps.end());
  caps.erase(std::unique(caps.begin(), caps.end()), caps.end());
  std::vector<CalibrationBudget> result;
  for (unsigned cap : caps) {
    if (cap > maximum || cap < 5) continue;
    for (unsigned numerator : {cap * 2, cap * 3, (cap - 5) * 4}) {
      const unsigned target = ((numerator + 19) / 20) * 5;
      CalibrationBudget budget{static_cast<std::uint16_t>(target), static_cast<std::uint16_t>(cap)};
      if (Budget(budget, reserve) && (result.empty() || result.back() != budget)) result.push_back(budget);
    }
  }
  return result;
}

std::vector<std::byte> EncodeCalibrationMessage(const CalibrationMessage& m) {
  std::vector<std::byte> b{std::byte{4}, std::byte(m.kind)};
  Put(b, m.plan_id, 4);
  switch (m.kind) {
    case CalibrationMessageKind::setup:
      Put(b,m.seconds,2); Put(b,m.budget.maximum_ms,2); break;
    case CalibrationMessageKind::round:
      for (unsigned v : {unsigned(m.phase),unsigned(m.index),unsigned(m.count),unsigned(m.profile_mask),unsigned(m.reliable),0u}) Put(b,v,1);
      Put(b,m.seconds,2); Put(b,m.budget.target_ms,2); Put(b,m.budget.maximum_ms,2); Put(b,m.output_reserve_ms,2);
      Put(b,m.first_sequence,4); Put(b,m.generation,4); Put(b,m.first_source_frame,8); break;
    case CalibrationMessageKind::ack:
      Put(b,m.phase,1); Put(b,m.index,1); break;
    case CalibrationMessageKind::analyze: break;
    case CalibrationMessageKind::selection:
      Put(b,m.choices.size(),2);
      for (const auto& c : m.choices) {
        Put(b,c.profile_mask,1); Put(b,c.reliable,1); Put(b,c.budget.target_ms,2);
        Put(b,c.budget.maximum_ms,2); Put(b,c.output_reserve_ms,2);
      }
      break;
    case CalibrationMessageKind::progress: Put(b,m.completed,2); Put(b,m.total,2); break;
  }
  if (!DecodeCalibrationMessage(b)) throw std::invalid_argument("invalid calibration message");
  return b;
}

std::optional<CalibrationMessage> DecodeCalibrationMessage(std::span<const std::byte> b) noexcept {
  try {
    Reader r{b};
    if (r.get(1) != 4) return std::nullopt;
    const auto kind = r.get(1);
    if (kind > 5) return std::nullopt;
    CalibrationMessage m;
    m.kind = static_cast<CalibrationMessageKind>(kind); m.plan_id = static_cast<std::uint32_t>(r.get(4));
    if (!m.plan_id) return std::nullopt;
    switch (m.kind) {
      case CalibrationMessageKind::setup:
        m.seconds = static_cast<std::uint16_t>(r.get(2)); m.budget.maximum_ms = static_cast<std::uint16_t>(r.get(2));
        if (!Seconds(m.seconds) || m.budget.maximum_ms < 20 || m.budget.maximum_ms > 2000) return std::nullopt;
        break;
      case CalibrationMessageKind::round: {
        m.phase = static_cast<std::uint8_t>(r.get(1)); m.index = static_cast<std::uint8_t>(r.get(1));
        m.count = static_cast<std::uint8_t>(r.get(1)); m.profile_mask = static_cast<std::uint8_t>(r.get(1));
        const auto reliable = r.get(1), reserved = r.get(1); m.reliable = reliable != 0;
        m.seconds = static_cast<std::uint16_t>(r.get(2)); m.budget.target_ms = static_cast<std::uint16_t>(r.get(2));
        m.budget.maximum_ms = static_cast<std::uint16_t>(r.get(2)); m.output_reserve_ms = static_cast<std::uint16_t>(r.get(2));
        m.first_sequence = static_cast<std::uint32_t>(r.get(4)); m.generation = static_cast<std::uint32_t>(r.get(4));
        m.first_source_frame = r.get(8);
        if (m.phase > 1 || !m.index || m.index > m.count || m.count > 10 || reliable > 1 || reserved || !m.generation ||
            !Seconds(m.seconds) || !Budget(m.budget,m.output_reserve_ms) ||
            m.first_source_frame != std::uint64_t(m.first_sequence) * 120 ||
            std::uint64_t(m.first_sequence) + std::uint64_t(m.seconds) * 400 > UINT32_MAX ||
            (m.phase == 0 ? m.profile_mask != 0 : m.profile_mask == 0 || m.profile_mask > 7)) return std::nullopt;
        break;
      }
      case CalibrationMessageKind::ack:
        m.phase = static_cast<std::uint8_t>(r.get(1)); m.index = static_cast<std::uint8_t>(r.get(1));
        if (m.phase > 1 || !m.index || m.index > 10) return std::nullopt;
        break;
      case CalibrationMessageKind::analyze: break;
      case CalibrationMessageKind::selection: {
        const auto count = r.get(2);
        if (count > 3) return std::nullopt;
        unsigned seen = 0;
        for (unsigned i = 0; i < count; ++i) {
          CalibrationChoice c;
          c.profile_mask = static_cast<std::uint8_t>(r.get(1)); const auto reliable = r.get(1); c.reliable = reliable != 0;
          c.budget.target_ms = static_cast<std::uint16_t>(r.get(2)); c.budget.maximum_ms = static_cast<std::uint16_t>(r.get(2));
          c.output_reserve_ms = static_cast<std::uint16_t>(r.get(2));
          if (!c.profile_mask || c.profile_mask > 7 || (seen & c.profile_mask) || reliable > 1 || !Budget(c.budget,c.output_reserve_ms)) return std::nullopt;
          seen |= c.profile_mask; m.choices.push_back(c);
        }
        break;
      }
      case CalibrationMessageKind::progress:
        m.completed = static_cast<std::uint16_t>(r.get(2)); m.total = static_cast<std::uint16_t>(r.get(2));
        if (!m.total || m.total > 256 || m.completed > m.total) return std::nullopt;
        break;
    }
    if (r.at != b.size()) return std::nullopt;
    return m;
  } catch (...) { return std::nullopt; }
}
CalibrationExchange::CalibrationExchange(std::uint32_t plan_id, CalibrationOptions options, std::uint16_t reserve)
    : plan_id_(plan_id), options_(options), reserve_(reserve) {}

std::optional<CalibrationMessage> CalibrationExchange::NextRound(std::uint32_t generation) {
  if (pending_ || finished() || awaiting_selection() || generation == 0) return std::nullopt;
  const auto candidates = MakeCalibrationBudgets(options_.maximum_ms, reserve_);
  const auto sampling = std::find_if(candidates.begin(), candidates.end(), [&](const auto& b) { return b.maximum_ms == options_.maximum_ms; });
  if (sampling == candidates.end()) return std::nullopt;
  CalibrationMessage m;
  m.kind = CalibrationMessageKind::round; m.plan_id = plan_id_;
  m.phase = completed_ >= 4; m.index = static_cast<std::uint8_t>(completed_ + 1);
  m.count = static_cast<std::uint8_t>(m.phase ? total() : 4);
  m.seconds = options_.seconds; m.output_reserve_ms = reserve_; m.generation = generation;
  m.first_sequence = completed_ * options_.seconds * 400;
  m.first_source_frame = std::uint64_t(m.first_sequence) * 120;
  if (!m.phase) {
    m.reliable = (completed_ == 1 || completed_ == 2) != ((plan_id_ & 1) != 0);
    m.budget = *sampling;
  } else {
    const auto& choice = validation_.at(completed_ - 4);
    m.reliable = choice.reliable; m.budget = choice.budget; m.profile_mask = choice.profile_mask;
  }
  acked_ = false; pending_ = m;
  return m;
}

bool CalibrationExchange::Handle(const CalibrationMessage& m) {
  if (m.plan_id != plan_id_) return false;
  if (m.kind == CalibrationMessageKind::ack) {
    if (!awaiting_ack() || pending_->index != m.index || pending_->phase != m.phase) return false;
    acked_ = true; return true;
  }
  if (!awaiting_selection()) return false;
  if (m.kind == CalibrationMessageKind::progress) {
    if (!m.total || m.completed > m.total || m.completed < analysis_completed_ ||
        (analysis_total_ != 0 && m.total != analysis_total_)) return false;
    analysis_completed_ = m.completed; analysis_total_ = m.total; return true;
  }
  if (m.kind != CalibrationMessageKind::selection || m.choices.size() > 3) return false;
  const auto budgets = MakeCalibrationBudgets(options_.maximum_ms, reserve_);
  unsigned seen = 0;
  for (const auto& choice : m.choices) {
    if (!choice.profile_mask || choice.profile_mask > 7 || (seen & choice.profile_mask) ||
        choice.output_reserve_ms != reserve_ || std::find(budgets.begin(), budgets.end(), choice.budget) == budgets.end()) return false;
    seen |= choice.profile_mask;
  }
  validation_ = m.choices;
  std::uint32_t seed = plan_id_ ^ 0xa5a55a5au;
  for (std::size_t remaining = validation_.size(); remaining > 1; --remaining) {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    std::swap(validation_[remaining - 1],validation_[seed % remaining]);
  }
  const auto first = validation_;
  validation_.insert(validation_.end(), first.rbegin(), first.rend());
  selected_ = true; return true;
}

bool CalibrationExchange::CompleteRound() {
  if (!pending_ || !acked_) return false;
  ++completed_; pending_.reset(); acked_ = false; return true;
}
}  // namespace hearport::windows
