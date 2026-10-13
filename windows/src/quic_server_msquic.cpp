#include "hearport/windows/quic_server.h"

#if defined(HEARPORT_HAS_MSQUIC) && HEARPORT_HAS_MSQUIC

#include <msquic.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace hearport::windows {
namespace {

constexpr char kAlpnText[] = "hearport/1";
constexpr std::size_t kAudioDatagramBytes = 968;
constexpr std::size_t kMaxReliablePendingSends = 128;

struct SendBufferContext {
  std::vector<std::uint8_t> storage;
  QUIC_BUFFER buffer{};
  std::function<void(std::uint32_t, std::uint32_t, DebugSendState)>
      on_send_state;
  std::function<void(std::uint32_t, std::uint32_t, bool)> on_probe_send_complete;
  std::uint32_t stream_id = 0;
  std::uint32_t sequence = 0;
  std::uint64_t audio_epoch = 0;
  bool pending_datagram = false;
  bool auxiliary = false;
  std::uint64_t source_frames = 0;

  explicit SendBufferContext(std::span<const std::byte> bytes)
      : storage(bytes.size()) {
    std::memcpy(storage.data(), bytes.data(), bytes.size());
    buffer.Length = static_cast<std::uint32_t>(storage.size());
    buffer.Buffer = storage.data();
  }

  SendBufferContext(const wire::EncodedAudioDatagram& datagram,
                    std::uint32_t audio_stream_id,
                    std::uint32_t audio_sequence)
      : storage(datagram.size()) {
    stream_id = audio_stream_id;
    sequence = audio_sequence;
    std::memcpy(storage.data(), datagram.data(), datagram.size());
    buffer.Length = static_cast<std::uint32_t>(storage.size());
    buffer.Buffer = storage.data();
  }
};

DebugSendState ConvertSendState(QUIC_DATAGRAM_SEND_STATE state) {
  switch (state) {
    case QUIC_DATAGRAM_SEND_SENT: return DebugSendState::sent;
    case QUIC_DATAGRAM_SEND_LOST_SUSPECT: return DebugSendState::lost_suspect;
    case QUIC_DATAGRAM_SEND_LOST_DISCARDED: return DebugSendState::lost_discarded;
    case QUIC_DATAGRAM_SEND_ACKNOWLEDGED: return DebugSendState::acknowledged;
    case QUIC_DATAGRAM_SEND_ACKNOWLEDGED_SPURIOUS:
      return DebugSendState::acknowledged_spurious;
    case QUIC_DATAGRAM_SEND_CANCELED: return DebugSendState::canceled;
    default: return DebugSendState::unknown;
  }
}

class MsQuicServer final : public QuicServer {
 public:
  ~MsQuicServer() override { Stop(); }

