#include <array>
#include <cassert>
#include <iostream>
#include <string>
#include <string_view>

#include "hearport/windows/sender_options.h"

#undef assert
#define assert(condition)                                      \
  do {                                                          \
    if (!(condition)) {                                         \
      std::cerr << "assertion failed: " #condition << '\n';      \
      return 1;                                                  \
    }                                                           \
  } while (false)

using hearport::windows::ParseSenderOptions;

int main() {
  const auto ordinary_arguments = std::array<std::string_view, 3>{
      "--port=52137",
      "--cert-sha1=0123456789abcdef0123456789abcdef01234567",
      "--cert-spki-sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"};
  const auto ordinary = ParseSenderOptions(ordinary_arguments);
  assert(ordinary.has_value());
  assert(ordinary->quic.port == 52137);
  assert(!ordinary->open_pairing);
  assert(!ordinary->debug_seconds.has_value());

  for (const auto value : {"60", "300", "600"}) {
    std::string debug_argument = "--debug-seconds=";
    debug_argument += value;
    const std::array<std::string_view, 4> arguments{
        "--port=52137", "--cert-sha1=0123456789abcdef0123456789abcdef01234567",
        "--cert-spki-sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        debug_argument};
    const auto options = ParseSenderOptions(arguments);
    assert(options.has_value());
    assert(options->debug_seconds == static_cast<std::uint32_t>(std::stoi(value)));
  }

  for (const auto value : {"59", "601", "abc", ""}) {
    std::string debug_argument = "--debug-seconds=";
    debug_argument += value;
    const std::array<std::string_view, 4> arguments{
        "--port=52137", "--cert-sha1=0123456789abcdef0123456789abcdef01234567",
        "--cert-spki-sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        debug_argument};
    assert(!ParseSenderOptions(arguments).has_value());
  }
  return 0;
}
