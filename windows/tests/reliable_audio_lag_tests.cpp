#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include "hearport/wire/audio_datagram.h"

#include "hearport/windows/reliable_audio_lag.h"

int main() {
#ifdef _MSC_VER
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
#endif
  using hearport::windows::ReliableAudioLag;
  using Clock = std::chrono::steady_clock;
  const auto start = Clock::time_point{};
  ReliableAudioLag lag;
  lag.Begin(7, 1, start);
  for (std::uint32_t sequence = 0; sequence <= 100; ++sequence) {
    lag.Produced(sequence);
  }
  assert(!lag.Observe(7, 1, 20, start + std::chrono::milliseconds(100)));
  assert(!lag.Observe(7, 1, 19, start + std::chrono::milliseconds(200)));
  assert(!lag.Observe(7, 2, 0, start + std::chrono::milliseconds(300)));
  assert(!lag.Observe(7, 1, 19, start + std::chrono::milliseconds(300)));
  assert(!lag.Observe(7, 1, 19, start + std::chrono::milliseconds(600)));
  for (std::uint32_t sequence = 101; sequence <= 200; ++sequence) {
    lag.Produced(sequence);
  }
  assert(!lag.Observe(7, 1, 39, start + std::chrono::milliseconds(700)));
  assert(lag.Observe(7, 1, 39, start + std::chrono::milliseconds(800)));

  lag.Begin(7, 2, start + std::chrono::milliseconds(800));
  for (std::uint32_t sequence = 0xfffffff0u; sequence != 6; ++sequence) {
    lag.Produced(sequence);
  }
  assert(!lag.Observe(7, 2, 0xfffffff0u,
                      start + std::chrono::milliseconds(1200)));
  assert(!lag.Observe(7, 2, 5, start + std::chrono::milliseconds(1300)));

  lag.Begin(7, 3, start + std::chrono::milliseconds(1400));
  for (std::uint32_t sequence = 0; sequence < 80; ++sequence) {
    lag.Produced(sequence);
  }
  assert(!lag.Observe(7, 3, std::nullopt,
                      start + std::chrono::milliseconds(2000)));
  lag.Produced(80);
  assert(!lag.Observe(7, 3, std::nullopt,
                      start + std::chrono::milliseconds(2100)));
  for (std::uint32_t sequence = 81; sequence <= 160; ++sequence) {
    lag.Produced(sequence);
  }
  assert(!lag.Observe(7, 3, std::nullopt,
                      start + std::chrono::milliseconds(2200)));
  assert(lag.Observe(7, 3, std::nullopt,
                     start + std::chrono::milliseconds(2300)));

  lag.Begin(7, 4, start + std::chrono::milliseconds(2400));
  assert(!lag.Observe(7, 4, std::nullopt,
                      start + std::chrono::milliseconds(3000)));
  lag.Begin(7, 5, start, std::chrono::milliseconds(100));
  for (std::uint32_t sequence = 0; sequence <= 60; ++sequence) lag.Produced(sequence);
  assert(!lag.Observe(7, 4, 0, start + std::chrono::milliseconds(10)));
  assert(!lag.Observe(7, 5, 0, start + std::chrono::milliseconds(10),
                      std::chrono::milliseconds(200)));
  assert(lag.Observe(7, 5, 0, start + std::chrono::milliseconds(20)));
  lag.Begin(7, 6, start, std::chrono::milliseconds(600));
  lag.Produced(140, 33'840, 240);
  assert(!lag.Observe(7, 6, 140, start + std::chrono::milliseconds(10),
                     std::chrono::milliseconds(0), 0));
  lag.Begin(7, 7, start, std::chrono::milliseconds(100));
  lag.Produced(30, 7'440, 240);
  assert(!lag.Observe(7, 7, 30, start + std::chrono::milliseconds(10),
                      std::chrono::milliseconds(0), 4'800));
  assert(!lag.Observe(7, 7, 30, start + std::chrono::milliseconds(10),
                     std::chrono::milliseconds(0), 2'400));
  lag.Begin(7, 8, start, std::chrono::milliseconds(100));
  for (std::uint32_t sequence = 0; sequence < 50; ++sequence) {
    lag.Produced(sequence, std::uint64_t(sequence + 1) * 240, 240);
  }
  assert(!lag.Observe(7, 8, 49, start + std::chrono::milliseconds(500),
                      std::chrono::milliseconds(0), 0));
  assert(lag.Observe(7, 8, 10, start + std::chrono::milliseconds(500),
                     std::chrono::milliseconds(0), 0));
  lag.Begin(7, 9, start, std::chrono::milliseconds(100));
  for (std::uint32_t sequence = 0; sequence < 5; ++sequence) {
    hearport::wire::TimedAudioRecord record;
    record.stream_id = 7; record.generation = 9; record.sequence = sequence;
    record.kind = hearport::wire::AudioRecordKind::probe;
    record.source_frame = sequence * 120; record.frame_count = 120;
    record.captured_at_ns = 1'000'000'000 + sequence * 10'000'000;
    record.payload = {std::byte{1}, std::byte{2}};
    lag.Retain(record, record.captured_at_ns);
  }
  assert(!lag.ConfirmReceived(7, 8, 4, std::nullopt));
  const auto replay = lag.ReplayFresh(10, 1'110'000'000, 1, 360);
  assert(replay.size() == 2);
  assert(replay[0].sequence == 3 && replay[1].sequence == 4);
  assert(replay[0].generation == 10);
  assert(replay[0].kind == hearport::wire::AudioRecordKind::retransmission);
  assert(replay[0].captured_at_ns == 1'030'000'000);
  assert(lag.ConfirmReceived(7, 9, 3, std::nullopt));
  assert(lag.ReplayFresh(10, 1'110'000'000, std::nullopt, std::nullopt).size() == 1);
  assert(lag.ReplayFresh(10, 1'200'000'000, std::nullopt, std::nullopt).empty());
  lag.Begin(7, 10, start, std::chrono::milliseconds(100));
  assert(lag.ReplayFresh(11, 1'110'000'000, std::nullopt, std::nullopt).empty());
  hearport::wire::TimedAudioRecord audio;
  audio.stream_id = 7; audio.generation = 10; audio.kind = hearport::wire::AudioRecordKind::audio;
  audio.captured_at_ns = 1'110'000'000;
  audio.payload.assign(960, std::byte{1});
  lag.Retain(audio, audio.captured_at_ns);
  const auto audio_replay = lag.ReplayFresh(11, 1'120'000'000, std::nullopt, std::nullopt);
  assert(audio_replay.size() == 1 && audio_replay[0].kind == hearport::wire::AudioRecordKind::audio);
  assert(hearport::wire::EncodeTimedAudioRecord(audio_replay[0]).size() == 992);

  lag.Begin(7, 11, start, std::chrono::milliseconds(89));
  lag.Produced(100431);
  assert(!lag.Observe(7, 11, 100391, start + std::chrono::milliseconds(120),
                      std::chrono::milliseconds(23)));
  assert(!lag.Observe(7, 11, 100387, start + std::chrono::milliseconds(120),
                      std::chrono::milliseconds(21)));
  assert(lag.Observe(7, 11, 100386, start + std::chrono::milliseconds(120),
                     std::chrono::milliseconds(23)));

  lag.Begin(7, 12, start, std::chrono::milliseconds(89));
  for (std::uint32_t sequence = 0; sequence < 40; ++sequence) lag.Produced(sequence);
  assert(!lag.Observe(7, 12, std::nullopt, start + std::chrono::milliseconds(120),
                      std::chrono::milliseconds(23)));
  lag.Produced(40, 5'040);
  assert(!lag.Observe(7, 12, std::nullopt, start + std::chrono::milliseconds(120),
                      std::chrono::milliseconds(23), 240));
  assert(lag.Observe(7, 12, std::nullopt, start + std::chrono::milliseconds(120),
                     std::chrono::milliseconds(10), 240));


  lag.Begin(7, 13, start, std::chrono::milliseconds(100));
  for (std::uint32_t sequence = 0; sequence < 20; ++sequence) {
    audio.generation = 13; audio.sequence = sequence;
    audio.source_frame = sequence * 120; audio.frame_count = 120;
    audio.captured_at_ns = 1'000'000'000 + sequence * 2'500'000ull;
    lag.Retain(audio, audio.captured_at_ns);
  }
  ReliableAudioLag::ReplayBudget budget;
  budget.delivery_delay_ns = 10'000'000;
  assert(lag.ReplayForDelivery(14, 1'050'000'000, {}, {}, budget).empty());
  budget.bytes_per_second = 300'000;
  assert(lag.ReplayForDelivery(14, 1'050'000'000, {}, {}, budget).empty());
  budget.bytes_per_second = 450'000;
  auto bounded = lag.ReplayForDelivery(14, 1'050'000'000, {}, {}, budget);
  assert(bounded.size() == 4 && bounded.front().sequence == 16);
  budget.reserved_bytes = 4'000;
  assert(lag.ReplayForDelivery(14, 1'050'000'000, {}, {}, budget).empty());
  budget.reserved_bytes = 0;
  budget.delivery_delay_ns = 99'000'000;
  assert(lag.ReplayForDelivery(14, 1'050'000'000, {}, {}, budget).empty());
  budget.delivery_delay_ns = 10'000'000;
  budget.bytes_per_second = 1'000'000;
  assert(lag.ConfirmReceived(7, 13, {}, 0, 1'000'000'000));
  assert(lag.ConfirmReceived(7, 13, {}, 1'200, 1'025'000'000));
  auto projected = lag.ReplayForDelivery(14, 1'050'000'000, {}, 1'200, budget);
  assert(projected.empty());
  // A stopped consumer must not keep projecting the preceding running rate.
  assert(lag.ConfirmReceived(7, 13, {}, 1'200, 1'050'000'000));
  assert(!lag.ReplayForDelivery(14, 1'050'000'000, {}, 1'200, budget).empty());
  // A source jump is not a measurement of the playback clock.
  assert(lag.ConfirmReceived(7, 13, {}, 2'000, 1'051'000'000));
  assert(!lag.ReplayForDelivery(14, 1'051'000'000, {}, 2'000, budget).empty());
}
