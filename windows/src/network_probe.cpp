#include "hearport/windows/network_probe.h"

#include <algorithm>
#include <stdexcept>

namespace hearport::windows {
namespace {

void WriteU32(std::vector<std::byte>& bytes, std::size_t offset,
              std::uint32_t value) {
  for (int index = 3; index >= 0; --index) {
    bytes[offset + static_cast<std::size_t>(3 - index)] =
        std::byte{static_cast<std::uint8_t>(value >> (index * 8))};
  }
}

}  // namespace

std::array<NetworkProbeRound, kNetworkProbeRoundCount> MakeNetworkProbeRounds(
    std::uint32_t stream_id) {
  std::array<NetworkProbeRound, kNetworkProbeRoundCount> rounds{};
  std::uint32_t state = stream_id ^ 0xa5a55a5au;
  if (state == 0) state = 1;
  std::size_t next = 0;
  for (int mode = 0; mode < 2; ++mode) {
    std::array<std::uint8_t, kNetworkProbeVariants.size()> order{0, 1, 2, 3, 4};
    for (std::size_t remaining = order.size(); remaining > 1; --remaining) {
      state ^= state << 13;
      state ^= state >> 17;
      state ^= state << 5;
      std::swap(order[remaining - 1], order[state % remaining]);
    }
    for (int repeat = 0; repeat < 2; ++repeat) {
      for (std::size_t offset = 0; offset < order.size(); ++offset) {
        rounds[next] = kNetworkProbeVariants[
            order[repeat == 0 ? offset : order.size() - 1 - offset]];
        rounds[next].reliable = mode == 1;
        ++next;
      }
    }
  }
  return rounds;
}

std::vector<std::byte> MakeNetworkProbeDatagram(std::uint32_t stream_id,
                                                std::uint32_t sequence,
                                                std::size_t payload_bytes) {
  if (stream_id == 0 || payload_bytes < 8 || payload_bytes > 968) {
    throw std::invalid_argument("invalid network probe datagram size");
  }
  std::vector<std::byte> packet(payload_bytes);
  WriteU32(packet, 0, stream_id);
  WriteU32(packet, 4, sequence);
  std::uint32_t state = 0x4f7a91d3u ^ (sequence * 0x9e3779b9u);
  for (std::size_t index = 8; index < payload_bytes; ++index) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    packet[index] = std::byte{static_cast<std::uint8_t>(state)};
  }
  return packet;
}

}  // namespace hearport::windows
