#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <array>
#include <filesystem>
#include <chrono>
#include <iostream>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "hearport/windows/diagnostic_logger.h"
#include "hearport/windows/sender_authentication.h"
#include "hearport/windows/sender_options.h"
#include "hearport/windows/sender_service.h"

namespace {

std::filesystem::path ExecutableDirectory() {
  std::wstring buffer(32768, L'\0');
  const auto length = GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) return {};
  buffer.resize(length);
  return std::filesystem::path(buffer).parent_path();
}

}  // namespace

int main(int argc, char** argv) {
  std::vector<std::string_view> arguments;
  arguments.reserve(static_cast<std::size_t>(argc > 1 ? argc - 1 : 0));
  for (int index = 1; index < argc; ++index) {
    arguments.emplace_back(argv[index]);
  }
  auto parsed = hearport::windows::ParseSenderOptions(arguments);
  if (!parsed.has_value()) {
    std::cerr << "invalid sender arguments; --debug-seconds must be between "
                 "60 and 600, and certificate hashes must be valid hex\n";
    return 2;
  }
  auto options = std::move(parsed->quic);
  const auto open_pairing = parsed->open_pairing;
  const auto debug_seconds = parsed->debug_seconds;

  std::cerr << "HearPort sender requires a configured TLS certificate hash; "
               "pairing/authentication is not bypassed by this executable.\n";
  if (!options.has_certificate_sha1 || !options.has_certificate_spki_sha256) {
    std::cerr << "Provide certificate SHA-1 and current leaf SPKI SHA-256 "
                 "through the service host before starting a release listener.\n";
    return 2;
  }

  const auto executable_directory = ExecutableDirectory();
  if (executable_directory.empty()) {
    std::cerr << "unable to resolve sender executable directory\n";
    return 1;
  }
  const auto log_path = executable_directory / L"HearPort-sender.log";
  const auto report_root = executable_directory / L"HearPort-diagnostics";

  hearport::windows::SenderDiagnosticLogger logger;
  const bool logging_ready = logger.Start(log_path);
  if (logging_ready) {
    options.diagnostic_log = [&logger](std::string_view line) {
      logger.TryLog(line);
    };
    logger.TryLog("sender_start port=" + std::to_string(options.port));
    if (debug_seconds.has_value()) {
      logger.TryLog("sender_debug_mode duration_seconds=" +
                    std::to_string(*debug_seconds));
    }
    std::cout << "HearPort sender log: " << log_path.string() << '\n';
  } else {
    std::cerr << "unable to open sender log file: " << log_path.string()
              << "\nContinuing with console logging.\n";
  }
  std::cout << "HearPort iPad reports: " << report_root.string() << '\n';

  hearport::windows::SenderService service(options);
  service.ConfigureDebugDuration(
      debug_seconds.has_value()
          ? std::optional<std::chrono::seconds>(
                std::chrono::seconds(*debug_seconds))
          : std::nullopt);
  service.SetDebugOutputDirectory(report_root);
  hearport::security::Bytes32 spki = options.certificate_spki_sha256;
  hearport::windows::SenderAuthentication authentication(
      service, spki, {}, report_root);
  service.SetControlHandler([&](std::span<const std::byte> payload) {
    return authentication.HandleControlPayload(payload);
  });
  service.SetResetHandler([&] { authentication.OnCaptureReset(); });
  service.SetClosedHandler([&] { authentication.Reset(); });
  service.SetDebugEndedHandler(
      [&](std::array<std::byte, 16> session_id, std::uint32_t reason) {
        authentication.OnDebugSessionEnded(session_id, reason);
      });
  if (open_pairing && !authentication.OpenPairingWindow()) {
    std::cerr << "failed to open the authenticated pairing window\n";
    logger.Stop();
    return 1;
  }
  if (!service.Start()) {
    std::cerr << "failed to start WASAPI/MsQuic sender\n";
    logger.Stop();
    return 1;
  }
  if (open_pairing) {
    std::cout << "Pairing PIN: " << authentication.pairing_pin() << '\n';
  }
  std::cout << "HearPort sender listening on UDP " << options.port
            << '\n';
  if (debug_seconds.has_value()) {
    std::cout << "Timed diagnostics: " << *debug_seconds
              << " seconds after stream acknowledgement; waiting for the iPad "
                 "report.\n";
    const auto timeout = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::seconds(*debug_seconds) + std::chrono::minutes(7));
    const bool completed = service.WaitForDebugCompletion(timeout);
    service.Stop();
    logger.Stop();
    if (!completed) {
      std::cerr << "diagnostic session did not complete; inspect HearPort-sender.log\n";
      return 1;
    }
    std::cout << "iPad diagnostic report received and saved under: "
              << report_root.string() << '\n';
    return 0;
  }
  std::cout << "Press Enter to stop.\n";
  std::string line;
  std::getline(std::cin, line);
  service.Stop();
  logger.Stop();
  return 0;
}
