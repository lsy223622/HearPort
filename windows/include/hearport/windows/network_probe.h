#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace hearport::windows {

struct NetworkProbeRound {
  std::size_t payload_bytes;
  std::uint32_t packets_per_second;
  std::uint32_t burst_packets;
  std::uint8_t variant;
  bool reliable;
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

std::vector<std::byte> MakeNetworkProbeDatagram(std::uint32_t stream_id,
                                                std::uint32_t sequence,
                                                std::size_t payload_bytes);

}  // namespace hearport::windows
