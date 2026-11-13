#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>

enum class MainAction {
  pair, sender, live_test, network_test, music_test, log, reports,
  results, detailed_logging, port, capture, auto_start, hide, exit
};

class MainWindow {
 public:
  explicit MainWindow(std::function<void(MainAction)> action,
                      std::function<void(bool, bool, std::uint32_t)> volume);
  ~MainWindow();
  HRESULT Create(std::uint16_t port, bool endpoint, bool auto_start);
  HWND handle() const;
  void Show();
  void SelectPage(int page);
  int page() const;
  void SetStatus(const std::wstring& heading, const std::wstring& detail,
                 const std::wstring& audio, const std::wstring& port);
  void SetComputer(const std::wstring& text);
  void SetActions(bool running, bool sender_enabled, bool paired, bool pair_enabled);
  void SetPairing(const std::wstring& text);
  void SetCertificate(const std::wstring& text);
  void SetDiagnostic(const std::wstring& text);
  void SetVolume(std::optional<std::uint32_t> value);
  void EnableCapture(bool enabled);
  void SetCapture(int value);
  int capture() const;
  void SetPort(std::uint16_t value);
  bool detailed_logging() const;
  bool auto_start() const;
  void SetAutoStart(bool enabled);
  void EnableHide(bool enabled);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
