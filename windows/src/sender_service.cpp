#include "hearport/windows/sender_service.h"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <utility>

#include "hearport/wire/audio_datagram.h"
#include "hearport/wire/control_framing.h"

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
  audio_thread_ = std::thread([this] { AudioWorker(); });
  {
    std::lock_guard lock(diagnostics_mutex_);
    stop_diagnostics_ = false;
  }
  diagnostics_thread_ = std::thread([this] { DiagnosticsWorker(); });
  if (!capture_.Start(
          [this](std::span<const std::byte> bytes, const PcmFormat& format) {
            HandleCapturePacket(bytes, format);
          },
          [this] { HandleCaptureReset(); })) {
    Stop();
    return false;
  }
  started_ = true;
  return true;
}

void SenderService::Stop() {
  if (!started_ && !audio_thread_.joinable() && !diagnostics_thread_.joinable()) {
    return;
  }
  if (debug_trace_.IsActive()) EndDebugSession(2);
  capture_.Stop();
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
  if (!debug_session_id.empty() && debug_session_id.size() != 16) return false;
  if (!debug_session_id.empty() && !debug_duration().has_value()) return false;
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
  std::lock_guard capture_lock(capture_mutex_);
  std::lock_guard session_lock(session_mutex_);
  if (session_.AckWritten(stream_id) != AudioDisposition::accepted) {
    return false;
  }
  std::lock_guard debug_lock(debug_mutex_);
  if (pending_debug_session_) {
    if (!debug_trace_.Begin(pending_debug_session_id_, stream_id)) {
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
  return true;
}

void SenderService::ConfigureDebugDuration(
    std::optional<std::chrono::seconds> duration) {
  if (duration.has_value() &&
      (*duration < std::chrono::seconds(60) ||
       *duration > std::chrono::seconds(600))) {
    throw std::invalid_argument("debug duration must be from 60 to 600 seconds");
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

void SenderService::MarkDebugReportCommitted(
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
                                 std::int64_t captured_at_ns) {
  std::lock_guard lock(queue_mutex_);
  if (audio_queue_.size() >= kAudioQueueCapacity) {
    ++dropped_audio_packets_;
    audio_metrics_.record_dropped(false);
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
    return;
  }
  audio_queue_.push_back(
      QueuedAudioPacket{packet, captured_at_ns, MonotonicNanoseconds()});
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
      if (!datagram_ready_) {
        ++dropped_audio_packets_;
        audio_metrics_.record_dropped(false);
        continue;
      }
    }
    std::unique_lock send_lock(audio_send_mutex_);
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
    const auto encoded = wire::EncodeAudioDatagram(queued.packet);
    bool trace_this_packet = false;
    {
      std::lock_guard debug_lock(debug_mutex_);
      trace_this_packet =
          debug_trace_.IsActive() &&
          active_debug_stream_id_ == queued.packet.stream_id;
      if (trace_this_packet) ++outstanding_debug_sends_;
    }
    const auto send_at_ns = MonotonicNanoseconds();
    const bool sent = quic_->SendAudio(encoded);
    if (trace_this_packet) {
      debug_trace_.RecordPacket(queued.packet.sequence,
                                queued.captured_at_ns,
                                queued.queued_at_ns,
                                send_at_ns, sent);
      if (!sent) CompleteDebugSend(queued.packet.stream_id);
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
                                         const PcmFormat& format) {
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
  const auto samples = normalizer_->Convert(bytes);
  audio_metrics_.record_normalized_frames(samples.size() / 2);
  packetizer_.Push(samples, [this](const wire::AudioDatagram& packet) {
    audio_metrics_.record_packetized(packet.stream_id, packet.sequence);
    bool accepted = false;
    {
      std::lock_guard lock(session_mutex_);
      accepted = session_.AcceptAudio(packet) == AudioDisposition::accepted;
    }
    if (accepted) {
      EnqueueAudio(packet, MonotonicNanoseconds());
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
    debug_end_pending_ = false;
    debug_deadline_.reset();
    session_id = active_debug_session_id_;
    stream_id = active_debug_stream_id_;
  }

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
  std::ostringstream line;
  line << "quic_audio_summary interval_ms=" << elapsed_ms.count()
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
