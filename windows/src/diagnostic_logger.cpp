#include "hearport/windows/diagnostic_logger.h"

#include <algorithm>
#include <iostream>
#include <string>
#include <system_error>
#include <utility>

namespace hearport::windows {

SenderDiagnosticLogger::SenderDiagnosticLogger(std::size_t capacity,
                                               std::size_t max_file_bytes,
                                               std::size_t max_rotated_files)
    : capacity_(std::max<std::size_t>(1, capacity)),
      max_file_bytes_(std::max<std::size_t>(1, max_file_bytes)),
      max_rotated_files_(max_rotated_files),
      ordinary_file_bytes_(max_file_bytes_), ordinary_rotated_files_(max_rotated_files_),
      queue_(capacity_) {}

SenderDiagnosticLogger::~SenderDiagnosticLogger() { Stop(); }

bool SenderDiagnosticLogger::Start(const std::filesystem::path& path) {
  std::lock_guard lock(mutex_);
  if (started_ || writer_.joinable()) return false;
  file_path_ = path;
  file_.clear();
  file_.open(file_path_, std::ios::out | std::ios::binary | std::ios::trunc);
  if (!file_.is_open()) {
    file_path_.clear();
    return false;
  }
  file_bytes_ = 0;
  ApplyRetention();
  retention_changed_ = false;
  head_ = 0;
  tail_ = 0;
  count_ = 0;
  stopping_ = false;
  dropped_.store(0, std::memory_order_relaxed);
  try {
    writer_ = std::thread([this] { Writer(); });
  } catch (...) {
    file_.close();
    file_path_.clear();
    file_bytes_ = 0;
    return false;
  }
  started_ = true;
  return true;
}

bool SenderDiagnosticLogger::TryLog(std::string_view line) noexcept {
  if (!detailed_.load(std::memory_order_relaxed) && IsDetailedEvent(line)) return true;
  std::unique_lock lock(mutex_);
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

bool SenderDiagnosticLogger::IsDetailedEvent(std::string_view line) noexcept {
  if (line.starts_with("path=")) {
    const auto space = line.find(' ');
    if (space != std::string_view::npos) line.remove_prefix(space + 1);
  }
  const auto event = line.substr(0, line.find(' '));
  constexpr std::array events = {
      std::string_view("quic_control_send_queued"), std::string_view("quic_control_send_complete"),
      std::string_view("quic_control_receive"), std::string_view("quic_control_receive_handled"),
      std::string_view("network_probe_transport"), std::string_view("network_probe_repair_final")};
  return std::find(events.begin(), events.end(), event) != events.end();
}

void SenderDiagnosticLogger::SetDetailedLogging(bool enabled) {
  {
    std::lock_guard lock(mutex_);
    detailed_.store(enabled, std::memory_order_relaxed);
    retention_changed_ = true;
  }
  condition_.notify_one();
}

// Only the writer (or Start before launching it) changes files and limits.
void SenderDiagnosticLogger::ApplyRetention() noexcept {
  try {
    max_file_bytes_ = detailed_.load(std::memory_order_relaxed) ? 16 * 1024 * 1024 : ordinary_file_bytes_;
    max_rotated_files_ = detailed_.load(std::memory_order_relaxed) ? 7 : ordinary_rotated_files_;
    file_.close(); file_.clear();
    for (std::size_t index = 0; index <= std::max<std::size_t>(7, ordinary_rotated_files_); ++index) {
      auto path = file_path_;
      if (index) path += "." + std::to_string(index);
      std::error_code error;
      if (!std::filesystem::exists(path, error)) continue;
      if (index > max_rotated_files_) { std::filesystem::remove(path, error); continue; }
      const auto bytes = std::filesystem::file_size(path, error);
      if (error || bytes <= max_file_bytes_) continue;
      std::ifstream input(path, std::ios::binary);
      input.seekg(static_cast<std::streamoff>(bytes - max_file_bytes_));
      std::string suffix(max_file_bytes_, '\0');
      input.read(suffix.data(), static_cast<std::streamsize>(suffix.size()));
      if (!input) continue;
      input.close();
      const auto newline = suffix.find('\n');
      suffix.erase(0, newline == std::string::npos ? suffix.size() : newline + 1);
      std::ofstream output(path, std::ios::binary | std::ios::trunc);
      output.write(suffix.data(), static_cast<std::streamsize>(suffix.size()));
    }
    file_.open(file_path_, std::ios::out | std::ios::binary | std::ios::app);
    std::error_code error;
    file_bytes_ = static_cast<std::size_t>(std::filesystem::file_size(file_path_, error));
    if (error) file_bytes_ = 0;
  } catch (...) { DisableFileLogging(); }
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

bool SenderDiagnosticLogger::RotateFile() noexcept {
  try {
    if (!file_.is_open()) return false;
    file_.flush();
    if (!file_) return false;
    file_.close();
    if (file_.fail()) return false;

    const auto move_if_exists = [](const std::filesystem::path& source,
                                   const std::filesystem::path& destination) {
      std::error_code error;
      const bool destination_exists =
          std::filesystem::exists(destination, error);
      if (error) return false;
      if (destination_exists) {
        std::filesystem::remove(destination, error);
        if (error) return false;
      }

      const bool source_exists = std::filesystem::exists(source, error);
      if (error) return false;
      if (!source_exists) return true;
      std::filesystem::rename(source, destination, error);
      return !error;
    };

    for (std::size_t index = max_rotated_files_; index > 0; --index) {
      auto source = file_path_;
      if (index > 1) source += "." + std::to_string(index - 1);
      auto destination = file_path_;
      destination += "." + std::to_string(index);
      if (!move_if_exists(source, destination)) return false;
    }
    if (max_rotated_files_ == 0) {
      std::error_code error;
      std::filesystem::remove(file_path_, error);
      if (error) return false;
    }

    file_.open(file_path_, std::ios::out | std::ios::binary | std::ios::trunc);
    if (!file_.is_open()) return false;
    file_bytes_ = 0;
    return true;
  } catch (...) {
    return false;
  }
}

void SenderDiagnosticLogger::DisableFileLogging() noexcept {
  if (file_.is_open()) file_.close();
  file_.clear();
  file_path_.clear();
  file_bytes_ = 0;
}

bool SenderDiagnosticLogger::WriteFileLine(std::string_view line) noexcept {
  if (!file_.is_open()) return false;
  const auto line_limit = max_file_bytes_ > 1 ? max_file_bytes_ - 1 : 0;
  const auto file_line_length = std::min(line.size(), line_limit);
  const auto record_bytes = file_line_length + 1;
  if (file_bytes_ > 0 && record_bytes > max_file_bytes_ - file_bytes_) {
    if (!RotateFile()) {
      DisableFileLogging();
      std::cerr << "HearPort sender diagnostic file rotation failed; "
                   "continuing with console logging\n";
      return false;
    }
  }

  file_.write(line.data(), static_cast<std::streamsize>(file_line_length));
  file_.put('\n');
  if (!file_) {
    DisableFileLogging();
    std::cerr << "HearPort sender diagnostic file write failed; "
                 "continuing with console logging\n";
    return false;
  }
  file_bytes_ += record_bytes;
  return true;
}

void SenderDiagnosticLogger::Writer() noexcept {
  for (;;) {
    QueueSlot slot;
    {
      std::unique_lock lock(mutex_);
      condition_.wait(lock, [this] { return stopping_ || count_ != 0 || retention_changed_; });
      if (retention_changed_) { ApplyRetention(); retention_changed_ = false; }
      if (count_ == 0 && !stopping_) continue;
      if (count_ == 0 && stopping_) break;
      slot = queue_[head_];
      head_ = (head_ + 1) % capacity_;
      --count_;
    }
    if (file_.is_open()) {
      WriteFileLine(std::string_view(slot.bytes.data(), slot.length));
    }
    std::cerr.write(slot.bytes.data(), static_cast<std::streamsize>(slot.length));
    std::cerr.put('\n');
  }

  const auto dropped = dropped_.load(std::memory_order_relaxed);
  if (dropped != 0) {
    const auto line = "sender_diagnostic_log_dropped count=" + std::to_string(dropped);
    if (file_.is_open()) WriteFileLine(line);
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
