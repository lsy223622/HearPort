#include "hearport/repair_window.h"
#include <algorithm>

namespace hearport {
void RepairWindow::Reset() { records_.clear(); stream_ = generation_ = 0; }
void RepairWindow::Expire(std::uint64_t now) {
  std::erase_if(records_, [now](const auto& item) { return item.second.deadline <= now; });
}
std::optional<wire::TimedAudioRecord> RepairWindow::Add(const wire::TimedAudioRecord& record,
                                                      std::uint64_t deadline) {
  if (record.kind != wire::AudioRecordKind::audio && record.kind != wire::AudioRecordKind::probe)
    return {};
  if (stream_ != record.stream_id || generation_ != record.generation) {
    if (stream_ == record.stream_id && generation_ != 0 &&
        record.generation - generation_ >= 0x80000000u) return {};
    Reset(); stream_ = record.stream_id; generation_ = record.generation;
  }
  Expire(record.captured_at_ns);
  if (!records_.emplace(record.sequence, Entry{record, deadline}).second) return {};
  if (records_.size() > 256) {
    const auto oldest = std::min_element(records_.begin(), records_.end(), [](const auto& a, const auto& b) {
      return a.second.deadline < b.second.deadline;
    });
    records_.erase(oldest);
  }
  const auto first = record.sequence & ~3u;
  std::vector<std::byte> bytes;
  for (unsigned i = 0; i < 4; ++i) {
    const auto found = records_.find(first + i);
    if (found == records_.end()) return {};
    const auto encoded = wire::EncodeTimedAudioRecord(found->second.record);
    if (i == 0) bytes.resize(encoded.size());
    if (encoded.size() != bytes.size() || encoded.size() > 992) return {};
    for (std::size_t j = 0; j < bytes.size(); ++j) bytes[j] ^= encoded[j];
  }
  const auto& start = records_.at(first).record;
  return wire::TimedAudioRecord{stream_, generation_, first, 4, wire::AudioRecordKind::fec,
                               start.captured_at_ns, start.source_frame, std::move(bytes)};
}
std::optional<wire::TimedAudioRecord> RepairWindow::Recover(const wire::TimedAudioRecord& parity,
                                                          std::uint64_t now) {
  Expire(now);
  if (parity.kind != wire::AudioRecordKind::fec || parity.frame_count != 4 ||
      parity.stream_id != stream_ || parity.generation != generation_) return {};
  auto bytes = parity.payload;
  std::optional<std::uint32_t> missing;
  std::uint64_t deadline = UINT64_MAX;
  for (unsigned i = 0; i < 4; ++i) {
    const auto key = parity.sequence + i;
    const auto found = records_.find(key);
    if (found == records_.end()) { if (missing) return {}; missing = key; continue; }
    deadline = std::min(deadline, found->second.deadline);
    const auto encoded = wire::EncodeTimedAudioRecord(found->second.record);
    if (encoded.size() != bytes.size()) return {};
    for (std::size_t j = 0; j < bytes.size(); ++j) bytes[j] ^= encoded[j];
  }
  if (!missing || deadline <= now) return {};
  auto recovered = wire::DecodeTimedAudioRecord(bytes);
  if (!recovered || recovered->stream_id != stream_ || recovered->generation != generation_ ||
      recovered->sequence != *missing || (recovered->kind != wire::AudioRecordKind::audio &&
      recovered->kind != wire::AudioRecordKind::probe)) return {};
  records_.emplace(*missing, Entry{*recovered, deadline, true});
  recovered->kind = wire::AudioRecordKind::retransmission;
  return recovered;
}
std::optional<wire::TimedAudioRecord> RepairWindow::Retry(std::uint32_t sequence, std::uint64_t now) {
  Expire(now);
  const auto found = records_.find(sequence);
  if (found == records_.end() || found->second.retried) return {};
  found->second.retried = true;
  auto record = found->second.record;
  record.kind = wire::AudioRecordKind::retransmission;
  return record;
}
}
