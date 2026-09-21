#include <charconv>
#include <array>
#include <cstdint>
#include <iostream>
#include <string_view>

#include "hearport/windows/sender_service.h"

namespace {

int HexValue(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

bool ParseSha1(std::string_view text,
               std::array<std::uint8_t, 20>& output) {
  if (text.size() != output.size() * 2) return false;
  for (std::size_t index = 0; index < output.size(); ++index) {
    const auto high = HexValue(text[index * 2]);
    const auto low = HexValue(text[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    output[index] = static_cast<std::uint8_t>((high << 4) | low);
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  hearport::windows::QuicServerOptions options;
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument(argv[index]);
    constexpr std::string_view prefix = "--port=";
    if (argument.starts_with(prefix)) {
      const auto text = argument.substr(prefix.size());
      std::uint16_t port = 0;
      const auto result = std::from_chars(text.data(), text.data() + text.size(),
                                          port);
      if (result.ec != std::errc{} || port == 0) {
        std::cerr << "invalid --port value\n";
        return 2;
      }
      options.port = port;
      continue;
    }
    constexpr std::string_view certificate_prefix = "--cert-sha1=";
    if (argument.starts_with(certificate_prefix)) {
      if (!ParseSha1(argument.substr(certificate_prefix.size()),
                      options.certificate_sha1)) {
        std::cerr << "invalid --cert-sha1 value; expected 40 hex characters\n";
        return 2;
      }
      options.has_certificate_sha1 = true;
    }
  }

  std::cerr << "HearPort sender requires a configured TLS certificate hash; "
               "pairing/authentication is not bypassed by this executable.\n";
  if (!options.has_certificate_sha1) {
    std::cerr << "Provide certificate configuration through the service host "
                 "before starting a release listener.\n";
    return 2;
  }

  hearport::windows::SenderService service(options);
  if (!service.Start()) {
    std::cerr << "failed to start WASAPI/MsQuic sender\n";
    return 1;
  }
  std::cout << "HearPort sender listening on UDP " << options.port
            << "; press Enter to stop.\n";
  std::string line;
  std::getline(std::cin, line);
  service.Stop();
  return 0;
}
