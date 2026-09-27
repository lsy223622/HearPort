#include <cassert>
#include <chrono>
#include <cstdint>
#include <optional>

#include "hearport/windows/reliable_audio_lag.h"

int main() {
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
}
