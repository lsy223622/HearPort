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

std::string_view ProbeSendStatusName(ProbeSendStatus status) noexcept {
  switch (status) {
    case ProbeSendStatus::expired: return "expired";
    case ProbeSendStatus::accepted: return "accepted";
    case ProbeSendStatus::disconnected: return "disconnected";
    case ProbeSendStatus::stream_unavailable: return "stream_unavailable";
    case ProbeSendStatus::pending_limit: return "pending_limit";
    case ProbeSendStatus::invalid_size: return "invalid_size";
    case ProbeSendStatus::datagram_unavailable: return "datagram_unavailable";
    case ProbeSendStatus::transport_rejected: return "transport_rejected";
  }
  return "unknown";
}

std::array<NetworkProbeRound, kNetworkProbeRoundCount> MakeNetworkProbeRounds(
    std::uint32_t stream_id) {
  std::array<NetworkProbeRound, kNetworkProbeRoundCount> rounds{};
  std::uint32_t state = stream_id ^ 0xa5a55a5au;
  if (state == 0) state = 1;
  std::size_t next = 0;
  std::array<std::uint8_t, kNetworkProbeVariants.size()> order{0, 1, 2, 3, 4};
  for (std::size_t remaining = order.size(); remaining > 1; --remaining) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    std::swap(order[remaining - 1], order[state % remaining]);
  }
  for (int repeat = 0; repeat < 2; ++repeat) {
    for (std::size_t offset = 0; offset < order.size(); ++offset) {
      for (int mode = 0; mode < 2; ++mode) {
        rounds[next] = kNetworkProbeVariants[
            order[repeat == 0 ? offset : order.size() - 1 - offset]];
        rounds[next].reliable = mode != repeat;
        rounds[next].repeat = static_cast<std::uint8_t>(repeat + 1);
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

std::vector<NetworkProbeRound> MakeCoordinatedProbeRounds(std::uint32_t stream_id) {
  std::vector<NetworkProbeRound> candidates;
  auto add = [&](std::size_t variant, bool reliable, std::uint8_t controller, std::uint8_t repair = 0) {
    auto round = kNetworkProbeVariants[variant];
    round.payload_bytes += 24;
    round.reliable = reliable;
    round.controller = controller;
    round.repair = repair;
    round.correction_percent = controller == 3 ? 10 : 5;
    candidates.push_back(round);
  };
  for (std::size_t variant = 0; variant < 5; ++variant)
    for (bool reliable : {false, true}) add(variant, reliable, 0);
  for (std::size_t variant : {1u, 3u, 4u})
    for (bool reliable : {false, true})
      for (std::uint8_t controller : {1, 2}) add(variant, reliable, controller);
  for (bool reliable : {false, true}) add(1, reliable, 3);
  for (std::size_t variant : {1u, 4u})
    for (std::uint8_t repair : {1, 2, 3}) add(variant, false, 2, repair);
  std::uint32_t state = stream_id ^ 0xa5a55a5au;
  if (state == 0) state = 1;
  for (std::size_t remaining = candidates.size(); remaining > 1; --remaining) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    std::swap(candidates[remaining - 1], candidates[state % remaining]);
  }
  auto rounds = candidates;
  for (auto item = candidates.rbegin(); item != candidates.rend(); ++item) {
    auto round = *item; round.repeat = 2; rounds.push_back(round);
  }
  return rounds;
}

std::vector<std::byte> EncodeProbeManifest(const std::vector<NetworkProbeRound>& rounds) {
  if (rounds.empty() || rounds.size() > 100) throw std::invalid_argument("invalid probe plan");
  std::vector<std::byte> bytes{std::byte{2}, std::byte(rounds.size()), std::byte{30}, std::byte{kCoordinatedProbeRecoverySeconds}};
  for (const auto& round : rounds) {
    bytes.push_back(std::byte(round.payload_bytes >> 8));
    bytes.push_back(std::byte(round.payload_bytes & 255));
    bytes.push_back(std::byte(round.packets_per_second >> 8));
    bytes.push_back(std::byte(round.packets_per_second & 255));
    for (unsigned value : {round.burst_packets, unsigned(round.variant), unsigned(round.reliable),
                          unsigned(round.repeat), unsigned(round.controller), unsigned(round.repair),
                          unsigned(round.correction_percent), 0u}) bytes.push_back(std::byte(value));
  }
  return bytes;
}

}  // namespace hearport::windows
