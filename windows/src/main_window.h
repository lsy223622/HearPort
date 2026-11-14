#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

enum class MainAction {
  pair, sender, live_test, network_test, music_test, log, reports,
  results, detailed_logging, port, capture, auto_start, hide, exit
};

struct TestSettings {
  std::wstring file;
  std::wstring start;
  std::wstring duration;
  unsigned maximum = 100;
  unsigned round_seconds = 30;
  bool recommendations = true;
};

struct RecommendationPoint {
  double age_ms;
  double gap_ratio;
  bool reliable;
};

class MainWindow {
 public:
  static HRESULT RunApp(std::function<void()> launched, std::function<void()> finished);
  static void ExitApp();
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
  void Notify(std::wstring message);
  void Confirm(std::wstring message, const wchar_t* primary, std::function<void()> accepted);
  void EditPort(std::function<std::wstring(std::uint16_t)> save);
  void ConfigureTest(MainAction test, TestSettings settings,
                     std::function<void(TestSettings)> start);
  void ShowRecommendations(std::wstring report, const std::vector<RecommendationPoint>& points);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