  bool Start(const QuicServerOptions& options,
             QuicServerCallbacks callbacks) override {
    std::unique_lock lock(mutex_);
    if (started_ || !options.has_certificate_sha1) {
      return false;
    }
    options_ = options;
    callbacks_ = std::move(callbacks);
    Log("quic_start port=" + std::to_string(options_.port));

    const auto open_status = MsQuicOpen2(&api_);
    if (QUIC_FAILED(open_status)) {
      Log("quic_open_failed status=" +
          std::to_string(static_cast<unsigned long>(open_status)));
      api_ = nullptr;
      return false;
    }

    const QUIC_REGISTRATION_CONFIG registration_config{
        "HearPort", QUIC_EXECUTION_PROFILE_LOW_LATENCY};
    const auto registration_status =
        api_->RegistrationOpen(&registration_config, &registration_);
    if (QUIC_FAILED(registration_status)) {
      Log("quic_registration_failed status=" +
          std::to_string(static_cast<unsigned long>(registration_status)));
      StopLocked(lock);
      return false;
    }

    QUIC_SETTINGS settings{};
    settings.DatagramReceiveEnabled = TRUE;
    settings.IsSet.DatagramReceiveEnabled = TRUE;
    settings.ServerResumptionLevel = QUIC_SERVER_NO_RESUME;
    settings.IsSet.ServerResumptionLevel = TRUE;
    settings.PeerBidiStreamCount = 1;
    settings.IsSet.PeerBidiStreamCount = TRUE;
    // Keep unacknowledged stream bytes in bounded application-owned buffers.
    settings.SendBufferingEnabled = FALSE;
    settings.IsSet.SendBufferingEnabled = TRUE;

    const QUIC_BUFFER alpn{sizeof(kAlpnText) - 1,
                            reinterpret_cast<uint8_t*>(
                                const_cast<char*>(kAlpnText))};
    const auto configuration_status = api_->ConfigurationOpen(
        registration_, &alpn, 1, &settings, sizeof(settings), nullptr,
        &configuration_);
    if (QUIC_FAILED(configuration_status)) {
      Log("quic_configuration_failed status=" +
          std::to_string(static_cast<unsigned long>(configuration_status)));
      StopLocked(lock);
      return false;
    }

    QUIC_CERTIFICATE_HASH certificate_hash{};
    std::copy(options_.certificate_sha1.begin(), options_.certificate_sha1.end(),
              certificate_hash.ShaHash);
    QUIC_CREDENTIAL_CONFIG credential{};
    credential.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_HASH;
    credential.CertificateHash = &certificate_hash;
    const auto credential_status =
        api_->ConfigurationLoadCredential(configuration_, &credential);
    if (QUIC_FAILED(credential_status)) {
      Log("quic_credential_failed status=" +
          std::to_string(static_cast<unsigned long>(credential_status)));
      StopLocked(lock);
      return false;
    }

    const auto listener_open_status =
        api_->ListenerOpen(registration_, ListenerCallback, this, &listener_);
    if (QUIC_FAILED(listener_open_status)) {
      Log("quic_listener_open_failed status=" +
          std::to_string(static_cast<unsigned long>(listener_open_status)));
      StopLocked(lock);
      return false;
    }

    QUIC_ADDR address{};
    QuicAddrSetFamily(&address, QUIC_ADDRESS_FAMILY_UNSPEC);
    QuicAddrSetPort(&address, options_.port);
    const auto listener_start_status =
        api_->ListenerStart(listener_, &alpn, 1, &address);
    if (QUIC_FAILED(listener_start_status)) {
      Log("quic_listener_start_failed status=" +
          std::to_string(static_cast<unsigned long>(listener_start_status)));
      StopLocked(lock);
      return false;
    }
    started_ = true;
    return true;
  }

  bool SendControl(std::span<const std::byte> framed_bytes) override {
    std::lock_guard lock(mutex_);
    if (!started_ || control_stream_ == nullptr || api_ == nullptr ||
        framed_bytes.empty()) {
      std::ostringstream line;
      line << "quic_control_send_skipped started=" << started_
           << " has_control_stream=" << (control_stream_ != nullptr)
           << " has_api=" << (api_ != nullptr)
           << " bytes=" << framed_bytes.size();
      Log(line.str());
      return false;
    }
    auto* context = new SendBufferContext(framed_bytes);
    const auto status = api_->StreamSend(
        control_stream_, &context->buffer, 1, QUIC_SEND_FLAG_NONE, context);
    if (QUIC_FAILED(status)) {
      std::ostringstream line;
      line << "quic_control_send_failed status="
           << static_cast<unsigned long>(status)
           << " bytes=" << framed_bytes.size();
      Log(line.str());
      delete context;
      return false;
    }
    Log("quic_control_send_queued bytes=" +
        std::to_string(framed_bytes.size()));
    return true;
  }

  bool SendAudio(std::span<const std::byte> datagram) override {
    std::lock_guard lock(mutex_);
    if (!started_ || connection_ == nullptr || api_ == nullptr) {
      return false;
    }
    const auto timed = wire::DecodeTimedAudioRecord(datagram);
    const auto frames = timed ? timed->frame_count : 0;
    if (reliable_mode_) {
      if ((reliable_window_frames_ != 0 && reliable_pending_frames_ + frames > reliable_window_frames_) || audio_stream_ == nullptr ||
          pending_reliable_sends_.load() >= kMaxReliablePendingSends) return false;
      auto* context = new SendBufferContext(
          std::span<const std::byte>(datagram.data(), datagram.size()));
      context->audio_epoch = audio_epoch_.load();
      if (timed) { context->stream_id = timed->stream_id; context->sequence = timed->sequence; }
      context->source_frames = frames;
      reliable_pending_frames_ += frames;
      if (timed) reliable_pending_buffers_.insert(context);
      pending_reliable_sends_.fetch_add(1);
      const auto status = api_->StreamSend(audio_stream_, &context->buffer, 1,
                                           QUIC_SEND_FLAG_NONE, context);
      if (QUIC_FAILED(status)) {
        pending_reliable_sends_.fetch_sub(1);
        reliable_pending_frames_ -= context->source_frames;
        reliable_pending_buffers_.erase(context);
        delete context;
        return false;
      }
      return true;
    }
    if (!datagram_ready_ || datagram.size() > datagram_max_payload_ || (datagram_window_frames_ == 0 ? pending_datagrams_.load() >= 16 :
        pending_original_frames_.load() + frames > datagram_window_frames_)) return false;
    const auto packet = wire::DecodeAudioDatagram(datagram);
    if (!packet && !timed) return false;
    auto* context = new SendBufferContext(datagram);
    context->stream_id = packet ? packet->stream_id : timed->stream_id;
    context->sequence = packet ? packet->sequence : timed->sequence;
    context->on_send_state = callbacks_.on_datagram_send_state;
    context->pending_datagram = true;
    context->source_frames = frames;
    pending_original_frames_.fetch_add(frames);
    pending_datagrams_.fetch_add(1);
    const auto status = api_->DatagramSend(
        connection_, &context->buffer, 1, QUIC_SEND_FLAG_DGRAM_PRIORITY, context);
    if (QUIC_FAILED(status)) {
      if (context->pending_datagram) {
        pending_datagrams_.fetch_sub(1);
        pending_original_frames_.fetch_sub(context->source_frames);
      }
      delete context;
      return false;
    }
    return true;
  }

