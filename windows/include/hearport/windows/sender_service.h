#pragma once

#include <chrono>
#include <array>
#include <atomic>
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
#include "hearport/repair_window.h"
#include "hearport/wire/control_message.h"
#include "hearport/windows/audio_metrics.h"
#include "hearport/windows/debug_session_trace.h"
#include "hearport/windows/music_file.h"
#include "hearport/windows/music_test.h"
#include "hearport/windows/calibration.h"
#include "hearport/windows/packetizer.h"
#include "hearport/windows/live_audio_encoder.h"
#include "hearport/windows/quic_server.h"
#include "hearport/windows/reliable_audio_lag.h"
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
  void SetActivationHandler(std::function<bool()> handler) { activation_handler_ = std::move(handler); }
  void SetBudgetHandler(std::function<void(std::uint32_t)> handler) { budget_handler_ = std::move(handler); }
  void SuspendForHandover();
  void NotifyUserStop();
  void AcknowledgeEnd();
  void CloseConnection() { quic_->CloseConnection(); }
  std::uint16_t local_port() const { return quic_->LocalPort(); }
  void SetAuthenticatedPeer(std::string peer) { authenticated_peer_ = std::move(peer); }
  const std::string& authenticated_peer() const { return authenticated_peer_; }

  // Authentication/control code calls these after it has validated the
  // corresponding v1 messages. They deliberately do not invent wire fields.
  bool ReceiveConnect(AuthMode mode,
                      std::span<const std::byte> peer_id);
  bool MarkAuthenticated();
  bool SendControlPayload(std::span<const std::byte> payload);
  bool BeginStream(std::uint32_t stream_id,
                   std::span<const std::byte> debug_session_id = {});
  bool MarkStartStreamAckWritten(std::uint32_t stream_id);
  void ConfigureReliableAudio(bool enabled);
  void ConfigureCoordinatedAudio(bool enabled);
  bool ConfigureAudioFormat(wire::ControlEnvelope& setup);
  bool ConfigurePlayoutBudget(std::uint32_t target_ms, std::uint32_t maximum_ms,
                              std::uint32_t output_reserve_ms);
  void ConfigureNetworkProbe(bool enabled);
  void ConfigureCalibration(CalibrationOptions options);
  bool adaptive_calibration() const { return calibration_options_ && calibration_options_->goal; }
  bool environment_calibration() const noexcept { return calibration_options_.has_value(); }
  CalibrationMessage calibration_setup(std::uint32_t plan_id) const;
  CalibrationProgress calibration_progress() const;
  bool HandleCalibrationMessage(const CalibrationMessage& message);
  void ConfigureMusicTest(MusicExcerpt clip);
  bool music_test() const noexcept { return music_clip_.has_value(); }
  bool AcknowledgeMusicRound();
  std::uint32_t music_test_round() const noexcept { return music_round_.load(); }
  std::uint32_t music_test_frames_processed() const noexcept { return music_frames_processed_.load(); }
  MusicTestPolicy music_test_policy() const noexcept {
    const auto packed = music_policy_.load();
    auto result = MusicProfile(static_cast<std::uint8_t>(packed & 255));
    result.repeat = static_cast<std::uint8_t>((packed >> 8) & 255);
    result.reliable = (packed & 0x10000) != 0;
    return result;
  }
  bool network_probe() const noexcept { return network_probe_; }
  bool network_probe_recovering() const { return probe_recovering_.load(); }
  std::uint32_t network_probe_packets_processed() const noexcept {
    return probe_packets_processed_.load();
  }
  std::uint32_t network_probe_stream_id() const noexcept {
    return probe_stream_id_.load();
  }
  bool ObserveAudioProgress(std::uint32_t stream_id, std::uint32_t generation,
                            std::optional<std::uint32_t> latest_received,
                            std::uint64_t feedback_at_ns = 0,
                            std::optional<std::uint64_t> played_source = std::nullopt,
                            std::uint32_t buffered_ms = 0);
  bool HandleRepairRequest(const wire::ControlEnvelope& request);
  std::vector<NetworkProbeRound> network_probe_rounds() const;
  void ConfigureDebugDuration(std::optional<std::chrono::seconds> duration);
  std::optional<std::chrono::seconds> debug_duration() const;
  void SetDebugOutputDirectory(std::filesystem::path directory);
  std::filesystem::path debug_session_directory() const;
  bool WaitForDebugCompletion(std::chrono::milliseconds timeout);
  bool debug_test_succeeded() const {
    std::lock_guard lock(debug_mutex_);
    if (!debug_completed_ || debug_end_reason_ != 1) return false;
    if (music_clip_) return music_round_.load() == kMusicTestRoundCount &&
        music_frames_processed_.load() == music_clip_->duration_seconds * 48'000;
    if (calibration_options_) return calibration_stage_.load() == 4;
    if (network_probe_) {
      std::uint32_t expected = 0;
      for (const auto& round : network_probe_rounds()) expected += round.packets_per_second * 30;
      return probe_packets_processed_.load() == expected;
    }
    return true;
  }
  void MarkDebugResultReceived(std::span<const std::byte> session_id);
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
    std::uint64_t source_frame = 0;
  };

  void EnqueueAudio(const wire::AudioDatagram& packet,
                    std::int64_t captured_at_ns, std::uint64_t source_frame);
  void AudioWorker();
  void ProbeWorker(std::uint32_t stream_id);
  void CalibrationWorker(std::uint32_t stream_id);
  void MusicWorker();
  void HandleCapturePacket(std::span<const std::byte> bytes,
                           const PcmFormat& format, std::uint64_t captured_at_ns);
  void HandleCaptureReset();
  void DiagnosticsWorker();
  void LogAudioSummary();
  void EndDebugSession(std::uint32_t reason);
  void CompleteDebugSend(std::uint32_t stream_id) noexcept;
  void WriteDebugTrace(std::span<const std::byte> session_id,
                       std::string_view contents);

  static constexpr std::size_t kAudioQueueCapacity = 256;

  QuicServerOptions options_;
  std::function<bool()> activation_handler_;
  std::function<void(std::uint32_t)> budget_handler_;
  std::string authenticated_peer_;
  bool capture_started_ = false;
  std::mutex capture_lifecycle_mutex_;
  std::mutex end_mutex_;
  std::condition_variable end_condition_;
  bool end_acknowledged_ = false;
  void StopCapture();
  std::unique_ptr<QuicServer> quic_;
  WasapiLoopbackCapture capture_;
  std::optional<PcmNormalizer> normalizer_;
  std::optional<PcmFormat> normalizer_format_;
  AudioPacketizer packetizer_;
  LiveAudioEncoder live_encoder_;
  std::atomic<bool> live_opus_ = false;
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
  mutable std::mutex reliable_mutex_;
  ReliableAudioLag reliable_lag_;
  std::atomic<bool> reliable_mode_ = false;
  std::atomic<bool> coordinated_audio_ = false;
  std::atomic<std::uint32_t> target_ms_ = 50;
  std::atomic<std::uint32_t> maximum_ms_ = 100;
  std::atomic<std::uint32_t> output_reserve_ms_ = 10;
  std::uint32_t reliable_generation_ = 0;
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
  std::thread probe_thread_;
  std::thread music_thread_;
  std::optional<MusicExcerpt> music_clip_;
  std::atomic<std::uint32_t> music_round_ = 0;
  std::atomic<std::uint32_t> music_policy_ = 0x100;
  std::mutex music_mutex_;
  std::condition_variable music_condition_;
  bool music_round_pending_ = false;
  std::atomic<bool> stop_music_ = false;
  std::atomic<std::uint32_t> music_frames_processed_ = 0;
  std::int64_t music_begin_ns_ = 0;
  std::thread diagnostics_thread_;
  bool stop_worker_ = false;
  std::atomic<bool> stop_probe_ = false;
  std::atomic<std::uint32_t> probe_packets_processed_ = 0;
  std::atomic<bool> probe_recovering_ = false;
  std::atomic<std::uint32_t> probe_stream_id_ = 0;
  bool network_probe_ = false;
  std::optional<CalibrationOptions> calibration_options_;
  mutable std::mutex calibration_mutex_;
  std::condition_variable calibration_condition_;
  std::unique_ptr<CalibrationExchange> calibration_exchange_;
  std::optional<CalibrationMessage> calibration_display_round_;
  std::optional<std::chrono::steady_clock::time_point> calibration_round_started_at_;
  bool calibration_round_pending_ = false;
  std::atomic<bool> calibration_round_active_ = false;
  std::atomic<unsigned> calibration_stage_ = 0;
  RepairWindow probe_repair_window_;
  std::atomic<std::uint8_t> probe_repair_mode_ = 0;
  std::atomic<std::uint64_t> probe_repair_sent_bytes_ = 0;
  std::uint64_t repair_window_at_ = 0, repair_original_bytes_ = 0, repair_extra_bytes_ = 0;
  std::uint32_t last_buffered_ms_ = 0;
  bool repair_pressure_ = false;
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
