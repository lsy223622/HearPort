#include <array>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include <vector>

#include "hearport/windows/packetizer.h"
#include "hearport/windows/pcm_normalizer.h"

namespace {

std::array<std::byte, 6> MonoInt16() {
  return {std::byte{0}, std::byte{0}, std::byte{0xff}, std::byte{0x7f},
          std::byte{0}, std::byte{0x80}};
}

std::array<std::byte, 9> MonoInt24() {
  return {std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
          std::byte{0xff}, std::byte{0xff}, std::byte{0x7f},
          std::byte{0x00}, std::byte{0x00}, std::byte{0x80}};
}

}  // namespace

int main() {
  hearport::windows::PcmNormalizer normalizer(
      {48000, 1, hearport::windows::SampleFormat::int16_le});
  const auto input = MonoInt16();
  const auto output = normalizer.Convert(input);
  assert(output.size() == 6);
  assert(output[0] == 0.0f && output[1] == 0.0f);
  assert(output[2] > 0.99f && output[3] > 0.99f);
  assert(output[4] == -1.0f && output[5] == -1.0f);

  hearport::windows::PcmNormalizer resampler(
      {44100, 1, hearport::windows::SampleFormat::int24_le});
  const auto resampled = resampler.Convert(MonoInt24());
  assert(resampled.size() == 6);
  for (std::size_t frame = 0; frame < 3; ++frame) {
    assert(resampled[frame * 2] == resampled[frame * 2 + 1]);
  }

  hearport::windows::AudioPacketizer packetizer(9);
  std::vector<float> samples(121 * 2, 0.25f);
  std::size_t packets = 0;
  packetizer.Push(samples, [&](const auto& packet) {
    ++packets;
    assert(packet.stream_id == 9);
    assert(packet.sequence == 0);
  });
  assert(packets == 1);
  assert(packetizer.buffered_frames() == 1);
  return 0;
}
