#include "hearport/windows/debug_session_trace.h"

#include <algorithm>
#include <iomanip>
#include <new>
#include <utility>
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
    : capacity_(std::min(capacity, kMaximumPackets)) {}

bool DebugSessionTrace::Begin(std::span<const std::byte> session_id,
                              std::uint32_t stream_id,
                              std::uint32_t sequence_stride) {
  if (session_id.size() != session_id_.size() || stream_id == 0 || sequence_stride == 0) return false;
  std::lock_guard lock(mutex_);
  if (active_.load(std::memory_order_relaxed)) return false;
  try {
    blocks_.resize((capacity_ + kRecordsPerBlock - 1) / kRecordsPerBlock);
  } catch (const std::bad_alloc&) {
    return false;
  }
  std::copy(session_id.begin(), session_id.end(), session_id_.begin());
  stream_id_ = stream_id;
  sequence_stride_ = sequence_stride;
  packet_count_ = 0;
  dropped_records_.store(0, std::memory_order_relaxed);
  active_.store(true, std::memory_order_release);
  return true;
}

DebugSessionTrace::PacketRecord* DebugSessionTrace::GetRecord(std::uint32_t sequence) noexcept {
  if (sequence % sequence_stride_ != 0) return nullptr;
  const std::size_t slot = sequence / sequence_stride_;
  if (slot < capacity_) {
    auto& block = blocks_[slot / kRecordsPerBlock];
    if (!block) block.reset(new (std::nothrow) PacketRecord[kRecordsPerBlock]{});
    if (block) return &block[slot % kRecordsPerBlock];
  }
  dropped_records_.fetch_add(1, std::memory_order_relaxed);
  return nullptr;
}

bool DebugSessionTrace::RecordPacket(std::uint32_t sequence,
                                     std::int64_t captured_at_ns,
                                     std::int64_t queued_at_ns,
                                     std::int64_t send_at_ns,
                                     bool send_accepted,
                                     std::optional<ProbeSendOutcome> probe) noexcept {
  if (!IsActive()) return false;
  std::lock_guard lock(mutex_);
  if (!active_.load(std::memory_order_relaxed)) return false;
  auto* entry = GetRecord(sequence);
  if (!entry) return false;
  auto& record = *entry;
  if (record.has_packet) {
    dropped_records_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  record.sequence = sequence;
  record.captured_at_ns = captured_at_ns;
  record.queued_at_ns = queued_at_ns;
  record.send_at_ns = send_at_ns;
  record.send_accepted = send_accepted;
  record.probe = probe;
  record.has_packet = true;
  ++packet_count_;
  return true;
}

bool DebugSessionTrace::RecordSendState(std::uint32_t stream_id,
                                        std::uint32_t sequence,
                                        DebugSendState state,
                                        std::int64_t state_at_ns) noexcept {
  if (!IsActive()) return false;
  std::lock_guard lock(mutex_);
  if (!active_.load(std::memory_order_relaxed) || stream_id != stream_id_) {
    return false;
  }
  auto* entry = GetRecord(sequence);
  if (!entry) return false;
  auto& record = *entry;
  if (record.has_final_state) return false;
  record.sequence = sequence;
  if (state == DebugSendState::sent) record.transport_sent_at_ns = state_at_ns;
  record.send_state = state;
  record.send_state_at_ns = state_at_ns;
  record.has_send_state = true;
  if (IsFinalDebugSendState(state)) {
    record.has_final_state = true;
    return true;
  }
  return false;
}

bool DebugSessionTrace::RecordSendComplete(std::uint32_t stream_id,
                                          std::uint32_t sequence,
                                          bool canceled,
                                          std::int64_t completed_at_ns) noexcept {
  if (!IsActive()) return false;
  std::lock_guard lock(mutex_);
  if (!active_.load(std::memory_order_relaxed) || stream_id != stream_id_) return false;
  auto* entry = GetRecord(sequence);
  if (!entry) return false;
  auto& record = *entry;
  record.send_completed_at_ns = completed_at_ns;
  record.send_canceled = canceled;
  return true;
}

bool DebugSessionTrace::IsActive() const noexcept {
  return active_.load(std::memory_order_acquire);
}

std::uint64_t DebugSessionTrace::dropped_records() const noexcept {
  return dropped_records_.load(std::memory_order_relaxed);
}

void DebugSessionTrace::Finish(std::ostream& output, std::string_view reason) {
  std::unique_lock lock(mutex_);
  if (!active_.load(std::memory_order_relaxed)) return;
  active_.store(false, std::memory_order_release);

  auto blocks = std::exchange(blocks_, {});
  const auto session_id = session_id_;
  const auto stream_id = stream_id_;
  const auto sequence_stride = sequence_stride_;
  const auto packet_count = packet_count_;
  const auto dropped = dropped_records_.load(std::memory_order_relaxed);
  lock.unlock();

  output << "{\"type\":\"session\",\"format_version\":1"
         << ",\"session_id\":\""
         << SessionHex(session_id)
         << "\",\"stream_id\":" << stream_id
         << ",\"sequence_stride\":" << sequence_stride
         << ",\"record_count\":" << packet_count
         << ",\"dropped_records\":"
         << dropped
         << ",\"reason\":\"" << JsonString(reason) << "\"}\n";
  for (auto& block : blocks) {
    if (!output) return;
    if (!block) continue;
    for (std::size_t slot = 0; slot < kRecordsPerBlock && output; ++slot) {
      const auto& record = block[slot];
      if (!record.has_packet) continue;
      output << "{\"type\":\"packet\",\"sequence\":" << record.sequence
             << ",\"captured_at_ns\":" << record.captured_at_ns
             << ",\"queued_at_ns\":" << record.queued_at_ns
             << ",\"send_at_ns\":" << record.send_at_ns
             << ",\"send_accepted\":"
             << (record.send_accepted ? "true" : "false")
             << ",\"send_state\":\""
             << DebugSendStateName(record.send_state)
             << "\",\"send_state_at_ns\":" << record.send_state_at_ns
             << ",\"transport_sent_at_ns\":" << record.transport_sent_at_ns;
      if (record.probe) {
        output << ",\"send_status\":\"" << ProbeSendStatusName(record.probe->status)
               << "\",\"pending_reliable_sends\":" << record.probe->pending_reliable_sends
               << ",\"transport_status\":" << record.probe->transport_status
               << ",\"send_completed_at_ns\":" << record.send_completed_at_ns
               << ",\"send_canceled\":" << (record.send_canceled ? "true" : "false");
      }
      output << "}\n";
    }
    block.reset();
  }
}

}  // namespace hearport::windows
