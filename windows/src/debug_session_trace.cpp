#include "hearport/windows/debug_session_trace.h"

#include <algorithm>
#include <iomanip>
#include <sstream>

namespace hearport::windows {
namespace {

std::string SessionHex(std::span<const std::byte> session_id) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const auto byte : session_id) {
    output << std::setw(2) << std::to_integer<unsigned int>(byte);
  }
  return output.str();
}

std::string JsonString(std::string_view text) {
  std::string escaped;
  escaped.reserve(text.size() + 2);
  for (const auto value : text) {
    switch (value) {
      case '"': escaped += "\\\""; break;
      case '\\': escaped += "\\\\"; break;
      case '\n': escaped += "\\n"; break;
      case '\r': escaped += "\\r"; break;
      case '\t': escaped += "\\t"; break;
      default:
        if (static_cast<unsigned char>(value) >= 0x20) escaped += value;
        break;
    }
  }
  return escaped;
}

}  // namespace

std::string_view DebugSendStateName(DebugSendState state) noexcept {
  switch (state) {
    case DebugSendState::unknown: return "unknown";
    case DebugSendState::sent: return "sent";
    case DebugSendState::lost_suspect: return "lost_suspect";
    case DebugSendState::lost_discarded: return "lost_discarded";
    case DebugSendState::acknowledged: return "acknowledged";
    case DebugSendState::acknowledged_spurious: return "acknowledged_spurious";
    case DebugSendState::canceled: return "canceled";
  }
  return "unknown";
}

bool IsFinalDebugSendState(DebugSendState state) noexcept {
  return state == DebugSendState::lost_discarded ||
         state == DebugSendState::acknowledged ||
         state == DebugSendState::acknowledged_spurious ||
         state == DebugSendState::canceled;
}

DebugSessionTrace::DebugSessionTrace(std::size_t capacity)
    : capacity_(capacity), records_(capacity) {}

bool DebugSessionTrace::Begin(std::span<const std::byte> session_id,
                              std::uint32_t stream_id) {
  if (session_id.size() != session_id_.size() || stream_id == 0) return false;
  std::lock_guard lock(mutex_);
  if (active_.load(std::memory_order_relaxed)) return false;
  ++generation_;
  if (generation_ == 0) {
    std::fill(records_.begin(), records_.end(), PacketRecord{});
    generation_ = 1;
  }
  std::copy(session_id.begin(), session_id.end(), session_id_.begin());
  stream_id_ = stream_id;
  packet_count_ = 0;
  dropped_records_.store(0, std::memory_order_relaxed);
  active_.store(true, std::memory_order_release);
  return true;
}

bool DebugSessionTrace::RecordPacket(std::uint32_t sequence,
                                     std::int64_t captured_at_ns,
                                     std::int64_t queued_at_ns,
                                     std::int64_t send_at_ns,
                                     bool send_accepted) noexcept {
  std::unique_lock lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  if (!active_.load(std::memory_order_relaxed)) return false;
  if (sequence >= capacity_) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  auto& record = records_[sequence];
  if (record.generation != generation_) {
    record = PacketRecord{};
    record.generation = generation_;
  }
  if (record.has_packet) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  record.sequence = sequence;
  record.captured_at_ns = captured_at_ns;
  record.queued_at_ns = queued_at_ns;
  record.send_at_ns = send_at_ns;
  record.send_accepted = send_accepted;
  record.has_packet = true;
  ++packet_count_;
  return true;
}

bool DebugSessionTrace::RecordSendState(std::uint32_t stream_id,
                                        std::uint32_t sequence,
                                        DebugSendState state,
                                        std::int64_t state_at_ns) noexcept {
  std::unique_lock lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  if (!active_.load(std::memory_order_relaxed) || stream_id != stream_id_) {
    return false;
  }
  if (sequence >= capacity_) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  auto& record = records_[sequence];
  if (record.generation != generation_) {
    record = PacketRecord{};
    record.generation = generation_;
  }
  if (record.has_final_state) return false;
  record.sequence = sequence;
  record.send_state = state;
  record.send_state_at_ns = state_at_ns;
  record.has_send_state = true;
  if (IsFinalDebugSendState(state)) {
    record.has_final_state = true;
    return true;
  }
  return false;
}

bool DebugSessionTrace::IsActive() const noexcept {
  return active_.load(std::memory_order_acquire);
}

std::uint64_t DebugSessionTrace::dropped_records() const noexcept {
  return dropped_records_.load(std::memory_order_relaxed);
}

std::string DebugSessionTrace::Finish(std::string_view reason) {
  std::lock_guard lock(mutex_);
  if (!active_.load(std::memory_order_relaxed)) return {};
  active_.store(false, std::memory_order_release);

  std::ostringstream output;
  output << "{\"type\":\"session\",\"format_version\":1"
         << ",\"session_id\":\""
         << SessionHex(session_id_)
         << "\",\"stream_id\":" << stream_id_
         << ",\"record_count\":" << packet_count_
         << ",\"dropped_records\":"
         << dropped_records_.load(std::memory_order_relaxed)
         << ",\"reason\":\"" << JsonString(reason) << "\"}\n";
  for (const auto& record : records_) {
    if (record.generation != generation_ || !record.has_packet) continue;
    output << "{\"type\":\"packet\",\"sequence\":" << record.sequence
           << ",\"captured_at_ns\":" << record.captured_at_ns
           << ",\"queued_at_ns\":" << record.queued_at_ns
           << ",\"send_at_ns\":" << record.send_at_ns
           << ",\"send_accepted\":"
           << (record.send_accepted ? "true" : "false")
           << ",\"send_state\":\""
           << DebugSendStateName(record.send_state)
           << "\",\"send_state_at_ns\":" << record.send_state_at_ns
           << "}\n";
  }
  return output.str();
}

}  // namespace hearport::windows
