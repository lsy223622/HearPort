#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace hearport::windows {

struct MusicTestPolicy { bool reliable; bool adaptive; };
inline constexpr std::array<MusicTestPolicy, 8> kMusicTestPolicies{{
    {false, false}, {false, true}, {true, true}, {true, false},
    {true, false}, {true, true}, {false, true}, {false, false}}};
inline constexpr std::uint32_t kMusicRecoverySeconds = 5;

inline std::vector<std::byte> EncodeMusicTestRound(std::uint32_t round,
    std::uint32_t seconds, std::uint32_t first_sequence, std::uint32_t generation) {
  const auto policy = kMusicTestPolicies.at(round - 1);
  std::vector<std::byte> bytes{std::byte{3}, std::byte(round), std::byte{8},
      std::byte((policy.reliable ? 1 : 0) | (policy.adaptive ? 2 : 0)),
      std::byte(seconds >> 8), std::byte(seconds & 255), std::byte{0}, std::byte{0}};
  for (const auto value : {first_sequence, generation}) {
    for (int shift : {24, 16, 8, 0}) bytes.push_back(std::byte((value >> shift) & 255));
  }
  return bytes;
}

}  // namespace hearport::windows
