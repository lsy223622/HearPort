#define _WIN32_WINNT 0x0A00
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "hearport/windows/sender_service.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <utility>

#include "hearport/wire/audio_datagram.h"
#include "hearport/wire/control_framing.h"
#include "hearport/windows/network_probe.h"
#include "hearport/windows/audio_deadline.h"
#include "HearPortOpusBridge.h"

namespace hearport::windows {

namespace {

std::int64_t MonotonicNanoseconds() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::string SessionHex(std::span<const std::byte> session_id) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const auto byte : session_id) {
    output << std::setw(2) << std::to_integer<unsigned int>(byte);
  }
  return output.str();
}

const char* SampleFormatName(SampleFormat format) {
  switch (format) {
    case SampleFormat::float32_le:
      return "float32_le";
    case SampleFormat::int16_le:
      return "int16_le";
    case SampleFormat::int24_le:
      return "int24_le";
    case SampleFormat::int32_le:
      return "int32_le";
  }
  return "unknown";
}

}  // namespace

SenderService::SenderService(QuicServerOptions options)
    : options_(options), quic_(CreateMsQuicServer()), packetizer_(1) {}

SenderService::~SenderService() { Stop(); }

bool SenderService::Start() {
  if (started_ || quic_ == nullptr) {
    return false;
  }

  QuicServerCallbacks callbacks;
  options_.network_probe = network_probe_ || music_test();
  callbacks.on_probe_send_complete = [this](std::uint32_t stream_id,
                                            std::uint32_t sequence, bool canceled) {
    debug_trace_.RecordSendComplete(stream_id, sequence, canceled, MonotonicNanoseconds());
    CompleteDebugSend(stream_id);
  };
  callbacks.on_control_bytes = [this](std::span<const std::byte> bytes) {
    std::vector<std::vector<std::byte>> messages;
    if (!control_decoder_.Push(bytes, messages)) {
      if (quic_) quic_->CloseConnection();
      return false;
    }
    for (const auto& message : messages) {
      if (control_handler_ &&
          !control_handler_(std::span<const std::byte>(message.data(),
                                                       message.size()))) {
        if (quic_) quic_->CloseConnection();
        return false;
      }
    }
    return true;
  };
  callbacks.on_datagram_ready = [this](std::size_t max_payload) {
    std::lock_guard lock(queue_mutex_);
    datagram_ready_ = max_payload >= wire::kAudioDatagramBytes;
    datagram_max_payload_ = max_payload;
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
  };
  callbacks.on_datagram_unavailable = [this] {
    std::lock_guard lock(queue_mutex_);
    datagram_ready_ = false;
    datagram_max_payload_ = 0;
    audio_metrics_.set_queue_state(audio_queue_.size(), false, 0);
  };
  callbacks.on_datagram_send_state =
      [this](std::uint32_t stream_id, std::uint32_t sequence,
             DebugSendState state) {
        debug_trace_.RecordSendState(stream_id, sequence, state,
                                     MonotonicNanoseconds());
        if (IsFinalDebugSendState(state)) CompleteDebugSend(stream_id);
      };
  callbacks.on_closed = [this] {
    StopCapture();
    stop_music_.store(true);
    music_condition_.notify_all();
    stop_probe_.store(true);
    calibration_condition_.notify_all();
    reliable_mode_.store(false);
    {
      std::lock_guard lock(reliable_mutex_);
      reliable_generation_ = 0;
    }
    {
      std::lock_guard lock(queue_mutex_);
      datagram_ready_ = false;
      datagram_max_payload_ = 0;
      audio_metrics_.set_queue_state(audio_queue_.size(), false, 0);
    }
    {
      std::lock_guard lock(session_mutex_);
      session_.Reset();
    }
    {
      std::lock_guard lock(debug_mutex_);
      if (debug_duration_.has_value() && !debug_completed_ &&
          debug_trace_.IsActive()) {
        debug_wait_failed_ = true;
      }
      if (debug_trace_.IsActive()) {
        debug_end_pending_ = true;
        debug_end_reason_ = 2;
      }
    }
    debug_condition_.notify_all();
    diagnostics_condition_.notify_all();
    control_decoder_.Reset();
    if (closed_handler_) closed_handler_();
  };

  if (!quic_->Start(options_, std::move(callbacks))) {
    return false;
  }

  {
    std::lock_guard lock(queue_mutex_);
    stop_worker_ = false;
    capture_reset_pending_ = false;
    datagram_ready_ = false;
    datagram_max_payload_ = 0;
    audio_metrics_.exchange_interval();
    audio_metrics_.set_queue_state(0, false, 0);
  }
  control_decoder_.Reset();
  stop_probe_.store(false);
  stop_music_.store(false);
  if (!network_probe_) audio_thread_ = std::thread([this] { AudioWorker(); });
  {
    std::lock_guard lock(diagnostics_mutex_);
    stop_diagnostics_ = false;
  }
  diagnostics_thread_ = std::thread([this] { DiagnosticsWorker(); });
  started_ = true;
  return true;
}

void SenderService::Stop() {
  if (!started_ && !audio_thread_.joinable() && !diagnostics_thread_.joinable() &&
      !probe_thread_.joinable() && !music_thread_.joinable()) {
    return;
  }
  stop_probe_.store(true);
  calibration_condition_.notify_all();
  stop_music_.store(true);
    music_condition_.notify_all();
  if (music_thread_.joinable()) music_thread_.join();
  if (probe_thread_.joinable()) probe_thread_.join();
  if (debug_trace_.IsActive()) EndDebugSession(2);
  StopCapture();
  {
    std::lock_guard lock(queue_mutex_);
    stop_worker_ = true;
  }
  queue_condition_.notify_all();
  if (audio_thread_.joinable()) {
    audio_thread_.join();
  }
  {
    std::lock_guard lock(diagnostics_mutex_);
    stop_diagnostics_ = true;
  }
  diagnostics_condition_.notify_all();
  if (diagnostics_thread_.joinable()) {
    diagnostics_thread_.join();
  }
  if (quic_) {
    quic_->Stop();
  }
  StopCapture();
  {
    std::lock_guard lock(queue_mutex_);
    audio_queue_.clear();
    capture_reset_pending_ = false;
    datagram_ready_ = false;
    datagram_max_payload_ = 0;
    audio_metrics_.set_queue_state(0, false, 0);
  }
  normalizer_.reset();
  normalizer_format_.reset();
  started_ = false;
}

void SenderService::StopCapture() {
  std::lock_guard lifecycle(capture_lifecycle_mutex_);
  capture_.Stop();
  capture_started_ = false;
}

void SenderService::NotifyUserStop() {
  wire::ControlEnvelope end;
  end.type=wire::ControlMessageType::session_end; end.reason=1;
  std::unique_lock lock(end_mutex_);
  end_acknowledged_=false;
  if(SendControlPayload(wire::EncodeControlEnvelope(end)))
    end_condition_.wait_for(lock,std::chrono::milliseconds(500),[this] { return end_acknowledged_; });
}
void SenderService::AcknowledgeEnd() {
  std::lock_guard lock(end_mutex_); end_acknowledged_=true; end_condition_.notify_all();
}

void SenderService::SuspendForHandover() {
  StopCapture();
  {
    std::lock_guard send_lock(audio_send_mutex_);
    std::lock_guard session_lock(session_mutex_);
    session_.Reset();
    std::lock_guard queue_lock(queue_mutex_);
    audio_queue_.clear();
  }
  quic_->StopReliableAudio();
  quic_->CloseConnection();
}

bool SenderService::ReceiveConnect(AuthMode mode,
                                   std::span<const std::byte> peer_id) {
  std::lock_guard lock(session_mutex_);
  return session_.ReceiveConnect(mode, peer_id);
}

bool SenderService::MarkAuthenticated() {
  std::lock_guard lock(session_mutex_);
  return session_.MarkAuthenticated();
}

bool SenderService::SendControlPayload(std::span<const std::byte> payload) {
  if (!quic_) {
    return false;
  }
  const auto framed = wire::EncodeControlFrame(payload);
  return quic_->SendControl(framed);
}

bool SenderService::BeginStream(
    std::uint32_t stream_id,
    std::span<const std::byte> debug_session_id) {
  if (activation_handler_ && !activation_handler_()) return false;
  {
  std::lock_guard lifecycle(capture_lifecycle_mutex_);
  if (!network_probe_ && !music_clip_ && !capture_started_) {
    if (!capture_.Start([this](std::span<const std::byte> bytes, const PcmFormat& format, std::uint64_t at) {
          HandleCapturePacket(bytes, format, at);
        }, [this] { HandleCaptureReset(); })) return false;
    capture_started_ = true;
  }
  }
  if (!debug_session_id.empty() && debug_session_id.size() != 16) return false;
  if (!debug_session_id.empty() && !debug_duration().has_value()) return false;
  if (music_thread_.joinable()) {
    stop_music_.store(true);
    music_condition_.notify_all();
    music_thread_.join();
  }
  std::lock_guard capture_lock(capture_mutex_);
  std::lock_guard session_lock(session_mutex_);
  if (!session_.BeginStream(stream_id)) {
    return false;
  }
  {
    std::lock_guard debug_lock(debug_mutex_);
    pending_debug_session_ = !debug_session_id.empty();
    pending_debug_session_id_.fill(std::byte{0});
    if (pending_debug_session_) {
      std::copy(debug_session_id.begin(), debug_session_id.end(),
                pending_debug_session_id_.begin());
    }
  }
  packetizer_.Reset(stream_id);
  normalizer_.reset();
  normalizer_format_.reset();
  audio_metrics_.set_stream(stream_id);
  return true;
}

