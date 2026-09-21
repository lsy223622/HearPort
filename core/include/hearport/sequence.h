#pragma once

#include <cstdint>

namespace hearport {

// RFC-style serial-number ordering for the v1 uint32 sequence space. Values
// exactly half a uint32 space apart are intentionally not newer.
constexpr bool IsSequenceNewer(std::uint32_t candidate,
                               std::uint32_t reference) noexcept {
  const auto delta = candidate - reference;
  return delta != 0 && delta < 0x80000000u;
}

}  // namespace hearport
