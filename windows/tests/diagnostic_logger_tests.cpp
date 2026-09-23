#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>

#include "hearport/windows/diagnostic_logger.h"

#undef assert
#define assert(condition)                                      \
  do {                                                          \
    if (!(condition)) {                                         \
      std::cerr << "assertion failed: " #condition << '\n';      \
      return 1;                                                  \
    }                                                           \
  } while (false)

int main() {
  const auto directory = std::filesystem::temp_directory_path() /
                         "HearPort-DiagnosticLogger-Test";
  std::filesystem::remove_all(directory);
  std::filesystem::create_directories(directory);
  const auto path = directory / "HearPort-sender.log";

  hearport::windows::SenderDiagnosticLogger logger;
  assert(logger.Start(path));
  const auto enqueue = [&logger](const std::string& line) {
    for (int attempt = 0; attempt < 1000; ++attempt) {
      if (logger.TryLog(line)) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
  };
  assert(enqueue("quic_connection_connected accepted=1"));
  for (int index = 0; index < 100; ++index) {
    assert(enqueue("quic_audio_summary packet=" + std::to_string(index)));
  }
  logger.Stop();

  std::ifstream input(path, std::ios::binary);
  const std::string contents{std::istreambuf_iterator<char>(input),
                             std::istreambuf_iterator<char>()};
  assert(contents.find("quic_connection_connected accepted=1") != std::string::npos);
  assert(contents.find("quic_audio_summary packet=99") != std::string::npos);
  input.close();
  std::filesystem::remove_all(directory);
  return 0;
}