bool SenderService::MarkStartStreamAckWritten(std::uint32_t stream_id) {
  if (probe_thread_.joinable()) {
    stop_probe_.store(true);
    calibration_condition_.notify_all();
    probe_thread_.join();
  }
  stop_probe_.store(false);
  if (music_thread_.joinable()) {
    stop_music_.store(true);
    music_condition_.notify_all();
    music_thread_.join();
  }
  std::lock_guard capture_lock(capture_mutex_);
  std::lock_guard send_lock(audio_send_mutex_);
  std::lock_guard session_lock(session_mutex_);
  if (session_.AckWritten(stream_id) != AudioDisposition::accepted) {
    return false;
  }
  if (reliable_mode_.load()) {
    if (!quic_->StartReliableAudio(stream_id, 1)) return false;
    std::lock_guard reliable_lock(reliable_mutex_);
    reliable_generation_ = 1;
    reliable_lag_.Begin(stream_id, 1, ReliableAudioLag::Clock::now(),
        coordinated_audio_.load() ? std::optional(std::chrono::milliseconds(
            maximum_ms_.load() - output_reserve_ms_.load())) : std::nullopt);
  }
  std::lock_guard debug_lock(debug_mutex_);
  if (pending_debug_session_) {
    std::uint32_t trace_stride = 1;
    if (music_clip_) {
      const auto source_units = std::uint64_t(kMusicTestRoundCount) * music_clip_->duration_seconds * 400;
      while ((source_units + trace_stride - 1) / trace_stride > DebugSessionTrace::kMaximumPackets)
        trace_stride *= 2;
    }
    if (!debug_trace_.Begin(pending_debug_session_id_, stream_id, trace_stride)) {
      (void)session_.EndStream(stream_id);
      return false;
    }
    active_debug_session_id_ = pending_debug_session_id_;
    active_debug_stream_id_ = stream_id;
    outstanding_debug_sends_ = 0;
    debug_completed_ = false;
    debug_wait_failed_ = false;
    debug_ending_ = false;
    debug_end_pending_ = false;
    debug_deadline_ = std::chrono::steady_clock::now() + *debug_duration_;
    pending_debug_session_ = false;
    pending_debug_session_id_.fill(std::byte{0});
    diagnostics_condition_.notify_all();
  }
  if (network_probe_) {
    probe_thread_ = std::thread([this, stream_id] { ProbeWorker(stream_id); });
  } else if (music_clip_) {
    music_begin_ns_ = MonotonicNanoseconds();
    debug_deadline_ = std::chrono::steady_clock::time_point(std::chrono::nanoseconds(music_begin_ns_)) +
        *debug_duration_;
    stop_music_.store(false);
    music_frames_processed_.store(0);
    music_thread_ = std::thread([this] {
      try { MusicWorker(); }
      catch (const std::exception& error) {
        LogDiagnostic(std::string("music_test_failed error=") + error.what());
        std::lock_guard lock(debug_mutex_);
        debug_end_pending_ = true; debug_end_reason_ = 3;
      }
    });
  }
  return true;
}

void SenderService::ConfigureNetworkProbe(bool enabled) {
  network_probe_ = enabled;
}

void SenderService::ConfigureCalibration(CalibrationOptions options) {
  if (started_ || music_clip_ || (options.seconds != 30 && options.seconds != 60 && options.seconds != 120 && !(options.goal && options.seconds == 15)) ||
      options.maximum_ms < 20 || options.maximum_ms > 2000 || (options.goal && options.seconds > 60) || (options.goal && options.goal != 1 && options.goal != 2 && options.goal != 4)) throw std::invalid_argument("invalid calibration options");
  calibration_options_ = options; network_probe_ = true;
  ConfigureDebugDuration(std::chrono::seconds(3600));
}

CalibrationMessage SenderService::calibration_setup(std::uint32_t plan_id) const {
  CalibrationMessage message;
  message.kind = CalibrationMessageKind::setup; message.plan_id = plan_id;
  if (calibration_options_) {
    message.goal = calibration_options_->goal;
    message.seconds = calibration_options_->seconds;
    message.budget.maximum_ms = calibration_options_->maximum_ms;
  }
  return message;
}

CalibrationProgress SenderService::calibration_progress() const {
  std::lock_guard lock(calibration_mutex_);
  CalibrationProgress message;
  message.stage = calibration_stage_.load();
  if (calibration_exchange_) {
    message.completed_rounds = calibration_exchange_->completed();
    message.completed = calibration_exchange_->analysis_completed();
    message.total = calibration_exchange_->analysis_total();
    if (calibration_round_pending_ && calibration_display_round_) {
      const auto& round = *calibration_display_round_;
      message.round_pending = true;
      message.index = calibration_options_->goal || round.phase == 0 ? round.index : round.index - 4;
      message.count = calibration_exchange_->phase_total();
      if (calibration_round_started_at_) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - *calibration_round_started_at_).count();
        message.round_started = true;
        message.elapsed_seconds = static_cast<unsigned>(std::max<std::int64_t>(elapsed, 0));
        message.remaining_seconds = elapsed >= round.seconds ? 0 :
            round.seconds - static_cast<unsigned>(std::max<std::int64_t>(elapsed, 0));
      } else {
        message.remaining_seconds = round.seconds;
      }
    } else if (message.stage == 1 || message.stage == 3) {
      message.count = calibration_exchange_->phase_total();
      message.index = std::min(calibration_exchange_->phase_completed() + 1, message.count);
    }
  }
  return message;
}

bool SenderService::HandleCalibrationMessage(const CalibrationMessage& message) {
  std::lock_guard lock(calibration_mutex_);
  if (!calibration_exchange_ || !calibration_exchange_->Handle(message)) return false;
  calibration_condition_.notify_all(); return true;
}

void SenderService::ConfigureMusicTest(MusicExcerpt clip) {
  if (started_ || network_probe_ || clip.duration_seconds < 60 || clip.duration_seconds > 300 ||
      clip.samples.size() != std::size_t(clip.duration_seconds) * 48'000 * 2) {
    throw std::invalid_argument("Invalid music test configuration");
  }
  ConfigureDebugDuration(std::chrono::seconds(clip.duration_seconds * kMusicTestRoundCount +
      (kMusicTestRoundCount - 1) * kMusicRecoverySeconds + kMusicTestRoundCount * 5 + 30));
  music_clip_ = std::move(clip);
}

bool SenderService::AcknowledgeMusicRound() {
  std::lock_guard lock(music_mutex_);
  if (!music_round_pending_) return false;
  music_round_pending_ = false;
  music_condition_.notify_all();
  return true;
}

