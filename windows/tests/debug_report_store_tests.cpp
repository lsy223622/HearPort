#include <array>
#include <cassert>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include "hearport/windows/debug_report_store.h"

#undef assert
#define assert(condition)                                      \
  do {                                                          \
    if (!(condition)) {                                         \
      std::cerr << "assertion failed: " #condition << '\n';      \
      return 1;                                                  \
    }                                                           \
  } while (false)

using hearport::windows::DebugReportBeginResult;
using hearport::windows::DebugReportStore;

namespace {

std::array<std::byte, 16> Id(unsigned char value) {
  std::array<std::byte, 16> id{};
  id.fill(std::byte{value});
  return id;
}

std::vector<std::byte> Bytes(std::string_view value) {
  std::vector<std::byte> bytes;
  bytes.reserve(value.size());
  for (const auto ch : value) bytes.push_back(std::byte{static_cast<unsigned char>(ch)});
  return bytes;
}

std::string Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

}  // namespace

int main() {
  const auto root = std::filesystem::temp_directory_path() /
                    "HearPort-DebugReportStore-Test";
  std::filesystem::remove_all(root);
  const auto id = Id(0x42);
  DebugReportStore store(root);
  std::filesystem::create_directories(store.SessionDirectory(id));
  {
    std::ofstream sender_trace(store.SessionDirectory(id) / "sender-trace.jsonl",
                               std::ios::binary);
    sender_trace << "sender trace";
  }
  const auto first = Bytes("abcde");
  const auto second = Bytes("fghij");

  assert(store.Begin(id, 1, 10, 2) == DebugReportBeginResult::started);
  assert(store.WriteChunk(id, 0, first));
  assert(!store.WriteChunk(id, 2, second));
  assert(!store.WriteChunk(id, 0, first));
  assert(store.WriteChunk(id, 1, second));
  assert(store.Commit(id));
  const auto report_path = store.SessionDirectory(id) / "ipad-report.txt";
  assert(Read(report_path) == "abcdefghij");
  assert(Read(store.SessionDirectory(id) / "sender-trace.jsonl") ==
         "sender trace");
  assert(!std::filesystem::exists(store.PartialDirectory(id)));

  assert(store.Begin(id, 1, 10, 2) == DebugReportBeginResult::already_complete);
  assert(store.WriteChunk(id, 0, first));
  assert(store.WriteChunk(id, 1, second));
  assert(store.Commit(id));
  assert(Read(report_path) == "abcdefghij");

  const auto incomplete_id = Id(0x33);
  std::filesystem::create_directories(store.PartialDirectory(incomplete_id));
  {
    std::ofstream stale(store.PartialDirectory(incomplete_id) / "ipad-report.txt",
                        std::ios::binary);
    stale << "stale partial report";
  }
  assert(store.Begin(incomplete_id, 1, 10, 2) == DebugReportBeginResult::started);
  assert(std::filesystem::file_size(
             store.PartialDirectory(incomplete_id) / "ipad-report.txt") == 0);
  assert(store.WriteChunk(incomplete_id, 0, first));
  assert(!store.Commit(incomplete_id));
  store.Abort(incomplete_id);
  assert(!std::filesystem::exists(store.PartialDirectory(incomplete_id)));

  const auto oversized_id = Id(0x11);
  assert(store.Begin(oversized_id, 1, 60 * 1024 + 1, 1) ==
         DebugReportBeginResult::started);
  std::vector<std::byte> oversized(60 * 1024 + 1);
  assert(!store.WriteChunk(oversized_id, 0, oversized));
  store.Abort(oversized_id);

  const auto maximum_chunk_id = Id(0x12);
  assert(store.Begin(maximum_chunk_id, 1, 60 * 1024, 1) ==
         DebugReportBeginResult::started);
  std::vector<std::byte> maximum_chunk(60 * 1024, std::byte{0x5a});
  assert(store.WriteChunk(maximum_chunk_id, 0, maximum_chunk));
  assert(store.Commit(maximum_chunk_id));
  assert(std::filesystem::file_size(
             store.SessionDirectory(maximum_chunk_id) / "ipad-report.txt") ==
         60 * 1024);
  std::filesystem::remove_all(root);
  return 0;
}
