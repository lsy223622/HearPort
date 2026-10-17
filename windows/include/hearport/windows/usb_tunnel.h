#pragma once
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace hearport::windows {
std::vector<std::byte> EncodeUsbPacket(std::span<const std::byte> payload);
class UsbPacketDecoder {
 public:
  bool Push(std::span<const std::byte>, std::vector<std::vector<std::byte>>&);
  bool Complete() const { return buffer_.empty(); }
 private:
  std::vector<std::byte> buffer_;
};
class UsbPacketQueue {
 public:
  using Clock = std::chrono::steady_clock;
  bool Push(std::span<const std::byte>, Clock::time_point);
  std::span<const std::byte> Front() const;
  void Consume(std::size_t);
  bool Expired(Clock::time_point, std::chrono::milliseconds) const;
  std::size_t payload_bytes() const { return bytes_; }
 private:
  struct Frame { std::vector<std::byte> bytes; std::size_t offset; Clock::time_point at; };
  std::deque<Frame> frames_;
  std::size_t bytes_ = 0;
};
std::vector<std::uint32_t> ParseUsbDevices(std::string_view plist);
bool IsUsbDeviceChange(std::span<const std::uint32_t> known, std::string_view plist);
bool IsUsbDeviceDetached(std::uint32_t device, std::string_view plist);
class UsbTunnel {
 public:
  using StatusHandler = std::function<void(std::string)>;
  using LogHandler = std::function<void(std::string_view)>;
  UsbTunnel();
  ~UsbTunnel();
  bool Start(std::uint16_t quic_port, StatusHandler status, LogHandler log);
  void SetMaximumLatency(std::chrono::milliseconds);
  void Stop();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
