#pragma once

#include <cstddef>
#include <functional>
#include <memory>
#include <span>

#include "hearport/windows/pcm_normalizer.h"

namespace hearport::windows {

class WasapiLoopbackCapture {
 public:
  using PacketHandler = std::function<void(std::span<const std::byte>,
                                           const PcmFormat&)>;
  using ResetHandler = std::function<void()>;

  WasapiLoopbackCapture();
  ~WasapiLoopbackCapture();

  WasapiLoopbackCapture(const WasapiLoopbackCapture&) = delete;
  WasapiLoopbackCapture& operator=(const WasapiLoopbackCapture&) = delete;

  bool Start(PacketHandler on_packet, ResetHandler on_reset);
  void Stop();
  bool running() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace hearport::windows
