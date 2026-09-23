#include "hearport/windows/diagnostic_logger.h"

#include <algorithm>
#include <iostream>
#include <string>
#include <utility>

namespace hearport::windows {

SenderDiagnosticLogger::SenderDiagnosticLogger(std::size_t capacity)
    : capacity_(std::max<std::size_t>(1, capacity)), queue_(capacity_) {}

SenderDiagnosticLogger::~SenderDiagnosticLogger() { Stop(); }

bool SenderDiagnosticLogger::Start(const std::filesystem::path& path) {
  std::lock_guard lock(mutex_);
  if (started_ || writer_.joinable()) return false;
  file_.open(path, std::ios::out | std::ios::binary | std::ios::trunc);
  if (!file_.is_open()) return false;
  head_ = 0;
  tail_ = 0;
  count_ = 0;
  stopping_ = false;
  dropped_.store(0, std::memory_order_relaxed);
  try {
    writer_ = std::thread([this] { Writer(); });
  } catch (...) {
    file_.close();
    return false;
  }
  started_ = true;
  return true;
}

bool SenderDiagnosticLogger::TryLog(std::string_view line) noexcept {
  std::unique_lock lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) {
    dropped_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  if (!started_ || stopping_ || line.size() >= QueueSlot{}.bytes.size() ||
      count_ >= capacity_) {
    dropped_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  auto& slot = queue_[tail_];
  std::copy(line.begin(), line.end(), slot.bytes.begin());
  slot.length = line.size();
  tail_ = (tail_ + 1) % capacity_;
  ++count_;
  lock.unlock();
  condition_.notify_one();
  return true;
}

void SenderDiagnosticLogger::Stop() {
  {
    std::lock_guard lock(mutex_);
    if (!started_ && !writer_.joinable()) return;
    stopping_ = true;
  }
  condition_.notify_one();
  if (writer_.joinable()) writer_.join();
}

std::uint64_t SenderDiagnosticLogger::dropped_count() const noexcept {
  return dropped_.load(std::memory_order_relaxed);
}

void SenderDiagnosticLogger::Writer() noexcept {
  for (;;) {
    QueueSlot slot;
    {
      std::unique_lock lock(mutex_);
      condition_.wait(lock, [this] { return stopping_ || count_ != 0; });
      if (count_ == 0 && stopping_) break;
      slot = queue_[head_];
      head_ = (head_ + 1) % capacity_;
      --count_;
    }
    if (file_.is_open()) {
      file_.write(slot.bytes.data(), static_cast<std::streamsize>(slot.length));
      file_.put('\n');
      if (!file_) {
        file_.close();
        std::cerr << "HearPort sender diagnostic file write failed; "
                     "continuing with console logging\n";
      }
    }
    std::cerr.write(slot.bytes.data(), static_cast<std::streamsize>(slot.length));
    std::cerr.put('\n');
  }

  const auto dropped = dropped_.load(std::memory_order_relaxed);
  if (dropped != 0) {
    const auto line = "sender_diagnostic_log_dropped count=" + std::to_string(dropped);
    if (file_.is_open()) file_ << line << '\n';
    std::cerr << line << '\n';
  }
  if (file_.is_open()) {
    file_.flush();
    file_.close();
  }
  std::lock_guard lock(mutex_);
  started_ = false;
  stopping_ = false;
}

}  // namespace hearport::windows
