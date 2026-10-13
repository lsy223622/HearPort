#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

namespace hearport::windows {

enum class ProbeSendStatus {
  accepted, disconnected, stream_unavailable, pending_limit, invalid_size,
  datagram_unavailable, transport_rejected, expired,
};

struct ProbeSendOutcome {
  ProbeSendStatus status = ProbeSendStatus::disconnected;
  std::size_t pending_reliable_sends = 0;
  std::uint32_t transport_status = 0;
};

std::string_view ProbeSendStatusName(ProbeSendStatus status) noexcept;

struct NetworkProbeRound {
  std::size_t payload_bytes;
  std::uint32_t packets_per_second;
  std::uint32_t burst_packets;
  std::uint8_t variant;
  bool reliable;
  std::uint8_t repeat = 1;
  std::uint8_t controller = 0;
  std::uint8_t repair = 0;
  std::uint8_t correction_percent = 5;
};

inline constexpr std::uint32_t kNetworkProbeSecondsPerRound = 30;
inline constexpr std::array<NetworkProbeRound, 5> kNetworkProbeVariants{{
    {968, 400, 4, 0, false},
    {968, 400, 1, 1, false},
    {488, 400, 4, 2, false},
    {968, 200, 1, 3, false},
    {488, 400, 1, 4, false},
}};
inline constexpr std::size_t kNetworkProbeRoundCount = 20;
inline constexpr std::uint32_t kNetworkProbeDurationSeconds =
    kNetworkProbeRoundCount * kNetworkProbeSecondsPerRound + 10;

std::array<NetworkProbeRound, kNetworkProbeRoundCount> MakeNetworkProbeRounds(
    std::uint32_t stream_id);

std::vector<NetworkProbeRound> MakeCoordinatedProbeRounds(std::uint32_t stream_id);
std::vector<std::byte> EncodeProbeManifest(const std::vector<NetworkProbeRound>& rounds);
inline constexpr std::uint32_t kCoordinatedProbeRoundCount = 12;
inline constexpr std::uint32_t kCoordinatedProbeRecoverySeconds = 5;
inline constexpr std::uint32_t kCoordinatedProbeDurationSeconds =
    kCoordinatedProbeRoundCount * kNetworkProbeSecondsPerRound +
    (kCoordinatedProbeRoundCount - 1) * kCoordinatedProbeRecoverySeconds + 10;

std::vector<std::byte> MakeNetworkProbeDatagram(std::uint32_t stream_id,
                                                std::uint32_t sequence,
                                                std::size_t payload_bytes);

}  // namespace hearport::windows
