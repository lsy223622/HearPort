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
}  // namespace hearport::windows
