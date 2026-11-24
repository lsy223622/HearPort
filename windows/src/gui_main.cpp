#define _WIN32_WINNT 0x0A00
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <iphlpapi.h>
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "gui_resources.h"
#include "tray_popup.h"
#include "main_window.h"
#include "hearport/windows/diagnostic_logger.h"
#include "hearport/windows/sender_authentication.h"
#include "hearport/windows/sender_certificate.h"
#include "hearport/windows/sender_service.h"
#include "hearport/windows/sender_host.h"
#include "hearport/windows/network_probe.h"
#include "hearport/windows/auto_start.h"

namespace {

using hearport::windows::SenderAuthentication;
using hearport::windows::CaptureSource;
using hearport::windows::PcmResolution;
using hearport::windows::SenderDiagnosticLogger;
using hearport::windows::SenderService;
using Clock = std::chrono::steady_clock;

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kStartMessage = WM_APP + 2;
constexpr UINT kConnectionMessage = WM_APP + 3;
constexpr UINT kCalibrationRequestMessage = WM_APP + 4;
constexpr UINT kUnpairCompletedMessage = WM_APP + 5;
constexpr UINT kTimer = 1;
constexpr UINT kTrayIcon = 1;
constexpr int kDiagnostics = 105;
constexpr int kNetworkProbe = 110;
constexpr int kMusicTest = 115;
constexpr int kTrayOpen = 201;
constexpr int kTrayExit = 202;

std::wstring Tr(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE
             ? chinese
             : english;
}

HICON DrawTrayIcon(int size, bool running, bool connected, bool usb,
                  LinkStability stability, bool dark) {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  const auto bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bitmap) return nullptr;
  const auto stride = ((size + 15) / 16) * 2;
  const std::vector<BYTE> mask_bits(stride * size, 0);
  const auto mask = CreateBitmap(size, size, 1, 1, mask_bits.data());
  if (!mask) { DeleteObject(bitmap); return nullptr; }

  struct Stroke { double x1, y1, x2, y2; };
  // The same overlapping devices and connection marks as the overview logo,
  // simplified to stay legible at the notification area's 16 px size.
  constexpr Stroke outline[]{
      {3.5,7,3.5,3.8},{3.5,3.8,4.5,2.7},{4.5,2.7,12.1,2.7},
      {12.1,2.7,13.1,3.8},{13.1,3.8,13.1,6},
      {13.1,12.1,12.3,13.3},{12.3,13.3,10.4,13.3},
      {1.5,9.3,2.2,8.6},{2.2,8.6,7.8,8.6},{7.8,8.6,8.5,9.3},
      {8.5,9.3,8.5,12.6},{8.5,12.6,7.8,13.3},{7.8,13.3,2.2,13.3},
      {2.2,13.3,1.5,12.6},{1.5,12.6,1.5,9.3}};
  constexpr Stroke closed_edge{13.1,6,13.1,12.1};
  constexpr Stroke cable[]{{8.5,10.8,11.3,10.8},{11.3,10.8,13.4,9.9},
      {13.4,9.9,14.1,8.6},{14.1,8.6,13.9,7.2},{13.9,7.2,13.1,6}};
  constexpr Stroke signal[][2]{
      {{9.8,8.9,10.2,10},{10.2,10,9.8,11.1}},
      {{11.9,8.0,12.5,10},{12.5,10,11.9,12.0}},
      {{14.1,7.0,14.9,10},{14.9,10,14.1,13.0}}};
  const bool contrast = [] {
    HIGHCONTRASTW state{sizeof(state)};
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(state), &state, 0) &&
           (state.dwFlags & HCF_HIGHCONTRASTON);
  }();
  const auto ink = contrast ? GetSysColor(COLOR_WINDOWTEXT)
                            : dark ? RGB(255,255,255) : RGB(27,27,27);
  const auto link = contrast ? GetSysColor(COLOR_HIGHLIGHT) : LinkColor(usb, stability, dark);
  const auto covers = [](const Stroke& line, double x, double y) {
    const auto dx = line.x2 - line.x1, dy = line.y2 - line.y1;
    const auto t = std::clamp(((x - line.x1) * dx + (y - line.y1) * dy) / (dx * dx + dy * dy), 0.0, 1.0);
    return std::hypot(x - line.x1 - t * dx, y - line.y1 - t * dy) <= .70;
  };
  auto* pixels = static_cast<std::uint32_t*>(bits);
  for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
    unsigned a = 0, r = 0, g = 0, b = 0;
    for (int sy = 0; sy < 4; ++sy) for (int sx = 0; sx < 4; ++sx) {
      const auto px = (x + (sx + .5) / 4) * 16 / size;
      const auto py = (y + (sy + .5) / 4) * 16 / size;
      const auto hit = [&](const Stroke& stroke) { return covers(stroke, px, py); };
      bool signal_hit = connected && usb && std::ranges::any_of(cable, hit);
      if (connected && !usb) {
        for (int bar = 0; bar < LinkBars(stability); ++bar)
          signal_hit = signal_hit || std::ranges::any_of(signal[bar], hit);
      }
      const bool outline_hit = std::ranges::any_of(outline, hit) || (!running && hit(closed_edge));
      if (!signal_hit && !outline_hit) continue;
      const auto color = signal_hit ? link : ink;
      a += 255; r += GetRValue(color); g += GetGValue(color); b += GetBValue(color);
    }
    pixels[y * size + x] = (a / 16 << 24) | (r / 16 << 16) | (g / 16 << 8) | (b / 16);
  }
  ICONINFO icon{TRUE, 0, 0, mask, bitmap};
  const auto result = CreateIconIndirect(&icon);
  DeleteObject(mask);
  DeleteObject(bitmap);
  return result;
}

std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
                                        static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) return {};
  path.resize(size);
  return path;
}

std::filesystem::path DataDirectory() {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                  &local_app_data))) {
    return {};
  }
  std::filesystem::path directory(local_app_data);
  CoTaskMemFree(local_app_data);
  return directory / L"HearPort";
}

std::wstring LocalIPv4() {
  ULONG bytes = 0;
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST |
                                        GAA_FLAG_SKIP_MULTICAST |
                                        GAA_FLAG_SKIP_DNS_SERVER,
                           nullptr, nullptr, &bytes) != ERROR_BUFFER_OVERFLOW) {
    return {};
  }
  std::vector<BYTE> storage(bytes);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST |
                                        GAA_FLAG_SKIP_MULTICAST |
                                        GAA_FLAG_SKIP_DNS_SERVER,
                           nullptr, adapters, &bytes) != NO_ERROR) {
    return {};
  }
  std::wstring fallback;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    for (auto* address = adapter->FirstUnicastAddress; address;
         address = address->Next) {
      if (!address->Address.lpSockaddr ||
          address->Address.lpSockaddr->sa_family != AF_INET ||
          address->Address.iSockaddrLength <
              static_cast<int>(sizeof(sockaddr_in))) {
        continue;
      }
      const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(
          address->Address.lpSockaddr);
      const auto* octets = reinterpret_cast<const BYTE*>(&ipv4->sin_addr);
      if (octets[0] == 169 && octets[1] == 254) continue;
      std::wstring value = std::to_wstring(octets[0]) + L"." +
                           std::to_wstring(octets[1]) + L"." +
                           std::to_wstring(octets[2]) + L"." +
                           std::to_wstring(octets[3]);
      if (octets[0] == 10 ||
          (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
          (octets[0] == 192 && octets[1] == 168)) {
        return value;
      }
      if (fallback.empty()) fallback = std::move(value);
    }
  }
  return fallback;
}

std::uint16_t LoadPort() {
  DWORD port = 0;
  DWORD size = sizeof(port);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\HearPort", L"Port",
                   RRF_RT_REG_DWORD, nullptr, &port, &size) == ERROR_SUCCESS &&
      port > 0 && port <= 65535) {
    return static_cast<std::uint16_t>(port);
  }
  return 52137;
}

bool SystemDarkMode() {
  HIGHCONTRASTW contrast{sizeof(contrast)};
  if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast,
                            0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
    return false;
  }
  DWORD light = 1;
  DWORD size = sizeof(light);
  return RegGetValueW(
             HKEY_CURRENT_USER,
             L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
             L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light,
             &size) == ERROR_SUCCESS &&
         light == 0;
}