  ProbeSendOutcome SendProbe(std::span<const std::byte> datagram,
                             std::uint32_t stream_id,
                             std::uint32_t sequence, bool reliable, bool auxiliary) override {
    std::lock_guard lock(mutex_);
    if (!started_ || connection_ == nullptr || api_ == nullptr ||
        datagram.empty()) return {ProbeSendStatus::disconnected};
    const auto timed = wire::DecodeTimedAudioRecord(datagram);
    if (timed && !auxiliary) last_original_frames_ = timed->frame_count;
    const auto frames = timed ? (auxiliary && timed->kind == wire::AudioRecordKind::fec ?
        last_original_frames_ : timed->frame_count) : 0u;
    if (reliable) {
      const auto pending = pending_reliable_sends_.load();
      if (audio_stream_ == nullptr) {
        return {ProbeSendStatus::stream_unavailable, pending};
      }
      if (datagram.size() > 1024) {
        return {ProbeSendStatus::invalid_size, pending};
      }
      if (pending >= kMaxReliablePendingSends || (reliable_window_frames_ != 0 &&
          reliable_pending_frames_ + frames > reliable_window_frames_)) {
        return {ProbeSendStatus::pending_limit, pending};
      }
      std::vector<std::byte> framed(datagram.size() + 2);
      framed[0] = std::byte{static_cast<std::uint8_t>(datagram.size() >> 8)};
      framed[1] = std::byte{static_cast<std::uint8_t>(datagram.size())};
      std::copy(datagram.begin(), datagram.end(), framed.begin() + 2);
      auto* context = new SendBufferContext(framed);
      context->audio_epoch = audio_epoch_.load();
      context->stream_id = stream_id;
      context->sequence = sequence;
      context->auxiliary = auxiliary;
      if (!auxiliary) context->on_probe_send_complete = callbacks_.on_probe_send_complete;
      context->source_frames = frames;
      reliable_pending_frames_ += frames;
      if (timed) reliable_pending_buffers_.insert(context);
      pending_reliable_sends_.fetch_add(1);
      const auto status = api_->StreamSend(audio_stream_, &context->buffer, 1,
                                           QUIC_SEND_FLAG_NONE, context);
      if (QUIC_FAILED(status)) {
        pending_reliable_sends_.fetch_sub(1);
        reliable_pending_frames_ -= context->source_frames;
        reliable_pending_buffers_.erase(context);
        delete context;
        return {ProbeSendStatus::transport_rejected, pending,
                static_cast<std::uint32_t>(status)};
      }
      return {ProbeSendStatus::accepted, pending + 1};
    }
    if (!datagram_ready_) return {ProbeSendStatus::datagram_unavailable};
    if (datagram.size() > datagram_max_payload_) return {ProbeSendStatus::invalid_size};
    if (datagram_window_frames_ == 0 ? pending_datagrams_.load() >= 16 :
        (auxiliary ? (pending_original_frames_.load() > datagram_window_frames_ / 2 ||
                      pending_auxiliary_frames_.load() + frames > datagram_window_frames_ * 3 / 10) :
                     pending_original_frames_.load() + frames > datagram_window_frames_))
      return {ProbeSendStatus::pending_limit};
    auto* context = new SendBufferContext(datagram);
    context->stream_id = stream_id;
    context->sequence = sequence;
    context->auxiliary = auxiliary;
    if (!auxiliary) context->on_send_state = callbacks_.on_datagram_send_state;
    context->pending_datagram = true;
    context->source_frames = frames;
    (auxiliary ? pending_auxiliary_frames_ : pending_original_frames_).fetch_add(frames);
    pending_datagrams_.fetch_add(1);
    const auto status = api_->DatagramSend(
        connection_, &context->buffer, 1, auxiliary ? QUIC_SEND_FLAG_NONE : QUIC_SEND_FLAG_DGRAM_PRIORITY, context);
    if (QUIC_FAILED(status)) {
      if (context->pending_datagram) {
        pending_datagrams_.fetch_sub(1);
        (auxiliary ? pending_auxiliary_frames_ : pending_original_frames_).fetch_sub(frames);
      }
      delete context;
      return {ProbeSendStatus::transport_rejected, 0,
              static_cast<std::uint32_t>(status)};
    }
    return {ProbeSendStatus::accepted};
  }

