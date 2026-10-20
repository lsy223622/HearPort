#include "hearport/windows/live_audio_encoder.h"
#include "HearPortOpusBridge.h"
#include <cassert>
#include "hearport/windows/sender_service.h"

int main() {
  using hearport::windows::LiveAudioEncoder;
  hearport::windows::SenderService service({});
  hearport::wire::ControlEnvelope setup{};
  setup.audio_codec = 1; setup.audio_bitrate = 192000; setup.audio_frame_count = 480;
  setup.maximum_ms = 150; setup.output_reserve_ms = 11;
  assert(service.ConfigureAudioFormat(setup));
  auto format = service.audio_format();
  assert(format.opus && format.bitrate == 192000 && format.frames == 480);
  setup.maximum_ms = 10;
  assert(!service.ConfigureAudioFormat(setup));
  assert(service.audio_format().frames == 480);
  setup.audio_codec = 0; setup.audio_bitrate = 0; setup.audio_frame_count = 120;
  assert(service.ConfigureAudioFormat(setup));
  format = service.audio_format();
  assert(!format.opus && format.bitrate == 3072000 && format.frames == 120);
  for (auto frames : {120u, 240u, 480u}) {
    LiveAudioEncoder encoder;
    assert(encoder.Configure(256000, frames));
    const auto lookahead = encoder.lookahead();
    assert(lookahead == 120);
    hearport::wire::AudioDatagram packet{};
    packet.stream_id = 9;
    for (unsigned sequence = 0; sequence < 8; ++sequence) {
      packet.sequence = sequence;
      auto record = encoder.Push(packet, 1'000'000'000ull + sequence * 2'500'000,
                                 sequence * 120ull, 1);
      assert(record.has_value() == ((sequence + 1) % (frames / 120) == 0));
      if (record) {
        assert(record->sequence == sequence + 1 - frames / 120);
        assert(record->source_frame == record->sequence * 120ull);
        assert(record->captured_at_ns == 997'500'000ull + record->sequence * 2'500'000);
        assert(record->frame_count == frames && !record->payload.empty());
        int error = 0; auto* decoder = hp_opus_decoder_create(&error);
        float pcm[960]{};
        assert(hp_opus_decode(decoder, reinterpret_cast<const unsigned char*>(record->payload.data()),
            static_cast<int>(record->payload.size()), pcm, frames) == static_cast<int>(frames));
        hp_opus_decoder_destroy(decoder);
      }
    }
  }
  LiveAudioEncoder encoder;
  assert(!encoder.Configure(128000, 240));
  assert(!encoder.Configure(256000, 121));
  assert(encoder.Configure(192000, 480));
  hearport::wire::AudioDatagram p{}; p.stream_id = 1;
  assert(!encoder.Push(p, 1'000'000'000, 0, 1));
  // A dropped PCM unit must not be joined to stale samples or shift the wire alignment.
  p.sequence = 3; assert(!encoder.Push(p, 1'007'500'000, 360, 1));
  for (unsigned seq = 4; seq < 8; ++seq) {
    p.sequence = seq;
    const auto record = encoder.Push(p, 1'000'000'000 + seq * 2'500'000ull, seq * 120, 1);
    assert(record.has_value() == (seq == 7));
    if (record) assert(record->sequence == 4);
  }
  assert(encoder.Configure(192000, 480));
  p.sequence = 0; assert(!encoder.Push(p, 1'000'000'000, 0, 1));
  p.sequence = 1; assert(!encoder.Push(p, 5'000'000'000, 120, 1));
  for (unsigned seq = 4; seq < 8; ++seq) {
    p.sequence = seq;
    auto record = encoder.Push(p, 6'000'000'000 + seq * 2'500'000ull, seq * 120, 1);
    if (record) assert(record->captured_at_ns > 5'900'000'000);
  }
}
