#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string_view>

#include "hearport/wire/audio_datagram.h"
#include "hearport/windows/debug_session_trace.h"

namespace hearport::windows {

struct QuicServerOptions {
  std::uint16_t port = 52137;
  std::array<std::uint8_t, 20> certificate_sha1{};
  bool has_certificate_sha1 = false;
  std::array<std::byte, 32> certificate_spki_sha256{};
  bool has_certificate_spki_sha256 = false;
  std::function<void(std::string_view)> diagnostic_log;
};

struct QuicServerCallbacks {
  std::function<void()> on_connected;
  std::function<bool(std::span<const std::byte>)> on_control_bytes;
  std::function<void(std::size_t)> on_datagram_ready;
  std::function<void()> on_datagram_unavailable;
  std::function<void(std::uint32_t, std::uint32_t, DebugSendState)>
      on_datagram_send_state;
  std::function<void()> on_closed;
};

class QuicServer {
 public:
  virtual ~QuicServer() = default;
  virtual bool Start(const QuicServerOptions& options,
                     QuicServerCallbacks callbacks) = 0;
  virtual bool SendControl(std::span<const std::byte> framed_bytes) = 0;
  virtual bool SendAudio(const wire::EncodedAudioDatagram& datagram) = 0;
  virtual void CloseConnection() = 0;
  virtual void Stop() = 0;
};

std::unique_ptr<QuicServer> CreateMsQuicServer();

}  // namespace hearport::windows
