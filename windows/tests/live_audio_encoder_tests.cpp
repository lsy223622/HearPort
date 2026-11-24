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
      const auto queued = 1'001'000'000ll + sequence * 2'500'000ll;
      auto record = encoder.Push(packet, 1'000'000'000ull + sequence * 2'500'000,
                                 sequence * 120ull, 1, queued);
      assert(record.has_value() == ((sequence + 1) % (frames / 120) == 0));
      if (record) {
        assert(encoder.first_queued_at_ns() == 1'001'000'000ll + record->sequence * 2'500'000ll);
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
  assert(!encoder.Push(p, 1'000'000'000, 0, 1, 0));
  // A dropped PCM unit must not be joined to stale samples or shift the wire alignment.
  p.sequence = 3; assert(!encoder.Push(p, 1'007'500'000, 360, 1, 0));
  for (unsigned seq = 4; seq < 8; ++seq) {
    p.sequence = seq;
    const auto record = encoder.Push(p, 1'000'000'000 + seq * 2'500'000ull, seq * 120, 1, 0);
    assert(record.has_value() == (seq == 7));
    if (record) assert(record->sequence == 4);
  }
  assert(encoder.Configure(192000, 480));
  p.sequence = 0; assert(!encoder.Push(p, 1'000'000'000, 0, 1, 0));
  p.sequence = 1; assert(!encoder.Push(p, 5'000'000'000, 120, 1, 0));
  for (unsigned seq = 4; seq < 8; ++seq) {
    p.sequence = seq;
    auto record = encoder.Push(p, 6'000'000'000 + seq * 2'500'000ull, seq * 120, 1, 0);
    if (record) assert(record->captured_at_ns > 5'900'000'000);
  }

  // Invalid huge frame count in PCM mode must be rejected without reserving.
  assert(!encoder.Configure(0, 0x40000000u));

  // Clamped captured_at_ns when capture timestamp <= encoder lookahead must stay >= 1.
  assert(encoder.Configure(256000, 120));
  hearport::wire::AudioDatagram early{};
  early.stream_id = 3;
  early.sequence = 0;
  auto early_record = encoder.Push(early, 1000, 0, 1, 0);
  assert(early_record.has_value());
  assert(early_record->captured_at_ns >= 1);
  assert(!hearport::wire::EncodeTimedAudioRecord(*early_record).empty());

  // Failed latency check in ConfigureAudioFormat must preserve active Opus encoder.
  hearport::windows::SenderService preserve_service({});
  hearport::wire::ControlEnvelope valid_opus{};
  valid_opus.audio_codec = 1;
  valid_opus.audio_bitrate = 256000;
  valid_opus.audio_frame_count = 240;
  valid_opus.maximum_ms = 150;
  valid_opus.output_reserve_ms = 11;
  assert(preserve_service.ConfigureAudioFormat(valid_opus));
  hearport::wire::ControlEnvelope bad_latency = valid_opus;
  bad_latency.audio_codec = 0;
  bad_latency.audio_bitrate = 0;
  bad_latency.audio_frame_count = 9999;
  assert(!preserve_service.ConfigureAudioFormat(bad_latency));
  assert(preserve_service.audio_format().opus);
  assert(preserve_service.audio_format().frames == 240);
}