  void ConfigureAudioWindow(std::uint32_t target_ms, std::uint32_t maximum_ms,
                            std::uint32_t output_reserve_ms) override {
    std::lock_guard lock(mutex_);
    datagram_window_frames_ = std::uint64_t(target_ms - output_reserve_ms) * 48;
    reliable_window_frames_ = std::uint64_t(maximum_ms - output_reserve_ms) * 48;
    last_probe_statistics_ns_.store(0);
  }

  void ConfirmReliableReceived(std::uint32_t stream_id, std::uint32_t generation,
                               std::uint32_t sequence) override {
    std::lock_guard lock(mutex_);
    if (stream_id != audio_stream_id_ || generation != audio_generation_) return;
    for (auto* context : reliable_pending_buffers_) {
      if ((sequence - context->sequence) < 0x80000000u) {
        reliable_pending_frames_ -= context->source_frames;
        context->source_frames = 0;
      }
    }
  }

  void StopReliableAudio() override {
    std::lock_guard lock(mutex_);
    reliable_mode_ = false;
    audio_epoch_.fetch_add(1);
    pending_reliable_sends_.store(0);
    reliable_pending_frames_ = 0;
    reliable_pending_buffers_.clear();
    if (audio_stream_ != nullptr && api_ != nullptr) {
      api_->StreamShutdown(audio_stream_, QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND, 0);
      audio_stream_ = nullptr;
    }
  }

  bool StartReliableAudio(std::uint32_t stream_id,
                          std::uint32_t generation) override {
    std::lock_guard lock(mutex_);
    if (!started_ || api_ == nullptr || connection_ == nullptr ||
        stream_id == 0 || generation == 0) return false;
    reliable_mode_ = true;
    audio_stream_id_ = stream_id;
    audio_generation_ = generation;
    audio_epoch_.fetch_add(1);
    pending_reliable_sends_.store(0);
    reliable_pending_frames_ = 0;
    reliable_pending_buffers_.clear();
    if (audio_stream_ != nullptr) {
      api_->StreamShutdown(audio_stream_,
                           QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND, 0);
      audio_stream_ = nullptr;
    }
    HQUIC stream = nullptr;
    if (QUIC_FAILED(api_->StreamOpen(connection_,
                                    QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL,
                                    AudioStreamCallback, this, &stream))) {
      return false;
    }
    audio_stream_ = stream;
    if (QUIC_FAILED(api_->StreamStart(stream,
                                     QUIC_STREAM_START_FLAG_IMMEDIATE))) {
      audio_stream_ = nullptr;
      api_->StreamClose(stream);
      return false;
    }
    std::array<std::byte, 8> preface{};
    for (int index = 0; index < 4; ++index) {
      preface[index] = std::byte(stream_id >> (24 - index * 8));
      preface[index + 4] = std::byte(generation >> (24 - index * 8));
    }
    auto* context = new SendBufferContext(preface);
    context->audio_epoch = audio_epoch_.load();
    pending_reliable_sends_.fetch_add(1);
    const auto status = api_->StreamSend(stream, &context->buffer, 1,
                                         QUIC_SEND_FLAG_NONE, context);
    if (QUIC_FAILED(status)) {
      pending_reliable_sends_.fetch_sub(1);
      delete context;
      audio_stream_ = nullptr;
      api_->StreamShutdown(stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND, 0);
      return false;
    }
    Log("quic_reliable_audio_started stream_id=" + std::to_string(stream_id) +
        " generation=" + std::to_string(generation));
    return true;
  }

  void CloseConnection() override {
    std::lock_guard lock(mutex_);
    if (connection_ != nullptr && api_ != nullptr) {
      api_->ConnectionShutdown(connection_, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
                               0);
    }
  }

  void Stop() override {
    std::unique_lock lock(mutex_);
    StopLocked(lock);
  }

