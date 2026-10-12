#pragma once
#include "hearport/wire/audio_datagram.h"
#include <map>
#include <optional>

namespace hearport {
class RepairWindow {
 public:
  std::optional<wire::TimedAudioRecord> Add(const wire::TimedAudioRecord& record,
                                          std::uint64_t deadline);
  std::optional<wire::TimedAudioRecord> Recover(const wire::TimedAudioRecord& parity,
                                              std::uint64_t now);
  std::optional<wire::TimedAudioRecord> Retry(std::uint32_t sequence, std::uint64_t now);
  void Expire(std::uint64_t now);
  void Reset();
 private:
  struct Entry { wire::TimedAudioRecord record; std::uint64_t deadline; bool retried = false; };
  std::map<std::uint32_t, Entry> records_;
  std::uint32_t stream_ = 0, generation_ = 0;
};
}
