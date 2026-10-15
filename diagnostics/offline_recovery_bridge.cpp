#include "offline_recovery_bridge.h"
#include <algorithm>
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
  int replay_mode;
  int startup;
  double capacity;
  std::optional<uint64_t> previous_played;
  uint64_t previous_generated = 0;
  double consumption_rate = 0;
  Context(int value, int mode, int delay, double rate)
      : budget(value), replay_mode(mode), startup(delay), capacity(rate) {
    lag.Begin(7, generation, time_at(0), std::chrono::milliseconds(budget));
  }
};
}

void* offline_recovery_create(int budget_ms, int replay_mode, int startup_ms, double send_mbps) {
  return new Context(budget_ms, replay_mode, startup_ms, send_mbps);
}
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
  if (generation != state.generation) return -1;
  if (played_value && state.previous_played && generated > state.previous_generated &&
      *played_value >= *state.previous_played) {
    state.consumption_rate = std::min(1.05, double(*played_value - *state.previous_played) *
        1'000'000'000 / double(generated - state.previous_generated) / 48000);
  } else {
    state.consumption_rate = 0;
  }
  state.previous_played = played_value;
  state.previous_generated = generated;
  offlineRecoveryLeadMilliseconds = lead_ms;
  if (!state.lag.ConfirmReceived(7, generation, received_value, played_value) ||
      !state.lag.Observe(7, generation, received_value, time_at(now),
          corrected ? age : std::chrono::milliseconds(0), played_value)) return -1;
  auto replays = replay ? state.lag.ReplayFresh(state.generation + 1, now, received_value, played_value)
                       : std::vector<hearport::wire::TimedAudioRecord>{};
  if ((state.replay_mode == 2 || state.replay_mode == 3) && state.capacity > 0) {
    const double spare = std::max(0.0, state.capacity * 1'000'000 - 992.0 * 8 * 400);
    const double horizon = std::max(0, state.budget - state.startup - 12) / 1000.0;
    const size_t limit = static_cast<size_t>(spare * horizon / (992 * 8));
    if (replays.size() > limit) replays.erase(replays.begin(), replays.end() - limit);
  }
  if (state.replay_mode > 0) {
    const auto service = state.capacity > 0 ? static_cast<uint64_t>(992 * 8 * 1000 / state.capacity) : 0;
    uint64_t arrival = now + (state.startup + 12) * 1'000'000ull + service;
    std::vector<hearport::wire::TimedAudioRecord> eligible;
    for (const auto& record : replays) {
      if (arrival >= record.captured_at_ns + state.budget * 1'000'000ull) continue;
      if (state.replay_mode >= 3 && played_value) {
        const auto projected = *played_value + static_cast<uint64_t>(
            double(arrival - generated) * 48000 / 1'000'000'000 * state.consumption_rate);
        if (record.source_frame + record.frame_count <= projected) continue;
      }
      eligible.push_back(record);
      arrival += service;
    }
    replays = std::move(eligible);
  }
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
