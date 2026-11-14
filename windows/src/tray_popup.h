#pragma once

#include "link_presentation.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

class TrayPopup {
 public:
  TrayPopup(std::function<void()> open_home, std::function<void()> open_settings,
            std::function<void()> toggle_sender, std::function<void(std::uint32_t)> preview,
            std::function<void(std::uint32_t)> commit, std::function<void()> cancel);
  ~TrayPopup();
  HRESULT Show(const RECT& anchor);
  void Hide();
  bool visible() const;
  void Update(bool connected, bool usb, LinkStability stability, bool running, std::optional<std::uint32_t> volume);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
