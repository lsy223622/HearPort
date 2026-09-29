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
};

inline constexpr std::uint32_t kNetworkProbeSecondsPerRound = 30;
inline constexpr std::array<NetworkProbeRound, 8> kNetworkProbeRounds{{
    {968, 400, 4},
    {968, 400, 1},
    {488, 400, 4},
    {968, 200, 1},
    {968, 400, 4},
    {968, 400, 1},
    {488, 400, 4},
    {968, 200, 1},
}};
inline constexpr std::uint32_t kNetworkProbeDurationSeconds = 250;

std::vector<std::byte> MakeNetworkProbeDatagram(std::uint32_t stream_id,
                                                std::uint32_t sequence,
                                                std::size_t payload_bytes);

}  // namespace hearport::windows
