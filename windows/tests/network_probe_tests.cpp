#include <cassert>
#include <chrono>
#include <cstddef>
#include <cstdint>

#include "hearport/windows/network_probe.h"
#include "hearport/windows/sender_service.h"

int main() {
  using namespace hearport::windows;
  SenderService sender(QuicServerOptions{});
  sender.ConfigureNetworkProbe(true);
  sender.ConfigureDebugDuration(std::chrono::seconds(kNetworkProbeDurationSeconds));
  assert(sender.debug_duration() == std::chrono::seconds(610));
  sender.ConfigureDebugDuration(std::chrono::seconds(3600));
  assert(sender.debug_duration() == std::chrono::seconds(3600));
  const auto rounds = MakeNetworkProbeRounds(7);
  static_assert(kNetworkProbeRoundCount == 20);
  constexpr std::array<std::uint8_t, 20> expected_variants{
      2, 2, 1, 1, 3, 3, 0, 0, 4, 4,
      4, 4, 0, 0, 3, 3, 1, 1, 2, 2};
  for (std::size_t index = 0; index < rounds.size(); ++index) {
    assert(rounds[index].variant == expected_variants[index]);
    assert(rounds[index].reliable == ((index % 2) != (index / 10)));
    assert(rounds[index].repeat == index / 10 + 1);
  }
  assert(rounds[8].payload_bytes == 488);
  assert(rounds[8].packets_per_second == 400);
  assert(rounds[8].burst_packets == 1);
  for (std::size_t index = 0; index < 10; ++index) {
    assert(rounds[index].variant == rounds[19 - index].variant);
    assert(rounds[index].reliable == rounds[19 - index].reliable);
  }
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
  const auto coordinated = MakeCoordinatedProbeRounds(7);
  assert(coordinated.size() == 60);
  const auto manifest = EncodeProbeManifest(coordinated);
  assert(manifest.size() == 724);
  assert(manifest[0] == std::byte{2} && manifest[1] == std::byte{60});
  assert(manifest[3] == std::byte{5});
  assert(kCoordinatedProbeDurationSeconds == 2105);
  std::uint32_t source_seconds = 0;
  for (const auto& round : coordinated) {
    assert(round.payload_bytes == 512 || round.payload_bytes == 992);
    assert(!round.reliable || round.repair == 0);
    source_seconds += kNetworkProbeSecondsPerRound;
  }
  assert(source_seconds == 1800);
}
