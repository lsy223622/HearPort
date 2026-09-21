#include "hearport/windows/sender_service.h"

#include <algorithm>
#include <utility>

#include "hearport/wire/audio_datagram.h"

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
    if (control_handler_) {
      control_handler_(bytes);
    }
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
    std::lock_guard lock(queue_mutex_);
    datagram_ready_ = false;
  };

  if (!quic_->Start(options_, std::move(callbacks))) {
    return false;
  }

  {
    std::lock_guard lock(queue_mutex_);
    stop_worker_ = false;
  }
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
    datagram_ready_ = false;
  }
  normalizer_.reset();
  normalizer_format_.reset();
  started_ = false;
}

bool SenderService::MarkAuthenticated() { return session_.MarkAuthenticated(); }

bool SenderService::BeginStream(std::uint32_t stream_id) {
  if (!session_.BeginStream(stream_id)) {
    return false;
  }
  packetizer_.Reset(stream_id);
  normalizer_.reset();
  normalizer_format_.reset();
  return true;
}

bool SenderService::MarkStartStreamAckWritten(std::uint32_t stream_id) {
  return session_.AckWritten(stream_id) == AudioDisposition::accepted;
}

void SenderService::SetControlHandler(ControlHandler handler) {
  control_handler_ = std::move(handler);
}

void SenderService::SetResetHandler(ResetHandler handler) {
  reset_handler_ = std::move(handler);
}

std::uint64_t SenderService::dropped_audio_packets() const noexcept {
  std::lock_guard lock(queue_mutex_);
  return dropped_audio_packets_;
}

void SenderService::EnqueueAudio(const wire::AudioDatagram& packet) {
  std::lock_guard lock(queue_mutex_);
  if (audio_queue_.size() >= kAudioQueueCapacity) {
    ++dropped_audio_packets_;
    return;
  }
  audio_queue_.push_back(packet);
  queue_condition_.notify_one();
}

void SenderService::AudioWorker() {
  for (;;) {
    wire::AudioDatagram packet{};
    {
      std::unique_lock lock(queue_mutex_);
      queue_condition_.wait(lock, [this] {
        return stop_worker_ || !audio_queue_.empty();
      });
      if (stop_worker_ && audio_queue_.empty()) {
        return;
      }
      packet = audio_queue_.front();
      audio_queue_.pop_front();
      if (!datagram_ready_) {
        continue;
      }
    }
    const auto encoded = wire::EncodeAudioDatagram(packet);
    if (!quic_->SendAudio(encoded)) {
      std::lock_guard lock(queue_mutex_);
      ++dropped_audio_packets_;
    }
  }
}

void SenderService::HandleCapturePacket(std::span<const std::byte> bytes,
                                         const PcmFormat& format) {
  if (session_.phase() != SessionPhase::active) {
    return;
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
    if (session_.AcceptAudio(packet) == AudioDisposition::accepted) {
      EnqueueAudio(packet);
    }
  });
}

void SenderService::HandleCaptureReset() {
  normalizer_.reset();
  normalizer_format_.reset();
  if (reset_handler_) {
    reset_handler_();
  }
}

}  // namespace hearport::windows
