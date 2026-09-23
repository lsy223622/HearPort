#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

#include "hearport/windows/quic_server.h"

namespace hearport::windows {

struct SenderOptions {
  QuicServerOptions quic;
  bool open_pairing = false;
  std::optional<std::uint32_t> debug_seconds;
};

std::optional<SenderOptions> ParseSenderOptions(
    std::span<const std::string_view> arguments);

}  // namespace hearport::windows
