#include <cassert>
#include <atomic>
#include <array>
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
  hearport::windows::SenderDiagnosticLogger concurrent(2048);
  assert(concurrent.Start(path));
  std::atomic<std::size_t> accepted = 0;
  std::array<std::thread, 4> writers;
  for (auto& writer : writers) {
    writer = std::thread([&] {
      for (int index = 0; index < 200; ++index) {
        if (concurrent.TryLog("network_probe_round_end test=concurrent")) ++accepted;
      }
    });
  }
  for (auto& writer : writers) writer.join();
  concurrent.Stop();
  assert(accepted == 800);
  assert(concurrent.dropped_count() == 0);
  std::ifstream concurrent_input(path);
  std::string line;
  std::size_t written = 0;
  while (std::getline(concurrent_input, line)) ++written;
  assert(written == 800);
  concurrent_input.close();

  constexpr std::size_t kRotationFileBytes = 64;
  constexpr std::size_t kRotationBackups = 3;
  hearport::windows::SenderDiagnosticLogger rotating(
      64, kRotationFileBytes, kRotationBackups);
  assert(rotating.Start(path));
  const auto enqueue_rotating = [&rotating](const std::string& entry) {
    for (int attempt = 0; attempt < 1000; ++attempt) {
      if (rotating.TryLog(entry)) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
  };
  for (int index = 0; index < 40; ++index) {
    assert(enqueue_rotating("rotation_entry_" + std::to_string(index)));
  }
  rotating.Stop();

  std::string retained;
  std::size_t retained_bytes = 0;
  for (std::size_t index = 0; index <= kRotationBackups; ++index) {
    auto retained_path = path;
    if (index != 0) {
      retained_path += L".";
      retained_path += std::to_wstring(index);
    }
    assert(std::filesystem::exists(retained_path));
    const auto bytes = std::filesystem::file_size(retained_path);
    assert(bytes <= kRotationFileBytes);
    retained_bytes += static_cast<std::size_t>(bytes);
    std::ifstream retained_input(retained_path, std::ios::binary);
    retained.append(std::istreambuf_iterator<char>(retained_input),
                    std::istreambuf_iterator<char>());
  }
  assert(retained_bytes <= kRotationFileBytes * (kRotationBackups + 1));
  assert(retained.find("rotation_entry_39\n") != std::string::npos);
  assert(retained.find("rotation_entry_30\n") != std::string::npos);
  assert(retained.find("rotation_entry_0\n") == std::string::npos);
  assert(rotating.dropped_count() == 0);
  std::filesystem::remove_all(directory);
  return 0;
}
