#include <cassert>

#include "hearport/windows/audio_metrics.h"

int main() {
  hearport::windows::SenderAudioMetrics metrics;
  const hearport::windows::PcmFormat format{};
  metrics.record_capture(480 * sizeof(float) * 2, format);
  metrics.record_normalized_frames(240);
  metrics.record_packetized(7, 11);
  metrics.record_queued();
  metrics.record_dropped(true);

  const auto first = metrics.exchange_interval();
  assert(first.capture_callbacks == 1);
  assert(first.capture_frames == 480);
  assert(first.normalized_frames == 240);
  assert(first.packetized_packets == 1);
  assert(first.queued_packets == 1);
  assert(first.dropped_packets == 1);
  assert(first.send_failures == 1);
  assert(metrics.exchange_interval().capture_callbacks == 0);

  const hearport::windows::PcmFormat int16_format{
      48000, 2, hearport::windows::SampleFormat::int16_le};
  const hearport::windows::PcmFormat int24_format{
      48000, 2, hearport::windows::SampleFormat::int24_le};
  const hearport::windows::PcmFormat int32_format{
      48000, 2, hearport::windows::SampleFormat::int32_le};
  metrics.record_capture(4 * 2 * 2, int16_format);
  metrics.record_capture(4 * 2 * 3, int24_format);
  metrics.record_capture(4 * 2 * 4, int32_format);
  const auto formats = metrics.exchange_interval();
  assert(formats.capture_callbacks == 3);
  assert(formats.capture_frames == 12);
  assert(formats.capture_format.sample_format ==
         hearport::windows::SampleFormat::int32_le);

  metrics.set_queue_state(3, true, 1228);
  metrics.set_queue_state(7, true, 1228);
  const auto queue = metrics.exchange_interval();
  assert(queue.queue_depth == 7);
  assert(queue.queue_high_watermark == 7);
  assert(queue.datagram_ready);
  assert(queue.datagram_max_payload == 1228);
  return 0;
}
