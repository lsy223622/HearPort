#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

#include "hearport/windows/pcm_normalizer.h"

namespace hearport::windows {

struct SenderAudioMetricsSnapshot {
  std::uint64_t capture_callbacks = 0;
  std::uint64_t capture_frames = 0;
  std::uint64_t normalized_frames = 0;
  std::uint64_t packetized_packets = 0;
  std::uint64_t queued_packets = 0;
  std::uint64_t sent_packets = 0;
  std::uint64_t dropped_packets = 0;
  std::uint64_t send_failures = 0;
  std::uint64_t capture_resets = 0;
  std::size_t queue_depth = 0;
  std::size_t queue_high_watermark = 0;
  std::uint32_t stream_id = 0;
  std::uint32_t last_sequence = 0;
  std::size_t datagram_max_payload = 0;
  bool datagram_ready = false;
  PcmFormat capture_format{};
};

class SenderAudioMetrics {
 public:
  void record_capture(std::size_t bytes, const PcmFormat& format);
  void record_normalized_frames(std::size_t frames);
  void record_packetized(std::uint32_t stream_id, std::uint32_t sequence);
  void record_queued();
  void record_sent();
  void record_dropped(bool send_failure);
  void record_capture_reset();
  void set_queue_state(std::size_t depth, bool datagram_ready,
                       std::size_t datagram_max_payload);
  void set_stream(std::uint32_t stream_id);
  SenderAudioMetricsSnapshot exchange_interval();

 private:
  std::atomic<std::uint64_t> capture_callbacks_{0};
  std::atomic<std::uint64_t> capture_frames_{0};
  std::atomic<std::uint64_t> normalized_frames_{0};
  std::atomic<std::uint64_t> packetized_packets_{0};
  std::atomic<std::uint64_t> queued_packets_{0};
  std::atomic<std::uint64_t> sent_packets_{0};
  std::atomic<std::uint64_t> dropped_packets_{0};
  std::atomic<std::uint64_t> send_failures_{0};
  std::atomic<std::uint64_t> capture_resets_{0};

  std::atomic<std::size_t> queue_depth_{0};
  std::atomic<std::size_t> queue_high_watermark_{0};
  std::atomic<std::uint32_t> stream_id_{0};
  std::atomic<std::uint32_t> last_sequence_{0};
  std::atomic<std::size_t> datagram_max_payload_{0};
  std::atomic<bool> datagram_ready_{false};
  std::atomic<std::uint32_t> capture_sample_rate_hz_{48'000};
  std::atomic<std::uint16_t> capture_channels_{2};
  std::atomic<int> capture_sample_format_{
      static_cast<int>(SampleFormat::float32_le)};
};

}  // namespace hearport::windows
