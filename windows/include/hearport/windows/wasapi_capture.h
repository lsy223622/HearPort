#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string_view>

#include "hearport/windows/pcm_normalizer.h"

namespace hearport::windows {

enum class CaptureSource { process, endpoint };

struct PcmResolution {
  std::uint32_t rate = 0;
  unsigned bits = 0;
  bool operator==(const PcmResolution&) const = default;
};

std::optional<PcmResolution> ReadSystemPcmResolution();

class WasapiLoopbackCapture {
 public:
  using PacketHandler = std::function<void(std::span<const std::byte>,
                                           const PcmFormat&, std::uint64_t)>;
  using ResetHandler = std::function<void()>;
  using LogHandler = std::function<void(std::string_view)>;

  WasapiLoopbackCapture();
  ~WasapiLoopbackCapture();

  WasapiLoopbackCapture(const WasapiLoopbackCapture&) = delete;
  WasapiLoopbackCapture& operator=(const WasapiLoopbackCapture&) = delete;

  bool Start(PacketHandler on_packet, ResetHandler on_reset,
             CaptureSource source = CaptureSource::process, LogHandler log = {});
  CaptureSource source() const noexcept;
  void Stop();
  bool running() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace hearport::windows
