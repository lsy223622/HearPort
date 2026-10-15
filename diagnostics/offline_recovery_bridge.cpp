#include "offline_recovery_bridge.h"
static int offlineRecoveryLeadMilliseconds = 0;
#include "hearport/windows/reliable_audio_lag.h"

namespace {
using Lag = hearport::windows::ReliableAudioLag;
Lag::Clock::time_point time_at(uint64_t now) {
  return Lag::Clock::time_point(std::chrono::nanoseconds(now));
}
struct Context {
  Lag lag;
  uint32_t generation = 1;
  int budget;
  explicit Context(int value) : budget(value) {
    lag.Begin(7, generation, time_at(0), std::chrono::milliseconds(budget));
  }
};
}

void* offline_recovery_create(int budget_ms) { return new Context(budget_ms); }
void offline_recovery_destroy(void* context) { delete static_cast<Context*>(context); }
uint32_t offline_recovery_generation(void* context) {
  return static_cast<Context*>(context)->generation;
}
void offline_recovery_produced(void* context, uint32_t sequence, uint64_t captured, uint64_t now) {
  auto& state = *static_cast<Context*>(context);
  hearport::wire::TimedAudioRecord record;
  record.stream_id = 7;
  record.generation = state.generation;
  record.sequence = sequence;
  record.captured_at_ns = captured;
  record.source_frame = uint64_t(sequence) * 120;
  record.kind = hearport::wire::AudioRecordKind::probe;
  state.lag.Produced(sequence, record.source_frame + 120, 120);
  state.lag.Retain(record, now);
}
int offline_recovery_feedback(void* context, uint32_t generation, uint32_t received,
    uint64_t played, uint64_t generated, uint64_t now, int corrected, int replay, int lead_ms,
    uint32_t* replay_sequences, int capacity) {
  auto& state = *static_cast<Context*>(context);
  const auto age = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::nanoseconds(now - generated));
  if (age > std::chrono::milliseconds(state.budget) / 2) return -1;
  const auto received_value = received == UINT32_MAX ? std::nullopt : std::optional(received);
  const auto played_value = played == UINT64_MAX ? std::nullopt : std::optional(played);
  offlineRecoveryLeadMilliseconds = lead_ms;
  if (!state.lag.ConfirmReceived(7, generation, received_value, played_value) ||
      !state.lag.Observe(7, generation, received_value, time_at(now),
          corrected ? age : std::chrono::milliseconds(0), played_value)) return -1;
  const auto replays = replay ? state.lag.ReplayFresh(state.generation + 1, now, received_value, played_value)
                             : std::vector<hearport::wire::TimedAudioRecord>{};
  if (replays.size() > static_cast<size_t>(capacity)) return -2;
  ++state.generation;
  state.lag.Begin(7, state.generation, time_at(now), std::chrono::milliseconds(state.budget));
  for (size_t index = 0; index < replays.size(); ++index) {
    const auto& record = replays[index];
    replay_sequences[index] = record.sequence;
    state.lag.Produced(record.sequence, record.source_frame + record.frame_count, record.frame_count);
    state.lag.Retain(record, now);
  }
  return static_cast<int>(replays.size());
}
