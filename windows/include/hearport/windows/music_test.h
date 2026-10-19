#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace hearport::windows {

struct MusicTestPolicy {
  bool reliable = false;
  bool adaptive = true;
  std::uint8_t profile = 0, repeat = 1;
  std::uint16_t frames = 120, bitrate_kbps = 0;
  bool operator==(const MusicTestPolicy&) const = default;
};
inline constexpr std::uint32_t kMusicTestRoundCount = 32;
inline constexpr std::uint32_t kMusicRecoverySeconds = 5;

inline MusicTestPolicy MusicProfile(std::uint8_t profile) {
  if (profile > 7) throw std::invalid_argument("invalid music profile");
  MusicTestPolicy result;
  result.profile = profile;
  if (profile >= 2) {
    result.frames = std::array<std::uint16_t, 3>{120, 240, 480}[(profile - 2) % 3];
    result.bitrate_kbps = profile < 5 ? 192 : 256;
  }
  return result;
}

inline std::array<MusicTestPolicy, kMusicTestRoundCount> MakeMusicTestPolicies(std::uint32_t seed) {
  std::array<std::uint8_t, 8> order{0, 1, 2, 3, 4, 5, 6, 7};
  auto state = seed ^ 0x47a391bdu;
  if (!state) state = 1;
  for (std::size_t remaining = order.size(); remaining > 1; --remaining) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    std::swap(order[remaining - 1], order[state % remaining]);
  }
  std::array<MusicTestPolicy, kMusicTestRoundCount> result{};
  for (std::size_t i = 0; i < 16; ++i) {
    auto policy = MusicProfile(order[i / 2]);
    policy.reliable = (i % 2) != (seed % 2);
    result[i] = policy;
    policy.repeat = 2;
    result[31 - i] = policy;
  }
  return result;
}

inline std::vector<std::byte> EncodeMusicTestRound(std::uint32_t round,
    std::uint32_t seconds, std::uint32_t first_sequence, std::uint32_t generation,
    MusicTestPolicy policy, std::uint16_t lookahead) {
  const auto expected = MusicProfile(policy.profile);
  if (round < 1 || round > kMusicTestRoundCount || seconds < 60 || seconds > 300 ||
      first_sequence != (round - 1) * seconds * 400 || !generation ||
      policy.frames != expected.frames || policy.bitrate_kbps != expected.bitrate_kbps ||
      policy.repeat < 1 || policy.repeat > 2 || !policy.adaptive ||
      (policy.profile < 2 && lookahead != 0) || lookahead > 960)
    throw std::invalid_argument("invalid compression music round");
  std::vector<std::byte> bytes{std::byte{4}, std::byte(round), std::byte{kMusicTestRoundCount},
      std::byte((policy.reliable ? 1 : 0) | (policy.adaptive ? 2 : 0)),
      std::byte(seconds >> 8), std::byte(seconds & 255), std::byte{policy.profile}, std::byte{policy.repeat}};
  for (const auto value : {first_sequence, generation}) {
    for (int shift : {24, 16, 8, 0}) bytes.push_back(std::byte((value >> shift) & 255));
  }
  for (const auto value : {policy.frames, policy.bitrate_kbps, lookahead, std::uint16_t{0}}) {
    bytes.push_back(std::byte(value >> 8)); bytes.push_back(std::byte(value & 255));
  }
  return bytes;
}

}  // namespace hearport::windows
