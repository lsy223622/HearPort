#include "hearport/windows/sender_service.h"

#include <chrono>
#include <iostream>
#include <utility>

#include "hearport/wire/audio_datagram.h"
#include "hearport/wire/control_framing.h"

namespace hearport::windows {

namespace {

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

bool SenderService::BeginStream(std::uint32_t stream_id) {
  std::lock_guard capture_lock(capture_mutex_);
  std::lock_guard session_lock(session_mutex_);
  if (!session_.BeginStream(stream_id)) {
    return false;
  }
  packetizer_.Reset(stream_id);
  normalizer_.reset();
  normalizer_format_.reset();
  audio_metrics_.set_stream(stream_id);
  return true;
}

bool SenderService::MarkStartStreamAckWritten(std::uint32_t stream_id) {
  std::lock_guard lock(session_mutex_);
  return session_.AckWritten(stream_id) == AudioDisposition::accepted;
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

std::uint64_t SenderService::dropped_audio_packets() const noexcept {
  std::lock_guard lock(queue_mutex_);
  return dropped_audio_packets_;
}

void SenderService::EnqueueAudio(const wire::AudioDatagram& packet) {
  std::lock_guard lock(queue_mutex_);
  if (audio_queue_.size() >= kAudioQueueCapacity) {
    ++dropped_audio_packets_;
    audio_metrics_.record_dropped(false);
    audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                   datagram_max_payload_);
    return;
  }
  audio_queue_.push_back(packet);
  audio_metrics_.record_queued();
  audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                 datagram_max_payload_);
  queue_condition_.notify_one();
}

void SenderService::AudioWorker() {
  for (;;) {
    wire::AudioDatagram packet{};
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
      packet = audio_queue_.front();
      audio_queue_.pop_front();
      audio_metrics_.set_queue_state(audio_queue_.size(), datagram_ready_,
                                     datagram_max_payload_);
      if (!datagram_ready_) {
        ++dropped_audio_packets_;
        audio_metrics_.record_dropped(false);
        continue;
      }
    }
    const auto encoded = wire::EncodeAudioDatagram(packet);
    const bool sent = quic_->SendAudio(encoded);
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
      EnqueueAudio(packet);
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
    next_summary = now + std::chrono::seconds(1);
  }
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
  std::cerr << "quic_audio_summary interval_ms=" << elapsed_ms.count()
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
            << " capture_sample_rate="
            << snapshot.capture_format.sample_rate_hz
            << " capture_channels=" << snapshot.capture_format.channels
            << " capture_format="
            << SampleFormatName(snapshot.capture_format.sample_format) << "\n";
}

}  // namespace hearport::windows
