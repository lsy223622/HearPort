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
using hearport::windows::CaptureSource;

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
  assert(ordinary->capture_source == CaptureSource::process);
  const auto endpoint = ParseSenderOptions(std::array<std::string_view, 1>{"--capture=endpoint"});
  assert(endpoint && endpoint->capture_source == CaptureSource::endpoint);
  const auto process = ParseSenderOptions(std::array<std::string_view, 1>{"--capture=process"});
  assert(process && process->capture_source == CaptureSource::process);
  assert(!ParseSenderOptions(std::array<std::string_view, 1>{"--capture=unknown"}));

  for (const auto value : {"60", "300", "600", "610", "3600"}) {
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

  for (const auto value : {"59", "3601", "abc", ""}) {
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