void SenderService::MusicWorker() {
  const auto close_timer = [](HANDLE handle) { CloseHandle(handle); };
  std::unique_ptr<void, decltype(close_timer)> timer(CreateWaitableTimerExW(nullptr, nullptr,
      CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS), close_timer);
  const auto wait_until = [&](std::int64_t at) {
    const auto remaining = at - MonotonicNanoseconds();
    if (remaining > 0) {
      LARGE_INTEGER due{}; due.QuadPart = -std::max<std::int64_t>(1, remaining / 100);
      if (!SetWaitableTimerEx(timer.get(), &due, 0, nullptr, nullptr, nullptr, 0) ||
          WaitForSingleObject(timer.get(), INFINITE) != WAIT_OBJECT_0) return false;
    }
    return !stop_music_.load();
  };
  const auto fail = [&](std::string_view reason) {
    LogDiagnostic(reason);
    stop_music_.store(true);
    std::lock_guard lock(debug_mutex_);
    debug_end_pending_ = true; debug_end_reason_ = 3;
  };
  if (!timer) { fail("music_test_timer_create_failed"); return; }
  const auto path = music_clip_->source.u8string();
  LogDiagnostic("music_test_start file=" + std::string(path.begin(), path.end()) +
      " start_seconds=" + std::to_string(music_clip_->start_seconds) +
      " round_seconds=" + std::to_string(music_clip_->duration_seconds) +
      " rounds=32 sample_rate=48000 channels=2 opus_version=" + hp_opus_version());
  const auto samples = std::span<const float>(music_clip_->samples);
  std::uint32_t stream_id = 0;
  std::string session_id;
  { std::lock_guard lock(debug_mutex_); stream_id = active_debug_stream_id_;
    session_id = SessionHex(active_debug_session_id_); }
  const auto summary_directory = debug_session_directory();
  std::filesystem::create_directories(summary_directory);
  std::ofstream summary_file(summary_directory / "compression-summary.jsonl", std::ios::binary | std::ios::trunc);
  if (!summary_file) { fail("compression_summary_file_create_failed"); return; }
  const auto policies = MakeMusicTestPolicies(stream_id);
  for (std::size_t index = 0; index < policies.size(); ++index) {
    if (index && !wait_until(MonotonicNanoseconds() + kMusicRecoverySeconds * 1'000'000'000ll)) return;
    const auto policy = policies[index];
    int opus_error = 0;
    const auto create_at = MonotonicNanoseconds();
    std::unique_ptr<void, decltype(&hp_opus_encoder_destroy)> encoder(
        policy.profile >= 2 ? hp_opus_encoder_create(policy.bitrate_kbps * 1000, &opus_error) : nullptr,
        hp_opus_encoder_destroy);
    const auto create_ns = MonotonicNanoseconds() - create_at;
    if (policy.profile >= 2 && (!encoder || opus_error != 0)) {
      fail("compression_encoder_create_failed"); return;
    }
    const auto lookahead = static_cast<std::uint16_t>(encoder ? hp_opus_lookahead(encoder.get()) : 0);
    if (lookahead > 960) { fail("compression_lookahead_invalid"); return; }
    std::uint32_t generation = 0;
    const auto first_sequence = static_cast<std::uint32_t>(index) * music_clip_->duration_seconds * 400;
    {
      std::lock_guard capture_lock(capture_mutex_);
      std::lock_guard send_lock(audio_send_mutex_);
      std::lock_guard reliable_lock(reliable_mutex_);
      { std::lock_guard queue_lock(queue_mutex_); audio_queue_.clear(); }
      quic_->StopReliableAudio();
      generation = reliable_generation_ == UINT32_MAX ? 1 : reliable_generation_ + 1;
      reliable_generation_ = generation;
      reliable_mode_.store(policy.reliable);
      music_policy_.store(policy.profile | (std::uint32_t(policy.repeat) << 8) |
                          (policy.reliable ? 0x10000u : 0));
      music_round_.store(static_cast<std::uint32_t>(index + 1));
      music_frames_processed_.store(0);
      reliable_lag_.Begin(stream_id, generation, ReliableAudioLag::Clock::now(),
          std::chrono::milliseconds(maximum_ms_.load() - output_reserve_ms_.load()));
    }
    wire::ControlEnvelope round;
    round.type = wire::ControlMessageType::probe_manifest;
    round.stream_id = stream_id;
    round.bytes1 = EncodeMusicTestRound(static_cast<std::uint32_t>(index + 1),
        music_clip_->duration_seconds, first_sequence, generation, policy, lookahead);
    { std::lock_guard lock(music_mutex_); music_round_pending_ = true; }
    if (!SendControlPayload(wire::EncodeControlEnvelope(round))) { fail("music_test_round_send_failed"); return; }
    {
      std::unique_lock lock(music_mutex_);
      if (!music_condition_.wait_for(lock, std::chrono::seconds(5),
          [this] { return !music_round_pending_ || stop_music_.load(); })) {
        lock.unlock(); fail("music_test_round_ack_timeout"); return;
      }
    }
    if (stop_music_.load()) return;
    if (policy.reliable) {
      std::lock_guard send_lock(audio_send_mutex_);
      if (!quic_->StartReliableAudio(stream_id, generation)) { fail("music_test_stream_start_failed"); return; }
    }
    const auto began = MonotonicNanoseconds();
    const auto codec = policy.profile == 0 ? "float_pcm" : policy.profile == 1 ? "pcm16" : "opus";
    const auto identity = " source=real side=sender stream_id=" + std::to_string(stream_id) +
        " session_id=" + session_id + " connection_id=" + session_id +
        " path_id=" + (options_.loopback_only ? "usb" : "network") +
        " round=" + std::to_string(index + 1) + " profile=" + std::to_string(policy.profile) +
        " repeat=" + std::to_string(policy.repeat) +
        " transport=" + (policy.reliable ? "reliable_stream" : "datagram") +
        " codec=" + codec + " bitrate=" + std::to_string(policy.bitrate_kbps * 1000) +
        " frame_count=" + std::to_string(policy.frames) +
        " duration_seconds=" + std::to_string(music_clip_->duration_seconds) +
        " target_ms=" + std::to_string(target_ms_.load()) +
        " maximum_ms=" + std::to_string(maximum_ms_.load()) +
        " output_reserve_ms=" + std::to_string(output_reserve_ms_.load()) +
        " sample_rate=48000";
    LogDiagnostic("compression_round" + identity +
        " at_ns=" + std::to_string(began) + " first_sequence=" + std::to_string(first_sequence) +
        " generation=" + std::to_string(generation) +
        " encoder_create_ns=" + std::to_string(create_ns) +
        " codec_lookahead_frames=" + std::to_string(lookahead) +
        " output_reserve_ms=" + std::to_string(output_reserve_ms_.load()));
    std::vector<std::int64_t> encode_times;
    encode_times.reserve(samples.size() / (2 * policy.frames));
    std::uint64_t wire_bytes = 0, accepted_bytes = 0;
    std::array<std::uint32_t, 8> outcomes{};
    std::int64_t first_encode_ns = 0, total_encode_ns = 0, source_age_max_ns = 0;
    const auto summary = [&](bool complete) {
      auto sorted = encode_times;
      std::sort(sorted.begin(), sorted.end());
      const auto percentile = [&](double p) { return sorted.empty() ? std::int64_t{0} :
          sorted[std::min(sorted.size() - 1, static_cast<std::size_t>(std::ceil(p * sorted.size()) - 1))]; };
      const auto line = "compression_summary" + identity + " complete=" + (complete ? "1" : "0") +
          " packets=" + std::to_string(encode_times.size()) +
          " accepted=" + std::to_string(outcomes[0]) +
          " wire_bytes=" + std::to_string(wire_bytes) + " accepted_bytes=" + std::to_string(accepted_bytes) +
          " encode_ns=" + std::to_string(total_encode_ns) +
          " encoder_create_ns=" + std::to_string(create_ns) +
          " first_encode_ns=" + std::to_string(first_encode_ns) +
          " encode_p50_ns=" + std::to_string(percentile(.50)) +
          " encode_p95_ns=" + std::to_string(percentile(.95)) +
          " encode_p99_ns=" + std::to_string(percentile(.99)) +
          " encode_max_ns=" + std::to_string(sorted.empty() ? 0 : sorted.back()) +
          " source_age_max_ns=" + std::to_string(source_age_max_ns) +
          " expired_before_send=" + std::to_string(outcomes[7]) +
          " reject_pending_limit=" + std::to_string(outcomes[3]) +
          " reject_transport=" + std::to_string(outcomes[6]);
      LogDiagnostic(line);
      summary_file << "{\"message\":\"" << line << "\"}\n";
      summary_file.flush();
      if (!summary_file) fail("compression_summary_file_write_failed");
    };
    for (std::size_t offset = 0; offset < samples.size(); offset += 2 * policy.frames) {
      const auto captured = began + (static_cast<std::int64_t>(offset / 2) - lookahead) * 1'000'000'000 / 48'000;
      const auto collected_at = began + static_cast<std::int64_t>(offset / 2 + policy.frames) * 1'000'000'000 / 48'000;
      if (!wait_until(collected_at)) { summary(false); return; }
      const auto sequence = first_sequence + static_cast<std::uint32_t>(offset / 240);
      wire::TimedAudioRecord record{stream_id, generation, sequence, policy.frames,
          policy.profile == 0 ? wire::AudioRecordKind::audio : policy.profile == 1 ? wire::AudioRecordKind::pcm16 : wire::AudioRecordKind::opus,
          static_cast<std::uint64_t>(captured), std::uint64_t(sequence) * 120, {}};
      const auto encode_at = MonotonicNanoseconds();
      if (encoder) {
        record.payload.resize(992);
        const auto count = hp_opus_encode(encoder.get(), samples.data() + offset, policy.frames,
            reinterpret_cast<unsigned char*>(record.payload.data()), static_cast<int>(record.payload.size()));
        if (count <= 0) { summary(false); fail("compression_encode_failed"); return; }
        record.payload.resize(static_cast<std::size_t>(count));
      } else if (policy.profile == 1) {
        record.payload.reserve(480);
        for (const auto value : samples.subspan(offset, 240)) {
          const auto sample = std::isfinite(value) ? std::clamp(value, -1.0f, 1.0f) : 0.0f;
          const auto quantized = static_cast<std::int16_t>(std::clamp(std::lround(sample * 32768.0f), -32768l, 32767l));
          record.payload.push_back(std::byte(static_cast<std::uint16_t>(quantized) & 255));
          record.payload.push_back(std::byte(static_cast<std::uint16_t>(quantized) >> 8));
        }
      } else {
        const auto pcm = std::as_bytes(samples.subspan(offset, 240));
        record.payload.assign(pcm.begin(), pcm.end());
      }
      const auto encoded_ns = MonotonicNanoseconds() - encode_at;
      if (encode_times.empty()) first_encode_ns = encoded_ns;
      encode_times.push_back(encoded_ns); total_encode_ns += encoded_ns;
      const auto bytes = wire::EncodeTimedAudioRecord(record);
      std::lock_guard send_lock(audio_send_mutex_);
      bool trace_active = false;
      {
        std::lock_guard debug_lock(debug_mutex_);
        trace_active = debug_trace_.IsActive() && !debug_ending_;
        if (trace_active) ++outstanding_debug_sends_;
      }
      if (!trace_active) { summary(false); return; }
      const auto send_at = MonotonicNanoseconds();
      source_age_max_ns = std::max(source_age_max_ns, send_at - captured);
      const auto outcome = AudioDeadline(maximum_ms_.load(), output_reserve_ms_.load()).Expired(captured, send_at)
          ? ProbeSendOutcome{ProbeSendStatus::expired} : quic_->SendProbe(bytes, stream_id, sequence, policy.reliable);
      ++outcomes[static_cast<std::size_t>(outcome.status)];
      wire_bytes += bytes.size() + (policy.reliable ? 2 : 0);
      const auto sent = outcome.status == ProbeSendStatus::accepted;
      if (sent) accepted_bytes += bytes.size() + (policy.reliable ? 2 : 0);
      debug_trace_.RecordPacket(sequence, captured, encode_at, send_at, sent, outcome);
      if (!sent) CompleteDebugSend(stream_id);
      music_frames_processed_.store(static_cast<std::uint32_t>(offset / 2 + policy.frames));
    }
    if (!wait_until(began + music_clip_->duration_seconds * 1'000'000'000ll)) return;
    summary(true);
  }
  if (!wait_until(MonotonicNanoseconds() + 10'000'000'000ll)) return;
  std::lock_guard lock(debug_mutex_);
  debug_end_pending_ = true; debug_end_reason_ = 1;
}

void SenderService::CalibrationWorker(std::uint32_t stream_id) {
  using Clock = std::chrono::steady_clock;
  const auto options = *calibration_options_;
  probe_stream_id_.store(stream_id); probe_packets_processed_.store(0);
  {
    std::lock_guard lock(calibration_mutex_);
    calibration_exchange_ = std::make_unique<CalibrationExchange>(stream_id, options,
        static_cast<std::uint16_t>(output_reserve_ms_.load()));
    calibration_display_round_.reset();
    calibration_round_started_at_.reset();
    calibration_round_pending_ = false;
  }
  const auto close_timer = [](HANDLE handle) { CloseHandle(handle); };
  std::unique_ptr<void, decltype(close_timer)> timer(CreateWaitableTimerExW(nullptr, nullptr,
      CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS), close_timer);
  const auto finish = [&](bool success) {
    calibration_round_active_.store(false); calibration_stage_.store(success ? 4 : 5);
    std::lock_guard lock(debug_mutex_);
    debug_end_pending_ = true; debug_end_reason_ = success ? 1 : 2;
    diagnostics_condition_.notify_all();
  };
  if (!timer) { LogDiagnostic("calibration_timer_failed"); finish(false); return; }
  const auto wait_until = [&](Clock::time_point target) {
    while (!stop_probe_.load()) {
      const auto remaining = target - Clock::now();
      if (remaining <= Clock::duration::zero()) return true;
      if (remaining > std::chrono::milliseconds(20)) {
        std::unique_lock lock(calibration_mutex_);
        calibration_condition_.wait_for(lock, std::min(std::chrono::duration_cast<std::chrono::milliseconds>(remaining),
            std::chrono::milliseconds(50)), [&] { return stop_probe_.load(); });
      } else {
        LARGE_INTEGER due{};
        due.QuadPart = -std::max<std::int64_t>(1, std::chrono::duration_cast<std::chrono::nanoseconds>(remaining).count() / 100);
        if (!SetWaitableTimerEx(timer.get(), &due, 0, nullptr, nullptr, nullptr, 0) ||
            WaitForSingleObject(timer.get(), INFINITE) != WAIT_OBJECT_0) {
          LogDiagnostic("calibration_timer_wait_failed"); finish(false); return false;
        }
      }
    }
    return false;
  };
  const auto send_message = [&](const CalibrationMessage& message) {
    wire::ControlEnvelope envelope;
    envelope.type = wire::ControlMessageType::probe_manifest; envelope.stream_id = stream_id;
    envelope.bytes1 = EncodeCalibrationMessage(message);
    return SendControlPayload(wire::EncodeControlEnvelope(envelope));
  };
  while (!stop_probe_.load()) {
    calibration_round_active_.store(false);
    {
      std::unique_lock lock(calibration_mutex_);
      if (calibration_exchange_->finished()) break;
      if (calibration_exchange_->awaiting_selection()) {
        calibration_stage_.store(2);
        CalibrationMessage request;
        request.kind = CalibrationMessageKind::analyze; request.plan_id = stream_id; request.goal = options.goal;
        lock.unlock();
        if (!send_message(request)) { finish(false); return; }
        lock.lock();
        if (!calibration_condition_.wait_for(lock, std::chrono::seconds(120), [&] {
              return stop_probe_.load() || !calibration_exchange_->awaiting_selection();
            })) { lock.unlock(); LogDiagnostic("calibration_analysis_timeout"); finish(false); return; }
        if (stop_probe_.load()) return;
        if (calibration_exchange_->finished()) break;
      }
    }
    std::uint32_t generation;
    {
      std::lock_guard send_lock(audio_send_mutex_);
      std::lock_guard reliable_lock(reliable_mutex_);
      quic_->StopReliableAudio(); reliable_mode_.store(false);
      reliable_generation_ = reliable_generation_ == UINT32_MAX ? 1 : reliable_generation_ + 1;
      generation = reliable_generation_;
    }
    std::optional<CalibrationMessage> round;
    {
      std::lock_guard lock(calibration_mutex_);
      round = calibration_exchange_->NextRound(generation);
      if (round) {
        calibration_display_round_ = *round;
        calibration_round_started_at_.reset();
        calibration_round_pending_ = true;
      }
    }
    if (!round) { LogDiagnostic("calibration_round_invalid"); finish(false); return; }
    calibration_stage_.store(round->phase == 0 ? 1 : 3);
    if (!send_message(*round)) { finish(false); return; }
    {
      std::unique_lock lock(calibration_mutex_);
      if (!calibration_condition_.wait_for(lock, std::chrono::seconds(5), [&] {
            return stop_probe_.load() || !calibration_exchange_->awaiting_ack();
          })) { lock.unlock(); LogDiagnostic("calibration_round_ack_timeout"); finish(false); return; }
      if (stop_probe_.load()) return;
    }
    {
      std::lock_guard send_lock(audio_send_mutex_);
      std::lock_guard reliable_lock(reliable_mutex_);
      ConfigurePlayoutBudget(round->budget.target_ms,round->budget.maximum_ms,round->output_reserve_ms);
      reliable_mode_.store(round->reliable); probe_repair_mode_.store(0);
      last_buffered_ms_ = 0; repair_pressure_ = false;
      if (round->reliable) {
        if (!quic_->StartReliableAudio(stream_id,generation)) { finish(false); return; }
        reliable_lag_.Begin(stream_id,generation,Clock::now(),std::chrono::milliseconds(
            round->budget.maximum_ms - round->output_reserve_ms));
      }
    }
    const auto began = Clock::now();
    {
      std::lock_guard lock(calibration_mutex_);
      calibration_round_started_at_ = began;
    }
    calibration_round_active_.store(true);
    LogDiagnostic("calibration_round_start round=" + std::to_string(round->index) + " phase=" + std::to_string(round->phase) +
        " transport=" + (round->reliable ? std::string("reliable_stream") : std::string("datagram")) +
        " target_ms=" + std::to_string(round->budget.target_ms) + " maximum_ms=" + std::to_string(round->budget.maximum_ms) +
        " output_reserve_ms=" + std::to_string(round->output_reserve_ms));
    const auto frame_count = options.goal ? round->frames : 120;
    const auto packet_count = std::uint32_t(round->seconds) * 48000 / frame_count;
    const auto payload_size = options.goal && round->codec ? round->bitrate * frame_count / 48000 / 8 : 960u;
    for (std::uint32_t packet = 0; packet < packet_count; ++packet) {
      const auto target = began + std::chrono::nanoseconds(std::uint64_t(packet) * frame_count * 1'000'000'000 / 48000);
      if (!wait_until(target)) return;
      const auto woke = MonotonicNanoseconds();
      const auto sequence = round->first_sequence + packet * (frame_count / 120);
      auto random = MakeNetworkProbeDatagram(stream_id,sequence,payload_size + 8);
      std::lock_guard send_lock(audio_send_mutex_);
      {
        std::lock_guard debug_lock(debug_mutex_);
        if (!debug_trace_.IsActive() || active_debug_stream_id_ != stream_id || debug_ending_) return;
        ++outstanding_debug_sends_;
      }
      const auto capture = std::chrono::duration_cast<std::chrono::nanoseconds>(target.time_since_epoch()).count() -
          (options.goal && round->codec ? std::int64_t(frame_count) * 1'000'000'000 / 48000 : 0);
      const auto sent_at = MonotonicNanoseconds();
      wire::TimedAudioRecord record{stream_id,reliable_generation_,sequence,static_cast<std::uint16_t>(frame_count),wire::AudioRecordKind::probe,
          static_cast<std::uint64_t>(capture),round->first_source_frame + std::uint64_t(packet) * frame_count,
          std::vector<std::byte>(random.begin() + 8,random.end())};
      if (round->reliable) {
        std::lock_guard reliable_lock(reliable_mutex_);
        reliable_lag_.Produced(sequence,record.source_frame + frame_count,frame_count);
        reliable_lag_.Retain(record,static_cast<std::uint64_t>(sent_at));
      }
      const auto bytes = wire::EncodeTimedAudioRecord(record);
      const auto outcome = AudioDeadline(round->budget.maximum_ms,round->output_reserve_ms).Expired(capture,sent_at) ?
          ProbeSendOutcome{ProbeSendStatus::expired} : quic_->SendProbe(bytes,stream_id,sequence,round->reliable);
      const bool accepted = outcome.status == ProbeSendStatus::accepted;
      debug_trace_.RecordPacket(sequence,capture,woke,sent_at,accepted,outcome);
      if (!accepted) CompleteDebugSend(stream_id);
      probe_packets_processed_.store(sequence + 1);
    }
    if (!wait_until(began + std::chrono::seconds(round->seconds))) return;
    bool finished;
    {
      std::lock_guard lock(calibration_mutex_);
      finished = calibration_exchange_->CompleteRound() && calibration_exchange_->finished();
    }
    // Retain the current receiver and feedback during the bounded drain interval.
    if (!wait_until(Clock::now() + std::chrono::milliseconds(options.goal ? round->budget.maximum_ms + 100 : (finished ? 10000 : 5000)))) return;
    {
      std::lock_guard lock(calibration_mutex_);
      calibration_round_pending_ = false;
      calibration_display_round_.reset();
      calibration_round_started_at_.reset();
    }
  }
  finish(true);
}

void SenderService::ProbeWorker(std::uint32_t stream_id) {
  if (calibration_options_) { CalibrationWorker(stream_id); return; }
  using Clock = std::chrono::steady_clock;
  probe_packets_processed_.store(0);
  probe_recovering_.store(false);
  probe_stream_id_.store(stream_id);
  const auto rounds = network_probe_rounds();
  const auto close_timer = [](HANDLE handle) { CloseHandle(handle); };
  std::unique_ptr<void, decltype(close_timer)> timer(
      CreateWaitableTimerExW(nullptr, nullptr,
                             CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                             TIMER_ALL_ACCESS), close_timer);
  if (!timer) {
    LogDiagnostic("network_probe_timer_create_failed");
    return;
  }
  const auto began = Clock::now();
  LogDiagnostic("network_probe_trace_fields captured_at_ns=scheduled queued_at_ns=woke send_at_ns=send_call");
  std::uint32_t sequence = 0;
  std::uint64_t source_frame = 0;
  for (std::size_t index = 0; index < rounds.size(); ++index) {
    const auto& round = rounds[index];
    const bool reliable = round.reliable;
    const auto round_start = began +
        std::chrono::seconds(index * (kNetworkProbeSecondsPerRound +
            (coordinated_audio_.load() ? kCoordinatedProbeRecoverySeconds : 0)));
    // Keep the old stream alive during recovery so its tail can finish delivery.
    while (Clock::now() < round_start) {
      if (stop_probe_.load()) return;
      std::this_thread::sleep_for(std::min(std::chrono::milliseconds(5),
          std::chrono::duration_cast<std::chrono::milliseconds>(round_start - Clock::now())));
    }
    {
      std::lock_guard send_lock(audio_send_mutex_);
      std::lock_guard reliable_lock(reliable_mutex_);
      probe_recovering_.store(index > 0 && coordinated_audio_.load());
      if (coordinated_audio_.load()) quic_->ConfigureAudioWindow(
          target_ms_.load(), maximum_ms_.load(), output_reserve_ms_.load());
      reliable_mode_.store(reliable);
      reliable_generation_ = reliable_generation_ == UINT32_MAX ? 1 : reliable_generation_ + 1;
      probe_repair_window_.Reset();
      probe_repair_mode_.store(round.repair);
      probe_repair_sent_bytes_.store(0);
      repair_window_at_ = repair_original_bytes_ = repair_extra_bytes_ = 0;
      repair_pressure_ = false; last_buffered_ms_ = 0;
      if (!reliable) quic_->StopReliableAudio();
      if (reliable) {
        if (!quic_->StartReliableAudio(stream_id, reliable_generation_)) {
          LogDiagnostic("network_probe_reliable_stream_start_failed"); return;
        }
        reliable_lag_.Begin(stream_id, reliable_generation_, Clock::now(),
            coordinated_audio_.load() ? std::optional(std::chrono::milliseconds(
                maximum_ms_.load() - output_reserve_ms_.load())) : std::nullopt);
      }
    }
    const auto count = round.packets_per_second * kNetworkProbeSecondsPerRound;
    std::uint32_t accepted = 0;
    std::array<std::uint32_t, 8> outcomes{};
    std::size_t pending_peak = 0;
    std::uint32_t first_transport_status = 0;
    LogDiagnostic("network_probe_round_start round=" + std::to_string(index + 1) +
                  " variant=" + std::to_string(round.variant) +
                  " repeat=" + std::to_string(round.repeat) +
                  " transport=" + (reliable ? std::string("reliable_stream")
                                              : std::string("datagram")) +
                  " payload_bytes=" + std::to_string(round.payload_bytes) +
                  " packets_per_second=" + std::to_string(round.packets_per_second) +
                  " burst_packets=" + std::to_string(round.burst_packets) +
                  " controller=" + std::to_string(round.controller) +
                  " repair=" + std::to_string(round.repair) +
                  " correction_percent=" + std::to_string(round.correction_percent) +
                  " recovery_seconds=" + std::to_string(coordinated_audio_.load() && index > 0 ? kCoordinatedProbeRecoverySeconds : 0) +
                  " sequence=" + std::to_string(sequence));
    for (std::uint32_t packet = 0; packet < count; ++packet, ++sequence) {
      const auto tick = packet / round.burst_packets;
      const auto target = round_start + std::chrono::nanoseconds(
          (static_cast<std::uint64_t>(tick) * round.burst_packets +
           (coordinated_audio_.load() ? round.burst_packets - 1 : 0)) *
           1'000'000'000ull / round.packets_per_second);
      const auto remaining = target - Clock::now();
      if (remaining > Clock::duration::zero()) {
        LARGE_INTEGER due_time{};
        due_time.QuadPart = -std::max<std::int64_t>(
            1, std::chrono::duration_cast<std::chrono::nanoseconds>(
                   remaining).count() / 100);
        if (!SetWaitableTimerEx(timer.get(), &due_time, 0, nullptr, nullptr,
                                nullptr, 0) ||
            WaitForSingleObject(timer.get(), INFINITE) != WAIT_OBJECT_0) {
          LogDiagnostic("network_probe_timer_wait_failed");
          return;
        }
      }
      if (stop_probe_.load()) return;
      probe_recovering_.store(false);
      const auto woke_at = MonotonicNanoseconds();
      auto datagram = MakeNetworkProbeDatagram(stream_id, sequence,
          coordinated_audio_.load() ? round.payload_bytes - 24 : round.payload_bytes);
      std::lock_guard send_lock(audio_send_mutex_);
      bool trace = false;
      {
        std::lock_guard debug_lock(debug_mutex_);
        trace = debug_trace_.IsActive() &&
                active_debug_stream_id_ == stream_id && !debug_ending_;
        if (trace) ++outstanding_debug_sends_;
      }
      if (!trace) return;
      const auto sent_at = MonotonicNanoseconds();
      const auto captured_at = std::chrono::duration_cast<std::chrono::nanoseconds>(
          (round_start + std::chrono::nanoseconds(std::uint64_t(packet) * 1'000'000'000ull /
                                                round.packets_per_second)).time_since_epoch()).count();
      wire::TimedAudioRecord record;
      const auto frames = static_cast<std::uint16_t>(48000 / round.packets_per_second);
      if (coordinated_audio_.load()) {
        record = {stream_id, reliable_generation_, sequence, frames, wire::AudioRecordKind::probe,
                  static_cast<std::uint64_t>(captured_at), source_frame,
                  std::vector<std::byte>(datagram.begin() + 8, datagram.end())};
        datagram = wire::EncodeTimedAudioRecord(record);
        if (reliable) {
          std::lock_guard reliable_lock(reliable_mutex_);
          reliable_lag_.Produced(sequence, source_frame + frames, frames);
          reliable_lag_.Retain(record, static_cast<std::uint64_t>(sent_at));
        }
      }
      const bool expired = coordinated_audio_.load() && AudioDeadline(maximum_ms_.load(),
          output_reserve_ms_.load()).Expired(captured_at, sent_at);
      const auto outcome = expired ? ProbeSendOutcome{ProbeSendStatus::expired} :
          quic_->SendProbe(datagram, stream_id, sequence, reliable);
      const bool sent = outcome.status == ProbeSendStatus::accepted;
      ++outcomes[static_cast<std::size_t>(outcome.status)];
      pending_peak = std::max(pending_peak, outcome.pending_reliable_sends);
      if (outcome.status == ProbeSendStatus::transport_rejected &&
          first_transport_status == 0) {
        first_transport_status = outcome.transport_status;
      }
      if (sent) ++accepted;
      const auto scheduled_at = std::chrono::duration_cast<std::chrono::nanoseconds>(
          target.time_since_epoch()).count();
      debug_trace_.RecordPacket(sequence, coordinated_audio_.load() ? captured_at : scheduled_at,
                                woke_at, sent_at, sent, outcome);
      if (coordinated_audio_.load() && !reliable && sent && round.repair != 0) {
        const auto now = static_cast<std::uint64_t>(sent_at);
        if (now - repair_window_at_ >= 100'000'000) {
          repair_window_at_ = now; repair_original_bytes_ = repair_extra_bytes_ = 0;
        }
        repair_original_bytes_ += datagram.size();
        const auto parity = probe_repair_window_.Add(record, now +
            AudioDeadline(maximum_ms_.load(), output_reserve_ms_.load()).RemainingNanoseconds(captured_at, now));
        std::optional<wire::TimedAudioRecord> extra;
        if (round.repair == 1) extra = parity;
        if (round.repair == 3 && packet >= 4 && sequence % 4 == 0) {
          extra = probe_repair_window_.Retry(sequence - 4, now);
          if (extra) extra->kind = wire::AudioRecordKind::repeated;
        }
        if (extra && !repair_pressure_) {
          const auto bytes = wire::EncodeTimedAudioRecord(*extra);
          if ((repair_extra_bytes_ + bytes.size()) * 10 <= repair_original_bytes_ * 3) {
            const auto result = quic_->SendProbe(bytes, stream_id, extra->sequence, false, true);
            if (result.status == ProbeSendStatus::accepted) {
              repair_extra_bytes_ += bytes.size(); probe_repair_sent_bytes_.fetch_add(bytes.size());
            }
          }
        }
      }
      source_frame += frames;
      if (!sent) CompleteDebugSend(stream_id);
      probe_packets_processed_.store(sequence + 1);
    }
    LogDiagnostic("network_probe_round_end round=" + std::to_string(index + 1) +
                  " stream_id=" + std::to_string(stream_id) +
                  " sequence=" + std::to_string(sequence) +
                  " send_accepted=" + std::to_string(accepted) +
                  " send_rejected=" + std::to_string(count - accepted) +
                  " repair_sent_bytes=" + std::to_string(probe_repair_sent_bytes_.load()) +
                  " expired_before_send=" + std::to_string(outcomes[7]) +
                  " pending_peak=" + std::to_string(pending_peak) +
                  " reject_disconnected=" + std::to_string(outcomes[1]) +
                  " reject_stream_unavailable=" + std::to_string(outcomes[2]) +
                  " reject_pending_limit=" + std::to_string(outcomes[3]) +
                  " reject_invalid_size=" + std::to_string(outcomes[4]) +
                  " reject_datagram_unavailable=" + std::to_string(outcomes[5]) +
                  " reject_transport=" + std::to_string(outcomes[6]) +
                  " transport_status=" + std::to_string(first_transport_status));
  }
}

std::vector<NetworkProbeRound> SenderService::network_probe_rounds() const {
  const auto stream = probe_stream_id_.load();
  if (coordinated_audio_.load()) return MakeCoordinatedProbeRounds(stream);
  const auto rounds = MakeNetworkProbeRounds(stream);
  return {rounds.begin(), rounds.end()};
}

bool SenderService::HandleRepairRequest(const wire::ControlEnvelope& request) {
  std::lock_guard send_lock(audio_send_mutex_);
  if (!network_probe_ || !coordinated_audio_.load() || reliable_mode_.load() ||
      probe_repair_mode_.load() != 2 || request.stream_id != probe_stream_id_.load() ||
      request.audio_generation != reliable_generation_) return true;
  const auto now = static_cast<std::uint64_t>(MonotonicNanoseconds());
  for (const auto sequence : request.repair_sequences) {
    const auto extra = probe_repair_window_.Retry(sequence, now);
    if (!extra) {
      LogDiagnostic("network_probe_repair_request sequence=" + std::to_string(sequence) +
                    " accepted=0 reason=cache_miss_or_expired");
      continue;
    }
    const auto bytes = wire::EncodeTimedAudioRecord(*extra);
    bool accepted = false;
    std::string reason = repair_pressure_ ? "pressure" : "overhead_budget";
    if (!repair_pressure_ && now - repair_window_at_ < 100'000'000 &&
        (repair_extra_bytes_ + bytes.size()) * 10 <= repair_original_bytes_ * 3) {
      const auto outcome = quic_->SendProbe(bytes, request.stream_id, sequence, false, true);
      accepted = outcome.status == ProbeSendStatus::accepted;
      reason = std::string(ProbeSendStatusName(outcome.status));
      if (accepted) { repair_extra_bytes_ += bytes.size(); probe_repair_sent_bytes_.fetch_add(bytes.size()); }
    }
    LogDiagnostic("network_probe_repair_request sequence=" + std::to_string(sequence) +
                  " remaining_ms=" + std::to_string(request.maximum_ms) +
                  " accepted=" + std::to_string(accepted) + " reason=" + reason);
  }
  return true;
}

void SenderService::ConfigureReliableAudio(bool enabled) {
  std::lock_guard send_lock(audio_send_mutex_);
  reliable_mode_.store(enabled);
  std::lock_guard reliable_lock(reliable_mutex_);
  reliable_generation_ = 0;
}

SenderService::AudioFormat SenderService::audio_format() const {
  std::lock_guard lock(audio_send_mutex_);
  return negotiated_format_;
}

bool SenderService::ConfigureAudioFormat(wire::ControlEnvelope& setup) {
  std::lock_guard lock(audio_send_mutex_);
  if (!live_encoder_.Configure(setup.audio_codec ? setup.audio_bitrate : 0,
                                setup.audio_frame_count)) return false;
  if (setup.audio_codec && (setup.audio_frame_count + live_encoder_.lookahead()) / 48.0 +
      2 + setup.output_reserve_ms >= setup.maximum_ms) return false;
  live_opus_.store(setup.audio_codec != 0);
  setup.codec_lookahead_frames = live_encoder_.lookahead();
  negotiated_format_ = {setup.audio_codec != 0, setup.audio_codec ? setup.audio_bitrate : 3072000,
                        setup.audio_frame_count ? setup.audio_frame_count : 120};
  LogDiagnostic("audio_format codec=" + std::string(setup.audio_codec ? "opus" : "pcm") +
      " bitrate=" + std::to_string(setup.audio_bitrate) +
      " frame_count=" + std::to_string(setup.audio_frame_count ? setup.audio_frame_count : 120) +
      " lookahead_frames=" + std::to_string(setup.codec_lookahead_frames));
  return true;
}

void SenderService::ConfigureCoordinatedAudio(bool enabled) {
  coordinated_audio_.store(enabled);
}

bool SenderService::ConfigurePlayoutBudget(std::uint32_t target_ms,
                                           std::uint32_t maximum_ms,
                                           std::uint32_t output_reserve_ms) {
  if (target_ms <= output_reserve_ms || maximum_ms < target_ms || maximum_ms > 2000) {
    return false;
  }
  if (budget_handler_) budget_handler_(maximum_ms);
  target_ms_.store(target_ms);
  maximum_ms_.store(maximum_ms);
  output_reserve_ms_.store(output_reserve_ms);
  quic_->ConfigureAudioWindow(target_ms, maximum_ms, output_reserve_ms);
  LogDiagnostic("audio_budget target_ms=" + std::to_string(target_ms) +
                " maximum_ms=" + std::to_string(maximum_ms) +
                " output_reserve_ms=" + std::to_string(output_reserve_ms));
  return true;
}

bool SenderService::ObserveAudioProgress(
    std::uint32_t stream_id, std::uint32_t generation,
    std::optional<std::uint32_t> latest_received, std::uint64_t feedback_at_ns,
    std::optional<std::uint64_t> played_source, std::uint32_t buffered_ms) {
  std::unique_lock send_lock(audio_send_mutex_);
  if (calibration_options_ && !calibration_round_active_.load()) return true;
  if (music_test() || live_opus_.load()) {
    std::lock_guard reliable_lock(reliable_mutex_);
    if (generation == reliable_generation_ && latest_received && reliable_mode_.load())
      quic_->ConfirmReliableReceived(stream_id, generation, *latest_received);
    return true;
  }
  if (network_probe_) {
    if (stream_id != probe_stream_id_.load() || generation != reliable_generation_) return true;
    const auto stamp = static_cast<std::uint64_t>(MonotonicNanoseconds());
    if (coordinated_audio_.load() && (feedback_at_ns == 0 || feedback_at_ns > stamp + 10'000'000 ||
        (stamp > feedback_at_ns && stamp - feedback_at_ns > 50'000'000))) return true;
    repair_pressure_ = buffered_ms > maximum_ms_.load() - output_reserve_ms_.load() ||
                       (last_buffered_ms_ > 0 && buffered_ms > last_buffered_ms_ + 10);
    last_buffered_ms_ = buffered_ms;
    if (!reliable_mode_.load()) return true;
  }
  if (!reliable_mode_.load()) return music_test();
  std::optional<std::uint32_t> latest_produced;
  std::vector<wire::TimedAudioRecord> replay;
  ReliableAudioLag::ReplayBudget replay_budget;
  if (coordinated_audio_.load()) {
    const auto capacity = quic_->AudioCapacity();
    if (capacity.round_trip_ns != 0) {
      replay_budget.bytes_per_second = 0.75 * std::min(capacity.acknowledged_bytes_per_second,
          double(capacity.congestion_window_bytes) * 1e9 / double(capacity.round_trip_ns));
      replay_budget.delivery_delay_ns = capacity.round_trip_ns;
    }
    std::lock_guard queue_lock(queue_mutex_);
    const auto now = static_cast<std::uint64_t>(MonotonicNanoseconds());
    const AudioDeadline deadline(maximum_ms_.load(), output_reserve_ms_.load());
    for (const auto& queued : audio_queue_) {
      if (!deadline.Expired(static_cast<std::uint64_t>(queued.captured_at_ns), now)) {
        replay_budget.reserved_bytes += queued.packet.pcm.size() + 34;
      }
    }
  }
  std::chrono::milliseconds feedback_age{0};
  const auto next_generation = generation == UINT32_MAX ? 1 : generation + 1;
  {
    std::lock_guard reliable_lock(reliable_mutex_);
    if (coordinated_audio_.load()) {
      const auto now_ns = static_cast<std::uint64_t>(MonotonicNanoseconds());
      if (feedback_at_ns == 0 || feedback_at_ns > now_ns + 10'000'000ull) return true;
      feedback_age = std::chrono::milliseconds(
          now_ns > feedback_at_ns ? (now_ns - feedback_at_ns) / 1'000'000 : 0);
    }
    if (coordinated_audio_.load() && feedback_age >
        std::chrono::milliseconds((maximum_ms_.load() - output_reserve_ms_.load()) / 2)) return true;
    if (!reliable_lag_.ConfirmReceived(stream_id, generation, latest_received, played_source,
                                     coordinated_audio_.load() ? feedback_at_ns : 0)) return true;
    if (latest_received) quic_->ConfirmReliableReceived(stream_id, generation, *latest_received);
    if (!reliable_lag_.Observe(stream_id, generation, latest_received,
                               ReliableAudioLag::Clock::now(), feedback_age, played_source)) {
      return true;
    }
    latest_produced = reliable_lag_.latest_produced();
    if (coordinated_audio_.load()) replay = reliable_lag_.ReplayForDelivery(next_generation,
        static_cast<std::uint64_t>(MonotonicNanoseconds()), latest_received, played_source, replay_budget);
  }
  std::size_t discarded = 0;
  {
    std::lock_guard queue_lock(queue_mutex_);
    const AudioDeadline deadline(maximum_ms_.load(), output_reserve_ms_.load());
    const auto now = static_cast<std::uint64_t>(MonotonicNanoseconds());
    while (!audio_queue_.empty() && (!coordinated_audio_.load() ||
        deadline.Expired(static_cast<std::uint64_t>(audio_queue_.front().captured_at_ns), now))) {
      audio_queue_.pop_front(); ++discarded;
    }
    dropped_audio_packets_ += discarded;
    for (std::size_t index = 0; index < discarded; ++index) {
      audio_metrics_.record_dropped(false);
    }
  }
  if (!quic_->StartReliableAudio(stream_id, next_generation)) {
    send_lock.unlock();
    LogDiagnostic("reliable_audio_restart_failed");
    return false;
  }
  {
    std::lock_guard reliable_lock(reliable_mutex_);
    reliable_generation_ = next_generation;
    reliable_lag_.Begin(stream_id, next_generation,
                        ReliableAudioLag::Clock::now(), coordinated_audio_.load() ? std::optional(std::chrono::milliseconds(
                          maximum_ms_.load() - output_reserve_ms_.load())) : std::nullopt);
  }
  std::size_t replayed = 0;
  for (const auto& record : replay) {
    const auto now = static_cast<std::uint64_t>(MonotonicNanoseconds());
    if (AudioDeadline(maximum_ms_.load(), output_reserve_ms_.load()).Expired(record.captured_at_ns, now)) continue;
    const auto bytes = wire::EncodeTimedAudioRecord(record);
    const bool sent = network_probe_ ? quic_->SendProbe(bytes, stream_id, record.sequence, true, true).status ==
        ProbeSendStatus::accepted : quic_->SendAudio(bytes);
    if (sent) {
      ++replayed;
      std::lock_guard reliable_lock(reliable_mutex_);
      reliable_lag_.Produced(record.sequence, record.source_frame + record.frame_count, record.frame_count);
      reliable_lag_.Retain(record, now);
    }
  }
  send_lock.unlock();
  LogDiagnostic("reliable_audio_live_edge_restart stream_id=" +
                std::to_string(stream_id) + " old_generation=" +
                std::to_string(generation) + " new_generation=" +
                std::to_string(next_generation) + " produced=" +
                (latest_produced ? std::to_string(*latest_produced) : "none") +
                " received=" +
                (latest_received ? std::to_string(*latest_received) : "none") +
                " played_source=" + (played_source ? std::to_string(*played_source) : "none") +
                " feedback_age_ms=" + std::to_string(feedback_age.count()) +
                " replay_capacity_bytes_per_second=" + std::to_string(replay_budget.bytes_per_second) +
                " replay_delivery_delay_ms=" + std::to_string(replay_budget.delivery_delay_ns / 1'000'000) +
                " replay_candidates=" + std::to_string(replay.size()) +
                " replayed_packets=" + std::to_string(replayed) +
                " discarded_queue_packets=" + std::to_string(discarded));
  return true;
}

void SenderService::ConfigureDebugDuration(
    std::optional<std::chrono::seconds> duration) {
  if (duration.has_value() &&
      (*duration < std::chrono::seconds(60) ||
       *duration > std::chrono::seconds(86400))) {
    throw std::invalid_argument("debug duration must be from 60 to 86400 seconds");
  }
  std::lock_guard lock(debug_mutex_);
  debug_duration_ = duration;
}

std::optional<std::chrono::seconds> SenderService::debug_duration() const {
  std::lock_guard lock(debug_mutex_);
  return debug_duration_;
}

void SenderService::SetDebugOutputDirectory(
    std::filesystem::path directory) {
  std::lock_guard lock(debug_mutex_);
  debug_output_directory_ = std::move(directory);
}

bool SenderService::WaitForDebugCompletion(
    std::chrono::milliseconds timeout) {
  std::unique_lock lock(debug_mutex_);
  debug_condition_.wait_for(lock, timeout, [this] {
    return debug_completed_ || debug_wait_failed_;
  });
  return debug_completed_;
}

void SenderService::MarkDebugResultReceived(
    std::span<const std::byte> session_id) {
  std::lock_guard lock(debug_mutex_);
  if (!debug_duration_.has_value() || session_id.size() != active_debug_session_id_.size() ||
      !std::equal(session_id.begin(), session_id.end(),
                  active_debug_session_id_.begin())) {
    return;
  }
  debug_completed_ = true;
  debug_condition_.notify_all();
}

void SenderService::LogDiagnostic(std::string_view line) const {
  if (options_.diagnostic_log) {
    try {
      options_.diagnostic_log(line);
      return;
    } catch (...) {
    }
  }
  std::cerr << line << '\n';
}

std::filesystem::path SenderService::debug_session_directory() const {
  std::lock_guard lock(debug_mutex_);
  if (active_debug_stream_id_ == 0) return {};
  return debug_output_directory_ / SessionHex(active_debug_session_id_);
}

void SenderService::SetControlHandler(ControlHandler handler) {
  control_handler_ = std::move(handler);
}

void SenderService::SetResetHandler(ResetHandler handler) {
  reset_handler_ = std::move(handler);
}

void SenderService::SetClosedHandler(ClosedHandler handler) {
  closed_handler_ = std::move(handler);
}

void SenderService::SetDebugEndedHandler(DebugEndedHandler handler) {
  debug_ended_handler_ = std::move(handler);
}

std::uint64_t SenderService::dropped_audio_packets() const noexcept {
  std::lock_guard lock(queue_mutex_);
  return dropped_audio_packets_;
}

void SenderService::EnqueueAudio(const wire::AudioDatagram& packet,
                                  std::int64_t captured_at_ns, std::uint64_t source_frame) {
  std::lock_guard lock(queue_mutex_);
  if (coordinated_audio_.load()) {
    const AudioDeadline deadline(maximum_ms_.load(), output_reserve_ms_.load());
    const auto now = static_cast<std::uint64_t>(MonotonicNanoseconds());
    while (!audio_queue_.empty() && deadline.Expired(
             static_cast<std::uint64_t>(audio_queue_.front().captured_at_ns), now)) {
      audio_queue_.pop_front();
      ++dropped_audio_packets_;
      audio_metrics_.record_dropped(false);
    }
  }
  if (audio_queue_.size() >= kAudioQueueCapacity) {
    ++dropped_audio_packets_;
    audio_metrics_.record_dropped(false);
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
    return;
  }
  audio_queue_.push_back(
      QueuedAudioPacket{packet, captured_at_ns, MonotonicNanoseconds(), source_frame});
  audio_metrics_.record_queued();
  audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                 datagram_max_payload_);
  queue_condition_.notify_one();
}

void SenderService::AudioWorker() {
  for (;;) {
    QueuedAudioPacket queued{};
    {
      std::unique_lock lock(queue_mutex_);
      queue_condition_.wait(lock, [this] {
        return stop_worker_ || capture_reset_pending_ || !audio_queue_.empty();
      });
      if (stop_worker_ && audio_queue_.empty()) {
        return;
      }
      if (capture_reset_pending_) {
        capture_reset_pending_ = false;
        const bool should_notify = !stop_worker_;
        lock.unlock();
        if (should_notify && reset_handler_) reset_handler_();
        continue;
      }
      queued = audio_queue_.front();
      audio_queue_.pop_front();
      audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                     datagram_max_payload_);
      if (!datagram_ready_ && !reliable_mode_.load()) {
        ++dropped_audio_packets_;
        audio_metrics_.record_dropped(false);
        continue;
      }
    }
    std::unique_lock send_lock(audio_send_mutex_);
    if (coordinated_audio_.load() && AudioDeadline(maximum_ms_.load(), output_reserve_ms_.load())
          .Expired(static_cast<std::uint64_t>(queued.captured_at_ns),
                   static_cast<std::uint64_t>(MonotonicNanoseconds()))) {
      std::lock_guard queue_lock(queue_mutex_);
      ++dropped_audio_packets_;
      audio_metrics_.record_dropped(false);
      continue;
    }
    {
      std::lock_guard session_lock(session_mutex_);
      if (session_.AcceptAudio(queued.packet) != AudioDisposition::accepted) {
        std::lock_guard queue_lock(queue_mutex_);
        ++dropped_audio_packets_;
        audio_metrics_.record_dropped(false);
        audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                       datagram_max_payload_);
        continue;
      }
    }
    std::vector<std::byte> encoded;
    std::optional<wire::TimedAudioRecord> compressed;
    if (live_opus_.load()) {
      std::uint32_t generation;
      { std::lock_guard lock(reliable_mutex_);
        generation = reliable_mode_.load() ? std::max(1u, reliable_generation_) : 1; }
      try {
        compressed = live_encoder_.Push(queued.packet, queued.captured_at_ns, queued.source_frame, generation);
      } catch (const std::exception& error) {
        LogDiagnostic(std::string("live_audio_encode_failed error=") + error.what());
        audio_metrics_.record_dropped(false); continue;
      }
      if (!compressed) continue;
      if (AudioDeadline(maximum_ms_.load(), output_reserve_ms_.load()).Expired(
          compressed->captured_at_ns, static_cast<std::uint64_t>(MonotonicNanoseconds()))) {
        audio_metrics_.record_dropped(false); continue;
      }
      encoded = wire::EncodeTimedAudioRecord(*compressed);
    } else
    if (coordinated_audio_.load()) {
      std::uint32_t generation = 1;
      if (reliable_mode_.load() || music_clip_) {
        std::lock_guard reliable_lock(reliable_mutex_);
        generation = reliable_generation_;
      }
      wire::TimedAudioRecord record;
      record.stream_id = queued.packet.stream_id;
      record.generation = generation;
      record.sequence = queued.packet.sequence;
      record.captured_at_ns = static_cast<std::uint64_t>(queued.captured_at_ns);
      record.source_frame = queued.source_frame;
      record.payload.assign(queued.packet.pcm.begin(), queued.packet.pcm.end());
      if (reliable_mode_.load()) {
        std::lock_guard reliable_lock(reliable_mutex_);
        reliable_lag_.Retain(record, static_cast<std::uint64_t>(MonotonicNanoseconds()));
      }
      encoded = wire::EncodeTimedAudioRecord(record);
    } else {
      const auto bytes = wire::EncodeAudioDatagram(queued.packet);
      encoded.assign(bytes.begin(), bytes.end());
    }
    bool trace_this_packet = false;
    {
      std::lock_guard debug_lock(debug_mutex_);
      trace_this_packet =
          debug_trace_.IsActive() &&
          active_debug_stream_id_ == queued.packet.stream_id;
      if (trace_this_packet && !reliable_mode_.load()) ++outstanding_debug_sends_;
    }
    const auto send_at_ns = MonotonicNanoseconds();
    const bool sent = compressed ? quic_->SendProbe(encoded, compressed->stream_id,
        compressed->sequence, reliable_mode_.load()).status == ProbeSendStatus::accepted :
        quic_->SendAudio(encoded);
    if (trace_this_packet) {
      debug_trace_.RecordPacket(queued.packet.sequence,
                                queued.captured_at_ns,
                                queued.queued_at_ns,
                                send_at_ns, sent);
      if (!sent && !reliable_mode_.load()) CompleteDebugSend(queued.packet.stream_id);
    }
    if (sent) {
      audio_metrics_.record_sent();
    } else {
      std::lock_guard lock(queue_mutex_);
      ++dropped_audio_packets_;
      audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                     datagram_max_payload_);
      audio_metrics_.record_dropped(true);
    }
  }
}

void SenderService::HandleCapturePacket(std::span<const std::byte> bytes,
                                         const PcmFormat& format, std::uint64_t captured_at_ns) {
  audio_metrics_.record_capture(bytes.size(), format);
  std::lock_guard capture_lock(capture_mutex_);
  {
    std::lock_guard session_lock(session_mutex_);
    if (session_.phase() != SessionPhase::active) {
      return;
    }
  }
  if (!normalizer_format_.has_value() ||
      normalizer_format_->sample_rate_hz != format.sample_rate_hz ||
      normalizer_format_->channels != format.channels ||
      normalizer_format_->sample_format != format.sample_format) {
    normalizer_format_ = format;
    normalizer_.emplace(format);
  }
  const auto normalized_start = static_cast<std::uint64_t>(
      static_cast<std::int64_t>(captured_at_ns) + static_cast<std::int64_t>(
          normalizer_->next_sample_offset() * 1'000'000'000.0 / format.sample_rate_hz));
  const auto samples = normalizer_->Convert(bytes);
  audio_metrics_.record_normalized_frames(samples.size() / 2);
  packetizer_.PushTimed(samples, normalized_start,
                       [this](const wire::AudioDatagram& packet, std::uint64_t capture_time,
                              std::uint64_t source_frame) {
    audio_metrics_.record_packetized(packet.stream_id, packet.sequence);
    bool accepted = false;
    {
      std::lock_guard lock(session_mutex_);
      accepted = session_.AcceptAudio(packet) == AudioDisposition::accepted;
    }
    if (accepted) {
      if (reliable_mode_.load()) {
        std::lock_guard reliable_lock(reliable_mutex_);
        reliable_lag_.Produced(packet.sequence, source_frame + 120);
      }
      EnqueueAudio(packet, static_cast<std::int64_t>(capture_time), source_frame);
    }
  });
}

void SenderService::HandleCaptureReset() {
  audio_metrics_.record_capture_reset();
  {
    std::lock_guard lock(capture_mutex_);
    normalizer_.reset();
    normalizer_format_.reset();
  }
  {
    std::lock_guard lock(queue_mutex_);
    audio_queue_.clear();
    capture_reset_pending_ = true;
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
  }
  queue_condition_.notify_one();
}

void SenderService::DiagnosticsWorker() {
  diagnostics_last_summary_ = std::chrono::steady_clock::now();
  auto next_summary = diagnostics_last_summary_ + std::chrono::seconds(1);
  for (;;) {
    std::unique_lock lock(diagnostics_mutex_);
    if (diagnostics_condition_.wait_until(
            lock, next_summary, [this] { return stop_diagnostics_; })) {
      return;
    }
    lock.unlock();
    LogAudioSummary();
    const auto now = std::chrono::steady_clock::now();
    bool end_debug = false;
    std::uint32_t end_reason = 0;
    {
      std::lock_guard debug_lock(debug_mutex_);
      if (debug_end_pending_) {
        end_debug = true;
        end_reason = debug_end_reason_;
      } else if (debug_deadline_.has_value() && now >= *debug_deadline_) {
        end_debug = true;
        end_reason = 1;
      }
    }
    if (end_debug) EndDebugSession(end_reason);
    next_summary = now + std::chrono::seconds(1);
  }
}

void SenderService::EndDebugSession(std::uint32_t reason) {
  std::array<std::byte, 16> session_id{};
  std::uint32_t stream_id = 0;
  {
    std::lock_guard lock(debug_mutex_);
    if (!debug_trace_.IsActive() || debug_ending_) return;
    debug_ending_ = true;
    debug_end_reason_ = reason;
    debug_end_pending_ = false;
    debug_deadline_.reset();
    session_id = active_debug_session_id_;
    stream_id = active_debug_stream_id_;
  }
  stop_music_.store(true);
    music_condition_.notify_all();

  {
    std::lock_guard capture_lock(capture_mutex_);
    std::lock_guard session_lock(session_mutex_);
    (void)session_.EndStream(stream_id);
  }
  {
    std::lock_guard queue_lock(queue_mutex_);
    const auto discarded = audio_queue_.size();
    audio_queue_.clear();
    dropped_audio_packets_ += discarded;
    for (std::size_t index = 0; index < discarded; ++index) {
      audio_metrics_.record_dropped(false);
    }
    audio_metrics_.set_queue_state(0, datagram_ready_, datagram_max_payload_);
  }
  {
    std::lock_guard send_barrier(audio_send_mutex_);
  }

  bool drain_timed_out = false;
  std::size_t outstanding_sends = 0;
  {
    std::unique_lock lock(debug_mutex_);
    drain_timed_out = !debug_condition_.wait_for(
        lock, std::chrono::seconds(5),
        [this] { return outstanding_debug_sends_ == 0; });
    outstanding_sends = outstanding_debug_sends_;
  }

  std::string end_reason;
  if (reason == 1) {
    end_reason = drain_timed_out ? "duration_expired_send_state_timeout"
                                 : "duration_expired";
  } else if (reason == 2) {
    end_reason = drain_timed_out ? "connection_closed_send_state_timeout"
                                 : "connection_closed";
  } else {
    end_reason = "sender_stopped";
  }
  const auto trace = debug_trace_.Finish(end_reason);
  WriteDebugTrace(session_id, trace);

  std::ostringstream message;
  message << "debug_session_ended session_id=" << SessionHex(session_id)
          << " stream_id=" << stream_id << " reason=" << reason
          << " outstanding_send_states=" << outstanding_sends
          << " send_state_drain_timed_out=" << drain_timed_out;
  LogDiagnostic(message.str());

  DebugEndedHandler handler;
  {
    std::lock_guard lock(debug_mutex_);
    handler = debug_ended_handler_;
  }
  if (handler) handler(session_id, reason);
}

void SenderService::CompleteDebugSend(std::uint32_t stream_id) noexcept {
  std::lock_guard lock(debug_mutex_);
  if (!debug_trace_.IsActive() || stream_id != active_debug_stream_id_ ||
      outstanding_debug_sends_ == 0) {
    return;
  }
  --outstanding_debug_sends_;
  debug_condition_.notify_all();
}

void SenderService::WriteDebugTrace(
    std::span<const std::byte> session_id, std::string_view contents) {
  if (contents.empty()) return;
  const auto directory = debug_output_directory_ / SessionHex(session_id);
  const auto temporary = directory / "sender-trace.jsonl.tmp";
  const auto destination = directory / "sender-trace.jsonl";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) {
    LogDiagnostic("debug_session_trace_directory_failed");
    return;
  }
  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output.is_open()) {
      LogDiagnostic("debug_session_trace_open_failed");
      return;
    }
    output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    output.flush();
    if (!output) {
      LogDiagnostic("debug_session_trace_write_failed");
      return;
    }
  }
  std::filesystem::rename(temporary, destination, error);
  if (error) {
    LogDiagnostic("debug_session_trace_publish_failed");
    return;
  }
  LogDiagnostic("debug_session_trace_written path=" + destination.string());
}

void SenderService::LogAudioSummary() {
  {
    std::lock_guard lock(queue_mutex_);
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
  }
  const auto now = std::chrono::steady_clock::now();
  const auto elapsed_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          now - diagnostics_last_summary_);
  diagnostics_last_summary_ = now;
  const auto snapshot = audio_metrics_.exchange_interval();
  std::uint32_t reliable_generation = 0;
  {
    std::lock_guard lock(reliable_mutex_);
    reliable_generation = reliable_generation_;
  }
  std::ostringstream line;
  line << "quic_audio_summary interval_ms=" << elapsed_ms.count()
       << " audio_mode=" << (reliable_mode_.load() ? "reliable" : "datagram")
       << " audio_generation=" << reliable_generation
       << " capture_callbacks=" << snapshot.capture_callbacks
       << " capture_frames=" << snapshot.capture_frames
       << " normalized_frames=" << snapshot.normalized_frames
       << " packetized_packets=" << snapshot.packetized_packets
       << " queued_packets=" << snapshot.queued_packets
       << " sent_packets=" << snapshot.sent_packets
       << " dropped_packets=" << snapshot.dropped_packets
       << " send_failures=" << snapshot.send_failures
       << " capture_resets=" << snapshot.capture_resets
       << " queue_depth=" << snapshot.queue_depth
       << " queue_high_watermark=" << snapshot.queue_high_watermark
       << " stream_id=" << snapshot.stream_id
       << " last_sequence=" << snapshot.last_sequence
       << " datagram_ready=" << snapshot.datagram_ready
       << " max_datagram_payload=" << snapshot.datagram_max_payload
       << " capture_sample_rate=" << snapshot.capture_format.sample_rate_hz
       << " capture_channels=" << snapshot.capture_format.channels
       << " capture_format="
       << SampleFormatName(snapshot.capture_format.sample_format);
  const auto message = line.str();
  LogDiagnostic(message);
}

}  // namespace hearport::windows
