#include "hearport/windows/network_probe.h"

#include <algorithm>
#include <array>
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
  candidates.reserve(kCoordinatedProbeRoundCount / 2);
  std::uint32_t state = stream_id ^ 0xa5a55a5au;
  if (state == 0) state = 1;
  std::array<std::uint8_t, kCoordinatedProbeProfiles.size()> order{};
  for (std::size_t index = 0; index < order.size(); ++index) {
    order[index] = static_cast<std::uint8_t>(index);
  }
  for (std::size_t remaining = order.size(); remaining > 1; --remaining) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    std::swap(order[remaining - 1], order[state % remaining]);
  }
  for (const auto variant : order) {
    for (const bool reliable : {false, true}) {
      auto round = kCoordinatedProbeProfiles[variant];
      round.reliable = reliable;
      candidates.push_back(round);
    }
  }
  auto rounds = candidates;
  for (auto item = candidates.rbegin(); item != candidates.rend(); ++item) {
    auto round = *item; round.repeat = 2; rounds.push_back(round);
  }
  return rounds;
}

std::vector<std::byte> EncodeProbeManifest(const std::vector<NetworkProbeRound>& rounds) {
  if (rounds.size() != kCoordinatedProbeRoundCount) {
    throw std::invalid_argument("invalid compression probe matrix size");
  }
  std::array<std::array<std::array<bool, 2>, kCoordinatedProbeProfiles.size()>, 2> seen{};
  for (const auto& round : rounds) {
    if (round.variant >= kCoordinatedProbeProfiles.size() ||
        round.payload_bytes != kCoordinatedProbeProfiles[round.variant].payload_bytes ||
        round.packets_per_second != kCoordinatedProbeProfiles[round.variant].packets_per_second ||
        round.burst_packets != 1 || (round.repeat != 1 && round.repeat != 2) ||
        round.controller != 2 || round.repair != 0 || round.correction_percent != 5) {
      throw std::invalid_argument("invalid compression probe profile");
    }
    auto& entry = seen[round.repeat - 1][round.variant][round.reliable ? 1 : 0];
    if (entry) throw std::invalid_argument("duplicate compression probe profile");
    entry = true;
  }
  for (const auto& repeat : seen) {
    for (const auto& profile : repeat) {
      if (!profile[0] || !profile[1]) {
        throw std::invalid_argument("incomplete compression probe matrix");
      }
    }
  }
  std::vector<std::byte> bytes{std::byte{3}, std::byte(rounds.size()), std::byte{30}, std::byte{kCoordinatedProbeRecoverySeconds}};
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
