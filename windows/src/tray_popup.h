#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

class TrayPopup {
 public:
  TrayPopup(std::function<void()> open, std::function<void(std::uint32_t)> preview,
            std::function<void(std::uint32_t)> commit, std::function<void()> cancel);
  ~TrayPopup();
  HRESULT Show(const RECT& anchor);
  void Hide();
  bool visible() const;
  void Update(bool connected, std::optional<std::uint32_t> volume);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
