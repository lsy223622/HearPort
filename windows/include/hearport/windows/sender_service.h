#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <thread>

#include "hearport/session_state.h"
#include "hearport/windows/audio_metrics.h"
#include "hearport/windows/packetizer.h"
#include "hearport/windows/quic_server.h"
#include "hearport/windows/wasapi_capture.h"
#include "hearport/wire/control_framing.h"

namespace hearport::windows {

class SenderService {
 public:
  using ControlHandler = std::function<bool(std::span<const std::byte>)>;
  using ResetHandler = std::function<void()>;
  using ClosedHandler = std::function<void()>;

  explicit SenderService(QuicServerOptions options);
  ~SenderService();

  SenderService(const SenderService&) = delete;
  SenderService& operator=(const SenderService&) = delete;

  bool Start();
  void Stop();

  // Authentication/control code calls these after it has validated the
  // corresponding v1 messages. They deliberately do not invent wire fields.
  bool ReceiveConnect(AuthMode mode,
                      std::span<const std::byte> peer_id);
  bool MarkAuthenticated();
  bool SendControlPayload(std::span<const std::byte> payload);
  bool BeginStream(std::uint32_t stream_id);
  bool MarkStartStreamAckWritten(std::uint32_t stream_id);

  void SetControlHandler(ControlHandler handler);
  void SetResetHandler(ResetHandler handler);
  void SetClosedHandler(ClosedHandler handler);

  std::uint64_t dropped_audio_packets() const noexcept;

 private:
  void EnqueueAudio(const wire::AudioDatagram& packet);
  void AudioWorker();
  void HandleCapturePacket(std::span<const std::byte> bytes,
                           const PcmFormat& format);
  void HandleCaptureReset();
  void DiagnosticsWorker();
  void LogAudioSummary();

  static constexpr std::size_t kAudioQueueCapacity = 256;

  QuicServerOptions options_;
  std::unique_ptr<QuicServer> quic_;
  WasapiLoopbackCapture capture_;
  std::optional<PcmNormalizer> normalizer_;
  std::optional<PcmFormat> normalizer_format_;
  AudioPacketizer packetizer_;
  SessionState session_;
  ControlHandler control_handler_;
  ResetHandler reset_handler_;
  ClosedHandler closed_handler_;

  mutable std::mutex session_mutex_;
  mutable std::mutex capture_mutex_;
  mutable std::mutex queue_mutex_;
  std::condition_variable queue_condition_;
  mutable std::mutex diagnostics_mutex_;
  std::condition_variable diagnostics_condition_;
  std::deque<wire::AudioDatagram> audio_queue_;
  std::thread audio_thread_;
  std::thread diagnostics_thread_;
  bool stop_worker_ = false;
  bool stop_diagnostics_ = false;
  bool capture_reset_pending_ = false;
  bool datagram_ready_ = false;
  std::size_t datagram_max_payload_ = 0;
  std::uint64_t dropped_audio_packets_ = 0;
  SenderAudioMetrics audio_metrics_;
  std::chrono::steady_clock::time_point diagnostics_last_summary_ =
      std::chrono::steady_clock::now();
  bool started_ = false;
  wire::ControlFrameDecoder control_decoder_;
};

}  // namespace hearport::windows
