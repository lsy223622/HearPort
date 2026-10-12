#include <cassert>
#include "hearport/windows/audio_deadline.h"

int main() {
  using hearport::windows::AudioDeadline;
  AudioDeadline deadline(100, 10);
  assert(!deadline.Expired(1'000'000'000, 1'089'999'999));
  assert(deadline.Expired(1'000'000'000, 1'090'000'000));
  assert(!deadline.Expired(1'100'000'000, 1'100'000'000));
  assert(deadline.RemainingNanoseconds(1'000'000'000, 1'080'000'000) == 10'000'000);
  assert(deadline.RemainingNanoseconds(1'000'000'000, 1'100'000'000) == 0);
}
