#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>
#include <condition_variable>

namespace hearport::windows {

class SenderDiagnosticLogger {
 public:
  explicit SenderDiagnosticLogger(std::size_t capacity = 1024);
  ~SenderDiagnosticLogger();
  SenderDiagnosticLogger(const SenderDiagnosticLogger&) = delete;
  SenderDiagnosticLogger& operator=(const SenderDiagnosticLogger&) = delete;

  bool Start(const std::filesystem::path& path);
  bool TryLog(std::string_view line) noexcept;
  void Stop();
  std::uint64_t dropped_count() const noexcept;

 private:
  struct QueueSlot {
    std::array<char, 2048> bytes{};
    std::size_t length = 0;
  };

  void Writer() noexcept;

  std::size_t capacity_;
  std::atomic<std::uint64_t> dropped_{0};
  std::vector<QueueSlot> queue_;
  std::size_t head_ = 0;
  std::size_t tail_ = 0;
  std::size_t count_ = 0;
  std::mutex mutex_;
  std::condition_variable condition_;
  std::ofstream file_;
  std::thread writer_;
  bool started_ = false;
  bool stopping_ = false;
};

}  // namespace hearport::windows
