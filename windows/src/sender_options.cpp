#include "hearport/windows/sender_options.h"

#include <array>
#include <charconv>
#include <system_error>

namespace hearport::windows {
namespace {

int HexValue(char value) noexcept {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

template <std::size_t N>
bool ParseHex(std::string_view text, std::array<std::uint8_t, N>& output) {
  if (text.size() != N * 2) return false;
  for (std::size_t index = 0; index < N; ++index) {
    const auto high = HexValue(text[index * 2]);
    const auto low = HexValue(text[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    output[index] = static_cast<std::uint8_t>((high << 4) | low);
  }
  return true;
}

bool ParseSpki(std::string_view text, std::array<std::byte, 32>& output) {
  std::array<std::uint8_t, 32> parsed{};
  if (!ParseHex(text, parsed)) return false;
  for (std::size_t index = 0; index < output.size(); ++index) {
    output[index] = std::byte{parsed[index]};
  }
  return true;
}

template <typename Integer>
bool ParseInteger(std::string_view text, Integer& output) {
  if (text.empty()) return false;
  const auto result = std::from_chars(text.data(), text.data() + text.size(), output);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

}  // namespace

std::optional<SenderOptions> ParseSenderOptions(
    std::span<const std::string_view> arguments) {
  SenderOptions options;
  for (const auto argument : arguments) {
    if (argument.starts_with("--port=")) {
      std::uint16_t port = 0;
      if (!ParseInteger(argument.substr(7), port) || port == 0) {
        return std::nullopt;
      }
      options.quic.port = port;
    } else if (argument.starts_with("--cert-sha1=")) {
      if (!ParseHex(argument.substr(12), options.quic.certificate_sha1)) {
        return std::nullopt;
      }
      options.quic.has_certificate_sha1 = true;
    } else if (argument.starts_with("--cert-spki-sha256=")) {
      if (!ParseSpki(argument.substr(19), options.quic.certificate_spki_sha256)) {
        return std::nullopt;
      }
      options.quic.has_certificate_spki_sha256 = true;
    } else if (argument == "--open-pairing") {
      options.open_pairing = true;
    } else if (argument.starts_with("--debug-seconds=")) {
      std::uint32_t seconds = 0;
      if (!ParseInteger(argument.substr(16), seconds) ||
          seconds < 60 || seconds > 600) {
        return std::nullopt;
      }
      options.debug_seconds = seconds;
    } else {
      return std::nullopt;
    }
  }
  return options;
}

}  // namespace hearport::windows
