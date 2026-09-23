#pragma once

#include <chrono>
#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string_view>
#include <thread>

#include "hearport/session_state.h"
#include "hearport/windows/audio_metrics.h"
#include "hearport/windows/debug_session_trace.h"
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
  using DebugEndedHandler =
      std::function<void(std::array<std::byte, 16>, std::uint32_t)>;

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
  bool BeginStream(std::uint32_t stream_id,
                   std::span<const std::byte> debug_session_id = {});
  bool MarkStartStreamAckWritten(std::uint32_t stream_id);
  void ConfigureDebugDuration(std::optional<std::chrono::seconds> duration);
  std::optional<std::chrono::seconds> debug_duration() const;
  void SetDebugOutputDirectory(std::filesystem::path directory);
  bool WaitForDebugCompletion(std::chrono::milliseconds timeout);
  void MarkDebugReportCommitted(std::span<const std::byte> session_id);
  void LogDiagnostic(std::string_view line) const;

  void SetControlHandler(ControlHandler handler);
  void SetResetHandler(ResetHandler handler);
  void SetClosedHandler(ClosedHandler handler);
  void SetDebugEndedHandler(DebugEndedHandler handler);

  std::uint64_t dropped_audio_packets() const noexcept;

 private:
  struct QueuedAudioPacket {
    wire::AudioDatagram packet;
    std::int64_t captured_at_ns = 0;
    std::int64_t queued_at_ns = 0;
  };

  void EnqueueAudio(const wire::AudioDatagram& packet,
                    std::int64_t captured_at_ns);
  void AudioWorker();
  void HandleCapturePacket(std::span<const std::byte> bytes,
                           const PcmFormat& format);
  void HandleCaptureReset();
  void DiagnosticsWorker();
  void LogAudioSummary();
  void EndDebugSession(std::uint32_t reason);
  void CompleteDebugSend() noexcept;
  void WriteDebugTrace(std::span<const std::byte> session_id,
                       std::string_view contents);

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
  mutable std::mutex audio_send_mutex_;
  DebugSessionTrace debug_trace_;
  mutable std::mutex debug_mutex_;
  std::condition_variable debug_condition_;
  std::optional<std::chrono::seconds> debug_duration_;
  std::optional<std::chrono::steady_clock::time_point> debug_deadline_;
  std::filesystem::path debug_output_directory_;
  std::array<std::byte, 16> pending_debug_session_id_{};
  bool pending_debug_session_ = false;
  std::array<std::byte, 16> active_debug_session_id_{};
  std::uint32_t active_debug_stream_id_ = 0;
  std::size_t outstanding_debug_sends_ = 0;
  bool debug_end_pending_ = false;
  std::uint32_t debug_end_reason_ = 0;
  bool debug_ending_ = false;
  bool debug_completed_ = false;
  bool debug_wait_failed_ = false;
  DebugEndedHandler debug_ended_handler_;
  std::deque<QueuedAudioPacket> audio_queue_;
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