 private:
  void Log(const std::string& line) const {
    if (options_.diagnostic_log) {
      options_.diagnostic_log(line);
    } else {
      std::cerr << line << '\n';
    }
  }

  static QUIC_STATUS QUIC_API ListenerCallback(
      HQUIC, void* context, QUIC_LISTENER_EVENT* event) {
    auto* server = static_cast<MsQuicServer*>(context);
    if (event->Type != QUIC_LISTENER_EVENT_NEW_CONNECTION) {
      return QUIC_STATUS_SUCCESS;
    }
    server->Log("quic_listener_new_connection");
    server->api_->SetCallbackHandler(
        event->NEW_CONNECTION.Connection,
        reinterpret_cast<void*>(ConnectionCallback), server);
    return server->api_->ConnectionSetConfiguration(
        event->NEW_CONNECTION.Connection, server->configuration_);
  }

  static QUIC_STATUS QUIC_API ConnectionCallback(
      HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event) {
    auto* server = static_cast<MsQuicServer*>(context);
    server->LogProbeStatistics(connection);
    switch (event->Type) {
      case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
        server->Log("quic_shutdown_transport status=" +
            std::to_string(static_cast<std::uint32_t>(event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status)) +
            " error_code=" + std::to_string(event->SHUTDOWN_INITIATED_BY_TRANSPORT.ErrorCode));
        break;
      case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
        server->Log("quic_shutdown_peer error_code=" +
            std::to_string(event->SHUTDOWN_INITIATED_BY_PEER.ErrorCode));
        break;
      case QUIC_CONNECTION_EVENT_CONNECTED: {
        std::function<void()> on_connected;
        const QUIC_API_TABLE* api = nullptr;
        bool accepted = false;
        {
          std::lock_guard lock(server->mutex_);
          api = server->api_;
          if (server->started_ && server->connection_ == nullptr) {
            server->connection_ = connection;
            on_connected = server->callbacks_.on_connected;
            accepted = true;
          }
        }
        server->Log(std::string("quic_connection_connected accepted=") +
                    (accepted ? "1" : "0"));
        if (!accepted) {
          if (api != nullptr) {
            api->ConnectionShutdown(connection,
                                    QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
          }
        } else if (on_connected) {
          on_connected();
        }
        break;
      }
      case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: {
        const auto stream = event->PEER_STREAM_STARTED.Stream;
        const auto flags = event->PEER_STREAM_STARTED.Flags;
        const bool unidirectional =
            (static_cast<std::uint32_t>(flags) &
             static_cast<std::uint32_t>(QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL)) !=
            0;
        const QUIC_API_TABLE* api = nullptr;
        bool accepted = false;
        {
          std::lock_guard lock(server->mutex_);
          api = server->api_;
          if (server->connection_ == connection &&
              server->control_stream_ == nullptr && !unidirectional) {
            server->control_stream_ = stream;
            accepted = true;
          }
        }
        std::ostringstream line;
        line << "quic_peer_stream_started flags="
             << static_cast<unsigned long>(flags)
             << " unidirectional=" << unidirectional
             << " accepted=" << accepted;
        server->Log(line.str());
        if (api != nullptr) {
          if (accepted) {
            api->SetCallbackHandler(stream,
                                    reinterpret_cast<void*>(StreamCallback),
                                    server);
          } else {
            api->StreamShutdown(stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT, 0);
          }
        }
        break;
      }
      case QUIC_CONNECTION_EVENT_STREAMS_AVAILABLE:
        server->Log("quic_streams_available unidirectional=" +
                    std::to_string(event->STREAMS_AVAILABLE.UnidirectionalCount));
        break;
      case QUIC_CONNECTION_EVENT_DATAGRAM_STATE_CHANGED: {
        std::function<void(std::size_t)> on_ready;
        std::function<void()> on_unavailable;
        const auto max_send_length =
            event->DATAGRAM_STATE_CHANGED.MaxSendLength;
        const auto send_enabled = event->DATAGRAM_STATE_CHANGED.SendEnabled;
        bool ready = false;
        {
          std::lock_guard lock(server->mutex_);
          if (server->connection_ == connection) {
            ready = send_enabled &&
                    max_send_length >= kAudioDatagramBytes;
          server->datagram_ready_ = ready;
          server->datagram_max_payload_ = max_send_length;
            on_ready = server->callbacks_.on_datagram_ready;
            on_unavailable = server->callbacks_.on_datagram_unavailable;
          }
        }
        std::ostringstream line;
        line << "quic_datagram_state send_enabled=" << send_enabled
             << " max_send_length=" << max_send_length
             << " ready=" << ready;
        server->Log(line.str());
        if (ready) {
          if (on_ready) {
            on_ready(max_send_length);
          }
        } else if (on_unavailable) {
          on_unavailable();
        }
        break;
      }
      case QUIC_CONNECTION_EVENT_DATAGRAM_SEND_STATE_CHANGED:
        if (event->DATAGRAM_SEND_STATE_CHANGED.ClientContext != nullptr) {
          auto* send_context = static_cast<SendBufferContext*>(
              event->DATAGRAM_SEND_STATE_CHANGED.ClientContext);
          const auto state = event->DATAGRAM_SEND_STATE_CHANGED.State;
          if (send_context->pending_datagram &&
              (state == QUIC_DATAGRAM_SEND_SENT || QUIC_DATAGRAM_SEND_STATE_IS_FINAL(state))) {
            send_context->pending_datagram = false;
            server->pending_datagrams_.fetch_sub(1);
            (send_context->auxiliary ? server->pending_auxiliary_frames_ :
                server->pending_original_frames_).fetch_sub(send_context->source_frames);
          }
          if (send_context->auxiliary && QUIC_DATAGRAM_SEND_STATE_IS_FINAL(state)) {
            server->Log("network_probe_repair_final sequence=" + std::to_string(send_context->sequence) +
                        " state=" + std::string(DebugSendStateName(ConvertSendState(state))));
          }
          if (send_context->stream_id != 0 && send_context->on_send_state) {
            send_context->on_send_state(
                send_context->stream_id, send_context->sequence,
                ConvertSendState(state));
          }
          if (QUIC_DATAGRAM_SEND_STATE_IS_FINAL(state)) {
            delete send_context;
            event->DATAGRAM_SEND_STATE_CHANGED.ClientContext = nullptr;
          }
        }
        break;
      case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        {
          std::function<void()> on_closed;
          const QUIC_API_TABLE* api = nullptr;
          bool tracked = false;
          {
            std::lock_guard lock(server->mutex_);
            api = server->api_;
            if (server->connection_ == connection) {
              tracked = true;
              server->connection_ = nullptr;
              server->control_stream_ = nullptr;
              server->audio_stream_ = nullptr;
              server->reliable_mode_ = false;
              server->audio_epoch_.fetch_add(1);
              server->pending_reliable_sends_.store(0);
              server->reliable_pending_frames_ = 0;
              server->reliable_pending_buffers_.clear();
              server->datagram_ready_ = false;
              on_closed = server->callbacks_.on_closed;
            }
          }
          server->Log(std::string("quic_connection_shutdown tracked=") +
                      (tracked ? "1" : "0"));
          if (api != nullptr) {
            api->ConnectionClose(connection);
          }
          if (tracked && on_closed) {
            on_closed();
          }
          if (tracked) {
            server->shutdown_condition_.notify_all();
          }
        }
        break;
      default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
  }

  static QUIC_STATUS QUIC_API StreamCallback(
      HQUIC stream, void* context, QUIC_STREAM_EVENT* event) {
    auto* server = static_cast<MsQuicServer*>(context);
    switch (event->Type) {
      case QUIC_STREAM_EVENT_RECEIVE:
        {
          std::function<bool(std::span<const std::byte>)> on_control_bytes;
          {
            std::lock_guard lock(server->mutex_);
            on_control_bytes = server->callbacks_.on_control_bytes;
          }
          std::ostringstream line;
          line << "quic_control_receive buffers="
               << event->RECEIVE.BufferCount
               << " bytes=" << event->RECEIVE.TotalBufferLength
               << " handler=" << static_cast<bool>(on_control_bytes);
          server->Log(line.str());
          if (!on_control_bytes) {
            break;
          }
          bool keep_connection = true;
          for (std::uint32_t index = 0;
               index < event->RECEIVE.BufferCount; ++index) {
            const auto& buffer = event->RECEIVE.Buffers[index];
            if (buffer.Length != 0) {
              keep_connection = on_control_bytes(std::span<const std::byte>(
                  reinterpret_cast<const std::byte*>(buffer.Buffer),
                  buffer.Length));
              std::ostringstream line;
              line << "quic_control_receive_handled bytes=" << buffer.Length
                   << " keep_connection=" << keep_connection;
              server->Log(line.str());
              if (!keep_connection) break;
            }
          }
        }
        break;
      case QUIC_STREAM_EVENT_SEND_COMPLETE:
        server->Log("quic_control_send_complete");
        delete static_cast<SendBufferContext*>(
            event->SEND_COMPLETE.ClientContext);
        break;
      case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE: {
        const QUIC_API_TABLE* api = nullptr;
        {
          std::lock_guard lock(server->mutex_);
          api = server->api_;
          if (server->control_stream_ == stream) {
            server->control_stream_ = nullptr;
          }
        }
        if (api != nullptr) {
          api->StreamClose(stream);
        }
        break;
      }
      default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
  }

  static QUIC_STATUS QUIC_API AudioStreamCallback(
      HQUIC stream, void* context, QUIC_STREAM_EVENT* event) {
    auto* server = static_cast<MsQuicServer*>(context);
    HQUIC connection = nullptr;
    if (server->options_.network_probe) {
      std::lock_guard lock(server->mutex_);
      connection = server->connection_;
    }
    if (connection) server->LogProbeStatistics(connection, stream);
    switch (event->Type) {
      case QUIC_STREAM_EVENT_START_COMPLETE: {
        std::ostringstream line;
        line << "quic_audio_stream_start_complete status="
             << static_cast<unsigned long>(event->START_COMPLETE.Status)
             << " id=" << event->START_COMPLETE.ID
             << " peer_accepted=" << event->START_COMPLETE.PeerAccepted;
        server->Log(line.str());
        break;
      }
      case QUIC_STREAM_EVENT_SEND_COMPLETE:
        if (auto* send_context = static_cast<SendBufferContext*>(
                event->SEND_COMPLETE.ClientContext)) {
          {
            std::lock_guard lock(server->mutex_);
            if (send_context->audio_epoch == server->audio_epoch_.load()) {
              server->pending_reliable_sends_.fetch_sub(1);
              server->reliable_pending_frames_ -= send_context->source_frames;
              server->reliable_pending_buffers_.erase(send_context);
            }
          }
          if (send_context->auxiliary) {
            server->Log("network_probe_reliable_replay_complete sequence=" + std::to_string(send_context->sequence) +
                        " canceled=" + std::to_string(event->SEND_COMPLETE.Canceled != FALSE));
          }
          if (send_context->on_probe_send_complete) {
            send_context->on_probe_send_complete(send_context->stream_id,
                                                 send_context->sequence,
                                                 event->SEND_COMPLETE.Canceled != FALSE);
          }
          delete send_context;
        }
        break;
      case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE: {
        const QUIC_API_TABLE* api = nullptr;
        {
          std::lock_guard lock(server->mutex_);
          api = server->api_;
          if (server->audio_stream_ == stream) server->audio_stream_ = nullptr;
        }
        if (api != nullptr) api->StreamClose(stream);
        break;
      }
      default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
  }

  void LogProbeStatistics(HQUIC connection, HQUIC stream = nullptr) {
    if (!options_.network_probe) return;
    const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    auto previous = last_probe_statistics_ns_.load();
    if (now - previous < 100'000'000 ||
        !last_probe_statistics_ns_.compare_exchange_strong(previous, now)) return;
    QUIC_STATISTICS_V2 statistics{};
    std::uint32_t size = sizeof(statistics);
    const auto status = api_->GetParam(connection, QUIC_PARAM_CONN_STATISTICS_V2,
                                       &size, &statistics);
    std::ostringstream line;
    line << "network_probe_transport at_ns=" << now
         << " query_status=" << static_cast<std::uint32_t>(status)
         << " pending_reliable_sends=" << pending_reliable_sends_.load()
         << " pending_reliable_delivery_ms=" << reliable_pending_frames_.load() / 48
         << " pending_original_ms=" << pending_original_frames_.load() / 48
         << " pending_auxiliary_ms=" << pending_auxiliary_frames_.load() / 48;
    if (QUIC_SUCCEEDED(status)) {
      line << " rtt_us=" << statistics.Rtt
           << " min_rtt_us=" << statistics.MinRtt
           << " max_rtt_us=" << statistics.MaxRtt
           << " sent_packets=" << statistics.SendTotalPackets
           << " suspected_lost_packets=" << statistics.SendSuspectedLostPackets
           << " spurious_lost_packets=" << statistics.SendSpuriousLostPackets
           << " congestion_events=" << statistics.SendCongestionCount
           << " persistent_congestion_events=" << statistics.SendPersistentCongestionCount
           << " congestion_window_bytes=" << statistics.SendCongestionWindow
           << " ack_frames=" << statistics.RecvValidAckFrames
           << " path_mtu=" << statistics.SendPathMtu;
    }
    if (stream) {
      QUIC_STREAM_STATISTICS blocked{};
      size = sizeof(blocked);
      const auto stream_status = api_->GetParam(stream, QUIC_PARAM_STREAM_STATISTICS,
                                               &size, &blocked);
      line << " stream_query_status=" << static_cast<std::uint32_t>(stream_status);
      if (QUIC_SUCCEEDED(stream_status)) {
        line << " blocked_scheduling_us=" << blocked.ConnBlockedBySchedulingUs
             << " blocked_pacing_us=" << blocked.ConnBlockedByPacingUs
             << " blocked_congestion_us=" << blocked.ConnBlockedByCongestionControlUs
             << " blocked_connection_flow_us=" << blocked.ConnBlockedByFlowControlUs
             << " blocked_stream_flow_us=" << blocked.StreamBlockedByFlowControlUs;
      }
    }
    Log(line.str());
  }

  void StopLocked(std::unique_lock<std::mutex>& lock) {
    started_ = false;
    if (listener_ != nullptr && api_ != nullptr) {
      api_->ListenerClose(listener_);
      listener_ = nullptr;
    }
    if (connection_ != nullptr && api_ != nullptr) {
      const auto connection = connection_;
      api_->ConnectionShutdown(connection, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
                               0);
      shutdown_condition_.wait(lock, [this, connection] {
        return connection_ != connection;
      });
      control_stream_ = nullptr;
      audio_stream_ = nullptr;
    }
    if (configuration_ != nullptr && api_ != nullptr) {
      api_->ConfigurationClose(configuration_);
      configuration_ = nullptr;
    }
    if (registration_ != nullptr && api_ != nullptr) {
      api_->RegistrationClose(registration_);
      registration_ = nullptr;
    }
    if (api_ != nullptr) {
      MsQuicClose(api_);
      api_ = nullptr;
    }
    datagram_ready_ = false;
    reliable_mode_ = false;
    audio_epoch_.fetch_add(1);
    pending_reliable_sends_.store(0);
    reliable_pending_frames_ = 0;
    reliable_pending_buffers_.clear();
  }

  std::mutex mutex_;
  std::condition_variable shutdown_condition_;
  const QUIC_API_TABLE* api_ = nullptr;
  HQUIC registration_ = nullptr;
  HQUIC configuration_ = nullptr;
  HQUIC listener_ = nullptr;
  HQUIC connection_ = nullptr;
  HQUIC control_stream_ = nullptr;
  HQUIC audio_stream_ = nullptr;
  QuicServerOptions options_{};
  QuicServerCallbacks callbacks_{};
  bool datagram_ready_ = false;
  std::size_t datagram_max_payload_ = 0;
  bool reliable_mode_ = false;
  std::uint32_t audio_stream_id_ = 0;
  std::uint32_t audio_generation_ = 0;
  std::atomic<std::uint64_t> audio_epoch_ = 0;
  std::atomic<std::size_t> pending_reliable_sends_ = 0;
  std::atomic<std::size_t> pending_datagrams_ = 0;
  std::atomic<std::uint64_t> pending_original_frames_ = 0;
  std::atomic<std::uint64_t> pending_auxiliary_frames_ = 0;
  std::uint16_t last_original_frames_ = 120;
  std::uint64_t datagram_window_frames_ = 0;
  std::uint64_t reliable_window_frames_ = 0;
  std::atomic<std::uint64_t> reliable_pending_frames_ = 0;
  std::set<SendBufferContext*> reliable_pending_buffers_;
  std::atomic<std::int64_t> last_probe_statistics_ns_ = 0;
  bool started_ = false;
};

}  // namespace

std::unique_ptr<QuicServer> CreateMsQuicServer() {
  return std::make_unique<MsQuicServer>();
}

}  // namespace hearport::windows

#else

#include <memory>

namespace hearport::windows {
namespace {

class UnavailableQuicServer final : public QuicServer {
 public:
  bool Start(const QuicServerOptions&, QuicServerCallbacks) override {
    return false;
  }
  bool SendControl(std::span<const std::byte>) override { return false; }
  bool SendAudio(std::span<const std::byte>) override { return false; }
  ProbeSendOutcome SendProbe(std::span<const std::byte>, std::uint32_t,
                             std::uint32_t, bool, bool) override {
    return {ProbeSendStatus::disconnected};
  }
  void ConfigureAudioWindow(std::uint32_t, std::uint32_t, std::uint32_t) override {}
  void ConfirmReliableReceived(std::uint32_t, std::uint32_t, std::uint32_t) override {}
  void StopReliableAudio() override {}
  bool StartReliableAudio(std::uint32_t, std::uint32_t) override { return false; }
  void CloseConnection() override {}
  void Stop() override {}
};

}  // namespace

std::unique_ptr<QuicServer> CreateMsQuicServer() {
  return std::make_unique<UnavailableQuicServer>();
}

}  // namespace hearport::windows

#endif
