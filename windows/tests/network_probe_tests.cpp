#include <cassert>
#include <cstddef>
#include <cstdint>

#include "hearport/windows/network_probe.h"

int main() {
  using namespace hearport::windows;
  static_assert(kNetworkProbeRounds.size() == 8);
  assert(kNetworkProbeRounds[0].payload_bytes == 968);
  assert(kNetworkProbeRounds[0].packets_per_second == 400);
  assert(kNetworkProbeRounds[0].burst_packets == 4);
  assert(kNetworkProbeRounds[1].payload_bytes == 968);
  assert(kNetworkProbeRounds[1].packets_per_second == 400);
  assert(kNetworkProbeRounds[1].burst_packets == 1);
  assert(kNetworkProbeRounds[2].payload_bytes == 488);
  assert(kNetworkProbeRounds[2].packets_per_second == 400);
  assert(kNetworkProbeRounds[2].burst_packets == 4);
  assert(kNetworkProbeRounds[3].payload_bytes == 968);
  assert(kNetworkProbeRounds[3].packets_per_second == 200);
  assert(kNetworkProbeRounds[3].burst_packets == 1);
  std::uint32_t total = 0;
  constexpr std::array<std::uint32_t, 8> boundaries{
      12'000, 24'000, 36'000, 42'000, 54'000, 66'000, 78'000, 84'000};
  for (std::size_t index = 0; index < kNetworkProbeRounds.size(); ++index) {
    total += kNetworkProbeRounds[index].packets_per_second *
             kNetworkProbeSecondsPerRound;
    assert(total == boundaries[index]);
  }

  const auto packet = MakeNetworkProbeDatagram(0x01020304, 0x11223344, 488);
  assert(packet.size() == 488);
  assert(packet[0] == std::byte{0x01});
  assert(packet[3] == std::byte{0x04});
  assert(packet[4] == std::byte{0x11});
  assert(packet[7] == std::byte{0x44});
  assert(packet[8] != packet[9]);
  const auto next = MakeNetworkProbeDatagram(0x01020304, 0x11223345, 488);
  assert(packet[8] != next[8]);
}
