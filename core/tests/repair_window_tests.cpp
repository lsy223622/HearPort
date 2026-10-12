#include "hearport/repair_window.h"
#include <cstdlib>
#include <iostream>

void Check(bool value) { if (!value) std::abort(); }
int main() {
  using namespace hearport;
  using namespace hearport::wire;
  std::array<TimedAudioRecord, 4> originals;
  RepairWindow sender;
  std::optional<TimedAudioRecord> parity;
  for (unsigned i = 0; i < 4; ++i) {
    originals[i] = {7, 1, i, 120, AudioRecordKind::audio,
                    1'000'000'000 + i * 2'500'000ull, i * 120ull,
                    std::vector<std::byte>(960, std::byte(i + 1))};
    parity = sender.Add(originals[i], 1'100'000'000);
  }
  Check(parity.has_value());
  Check(EncodeTimedAudioRecord(*parity).size() == 1024);
  for (unsigned missing = 0; missing < 4; ++missing) {
    RepairWindow receiver;
    for (unsigned i = 0; i < 4; ++i)
      if (i != missing) receiver.Add(originals[i], 1'100'000'000);
    const auto restored = receiver.Recover(*parity, 1'050'000'000);
    Check(restored && restored->sequence == missing && restored->payload == originals[missing].payload);
    Check(!receiver.Recover(*parity, 1'050'000'000));
    Check(!receiver.Retry(missing, 1'100'000'000));
  }
  RepairWindow two_missing;
  two_missing.Add(originals[0], 1'100'000'000);
  two_missing.Add(originals[3], 1'100'000'000);
  Check(!two_missing.Recover(*parity, 1'050'000'000));
  auto wrong = *parity;
  wrong.generation = 2;
  Check(!two_missing.Recover(wrong, 1'050'000'000));
  Check(sender.Retry(2, 1'050'000'000).has_value());
  Check(!sender.Retry(2, 1'060'000'000));
  Check(!sender.Retry(3, 1'100'000'000));
  std::cout << "repair_window_tests passed\n";
}
