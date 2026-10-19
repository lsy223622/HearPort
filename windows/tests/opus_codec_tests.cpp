#include "HearPortOpusBridge.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <chrono>
#include <cstring>
#include <iostream>
#include <numbers>
#include <vector>

int main() {
  constexpr int sample_rate = 48000;
  constexpr int frame_count = 960;
  constexpr int channels = 2;
  constexpr int packet_capacity = 4000;

  int error = -1;
  void* encoder = hp_opus_encoder_create(128000, &error);
  assert(encoder != nullptr && error == 0);
  void* decoder = hp_opus_decoder_create(&error);
  assert(decoder != nullptr && error == 0);
  assert(hp_opus_lookahead(encoder) >= 0);
  assert(hp_opus_version() != nullptr && std::strlen(hp_opus_version()) > 0);

  std::vector<float> input(frame_count * channels);
  for (int frame = 0; frame < frame_count; ++frame) {
    const float sample = static_cast<float>(
        0.2 * std::sin(2.0 * std::numbers::pi * 440.0 * frame / sample_rate));
    input[frame * channels] = sample;
    input[frame * channels + 1] = sample;
  }

  std::vector<unsigned char> packet(packet_capacity);
  const int encoded_bytes = hp_opus_encode(
      encoder, input.data(), frame_count, packet.data(), packet_capacity);
  assert(encoded_bytes > 0 && encoded_bytes <= packet_capacity);
  assert(hp_opus_encode(encoder, nullptr, frame_count, packet.data(), packet_capacity) < 0);

  std::vector<float> decoded(frame_count * channels);
  const int decoded_frames = hp_opus_decode(
      decoder, packet.data(), encoded_bytes, decoded.data(), frame_count);
  assert(decoded_frames == frame_count);
  assert(std::all_of(decoded.begin(), decoded.end(), [](float value) {
    return std::isfinite(value);
  }));
  assert(std::any_of(decoded.begin(), decoded.end(), [](float value) {
    return std::abs(value) > 0.0001F;
  }));

  const int plc_frames = hp_opus_decode(
      decoder, nullptr, 0, decoded.data(), frame_count);
  assert(plc_frames == frame_count);
  assert(hp_opus_decode(decoder, nullptr, 1, decoded.data(), frame_count) < 0);

  hp_opus_decoder_destroy(decoder);
  hp_opus_encoder_destroy(encoder);
  // Exercise the exact on-wire matrix, including its smallest 2.5 ms frame.
  for (const auto bitrate : {192000, 256000}) {
    for (const auto frames : {120, 240, 480}) {
      encoder = hp_opus_encoder_create(bitrate, &error);
      decoder = hp_opus_decoder_create(&error);
      assert(encoder && decoder && error == 0);
      const auto lookahead = hp_opus_lookahead(encoder);
      assert(lookahead >= 0 && lookahead <= 960);
      std::int64_t maximum_encode_ns = 0, maximum_decode_ns = 0;
      for (int iteration = 0; iteration < 40; ++iteration) {
        const auto began = std::chrono::steady_clock::now();
        const auto count = hp_opus_encode(encoder, input.data(), frames, packet.data(), 992);
        const auto encoded_at = std::chrono::steady_clock::now();
        assert(count == bitrate * frames / (48000 * 8));
        assert(hp_opus_decode(decoder, packet.data(), count, decoded.data(), frames) == frames);
        const auto finished = std::chrono::steady_clock::now();
        maximum_encode_ns = std::max(maximum_encode_ns,
            static_cast<std::int64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(encoded_at - began).count()));
        maximum_decode_ns = std::max(maximum_decode_ns,
            static_cast<std::int64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(finished - encoded_at).count()));
        assert(std::all_of(decoded.begin(), decoded.begin() + frames * 2,
                           [](float sample) { return std::isfinite(sample); }));
      }
      std::cout << "desktop_codec_check bitrate=" << bitrate << " frames=" << frames
                << " lookahead_frames=" << lookahead << " encode_max_ns=" << maximum_encode_ns
                << " decode_max_ns=" << maximum_decode_ns << '\n';
      hp_opus_decoder_destroy(decoder); hp_opus_encoder_destroy(encoder);
    }
  }
  std::cout << "Opus 48 kHz stereo encode/decode and PLC passed\n";
  return 0;
}
