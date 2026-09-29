#include <cassert>
#include <cstddef>
#include <cstdint>

#include "hearport/windows/network_probe.h"

int main() {
  using namespace hearport::windows;
  const auto rounds = MakeNetworkProbeRounds(7);
  static_assert(kNetworkProbeRoundCount == 20);
  constexpr std::array<std::uint8_t, 20> expected_variants{
      2, 1, 3, 0, 4, 4, 0, 3, 1, 2,
      0, 4, 2, 3, 1, 1, 3, 2, 4, 0};
  for (std::size_t index = 0; index < rounds.size(); ++index) {
    assert(rounds[index].variant == expected_variants[index]);
    assert(rounds[index].reliable == (index >= 10));
  }
  assert(rounds[4].payload_bytes == 488);
  assert(rounds[4].packets_per_second == 400);
  assert(rounds[4].burst_packets == 1);
  assert(rounds[9].variant == rounds[0].variant);
  assert(rounds[19].variant == rounds[10].variant);
  std::uint32_t total = 0;
  for (std::size_t index = 0; index < rounds.size(); ++index) {
    total += rounds[index].packets_per_second *
             kNetworkProbeSecondsPerRound;
  }
  assert(total == 216'000);

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
