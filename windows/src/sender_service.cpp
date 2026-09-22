#include "hearport/windows/sender_service.h"

#include <algorithm>
#include <iostream>
#include <utility>

#include "hearport/wire/audio_datagram.h"
#include "hearport/wire/control_framing.h"

namespace hearport::windows {

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
  };
  callbacks.on_datagram_unavailable = [this] {
    std::lock_guard lock(queue_mutex_);
    datagram_ready_ = false;
  };
  callbacks.on_closed = [this] {
    {
      std::lock_guard lock(queue_mutex_);
      datagram_ready_ = false;
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
    audio_summary_started_ = std::chrono::steady_clock::now();
    audio_captured_window_ = 0;
    audio_sent_window_ = 0;
    audio_dropped_window_ = 0;
    audio_send_failures_window_ = 0;
  }
  control_decoder_.Reset();
  audio_thread_ = std::thread([this] { AudioWorker(); });
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
  if (!started_ && !audio_thread_.joinable()) {
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
  if (quic_) {
    quic_->Stop();
  }
  {
    std::lock_guard lock(queue_mutex_);
    audio_queue_.clear();
    capture_reset_pending_ = false;
    datagram_ready_ = false;
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
  ++audio_captured_window_;
  if (audio_queue_.size() >= kAudioQueueCapacity) {
    ++dropped_audio_packets_;
    ++audio_dropped_window_;
    LogAudioSummaryIfDueLocked();
    return;
  }
  audio_queue_.push_back(packet);
  queue_condition_.notify_one();
  LogAudioSummaryIfDueLocked();
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
      if (!datagram_ready_) {
        ++dropped_audio_packets_;
        ++audio_dropped_window_;
        LogAudioSummaryIfDueLocked();
        continue;
      }
    }
    const auto encoded = wire::EncodeAudioDatagram(packet);
    const bool sent = quic_->SendAudio(encoded);
    std::lock_guard lock(queue_mutex_);
    if (sent) {
      ++audio_sent_window_;
    } else {
      ++dropped_audio_packets_;
      ++audio_dropped_window_;
      ++audio_send_failures_window_;
    }
    LogAudioSummaryIfDueLocked();
  }
}

void SenderService::HandleCapturePacket(std::span<const std::byte> bytes,
                                         const PcmFormat& format) {
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
  packetizer_.Push(samples, [this](const wire::AudioDatagram& packet) {
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
  {
    std::lock_guard lock(capture_mutex_);
    normalizer_.reset();
    normalizer_format_.reset();
  }
  {
    std::lock_guard lock(queue_mutex_);
    audio_queue_.clear();
    capture_reset_pending_ = true;
  }
  queue_condition_.notify_one();
}

void SenderService::LogAudioSummaryIfDueLocked() {
  const auto now = std::chrono::steady_clock::now();
  const auto elapsed = now - audio_summary_started_;
  if (elapsed < std::chrono::seconds(1)) {
    return;
  }
  const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      elapsed);
  std::cerr << "quic_audio_summary interval_ms=" << elapsed_ms.count()
            << " captured_packets=" << audio_captured_window_
            << " sent_packets=" << audio_sent_window_
            << " dropped_packets=" << audio_dropped_window_
            << " send_failures=" << audio_send_failures_window_
            << " queue_depth=" << audio_queue_.size()
            << " datagram_ready=" << datagram_ready_ << "\n";
  audio_summary_started_ = now;
  audio_captured_window_ = 0;
  audio_sent_window_ = 0;
  audio_dropped_window_ = 0;
  audio_send_failures_window_ = 0;
}

}  // namespace hearport::windows
