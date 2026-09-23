#include "hearport/windows/debug_report_store.h"

#include <algorithm>
#include <iomanip>
#include <sstream>
#include <utility>

namespace hearport::windows {
namespace {

constexpr std::size_t kSessionIDBytes = 16;
constexpr std::size_t kMaximumChunkBytes = 60 * 1024;

std::string SessionHex(std::span<const std::byte> session_id) {
  if (session_id.size() != kSessionIDBytes) return {};
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const auto value : session_id) {
    output << std::setw(2) << std::to_integer<unsigned int>(value);
  }
  return output.str();
}

bool ReadFileSize(const std::filesystem::path& path, std::uintmax_t& size) {
  std::error_code error;
  size = std::filesystem::file_size(path, error);
  return !error;
}

}  // namespace

DebugReportStore::DebugReportStore(std::filesystem::path root,
                                   std::size_t maximum_report_bytes)
    : root_(std::move(root)), maximum_report_bytes_(maximum_report_bytes) {}

DebugReportStore::~DebugReportStore() {
  if (active_) Abort(current_session_id_);
}

DebugReportBeginResult DebugReportStore::Begin(
    std::span<const std::byte> session_id, std::uint32_t format_version,
    std::uint32_t total_bytes, std::uint32_t chunk_count) {
  std::lock_guard lock(mutex_);
  if (active_ || session_id.size() != kSessionIDBytes || format_version != 1 ||
      total_bytes == 0 || total_bytes > maximum_report_bytes_ ||
      chunk_count == 0 || chunk_count > total_bytes) {
    return DebugReportBeginResult::rejected;
  }
  const auto session_name = SessionHex(session_id);
  const auto final_directory = root_ / session_name;
  const auto final_report = final_directory / "ipad-report.txt";
  std::error_code error;
  const auto final_directory_exists =
      std::filesystem::exists(final_directory, error);
  if (error) return DebugReportBeginResult::rejected;
  if (final_directory_exists) {
    const auto final_report_exists =
        std::filesystem::exists(final_report, error);
    if (error) return DebugReportBeginResult::rejected;
    if (final_report_exists) {
      std::uintmax_t final_size = 0;
      if (ReadFileSize(final_report, final_size) && final_size == total_bytes) {
        std::copy(session_id.begin(), session_id.end(),
                  current_session_id_.begin());
        format_version_ = format_version;
        total_bytes_ = total_bytes;
        chunk_count_ = chunk_count;
        next_chunk_index_ = 0;
        bytes_written_ = 0;
        duplicate_complete_ = true;
        active_ = true;
        return DebugReportBeginResult::already_complete;
      }
      return DebugReportBeginResult::rejected;
    }
  }

  const auto partial_directory = root_ / (session_name + ".partial");
  std::filesystem::remove_all(partial_directory, error);
  if (error) return DebugReportBeginResult::rejected;
  std::filesystem::create_directories(partial_directory, error);
  if (error) return DebugReportBeginResult::rejected;
  output_.open(partial_directory / "ipad-report.txt",
               std::ios::binary | std::ios::out | std::ios::trunc);
  if (!output_.is_open()) {
    std::filesystem::remove_all(partial_directory, error);
    return DebugReportBeginResult::rejected;
  }

  std::copy(session_id.begin(), session_id.end(), current_session_id_.begin());
  format_version_ = format_version;
  total_bytes_ = total_bytes;
  chunk_count_ = chunk_count;
  next_chunk_index_ = 0;
  bytes_written_ = 0;
  duplicate_complete_ = false;
  active_ = true;
  return DebugReportBeginResult::started;
}

bool DebugReportStore::WriteChunk(std::span<const std::byte> session_id,
                                  std::uint32_t index,
                                  std::span<const std::byte> bytes) {
  std::lock_guard lock(mutex_);
  if (!active_ || !Matches(session_id) || index != next_chunk_index_ ||
      index >= chunk_count_ || bytes.empty() || bytes.size() > kMaximumChunkBytes ||
      bytes_written_ + bytes.size() > total_bytes_) {
    return false;
  }
  if (!duplicate_complete_) {
    output_.write(reinterpret_cast<const char*>(bytes.data()),
                  static_cast<std::streamsize>(bytes.size()));
    if (!output_) return false;
  }
  bytes_written_ += bytes.size();
  ++next_chunk_index_;
  return true;
}

bool DebugReportStore::Commit(std::span<const std::byte> session_id) {
  std::lock_guard lock(mutex_);
  if (!active_ || !Matches(session_id) || next_chunk_index_ != chunk_count_ ||
      bytes_written_ != total_bytes_) {
    return false;
  }
  if (duplicate_complete_) {
    ResetActive();
    return true;
  }

  output_.flush();
  if (!output_) return false;
  output_.close();
  const auto session_name = SessionHex(session_id);
  const auto partial_directory = root_ / (session_name + ".partial");
  const auto final_directory = root_ / session_name;
  const auto partial_report = partial_directory / "ipad-report.txt";
  const auto final_report = final_directory / "ipad-report.txt";
  std::uintmax_t written_size = 0;
  if (!ReadFileSize(partial_report, written_size) ||
      written_size != total_bytes_) {
    return false;
  }
  std::error_code error;
  std::filesystem::create_directories(final_directory, error);
  if (error) return false;
  std::filesystem::rename(partial_report, final_report, error);
  if (error) return false;
  std::filesystem::remove(partial_directory, error);
  if (error) return false;
  ResetActive();
  return true;
}

void DebugReportStore::Abort(std::span<const std::byte> session_id) {
  std::lock_guard lock(mutex_);
  if (!active_ || !Matches(session_id)) return;
  if (output_.is_open()) output_.close();
  if (!duplicate_complete_) {
    std::error_code error;
    std::filesystem::remove_all(PartialDirectory(session_id), error);
  }
  ResetActive();
}

bool DebugReportStore::Matches(
    std::span<const std::byte> session_id) const noexcept {
  return session_id.size() == current_session_id_.size() &&
         std::equal(session_id.begin(), session_id.end(),
                    current_session_id_.begin());
}

void DebugReportStore::ResetActive() noexcept {
  if (output_.is_open()) output_.close();
  current_session_id_.fill(std::byte{0});
  format_version_ = 0;
  total_bytes_ = 0;
  chunk_count_ = 0;
  next_chunk_index_ = 0;
  bytes_written_ = 0;
  active_ = false;
  duplicate_complete_ = false;
}

std::filesystem::path DebugReportStore::SessionDirectory(
    std::span<const std::byte> session_id) const {
  const auto name = SessionHex(session_id);
  return name.empty() ? std::filesystem::path{} : root_ / name;
}
std::filesystem::path DebugReportStore::PartialDirectory(
    std::span<const std::byte> session_id) const {
  const auto name = SessionHex(session_id);
  return name.empty() ? std::filesystem::path{} : root_ / (name + ".partial");
}

}  // namespace hearport::windows
