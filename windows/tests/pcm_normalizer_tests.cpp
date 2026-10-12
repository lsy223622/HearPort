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

std::vector<std::byte> MonoFloat(const std::vector<float>& frames) {
  std::vector<std::byte> bytes(frames.size() * sizeof(float));
  std::memcpy(bytes.data(), frames.data(), bytes.size());
  return bytes;
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

  hearport::windows::PcmNormalizer streaming_resampler(
      {44100, 1, hearport::windows::SampleFormat::float32_le});
  std::vector<float> first_block(441, 1.0f);
  std::vector<float> second_block(441, 2.0f);
  const auto first_output = streaming_resampler.Convert(MonoFloat(first_block));
  const auto second_output = streaming_resampler.Convert(MonoFloat(second_block));
  assert(first_output.size() == 958);
  assert(second_output.size() == 960);
  assert(second_output[0] > 1.0f && second_output[0] < 2.0f);

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
  hearport::windows::AudioPacketizer timed_packetizer(9);
  std::vector<std::uint64_t> times;
  std::vector<std::uint64_t> positions;
  auto timed_handler = [&](const auto&, std::uint64_t timestamp, std::uint64_t position) {
    times.push_back(timestamp);
    positions.push_back(position);
  };
  std::vector<float> part(180 * 2, 0.25f);
  timed_packetizer.PushTimed(part, 1'000'000'000, timed_handler);
  timed_packetizer.PushTimed(std::span(part).first(120), 1'003'750'000, timed_handler);
  assert(times == std::vector<std::uint64_t>({1'000'000'000, 1'002'500'000}));
  assert(positions == std::vector<std::uint64_t>({0, 120}));
  return 0;
}