CaptureSource LoadCaptureSource() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\HearPort", L"CaptureSource",
                   RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS && value == 1) {
    return CaptureSource::endpoint;
  }
  return CaptureSource::process;
}

unsigned LoadPcmLimit(const wchar_t* name, unsigned minimum, unsigned maximum) {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\HearPort", name, RRF_RT_REG_DWORD,
                   nullptr, &value, &size) != ERROR_SUCCESS || value < minimum || value > maximum)
    return 0;
  return value;
}

bool SaveSetting(const wchar_t* name, DWORD value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\HearPort", 0, nullptr,
                      0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
      ERROR_SUCCESS) {
    return false;
  }
  const bool saved = RegSetValueExW(key, name, 0, REG_DWORD,
                                    reinterpret_cast<const BYTE*>(&value),
                                    sizeof(value)) == ERROR_SUCCESS;
  RegCloseKey(key);
  return saved;
}

std::wstring AutoStartValue() {
  wchar_t value[32768]{};
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                      L"HearPort", RRF_RT_REG_SZ, nullptr, value,
                      &size) != ERROR_SUCCESS) return {};
  return value;
}

bool AutoStartEnabled() { return !AutoStartValue().empty(); }

bool SetAutoStart(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
          nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LONG result = ERROR_SUCCESS;
  if (enabled) {
    const std::wstring path = ExecutablePath();
    if (path.empty()) {
      RegCloseKey(key);
      return false;
    }
    const std::wstring command = hearport::windows::AutoStartCommand(path);
    if (command.empty()) { RegCloseKey(key); return false; }
    result = RegSetValueExW(
        key, L"HearPort", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValueW(key, L"HearPort");
    if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

class Application {
 public:
  explicit Application(bool start_hidden)
      : start_hidden_(start_hidden), port_(LoadPort()), data_dir_(DataDirectory()) {}

  int Launch(HINSTANCE instance, int show_command) {
    instance_ = instance;
    if (hearport::windows::ShouldRepairAutoStart(AutoStartValue(), ExecutablePath())) {
      SetAutoStart(true);
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    INITCOMMONCONTROLSEX common_controls{sizeof(common_controls), ICC_TAB_CLASSES | ICC_BAR_CLASSES};
    InitCommonControlsEx(&common_controls);

    main_window_ = std::make_unique<MainWindow>(
        [this](MainAction action) { HandleAction(action); },
        [this](bool editing, bool changed, std::uint32_t value) {
          volume_editing_ = editing;
          volume_position_ = value;
          if (editing) {
            if (tray_popup_) tray_popup_->Update(connected_, usb_connected_, link_stability_, running_, value);
          } else {
            CommitVolume(changed);
          }
        });
    const auto result = main_window_->Create(port_, capture_source_ == CaptureSource::endpoint, AutoStartEnabled());
    if (FAILED(result)) {
      wchar_t code[16]{};
      swprintf_s(code, L"0x%08lX", static_cast<unsigned long>(result));
      const auto message = Tr(L"Could not start HearPort. Install Windows App Runtime 2.6.5 or newer.",
                              L"无法启动 HearPort。请安装 Windows App Runtime 2.6.5 或更高版本。") +
                           L"\n" + code;
      MessageBoxW(nullptr, message.c_str(), L"HearPort", MB_OK | MB_ICONERROR);
      return 1;
    }
    hwnd_ = main_window_->handle();
    main_window_->ConfigurePcmLimits(pcm_limits_.rate, pcm_limits_.bits,
        [this](bool rate, unsigned value) {
          if (!SaveSetting(rate ? L"PcmSampleRateLimit" : L"PcmBitDepthLimit", value)) {
            main_window_->Notify(Tr(L"Could not save the PCM limit.", L"无法保存 PCM 上限。"));
            return false;
          }
          if (rate) pcm_limits_.rate = value;
          else pcm_limits_.bits = value;
          RefreshSystemPcm();
          if (service_) service_->ConfigurePcmLimits(pcm_limits_);
          UpdateStatus();
          return true;
        });
    RefreshSystemPcm();
    if (!SetWindowSubclass(hwnd_, WindowProc, 1, reinterpret_cast<DWORD_PTR>(this))) return 1;
    if (const auto icon = LoadIconW(instance_, MAKEINTRESOURCEW(IDI_HEARPORT))) {
      SendMessageW(hwnd_, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
      SendMessageW(hwnd_, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
    }
    ApplyTheme();
    wchar_t name[MAX_COMPUTERNAME_LENGTH + 1]{};
    DWORD length = ARRAYSIZE(name);
    if (GetComputerNameW(name, &length)) {
      auto label = Tr(L"This PC: ", L"这台电脑：") + std::wstring(name);
      const auto address = LocalIPv4();
      if (!address.empty()) label += L"  ·  " + address;
      main_window_->SetComputer(label);
    }
    taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
    AddTrayIcon();
    SetTimer(hwnd_, kTimer, 1000, nullptr);
    PostMessageW(hwnd_, kStartMessage, 0, 0);
    UpdateStatus();
    if (!start_hidden_ || !tray_ready_) {
      main_window_->Show();
      if (show_command == SW_SHOWMINIMIZED && tray_ready_) ShowWindow(hwnd_, SW_HIDE);
    }

    return 0;
  }

 private:
  void SelectPage(int page) { main_window_->SelectPage(page); }

  void ApplyTheme() {
    dark_ = SystemDarkMode();
    RefreshTrayIcon();
  }

  void FillTrayIcon(NOTIFYICONDATAW& icon) {
    const int size = GetSystemMetrics(SM_CXSMICON);
    if (auto replacement = DrawTrayIcon(size, running_, connected_, usb_connected_,
                                       link_stability_, dark_)) {
      if (tray_connection_icon_) DestroyIcon(tray_connection_icon_);
      tray_connection_icon_ = replacement;
    }
    icon.hIcon = tray_connection_icon_;
    std::wstring tip = Tr(L"HearPort not connected", L"HearPort 未连接");
    if (connected_) {
      tip = usb_connected_ ? L"HearPort · USB" : Tr(L"HearPort · Network", L"HearPort · 网络");
      tip += link_stability_ == LinkStability::stable ? Tr(L" · Stable", L" · 稳定")
           : link_stability_ == LinkStability::variable ? Tr(L" · Fluctuating", L" · 波动")
           : link_stability_ == LinkStability::poor ? Tr(L" · Unstable", L" · 不稳定")
           : Tr(L" · Assessing", L" · 评估中");
    }
    lstrcpynW(icon.szTip, tip.c_str(), ARRAYSIZE(icon.szTip));
  }

  void RefreshTrayIcon() {
    if (!tray_ready_) return;
    NOTIFYICONDATAW icon{sizeof(icon)};
    icon.hWnd = hwnd_;
    icon.uID = kTrayIcon;
    icon.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    FillTrayIcon(icon);
    Shell_NotifyIconW(NIM_MODIFY, &icon);
  }

  void UpdateLinkPresentation() {
    main_window_->SetLinkStability(running_, connected_, connected_ && usb_connected_, link_stability_);
    const TrayLink current{running_, connected_, connected_ && usb_connected_, link_stability_};
    if (current == tray_link_) return;
    tray_link_ = current;
    RefreshTrayIcon();
  }

  void AddTrayIcon() {
    NOTIFYICONDATAW icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = hwnd_;
    icon.uID = kTrayIcon;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    icon.uCallbackMessage = kTrayMessage;
    FillTrayIcon(icon);
    tray_ready_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
    main_window_->EnableHide(tray_ready_);
    if (tray_ready_) {
      icon.uVersion = NOTIFYICON_VERSION_4;
      Shell_NotifyIconW(NIM_SETVERSION, &icon);
    }
  }

  void RemoveTrayIcon() {
    if (!tray_ready_) return;
    NOTIFYICONDATAW icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = hwnd_;
    icon.uID = kTrayIcon;
    Shell_NotifyIconW(NIM_DELETE, &icon);
    tray_ready_ = false;
  }

  void ShowWindowFromTray() {
    if (tray_popup_) tray_popup_->Hide();
    ShowWindow(hwnd_, SW_RESTORE);
    main_window_->Show();
    SetForegroundWindow(hwnd_);
  }

  void ToggleTrayPopup(POINT anchor) {
    if (tray_popup_ && tray_popup_->visible()) {
      tray_popup_->Hide();
      return;
    }
    if (!tray_popup_) {
      tray_popup_ = std::make_unique<TrayPopup>(
          [this] { SelectPage(0); ShowWindowFromTray(); },
          [this] { SelectPage(2); ShowWindowFromTray(); },
          [this] {
            if (unpair_pending_) return;
            if (running_) StopSender();
            else StartService();
          },
          [this](std::uint32_t percent) {
            volume_editing_ = true;
            volume_position_ = percent;
            main_window_->SetVolume(percent);
          },
          [this](std::uint32_t percent) {
            volume_position_ = percent;
            CommitVolume(true);
          },
          [this] { CommitVolume(false); });
    }
    UpdateVolume();
    NOTIFYICONIDENTIFIER icon{sizeof(icon), hwnd_, kTrayIcon};
    RECT bounds{};
    if (FAILED(Shell_NotifyIconGetRect(&icon, &bounds))) {
      bounds = {anchor.x, anchor.y, anchor.x, anchor.y};
    }
    if (const auto result = tray_popup_->Show(bounds); FAILED(result)) {
      tray_popup_.reset();
      wchar_t code[16]{};
      swprintf_s(code, L"0x%08lX", static_cast<unsigned long>(result));
      const auto message = Tr(L"Could not open the tray popup. It requires Windows 11 and Windows App Runtime 2.6.5 or newer.",
          L"无法打开托盘弹窗。需要 Windows 11 和 Windows App Runtime 2.6.5 或更高版本。") +
          L"\n" + code;
      main_window_->Notify(message);
    }
  }

  void ShowTrayMenu() {
    if (tray_popup_) tray_popup_->Hide();
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    const std::wstring open = Tr(L"Open HearPort", L"打开 HearPort");
    const std::wstring exit = Tr(L"Exit", L"退出");
    AppendMenuW(menu, MF_STRING, kTrayOpen, open.c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kTrayExit, exit.c_str());
    POINT cursor{};
    GetCursorPos(&cursor);
    SetForegroundWindow(hwnd_);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, cursor.x,
                   cursor.y, 0, hwnd_, nullptr);
    DestroyMenu(menu);
  }

  void CommitVolume(bool changed) {
    volume_editing_ = false;
    if (changed && host_ && connected_ && volume_available_) {
      host_->RequestSystemVolume(volume_position_);
    }
    UpdateVolume();
  }

  void UpdateVolume() {
    const auto volume = host_ && connected_ ? host_->SystemVolume()
                                            : hearport::windows::SystemVolumeState{};
    volume_available_ = volume.percent.has_value();
    if (!volume_available_) volume_editing_ = false;
    if (volume.percent && !volume_editing_ && !volume.adjusting) volume_position_ = *volume.percent;
    const auto value = volume_available_ ? std::optional{volume_position_} : std::nullopt;
    main_window_->SetVolume(value);
    if (tray_popup_) tray_popup_->Update(connected_, usb_connected_, link_stability_, running_, value);
  }

  void UpdateLinkStability() {
    if (!connected_ || !service_) {
      ResetLinkStability();
      UpdateLinkPresentation();
      return;
    }

    const auto now = Clock::now();
    if (!link_started_ || (last_link_poll_ && now - *last_link_poll_ > std::chrono::seconds(3))) {
      ResetLinkStability();
      link_started_ = now;
    }
    if (!last_link_poll_ || now - *last_link_poll_ >= std::chrono::milliseconds(1800)) {
      last_link_poll_ = now;
      // Wait for fresh transport ACKs before taking another RTT observation.
      const auto sample = service_->ReadLinkTiming();
      if (sample && sample->rtt_us && sample->ack_frames > last_link_ack_) {
        last_link_ack_ = sample->ack_frames;
        last_link_response_ = now;
        link_observations_.emplace_back(now, sample->rtt_us / 1000.0);
      }
      while (!link_observations_.empty() && now - link_observations_.front().first > std::chrono::seconds(12))
        link_observations_.pop_front();

      if (now - last_link_response_.value_or(*link_started_) > std::chrono::seconds(6)) {
        link_stability_ = LinkStability::poor;
        link_improvement_at_.reset();
      } else if (link_observations_.size() < 3 ||
                 link_observations_.back().first - link_observations_.front().first < std::chrono::seconds(4)) {
        if (link_stability_ != LinkStability::poor) link_stability_ = LinkStability::unknown;
      } else {
        std::vector<double> sorted;
        for (const auto& observation : link_observations_) sorted.push_back(observation.second);
        std::sort(sorted.begin(), sorted.end());
        const auto percentile = [&](double fraction) {
          const auto position = (sorted.size() - 1) * fraction;
          const auto low = static_cast<std::size_t>(position);
          return sorted[low] + (sorted[std::min(low + 1, sorted.size() - 1)] - sorted[low]) * (position - low);
        };
        const auto variation = percentile(.9) - percentile(.1);
        const auto candidate = variation <= 10 ? LinkStability::stable :
                               variation <= 30 ? LinkStability::variable : LinkStability::poor;
        if (link_stability_ == LinkStability::unknown || candidate <= link_stability_) {
          link_stability_ = candidate;
          link_improvement_at_.reset();
        } else if (!link_improvement_at_ || link_improving_to_ != candidate) {
          link_improving_to_ = candidate;
          link_improvement_at_ = now;
        } else if (now - *link_improvement_at_ >= std::chrono::seconds(8)) {
          link_stability_ = candidate;
          link_improvement_at_.reset();
        }
      }
    }
    UpdateLinkPresentation();
  }

  void ResetLinkStability() {
    link_started_.reset();
    last_link_poll_.reset();
    last_link_response_.reset();
    link_improvement_at_.reset();
    link_observations_.clear();
    last_link_ack_ = 0;
    link_stability_ = LinkStability::unknown;
  }

  void UpdateStatus() {
    UpdateLinkStability();
    UpdateVolume();
    std::wstring heading;
    std::wstring detail;
    const auto source = connected_ && service_ ? service_->capture_source() : capture_source_;
    std::wstring audio_label = source == CaptureSource::process
        ? Tr(L"Audio source: Process loopback", L"音频来源：进程回环")
        : Tr(L"Audio source: Windows default output", L"音频来源：Windows 默认输出设备");
    const bool capture_enabled = !diagnostic_duration_ && !music_test_active_ && !unpair_pending_;
    main_window_->EnableCapture(capture_enabled);
    if (running_ && music_test_active_) {
      audio_label = Tr(L"Audio source: selected file excerpt", L"音频来源：所选文件的固定片段");
      const auto seconds = service_->music_test_frames_processed() / 48'000;
      const auto round = service_->music_test_round();
      heading = connected_ ? Tr(L"Compression test ", L"压缩对比测试 ") + std::to_wstring(round) + L"/32" :
          Tr(L"Music compression test ready", L"音乐压缩对比测试待连接");
      if (connected_ && round > 0) {
        const auto policy = service_->music_test_policy();
        const auto encoding = policy.profile == 0 ? L"PCM Float32" : policy.profile == 1 ? L"PCM16" :
            L"Opus " + std::to_wstring(policy.bitrate_kbps) + L" kbps";
        detail = std::wstring(policy.reliable ? L"Reliable" : L"Datagram") + L" · " + encoding +
            L" · " + (policy.frames == 120 ? L"2.5" : policy.frames == 240 ? L"5" : L"10") + L" ms" +
            L"\n" + Tr(L"Round remaining: ", L"本组剩余：") +
            std::to_wstring(std::max(0, std::stoi(music_seconds_) - static_cast<int>(seconds))) + Tr(L" s", L" 秒") +
            Tr(L" · repetition ", L" · 第 ") + std::to_wstring(policy.repeat) + Tr(L"/2", L"/2 次");
        if (seconds >= std::stoul(music_seconds_)) {
          detail = round == hearport::windows::kMusicTestRoundCount ? Tr(L"Waiting for the iPad report.", L"正在等待 iPad 回传报告。") :
              Tr(L"Preparing the next comparison round.", L"正在准备下一组对照。 ");
        }
      } else {
        const auto duration = std::stoul(music_seconds_) * hearport::windows::kMusicTestRoundCount + 165;
        detail = Tr(L"32 rounds run automatically; estimated ", L"自动运行 32 组；预计 ") +
            std::to_wstring(duration / 60) + Tr(L" min ", L" 分 ") + std::to_wstring(duration % 60) +
            Tr(L" s, plus setup and report transfer.", L" 秒，另加协商与报告回传。");
      }
    } else if (running_ && network_probe_active_ && service_->environment_calibration()) {
      const auto progress = service_->calibration_progress();
      heading = !connected_ ? Tr(L"Automatic test and parameter recommendations ready", L"自动测试并推荐参数待连接") :
          progress.stage == 2 ? Tr(L"Analyzing recommendations", L"正在分析推荐参数") :
          progress.stage >= 4 ? Tr(L"Automatic test ended", L"自动测试已结束") :
          progress.stage == 3 ? Tr(L"Validating recommendations", L"正在复核推荐参数") : Tr(L"Sampling network", L"正在采样网络");
      const auto estimate = [&](unsigned minimum, unsigned maximum, const std::wstring& extra) {
        detail += L"\n" + Tr(L"Estimated remaining traffic: ",L"预计剩余传输：") +
            std::to_wstring(minimum) + (minimum == maximum ? L"" : L"–" + std::to_wstring(maximum)) +
            Tr(L" s; ",L" 秒；") + extra;
      };
      if (service_->adaptive_calibration()) {
        detail = Tr(L"Adaptive search · step ",L"自适应搜索 · 步骤 ") + std::to_wstring(progress.completed_rounds + (progress.round_pending ? 1 : 0));
        if (progress.round_started) detail += Tr(L" · this round remaining ",L" · 本轮剩余 ") + std::to_wstring(progress.remaining_seconds) + Tr(L" s",L" 秒");
        detail += Tr(L". Current parameters and recommendations are shown on iPad.",L"。当前参数和推荐结果显示在 iPad 上。");
      } else if (progress.stage >= 4) detail = Tr(L"Preparing and receiving the iPad report.", L"正在准备并回收 iPad 报告。");
      else if (progress.stage == 2) {
        detail = std::to_wstring(progress.completed) + L" / " + std::to_wstring(progress.total);
        estimate(0, 6 * (calibration_seconds_ + 5) + 5,
            Tr(L"0–6 validation rounds, plus remaining analysis and report upload.", L"后续复核 0–6 组；另加剩余分析与报告回传。"));
      } else if (connected_) {
        if (progress.index && progress.count) {
          detail = std::to_wstring(progress.index) + L" / " + std::to_wstring(progress.count) +
              Tr(L" rounds",L" 组");
          if (progress.round_pending && !progress.round_started)
            detail += Tr(L" · waiting for the iPad",L" · 等待 iPad 开始");
          else if (progress.round_pending && progress.remaining_seconds)
            detail += Tr(L" · current round remaining ",L" · 本组剩余 ") +
                std::to_wstring(progress.remaining_seconds) + Tr(L" s",L" 秒");
          else if (progress.round_pending)
            detail += Tr(L" · draining queued data",L" · 正在排空队列");
          else detail += Tr(L" · preparing next round",L" · 正在准备下一组");
        } else {
          detail = Tr(L"Preparing the automatic test.", L"正在准备自动测试。");
        }
        if (progress.stage == 1) {
          const unsigned completed_sampling = std::min(progress.completed_rounds, 4u);
          const unsigned remaining_sampling = progress.round_pending ?
              (progress.count - progress.index + 1) : (4 - completed_sampling);
          const unsigned sampling_seconds = progress.round_pending ?
              (progress.elapsed_seconds >= calibration_seconds_ + 5 ? 0 :
               calibration_seconds_ + 5 - progress.elapsed_seconds) +
                  (progress.count - progress.index) * (calibration_seconds_ + 5) :
              remaining_sampling * (calibration_seconds_ + 5);
          estimate(sampling_seconds, sampling_seconds + 6 * (calibration_seconds_ + 5) + 5,
              Tr(L"sampling plus 0–6 future validation rounds; analysis and report upload extra.",
                 L"含采样及后续复核 0–6 组；另加分析与报告回传。"));
        } else if (progress.stage == 3) {
          const unsigned completed_validation = progress.completed_rounds > 4 ?
              progress.completed_rounds - 4 : 0;
          const unsigned remaining_validation = progress.round_pending ?
              (progress.count - progress.index + 1) :
              (progress.count - std::min(completed_validation, progress.count));
          const unsigned later_validation = progress.round_pending ? progress.count - progress.index : 0;
          const unsigned validation_seconds = progress.round_pending ?
              (progress.elapsed_seconds >= calibration_seconds_ + (later_validation ? 5 : 10) ? 0 :
               calibration_seconds_ + (later_validation ? 5 : 10) - progress.elapsed_seconds) +
                  later_validation * (calibration_seconds_ + 5) + (later_validation ? 5 : 0) :
              remaining_validation * (calibration_seconds_ + 5) + (remaining_validation ? 5 : 0);
          estimate(validation_seconds, validation_seconds,
              Tr(L"known validation rounds, plus report upload.",L"已知数量的复核组，另加报告回传。"));
        }
      } else detail = Tr(L"Connect the iPad; sampling and validation run automatically.", L"连接 iPad 后自动完成采样与复核。");
      audio_label = service_->adaptive_calibration() ? Tr(L"Adaptive packet sizes and rates · no audio",L"动态包大小与发包频率 · 不播放音频") : Tr(L"Random data · 992 B · 400 packets/s · no audio", L"随机数据 · 992 字节 · 400 包/秒 · 不播放音频");
    } else if (running_ && network_probe_active_ && connected_) {
      const std::uint32_t processed = service_->network_probe_packets_processed();
      const auto rounds = service_->network_probe_rounds();
      std::uint32_t before_round = 0;
      std::size_t round_index = 0;
      for (; round_index < rounds.size(); ++round_index) {
        const auto& round = rounds[round_index];
        const auto round_packets = round.packets_per_second *
                                   hearport::windows::kNetworkProbeSecondsPerRound;
        if (processed < before_round + round_packets) break;
        before_round += round_packets;
      }
      if (round_index == rounds.size()) {
        heading = Tr(L"Network test sent", L"网络测试发送完成");
        detail = Tr(L"Waiting for the iPad report.", L"正在等待 iPad 回传报告。");
      } else {
        const auto& round = rounds[round_index];
        const auto round_seconds =
            (processed - before_round) / round.packets_per_second;
        const auto recovery_seconds = rounds.size() == hearport::windows::kCoordinatedProbeRoundCount ?
            hearport::windows::kCoordinatedProbeRecoverySeconds : 0;
        const auto total_seconds =
            round_index * (hearport::windows::kNetworkProbeSecondsPerRound + recovery_seconds) +
            round_seconds;
        heading = Tr(L"Network test ", L"网络测试 ") +
                  std::to_wstring(round_index + 1) + L"/" + std::to_wstring(rounds.size()) + L" · " +
                  (round.reliable ? L"Reliable stream" : L"Datagram");
        detail = Tr(L"Round ", L"本组 ") + std::to_wstring(round_seconds) +
                 Tr(L"/30 s · Total ", L"/30 秒 · 总计 ") +
                 std::to_wstring(total_seconds) +
                 L"/" + std::to_wstring(rounds.size() * 30 + (rounds.size() - 1) * recovery_seconds) + Tr(L" s", L" 秒");
        if (service_->network_probe_recovering()) {
          detail = Tr(L"Recovery interval: 5 s", L"组间恢复：5 秒");
        }
        audio_label = Tr(L"Packet: ", L"数据包：") +
                      std::to_wstring(round.payload_bytes) +
                      Tr(L" B · ", L" 字节 · ") +
                      std::to_wstring(round.packets_per_second) +
                      Tr(L" pkt/s · burst ", L" 包/秒 · 每批 ") +
                      std::to_wstring(round.burst_packets);
      }
    } else if (running_ && network_probe_active_) {
      heading = Tr(L"Network test ready", L"网络测试待连接");
      detail = Tr(L"Connect the iPad to begin the network test.",
                  L"连接 iPad 后开始网络测试。");
      audio_label = Tr(L"Test data only; no audio is sent.",
                       L"仅传输测试数据，不发送音频。");
    } else if (running_ && connected_) {
      heading = usb_connected_ ? Tr(L"iPad connected via USB", L"iPad 已通过 USB 连接") : Tr(L"iPad connected via network", L"iPad 已通过网络连接");
      if (service_) {
        const auto format = service_->audio_format();
        std::wostringstream description;
        description << Tr(L"Audio: ", L"音频：") << (format.opus ? L"Opus" : L"PCM")
                    << L" · ";
        if (!format.opus)
          description << format.pcm.rate / 1000.0 << L" kHz / " << format.pcm.bits << L" bit · ";
        description << format.bitrate / 1000.0 << L" kb/s · " << format.frames / 48.0 << L" ms";
        detail = description.str();
      }
    } else if (running_ && completed_test_) {
      heading = completed_test_ == kMusicTest
          ? Tr(L"Music compression test complete · 32/32", L"音乐压缩对比已完成 · 32/32")
          : completed_test_ == kNetworkProbe
              ? Tr(L"Network test complete", L"网络测试已完成")
              : Tr(L"Live diagnostics complete", L"实时诊断已完成");
      detail = Tr(L"iPad report received and saved in the diagnostics folder.",
                  L"iPad 报告已回收并保存到诊断文件夹。");
    } else if (running_) {
      heading = Tr(L"Ready for iPad", L"已就绪，等待 iPad 连接");
      const auto usb = host_ ? host_->usb_status() : std::string{};
      detail = usb.find("Apple device service unavailable") != std::string::npos
          ? Tr(L"Network ready. Install Apple device support for USB.", L"网络已就绪；USB 需要安装 Apple 设备支持服务。")
          : Tr(L"Searching network and USB; USB has priority.", L"同时等待网络与 USB 连接，优先使用 USB。");
    } else {
      heading = Tr(L"Sender stopped", L"发送服务已停止");
      detail = error_.empty()
                   ? Tr(L"Start the sender to make this PC available.",
                        L"启动后，这台电脑即可供 iPad 连接。")
                   : error_;
    }
    main_window_->SetActions(running_, !unpair_pending_, paired_,
        !unpair_pending_ && (paired_ || (running_ && !connected_)));
    main_window_->SetCertificate(certificate_ready_
        ? Tr(L"Secure connection: certificate ready", L"安全连接：证书已就绪")
        : Tr(L"Secure connection: preparing certificate", L"安全连接：正在准备证书"));
    const auto port_text = Tr(L"Listening port: UDP ", L"监听端口：UDP ") + std::to_wstring(port_);
    main_window_->SetStatus(heading, detail, audio_label, port_text);
    if (pin_expires_ && Clock::now() >= *pin_expires_) pin_expires_.reset();
    if (pin_expires_) {
      const std::string pin = host_ ? host_->pairing_pin() : std::string{};
      if (pin.size() < 6) {
        pin_expires_.reset();
      } else {
        const auto seconds = std::chrono::ceil<std::chrono::seconds>(
            *pin_expires_ - Clock::now()).count();
        const std::wstring digits(pin.begin(), pin.end());
        const std::wstring countdown = std::to_wstring(seconds / 60) + L":" +
                                       (seconds % 60 < 10 ? L"0" : L"") +
                                       std::to_wstring(seconds % 60);
        const std::wstring label = Tr(L"Pairing PIN: ", L"配对码：") +
                                   digits.substr(0, 3) + L" " + digits.substr(3) +
                                   Tr(L"  ·  Time left ", L"  ·  剩余 ") + countdown;
        main_window_->SetPairing(label);
      }
    }
    if (!pin_expires_) {
      const std::wstring pairing_hint =
          !running_ ? Tr(L"Start the sender to enable pairing.",
                         L"启动发送服务后可以开始配对。")
                    : connected_ ? Tr(L"An iPad is connected.",
                                      L"当前有 iPad 已连接。")
                    : paired_ ? Tr(L"The paired iPad can reconnect.", L"已配对的 iPad 可以重新连接。")
                                 : Tr(L"Choose Pair new iPad to show a code.",
                                      L"点击“配对新 iPad”显示配对码。");
      main_window_->SetPairing(pairing_hint);
    }
  }

  void ForgetPairing() {
    if (unpair_pending_) return;
    main_window_->Confirm(Tr(L"Unpair this iPad and end the current connection?", L"取消与 iPad 的配对并结束当前连接？"),
                         Tr(L"Unpair", L"取消配对").c_str(), [this] { RemovePairing(); });
  }

  void RemovePairing() {
    if (unpair_pending_) return;
    const bool restart = running_;
    if (!(host_ ? host_->RemovePairing() : hearport::windows::ProtectedCredentialStore{}.Remove())) {
      main_window_->Notify(Tr(L"Could not remove the saved pairing.", L"无法删除保存的配对。"));
      return;
    }
    paired_ = false;
    if (restart) {
      unpair_pending_ = true;
      unpair_session_directory_ = service_ ? service_->debug_session_directory() : std::filesystem::path{};
      service_ = nullptr; running_ = false; connected_ = false; pin_expires_.reset();
      unpair_worker_ = std::thread([this, closing = std::move(host_)]() mutable {
        closing->Stop(3);
        closing.reset();
        PostMessageW(hwnd_, kUnpairCompletedMessage, 0, 0);
      });
    }
    UpdateStatus();
  }

  void StartService(std::optional<std::chrono::seconds> diagnostics = std::nullopt,
                    bool network_probe = false,
                    std::shared_ptr<const hearport::windows::MusicExcerpt> music = nullptr,
                    bool calibration = false) {
    if (running_ || unpair_pending_) return;
    error_.clear();
    paired_ = hearport::windows::ProtectedCredentialStore{}.Load().has_value();
    if (data_dir_.empty()) {
      error_ = Tr(L"Cannot find the local data folder.",
                  L"无法找到本地数据文件夹。");
      UpdateStatus();
      return;
    }
    std::error_code file_error;
    std::filesystem::create_directories(data_dir_ / L"diagnostics", file_error);
    if (file_error) {
      error_ = Tr(L"Cannot create the local data folder.",
                  L"无法创建本地数据文件夹。");
      UpdateStatus();
      return;
    }
    auto identity = hearport::windows::LoadOrCreateSenderIdentity();
    certificate_ready_ = identity.has_value();
    if (!identity) {
      error_ = Tr(L"Could not prepare a TLS certificate.",
                  L"无法自动准备连接证书。");
      UpdateStatus();
      return;
    }
    identity->port = port_;
    const bool logging_ready = logger_.Start(data_dir_ / L"HearPort-sender.log");
    if (!logging_ready) {
      main_window_->SetDiagnostic(Tr(L"The sender log could not be opened.",
                        L"无法打开运行日志。")
                         );
    }
    identity->diagnostic_log = [this](std::string_view line) {
      logger_.TryLog(line);
    };
    host_ = std::make_unique<hearport::windows::SenderHost>(*identity, data_dir_ / L"diagnostics");
    host_->Configure([&](SenderService& service) {
      service.ConfigureCaptureSource(capture_source_);
      service.ConfigurePcmLimits(pcm_limits_);
      service.ConfigureNetworkProbe(network_probe);
      service.ConfigureDebugDuration(diagnostics);
      if (calibration) service.ConfigureCalibration({static_cast<std::uint16_t>(calibration_seconds_), static_cast<std::uint16_t>(calibration_maximum_), calibration_goal_});
      if (music) service.ConfigureMusicTest(music);
      service.SetDebugOutputDirectory(data_dir_ / L"diagnostics");
    });
    service_ = &host_->service();
    diagnostics = service_->debug_duration();
    host_->SetConnectionHandler([this](bool connected, bool reliable, hearport::windows::PhysicalPath path) {
      PostMessageW(hwnd_, kConnectionMessage, connected, (reliable ? 1 : 0) | (path == hearport::windows::PhysicalPath::usb ? 2 : 0));
    });
    host_->SetCalibrationRequestHandler([this](hearport::windows::CalibrationOptions options) {
      PostMessageW(hwnd_, kCalibrationRequestMessage, options.seconds | (options.goal << 16), options.maximum_ms);
    });
    if (!host_->Start()) {
      host_.reset();
      service_ = nullptr;
      logger_.Stop();
      error_ = network_probe
                   ? Tr(L"Could not start the network listener.", L"无法启动网络监听。")
                   : Tr(L"Could not start audio capture or the network listener.",
                        L"无法启动音频采集或网络监听。");
      UpdateStatus();
      return;
    }
    running_ = true;
    completed_test_ = 0;
    connected_ = false;
    diagnostic_duration_ = service_->debug_duration();
    network_probe_active_ = network_probe;
    music_test_active_ = bool(music);
    if (diagnostics) {
      diagnostic_started_ = Clock::now();
      const auto message = network_probe
          ? Tr(L"Connect the iPad to begin the automatic network test.",
               L"请连接 iPad，开始自动网络测试。")
          : Tr(L"Waiting for iPad and its diagnostic report…",
               L"正在等待 iPad 连接并传回诊断报告……");
      main_window_->SetDiagnostic(message);
    }
    UpdateStatus();
  }

  void StopService() {
    const auto session_directory = unpair_pending_ ? unpair_session_directory_ :
        (service_ ? service_->debug_session_directory() : std::filesystem::path{});
    if (unpair_worker_.joinable()) unpair_worker_.join();
    unpair_pending_ = false; unpair_session_directory_.clear();
    if (host_) host_->Stop();
    host_.reset();
    service_ = nullptr;
    FinishServiceStop(session_directory);
  }

  void FinishServiceStop(const std::filesystem::path& session_directory) {
    logger_.Stop();
    if (!session_directory.empty()) {
      std::error_code archive_error;
      std::filesystem::copy_file(data_dir_ / L"HearPort-sender.log",
                                 session_directory / L"sender.log",
                                 std::filesystem::copy_options::overwrite_existing,
                                 archive_error);
      if (archive_error) {
        error_ = Tr(L"Could not save the sender session log.",
                    L"无法保存本轮服务端日志。");
      }
    }
    running_ = false;
    connected_ = false;
    diagnostic_duration_.reset();
    network_probe_active_ = false;
    music_test_active_ = false;
    pin_expires_.reset();
    UpdateStatus();
  }

  void OpenPairing() {
    if (!running_ || !host_) return;
    if (!host_->OpenPairingWindow()) {
      main_window_->Notify(Tr(L"Could not open pairing. Check the security provider.",
                             L"无法开启配对，请检查安全组件。"));
      return;
    }
    pin_expires_ = Clock::now() + std::chrono::minutes(2);
    UpdateStatus();
  }

  void ConfirmExit() {
    ShowWindowFromTray();
    main_window_->Confirm(Tr(L"Exit HearPort and stop sending audio?", L"确定退出 HearPort 并停止发送声音吗？"),
                         Tr(L"Exit", L"退出").c_str(), [this] {
      Shutdown();
      MainWindow::ExitApp();
    });
  }

  void Shutdown() {
    if (std::exchange(shutting_down_, true)) return;
    KillTimer(hwnd_, kTimer);
    tray_popup_.reset();
    RemoveTrayIcon();
    if (tray_connection_icon_) DestroyIcon(std::exchange(tray_connection_icon_, nullptr));
    StopService();
  }

  void StartDiagnostics() {
    StopService();
    StartService(std::chrono::seconds(std::stoul(live_seconds_)));
    SelectPage(0);
  }

  void StartNetworkProbe() {
    StopService();
    StartService(std::chrono::seconds(
                     hearport::windows::kCoordinatedProbeDurationSeconds), true, nullptr, calibration_selected_);
    if (!running_) {
      main_window_->SetDiagnostic(Tr(L"Could not start the network test. Check the overview and log.",
                        L"无法启动网络测试，请查看概览和运行日志。")
                         );
    }
    SelectPage(0);
  }

  void ShowTestSettings(MainAction test) {
    TestSettings settings;
    settings.file = music_path_;
    settings.start = music_start_seconds_;
    settings.duration = test == MainAction::music_test ? music_seconds_ : live_seconds_;
    settings.recommendations = calibration_selected_;
    settings.maximum = calibration_maximum_;
    settings.round_seconds = calibration_seconds_;
    main_window_->ConfigureTest(test, std::move(settings), [this, test](TestSettings values) {
      if (test == MainAction::music_test) {
        music_path_ = std::move(values.file);
        music_start_seconds_ = std::move(values.start);
        music_seconds_ = std::move(values.duration);
        StartMusicTest();
      } else if (test == MainAction::network_test) {
        calibration_goal_ = 0;
        calibration_selected_ = values.recommendations;
        calibration_maximum_ = values.maximum;
        calibration_seconds_ = values.round_seconds;
        StartNetworkProbe();
      } else {
        live_seconds_ = std::move(values.duration);
        StartDiagnostics();
      }
    });
  }

  void ShowCalibrationResults() {
    const auto read = [](const std::filesystem::path& path) {
      std::ifstream file(path,std::ios::binary);
      return hearport::windows::ParseCalibrationReport(std::string(std::istreambuf_iterator<char>(file),{}));
    };
    calibration_report_ = read(calibration_report_path_);
    if (!calibration_report_) {
      std::error_code error;
      std::filesystem::file_time_type latest = std::filesystem::file_time_type::min();
      for (const auto& entry : std::filesystem::directory_iterator(data_dir_ / L"diagnostics",error)) {
        const auto path = entry.path() / L"ipad-report.txt";
        const auto time = std::filesystem::last_write_time(path,error);
        if (error || time <= latest) { error.clear(); continue; }
        if (auto result = read(path)) { latest = time; calibration_report_ = std::move(result); calibration_report_path_ = path; }
      }
    }
    if (!calibration_report_) {
      main_window_->Notify(Tr(L"No recommendation report is available. Select Automatic test and parameter recommendations in Network test settings.",
          L"尚无推荐参数报告，请在网络测试设置中选择“自动测试并推荐参数”。")); return;
    }
    const auto& report = *calibration_report_;
    std::wostringstream text; text << std::fixed << std::setprecision(3);
    text << (report.complete ? Tr(L"Complete observation",L"完整观测") : Tr(L"Incomplete observation; no validated recommendation",L"观测不完整；不能视为完整推荐")) << L" · " << report.seconds << Tr(L" s/round · ceiling ",L" 秒／组 · 上限 ") << report.ceiling_ms << L" ms\r\n\r\n";
    const auto measurement = [&](const auto& point) {
      text << (point.reliable ? L"Reliable" : L"Datagram") << L" · " << point.budget.target_ms << L"/" << point.budget.maximum_ms << Tr(L" ms (target/max) · reserve ",L" 毫秒（目标／最大）· 输出预留 ") << point.reserve_ms << L" ms\r\n";
      text << Tr(L"Source age P95: ",L"源年龄 P95：");
      if (point.age_p95_ms) text << *point.age_p95_ms; else text << L"—";
      text << L" ms · " << Tr(L"gap ",L"缺口 ") << point.gap_ratio*100 << L"% · " << Tr(L"longest ",L"最长 ") << point.longest_gap_ms << L" ms\r\n";
      if (point.gap_ratio == 0) text << Tr(L"No gaps observed in this sample.\r\n",L"本次样本未观察到缺口。\r\n");
    };
    text << Tr(L"Profile targets: Low latency <=0.5% gaps and <=40 ms longest; Balanced <=0.1% and <=20 ms. Stability first minimizes gap ratio, then longest gap, then source age within the chosen ceiling.\r\n\r\n",
        L"档位目标：低延迟缺口≤0.5%且最长≤40 毫秒；平衡≤0.1%且最长≤20 毫秒。稳定优先在所选上限内依次减少缺口占比、最长缺口及源年龄。\r\n\r\n");
    for (const auto& profile : report.profiles) {
      text << (profile.profile == 1 ? Tr(L"Low latency",L"低延迟") : profile.profile == 2 ? Tr(L"Balanced",L"平衡") : Tr(L"Stability first",L"稳定优先")) << L" · ";
      text << (profile.status == "observed" ? Tr(L"Observed in both repeats",L"两次复核已观测") : profile.status == "provisional" ? Tr(L"Provisional: live gaps worsened",L"暂定：复核缺口变差") : profile.status == "not_met" ? Tr(L"Live validation missed target",L"复核未达目标") : profile.status == "incomplete" ? Tr(L"Incomplete",L"不完整") : Tr(L"No qualifying recommendation",L"无达标推荐")) << L"\r\n";
      if (profile.met_goal) {
        measurement(profile);
        for (const auto& point : report.validation) if (point.reliable == profile.reliable && point.budget == profile.budget) {
          text << Tr(L"Live round ",L"实际复核第 ") << point.round << L"\r\n"; measurement(point);
          text << Tr(L"Source unavailable / output interruption: ",L"源缺失／输出中断占比：") << point.source_gap_ratio*100 << L"% / " << point.output_gap_ratio*100 << L"% · " << Tr(L"startup ",L"启动等待 ") << point.startup_ms << L" ms\r\n";
        }
      }
      text << L"\r\n";
    }
    text << Tr(L"Sampling curve details (each configuration uses identical input within its transport):\r\n",L"采样曲线详情（各传输模式内，各配置使用相同输入）：\r\n");
    for (const auto& point : report.curve) { measurement(point); if (!point.valid) text << Tr(L"Insufficient valid data\r\n",L"有效数据不足\r\n"); }
    text << Tr(L"\r\nApply profiles in the iPad's Settings > Automatic test and recommendations for the next connection.\r\nFinite observation only. Zero observed gaps do not guarantee future stability. Replay is conditional on sampling sender behavior; live validation uses new traffic, so differences may be network fluctuation. Source age includes estimated output reserve; audio DSP/render/acoustic latency was not measured. Source and output gaps are different axes and are not added.\r\n",
        L"\r\n请在 iPad 设置→自动测试并推荐参数中选择档位，下次连接生效。\r\n仅为有限样本观测。零缺口不是未来保证。回放依赖采样时的发送行为；实际复核使用新流量，差异可能来自网络波动。源年龄含估计输出预留，未测音频 DSP、实际输出或声学延迟。源缺失与输出中断是两条时间轴，不能相加。\r\n");
    std::vector<RecommendationPoint> points;
    for (const auto& point : report.curve) {
      if (point.valid && point.age_p95_ms)
        points.push_back({*point.age_p95_ms, point.gap_ratio, point.reliable});
    }
    main_window_->ShowRecommendations(text.str(), points);
  }

  void StartMusicTest() {
    try {
      SetCursor(LoadCursorW(nullptr,IDC_WAIT));
      auto clip = std::make_shared<const hearport::windows::MusicExcerpt>(
          hearport::windows::LoadMusicExcerpt(music_path_, std::stoul(music_start_seconds_),
                                             std::stoul(music_seconds_)));
      StopService();
      StartService(std::nullopt,false,std::move(clip));
      SelectPage(0);
      SetCursor(LoadCursorW(nullptr,IDC_ARROW));
    } catch (const std::exception& error) {
      SetCursor(LoadCursorW(nullptr,IDC_ARROW));
      const std::string message = error.what();
      const auto text = Tr(L"Could not decode the complete excerpt. Check the file and selected time range.\n",L"无法解码完整片段，请检查文件及所选时间范围。\n") +
          std::wstring(message.begin(),message.end());
      main_window_->Notify(text);
    }
  }

  void SaveCaptureSourceFromControl() {
    const auto selection = main_window_->capture();
    if (selection != 0 && selection != 1) return;
    const auto source = selection == 1 ? CaptureSource::endpoint : CaptureSource::process;
    if (source == capture_source_) return;
    if (!SaveSetting(L"CaptureSource", static_cast<DWORD>(selection))) {
      main_window_->SetCapture(capture_source_ == CaptureSource::endpoint ? 1 : 0);
      main_window_->Notify(Tr(L"Could not save audio capture settings.",
                             L"无法保存音频采集设置。"));
      return;
    }
    capture_source_ = source;
    if (running_) {
      StopService();
      StartService();
    }
    UpdateStatus();
  }

  std::wstring SavePort(std::uint16_t value) {
    if (!SaveSetting(L"Port", value)) {
      return Tr(L"Could not save the port.", L"无法保存端口。");
    }
    const bool restart = running_ && value != port_;
    port_ = static_cast<std::uint16_t>(value);
    main_window_->SetPort(port_);
    if (restart) {
      const auto diagnostics = diagnostic_duration_;
      const bool network_probe = network_probe_active_;
      const bool music = music_test_active_;
      StopService();
      if (music) StartMusicTest(); else StartService(diagnostics, network_probe);
      if (diagnostics && !running_) {
        main_window_->SetDiagnostic(Tr(L"Diagnostics stopped because the sender could not restart on the new port.",
                          L"诊断已中断：无法使用新端口重启发送服务。")
                           );
      }
    } else {
      UpdateStatus();
    }
    return {};
  }

  void RefreshSystemPcm() {
    const auto current = hearport::windows::ReadSystemPcmResolution().value_or(PcmResolution{});
    if (current != system_pcm_) {
      system_pcm_ = current;
      main_window_->SetSystemPcmResolution(current.rate, current.bits);
    }
    if (service_ && current.rate && current.bits) service_->SetSystemPcmResolution(current);
  }

  void OnTimer() {
    if ((connected_ || (main_window_->page() == 2 && IsWindowVisible(hwnd_))) &&
        Clock::now() >= next_pcm_refresh_) {
      next_pcm_refresh_ = Clock::now() + std::chrono::seconds(3);
      RefreshSystemPcm();
    }
    if (host_ && connected_ && !volume_editing_) {
      host_->RequestSystemVolume(std::nullopt);
    }
    if (running_ || pin_expires_) UpdateStatus();
    if (!diagnostic_duration_ || !service_) return;
    if (service_->WaitForDebugCompletion(std::chrono::milliseconds(0))) {
      const bool succeeded = service_->debug_test_succeeded();
      const int completed_test = music_test_active_ ? kMusicTest :
          network_probe_active_ ? kNetworkProbe : kDiagnostics;
      const bool local_calibration = service_->adaptive_calibration();
      if (service_->environment_calibration() && !local_calibration) calibration_report_path_ = service_->debug_session_directory() / L"ipad-report.txt";
      completed_test_ = succeeded && !local_calibration ? completed_test : 0;
      music_test_active_ = false;
      network_probe_active_ = false;
      connected_ = false;
      UpdateStatus();
      main_window_->SetDiagnostic((local_calibration ? Tr(L"Automatic test completed; results are available on iPad.",L"自动测试已完成；结果在 iPad 上查看和应用。") : Tr(L"Diagnostic report saved in the report folder.",
                        L"诊断报告已保存到报告文件夹。"))
                         );
      StopService();
      StartService();
      completed_test_ = running_ && succeeded && !local_calibration ? completed_test : 0;
      UpdateStatus();
      if (!succeeded) main_window_->SetDiagnostic(Tr(L"Test interrupted; the available report was saved. It is not a complete comparison.",
             L"测试已中断，现有报告已保存；本次不是完整对照。"));
    } else if (Clock::now() - diagnostic_started_ >
               *diagnostic_duration_ + std::chrono::minutes(7)) {
      StopService();
      StartService();
      main_window_->SetDiagnostic(Tr(L"Diagnostic session ended without a completed report. Check the log.",
                        L"诊断未收到完整报告，请查看运行日志。")
                         );
    }
  }

  void OpenPath(const std::filesystem::path& path) {
    if (reinterpret_cast<INT_PTR>(ShellExecuteW(
            hwnd_, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <=
        32) {
      main_window_->Notify(Tr(L"Could not open this location.",
                             L"无法打开此位置。"));
    }
  }

  void StopSender() {
    const bool diagnostic_active = diagnostic_duration_.has_value();
    StopService();
    if (diagnostic_active) main_window_->SetDiagnostic(Tr(L"Diagnostic session stopped.", L"诊断已停止。"));
  }

  void ToggleSender() {
    if (unpair_pending_) return;
    if (!running_) { StartService(); return; }
    main_window_->Confirm(Tr(L"Stop sending audio to the iPad?", L"停止向 iPad 发送声音吗？"),
                         Tr(L"Stop", L"停止").c_str(), [this] { StopSender(); });
  }

  void HandleAction(MainAction action) {
    switch (action) {
      case MainAction::pair: if (paired_) ForgetPairing(); else OpenPairing(); break;
      case MainAction::sender: ToggleSender(); break;
      case MainAction::live_test:
      case MainAction::network_test:
      case MainAction::music_test: ShowTestSettings(action); break;
      case MainAction::log: OpenPath(data_dir_ / L"HearPort-sender.log"); break;
      case MainAction::reports: OpenPath(data_dir_ / L"diagnostics"); break;
      case MainAction::results: ShowCalibrationResults(); break;
      case MainAction::detailed_logging: logger_.SetDetailedLogging(main_window_->detailed_logging()); break;
      case MainAction::port: main_window_->EditPort([this](std::uint16_t value) { return SavePort(value); }); break;
      case MainAction::capture: SaveCaptureSourceFromControl(); break;
      case MainAction::auto_start:
        if (!SetAutoStart(main_window_->auto_start())) {
          main_window_->SetAutoStart(AutoStartEnabled());
          main_window_->Notify(Tr(L"Could not change startup settings.", L"无法修改开机启动设置。"));
        }
        break;
      case MainAction::hide: SendMessageW(hwnd_, WM_CLOSE, 0, 0); break;
      case MainAction::exit: ConfirmExit(); break;
    }
  }

  LRESULT Handle(UINT message, WPARAM wparam, LPARAM lparam) {
    if (taskbar_created_ != 0 && message == taskbar_created_) {
      AddTrayIcon();
      return 0;
    }
    switch (message) {
      case kStartMessage:
        StartService();
        return 0;
      case kUnpairCompletedMessage:
        if (unpair_pending_) {
          StopService();
          StartService(); OpenPairing();
        }
        return 0;
      case kCalibrationRequestMessage:
        if (running_ && service_ && !service_->debug_duration() &&
            !service_->network_probe() && !service_->music_test() && !service_->environment_calibration() &&
            ((LOWORD(wparam) == 15 && HIWORD(wparam)) || LOWORD(wparam) == 30 || LOWORD(wparam) == 60 || LOWORD(wparam) == 120) && lparam >= 20 && lparam <= 2000) {
          calibration_seconds_ = LOWORD(wparam);
          calibration_goal_ = static_cast<std::uint8_t>(HIWORD(wparam));
          calibration_maximum_ = static_cast<unsigned>(lparam);
          StopService();
          StartService(std::nullopt, true, nullptr, true);
          SelectPage(0);
        }
        return 0;
      case kConnectionMessage:
        if (unpair_pending_) return 0;
        if (connected_ != (wparam != 0) || usb_connected_ != ((lparam & 2) != 0)) ResetLinkStability();
        connected_ = wparam != 0;
        usb_connected_ = (lparam & 2) != 0;
        if (host_) service_ = &host_->service();
        paired_ = hearport::windows::ProtectedCredentialStore{}.Load().has_value();
        if (connected_) {
          pin_expires_.reset();
          if (host_) host_->RequestSystemVolume(std::nullopt);
        }
        UpdateStatus();
        return 0;
      case WM_TIMER:
        if (wparam == kTimer) OnTimer();
        return 0;
      case WM_SIZE:
        if (wparam == SIZE_MINIMIZED && tray_ready_) ShowWindow(hwnd_, SW_HIDE);
        break;
      case WM_SETTINGCHANGE:
      case WM_THEMECHANGED:
        ApplyTheme();
        break;
      case WM_COMMAND:
        if (LOWORD(wparam) == kTrayOpen) ShowWindowFromTray();
        if (LOWORD(wparam) == kTrayExit) ConfirmExit();
        break;
      case kTrayMessage:
        switch (LOWORD(lparam)) {
          case WM_LBUTTONDBLCLK:
            suppress_tray_select_until_ = Clock::now() + std::chrono::milliseconds(GetDoubleClickTime());
            SelectPage(0);
            ShowWindowFromTray();
            break;
          case NIN_SELECT:
            // The shell sends a final select after the double-click's button-up.
            if (std::exchange(suppress_tray_select_until_, {}) > Clock::now()) break;
            [[fallthrough]];
          case NIN_KEYSELECT:
            ToggleTrayPopup({GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
            break;
          case WM_RBUTTONUP:
          case WM_CONTEXTMENU:
            ShowTrayMenu();
            break;
        }
        return 0;
      case WM_CLOSE:
        if (tray_ready_) {
          ShowWindow(hwnd_, SW_HIDE);
        } else {
          ConfirmExit();
        }
        return 0;
      case WM_DESTROY:
        Shutdown();
        break;
    }
    return DefSubclassProc(hwnd_, message, wparam, lparam);
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
    auto* app = reinterpret_cast<Application*>(data);
    if (message == WM_NCDESTROY) RemoveWindowSubclass(hwnd, WindowProc, id);
    return app->Handle(message, wparam, lparam);
  }

  HINSTANCE instance_ = nullptr;
  HWND hwnd_ = nullptr;
  std::unique_ptr<MainWindow> main_window_;
  std::unique_ptr<TrayPopup> tray_popup_;
  bool volume_editing_ = false;
  bool volume_available_ = false;
  std::uint32_t volume_position_ = 0;
  bool paired_ = false;
  UINT taskbar_created_ = 0;
  bool calibration_selected_ = true;
  std::uint8_t calibration_goal_ = 0;
  unsigned calibration_seconds_ = 30, calibration_maximum_ = 100;
  std::filesystem::path calibration_report_path_;
  std::optional<hearport::windows::CalibrationReport> calibration_report_;
  std::wstring music_path_, music_start_seconds_ = L"0", music_seconds_ = L"120", live_seconds_ = L"60";
  bool music_test_active_ = false;
  bool start_hidden_ = false;
  bool shutting_down_ = false;
  bool running_ = false;
  bool connected_ = false;
  bool usb_connected_ = false;
  std::optional<Clock::time_point> link_started_, last_link_poll_, last_link_response_, link_improvement_at_;
  std::deque<std::pair<Clock::time_point, double>> link_observations_;
  std::uint64_t last_link_ack_ = 0;
  LinkStability link_stability_ = LinkStability::unknown, link_improving_to_ = LinkStability::unknown;
  bool certificate_ready_ = false;
  bool tray_ready_ = false;
  struct TrayLink {
    bool running = false;
    bool connected = false;
    bool usb = false;
    LinkStability stability = LinkStability::unknown;
    bool operator==(const TrayLink&) const = default;
  } tray_link_;
  HICON tray_connection_icon_ = nullptr;
  Clock::time_point suppress_tray_select_until_{};
  bool dark_ = false;
  std::uint16_t port_ = 52137;
  CaptureSource capture_source_ = LoadCaptureSource();
  PcmResolution pcm_limits_{LoadPcmLimit(L"PcmSampleRateLimit", 8000, 48000),
                            LoadPcmLimit(L"PcmBitDepthLimit", 8, 32)};
  PcmResolution system_pcm_{};
  Clock::time_point next_pcm_refresh_{};
  std::wstring error_;
  std::filesystem::path data_dir_;
  std::optional<Clock::time_point> pin_expires_;
  std::optional<std::chrono::seconds> diagnostic_duration_;
  bool network_probe_active_ = false;
  int completed_test_ = 0;
  Clock::time_point diagnostic_started_{};
  SenderDiagnosticLogger logger_;
  std::unique_ptr<hearport::windows::SenderHost> host_;
  std::thread unpair_worker_;
  bool unpair_pending_ = false;
  std::filesystem::path unpair_session_directory_;
  SenderService* service_ = nullptr;
};

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR command_line,
                    int show_command) {
  HANDLE singleton = CreateMutexW(nullptr, TRUE, L"Local\\HearPortSenderGui");
  if (singleton && GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = FindWindowW(nullptr, L"HearPort")) {
      ShowWindow(existing, SW_RESTORE);
      SetForegroundWindow(existing);
    }
    CloseHandle(singleton);
    return 0;
  }
  const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int result = 1;
  {
    auto app = std::make_unique<Application>(command_line &&
                    std::wstring_view(command_line).find(L"--background") !=
                        std::wstring_view::npos);
    const auto status = MainWindow::RunApp([&] {
      result = app->Launch(instance, show_command);
      if (result) MainWindow::ExitApp();
    }, [&] { app.reset(); });
    if (FAILED(status)) {
      result = 1;
      MessageBoxW(nullptr, Tr(L"Could not start HearPort. Install Windows App Runtime 2.6.5 or newer.",
                             L"无法启动 HearPort。请安装 Windows App Runtime 2.6.5 或更高版本。").c_str(),
                  L"HearPort", MB_OK | MB_ICONERROR);
    }
  }
  if (SUCCEEDED(apartment)) CoUninitialize();
  if (singleton) CloseHandle(singleton);
  return result;
}
