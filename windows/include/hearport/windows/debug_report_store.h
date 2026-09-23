#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <span>
#include <array>

namespace hearport::windows {

enum class DebugReportBeginResult {
  started,
  already_complete,
  rejected,
};

class DebugReportStore {
 public:
  explicit DebugReportStore(std::filesystem::path root,
                            std::size_t maximum_report_bytes = 32 * 1024 * 1024);
  ~DebugReportStore();
  DebugReportBeginResult Begin(std::span<const std::byte> session_id,
                               std::uint32_t format_version,
                               std::uint32_t total_bytes,
                               std::uint32_t chunk_count);
  bool WriteChunk(std::span<const std::byte> session_id,
                  std::uint32_t index,
                  std::span<const std::byte> bytes);
  bool Commit(std::span<const std::byte> session_id);
  void Abort(std::span<const std::byte> session_id);
  std::filesystem::path SessionDirectory(
      std::span<const std::byte> session_id) const;
  std::filesystem::path PartialDirectory(
      std::span<const std::byte> session_id) const;

 private:
  bool Matches(std::span<const std::byte> session_id) const noexcept;
  void ResetActive() noexcept;

  std::filesystem::path root_;
  std::size_t maximum_report_bytes_;
  mutable std::mutex mutex_;
  std::ofstream output_;
  std::array<std::byte, 16> current_session_id_{};
  std::uint32_t format_version_ = 0;
  std::uint32_t total_bytes_ = 0;
  std::uint32_t chunk_count_ = 0;
  std::uint32_t next_chunk_index_ = 0;
  std::size_t bytes_written_ = 0;
  bool active_ = false;
  bool duplicate_complete_ = false;
};

}  // namespace hearport::windows
