#include "hearport/windows/audio_metrics.h"

namespace hearport::windows {
namespace {

std::size_t BytesPerSample(SampleFormat format) {
  switch (format) {
    case SampleFormat::float32_le:
    case SampleFormat::int32_le:
      return 4;
    case SampleFormat::int16_le:
      return 2;
    case SampleFormat::int24_le:
      return 3;
  }
  return 0;
}

void UpdateMaximum(std::atomic<std::size_t>& target, std::size_t value) {
  auto current = target.load(std::memory_order_relaxed);
  while (current < value &&
         !target.compare_exchange_weak(current, value,
                                       std::memory_order_relaxed,
                                       std::memory_order_relaxed)) {
  }
}

}  // namespace

void SenderAudioMetrics::record_capture(std::size_t bytes,
                                         const PcmFormat& format) {
  capture_callbacks_.fetch_add(1, std::memory_order_relaxed);
  const auto bytes_per_sample = BytesPerSample(format.sample_format);
  const auto bytes_per_frame = bytes_per_sample * format.channels;
  if (bytes_per_frame != 0) {
    capture_frames_.fetch_add(bytes / bytes_per_frame,
                              std::memory_order_relaxed);
  }
  capture_sample_rate_hz_.store(format.sample_rate_hz,
                                std::memory_order_relaxed);
  capture_channels_.store(format.channels, std::memory_order_relaxed);
  capture_sample_format_.store(static_cast<int>(format.sample_format),
                               std::memory_order_relaxed);
}

void SenderAudioMetrics::record_normalized_frames(std::size_t frames) {
  normalized_frames_.fetch_add(frames, std::memory_order_relaxed);
}

void SenderAudioMetrics::record_packetized(std::uint32_t stream_id,
                                           std::uint32_t sequence) {
  packetized_packets_.fetch_add(1, std::memory_order_relaxed);
  stream_id_.store(stream_id, std::memory_order_relaxed);
  last_sequence_.store(sequence, std::memory_order_relaxed);
}

void SenderAudioMetrics::record_queued() {
  queued_packets_.fetch_add(1, std::memory_order_relaxed);
}

void SenderAudioMetrics::record_sent() {
  sent_packets_.fetch_add(1, std::memory_order_relaxed);
}

void SenderAudioMetrics::record_dropped(bool send_failure) {
  dropped_packets_.fetch_add(1, std::memory_order_relaxed);
  if (send_failure) {
    send_failures_.fetch_add(1, std::memory_order_relaxed);
  }
}

void SenderAudioMetrics::record_capture_reset() {
  capture_resets_.fetch_add(1, std::memory_order_relaxed);
}

void SenderAudioMetrics::set_queue_state(std::size_t depth,
                                         bool datagram_ready,
                                         std::size_t datagram_max_payload) {
  queue_depth_.store(depth, std::memory_order_relaxed);
  UpdateMaximum(queue_high_watermark_, depth);
  datagram_ready_.store(datagram_ready, std::memory_order_relaxed);
  datagram_max_payload_.store(datagram_max_payload,
                              std::memory_order_relaxed);
}

void SenderAudioMetrics::set_stream(std::uint32_t stream_id) {
  stream_id_.store(stream_id, std::memory_order_relaxed);
  last_sequence_.store(0, std::memory_order_relaxed);
}

SenderAudioMetricsSnapshot SenderAudioMetrics::exchange_interval() {
  SenderAudioMetricsSnapshot snapshot;
  snapshot.capture_callbacks =
      capture_callbacks_.exchange(0, std::memory_order_relaxed);
  snapshot.capture_frames =
      capture_frames_.exchange(0, std::memory_order_relaxed);
  snapshot.normalized_frames =
      normalized_frames_.exchange(0, std::memory_order_relaxed);
  snapshot.packetized_packets =
      packetized_packets_.exchange(0, std::memory_order_relaxed);
  snapshot.queued_packets =
      queued_packets_.exchange(0, std::memory_order_relaxed);
  snapshot.sent_packets = sent_packets_.exchange(0, std::memory_order_relaxed);
  snapshot.dropped_packets =
      dropped_packets_.exchange(0, std::memory_order_relaxed);
  snapshot.send_failures =
      send_failures_.exchange(0, std::memory_order_relaxed);
  snapshot.capture_resets =
      capture_resets_.exchange(0, std::memory_order_relaxed);
  snapshot.queue_depth = queue_depth_.load(std::memory_order_relaxed);
  snapshot.queue_high_watermark =
      queue_high_watermark_.exchange(0, std::memory_order_relaxed);
  snapshot.stream_id = stream_id_.load(std::memory_order_relaxed);
  snapshot.last_sequence = last_sequence_.load(std::memory_order_relaxed);
  snapshot.datagram_max_payload =
      datagram_max_payload_.load(std::memory_order_relaxed);
  snapshot.datagram_ready = datagram_ready_.load(std::memory_order_relaxed);
  snapshot.capture_format.sample_rate_hz =
      capture_sample_rate_hz_.load(std::memory_order_relaxed);
  snapshot.capture_format.channels =
      capture_channels_.load(std::memory_order_relaxed);
  snapshot.capture_format.sample_format = static_cast<SampleFormat>(
      capture_sample_format_.load(std::memory_order_relaxed));
  return snapshot;
}

}  // namespace hearport::windows
