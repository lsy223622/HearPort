#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace hearport::windows {

enum class DebugSendState {
  unknown,
  sent,
  lost_suspect,
  lost_discarded,
  acknowledged,
  acknowledged_spurious,
  canceled,
};

std::string_view DebugSendStateName(DebugSendState state) noexcept;
bool IsFinalDebugSendState(DebugSendState state) noexcept;

class DebugSessionTrace {
 public:
  static constexpr std::size_t kMaximumPackets = 240'000;

  explicit DebugSessionTrace(std::size_t capacity = kMaximumPackets);
  bool Begin(std::span<const std::byte> session_id,
             std::uint32_t stream_id);
  bool RecordPacket(std::uint32_t sequence, std::int64_t captured_at_ns,
                    std::int64_t queued_at_ns, std::int64_t send_at_ns,
                    bool send_accepted) noexcept;
  bool RecordSendState(std::uint32_t stream_id, std::uint32_t sequence,
                       DebugSendState state,
                       std::int64_t state_at_ns) noexcept;
  bool IsActive() const noexcept;
  std::uint64_t dropped_records() const noexcept;
  std::string Finish(std::string_view reason);

 private:
  struct PacketRecord {
    std::uint32_t sequence = 0;
    std::int64_t captured_at_ns = 0;
    std::int64_t queued_at_ns = 0;
    std::int64_t send_at_ns = 0;
    std::int64_t send_state_at_ns = 0;
    DebugSendState send_state = DebugSendState::unknown;
    std::uint64_t generation = 0;
    bool has_packet = false;
    bool has_send_state = false;
    bool has_final_state = false;
    bool send_accepted = false;
  };

  std::size_t capacity_;
  std::vector<PacketRecord> records_;
  mutable std::mutex mutex_;
  std::array<std::byte, 16> session_id_{};
  std::uint32_t stream_id_ = 0;
  std::size_t packet_count_ = 0;
  std::uint64_t generation_ = 0;
  std::atomic<std::uint64_t> dropped_records_{0};
  std::atomic<bool> active_{false};
};

}  // namespace hearport::windows
