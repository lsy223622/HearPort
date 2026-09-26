#include "hearport/windows/quic_server.h"

#if defined(HEARPORT_HAS_MSQUIC) && HEARPORT_HAS_MSQUIC

#include <msquic.h>

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace hearport::windows {
namespace {

constexpr char kAlpnText[] = "hearport/1";
constexpr std::size_t kAudioDatagramBytes = 968;

struct SendBufferContext {
  std::vector<std::uint8_t> storage;
  QUIC_BUFFER buffer{};
  std::function<void(std::uint32_t, std::uint32_t, DebugSendState)>
      on_send_state;
  std::uint32_t stream_id = 0;
  std::uint32_t sequence = 0;

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

    if (QUIC_FAILED(MsQuicOpen2(&api_))) {
      api_ = nullptr;
      return false;
    }

    const QUIC_REGISTRATION_CONFIG registration_config{
        "HearPort", QUIC_EXECUTION_PROFILE_LOW_LATENCY};
    if (QUIC_FAILED(api_->RegistrationOpen(&registration_config,
                                           &registration_))) {
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

    const QUIC_BUFFER alpn{sizeof(kAlpnText) - 1,
                            reinterpret_cast<uint8_t*>(
                                const_cast<char*>(kAlpnText))};
    if (QUIC_FAILED(api_->ConfigurationOpen(
            registration_, &alpn, 1, &settings, sizeof(settings), nullptr,
            &configuration_))) {
      StopLocked(lock);
      return false;
    }

    QUIC_CERTIFICATE_HASH certificate_hash{};
    std::copy(options_.certificate_sha1.begin(), options_.certificate_sha1.end(),
              certificate_hash.ShaHash);
    QUIC_CREDENTIAL_CONFIG credential{};
    credential.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_HASH;
    credential.CertificateHash = &certificate_hash;
    if (QUIC_FAILED(
            api_->ConfigurationLoadCredential(configuration_, &credential))) {
      StopLocked(lock);
      return false;
    }

    if (QUIC_FAILED(api_->ListenerOpen(registration_, ListenerCallback, this,
                                       &listener_))) {
      StopLocked(lock);
      return false;
    }

    QUIC_ADDR address{};
    QuicAddrSetFamily(&address, QUIC_ADDRESS_FAMILY_UNSPEC);
    QuicAddrSetPort(&address, options_.port);
    if (QUIC_FAILED(api_->ListenerStart(listener_, &alpn, 1, &address))) {
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

  bool SendAudio(const wire::EncodedAudioDatagram& datagram) override {
    std::lock_guard lock(mutex_);
    if (!started_ || connection_ == nullptr || api_ == nullptr ||
        !datagram_ready_) {
      return false;
    }
    const auto packet = wire::DecodeAudioDatagram(datagram);
    if (!packet) return false;
    auto* context = new SendBufferContext(datagram, packet->stream_id,
                                         packet->sequence);
    context->on_send_state = callbacks_.on_datagram_send_state;
    const auto status = api_->DatagramSend(
        connection_, &context->buffer, 1, QUIC_SEND_FLAG_NONE, context);
    if (QUIC_FAILED(status)) {
      delete context;
      return false;
    }
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
    switch (event->Type) {
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
  }

  std::mutex mutex_;
  std::condition_variable shutdown_condition_;
  const QUIC_API_TABLE* api_ = nullptr;
  HQUIC registration_ = nullptr;
  HQUIC configuration_ = nullptr;
  HQUIC listener_ = nullptr;
  HQUIC connection_ = nullptr;
  HQUIC control_stream_ = nullptr;
  QuicServerOptions options_{};
  QuicServerCallbacks callbacks_{};
  bool datagram_ready_ = false;
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
  bool SendAudio(const wire::EncodedAudioDatagram&) override { return false; }
  void CloseConnection() override {}
  void Stop() override {}
};

}  // namespace

std::unique_ptr<QuicServer> CreateMsQuicServer() {
  return std::make_unique<UnavailableQuicServer>();
}

}  // namespace hearport::windows

#endif
