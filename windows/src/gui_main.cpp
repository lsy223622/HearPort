#define _WIN32_WINNT 0x0A00
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <iphlpapi.h>
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <uxtheme.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "gui_resources.h"
#include "hearport/windows/diagnostic_logger.h"
#include "hearport/windows/sender_authentication.h"
#include "hearport/windows/sender_certificate.h"
#include "hearport/windows/sender_service.h"
#include "hearport/windows/sender_host.h"
#include "hearport/windows/network_probe.h"

namespace {

using hearport::windows::SenderAuthentication;
using hearport::windows::SenderDiagnosticLogger;
using hearport::windows::SenderService;
using Clock = std::chrono::steady_clock;

constexpr wchar_t kWindowClass[] = L"HearPortSenderGui";
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kStartMessage = WM_APP + 2;
constexpr UINT kConnectionMessage = WM_APP + 3;
constexpr UINT kCalibrationRequestMessage = WM_APP + 4;
constexpr UINT kTimer = 1;
constexpr UINT kTrayIcon = 1;
constexpr int kTab = 100;
constexpr int kPair = 101;
constexpr int kToggle = 102;
constexpr int kLog = 103;
constexpr int kReports = 104;
constexpr int kDiagnostics = 105;
constexpr int kPort = 107;
constexpr int kSavePort = 108;
constexpr int kAutoStart = 109;
constexpr int kNetworkProbe = 110;
constexpr int kCloseWindow = 112;
constexpr int kExitApplication = 113;
constexpr int kMusicFile = 114;
constexpr int kMusicTest = 115;
constexpr int kCalibrationResults = 116;
constexpr int kDetailedLogging = 117;
constexpr int kTrayOpen = 201;
constexpr int kTrayExit = 202;

std::wstring Tr(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE
             ? chinese
             : english;
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

bool SavePort(std::uint16_t port) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\HearPort", 0, nullptr,
                      0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
      ERROR_SUCCESS) {
    return false;
  }
  const DWORD value = port;
  const bool saved = RegSetValueExW(key, L"Port", 0, REG_DWORD,
                                    reinterpret_cast<const BYTE*>(&value),
                                    sizeof(value)) == ERROR_SUCCESS;
  RegCloseKey(key);
  return saved;
}

bool AutoStartEnabled() {
  wchar_t value[32768]{};
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                      L"HearPort", RRF_RT_REG_SZ, nullptr, value,
                      &size) == ERROR_SUCCESS;
}

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
    const std::wstring command = L"\"" + path + L"\" --background";
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

  int Run(HINSTANCE instance, int show_command) {
    instance_ = instance;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    INITCOMMONCONTROLSEX common_controls{sizeof(common_controls), ICC_TAB_CLASSES};
    InitCommonControlsEx(&common_controls);

    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = instance;
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
    window_class.lpszClassName = kWindowClass;
    if (!RegisterClassExW(&window_class)) return 1;

    const UINT initial_dpi = GetDpiForSystem();
    dpi_ = initial_dpi;
    hwnd_ = CreateWindowExW(WS_EX_DLGMODALFRAME, kWindowClass, L"HearPort",
                            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
                                WS_MINIMIZEBOX,
                            CW_USEDEFAULT, CW_USEDEFAULT,
                            MulDiv(520, initial_dpi, 96),
                            MulDiv(500, initial_dpi, 96), nullptr, nullptr,
                            instance, this);
    if (!hwnd_) return 1;
    if (!start_hidden_ || !tray_ready_) ShowWindow(hwnd_, show_command);
    UpdateWindow(hwnd_);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
      if (!IsDialogMessageW(hwnd_, &message)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
    }
    return static_cast<int>(message.wParam);
  }

 private:
  HWND Control(int page, const wchar_t* kind, const std::wstring& label,
               DWORD style, int id = 0) {
    HWND control = CreateWindowExW(
        0, kind, label.c_str(), WS_CHILD | style, 0, 0, 0, 0, hwnd_,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), instance_, nullptr);
    if (control) {
      pages_[page].push_back(control);
      SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    }
    return control;
  }

  HWND Group(int page, const std::wstring& label) {
    HWND group = CreateWindowExW(0, L"BUTTON", label.c_str(),
                                  WS_CHILD | BS_GROUPBOX, 0, 0, 0, 0, hwnd_,
                                  nullptr, instance_, nullptr);
    if (group) {
      groups_[page].push_back(group);
      SendMessageW(group, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
      SetWindowSubclass(group, GroupSubclassProc, 1,
                        reinterpret_cast<DWORD_PTR>(this));
    }
    return group;
  }

  void Place(HWND control, int x, int y, int width, int height) const {
    if (!control) return;
    MoveWindow(control, MulDiv(x, dpi_, 96), MulDiv(y, dpi_, 96),
               MulDiv(width, dpi_, 96), MulDiv(height, dpi_, 96), TRUE);
  }

  void CreateFontForDpi() {
    HFONT old_font = font_;
    font_ = CreateFontW(-MulDiv(12, dpi_, 96), 0, 0, 0, FW_NORMAL, FALSE,
                        FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                        DEFAULT_PITCH, L"Segoe UI");
    if (tabs_) SendMessageW(tabs_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    for (auto& page : groups_) {
      for (HWND group : page) {
        SendMessageW(group, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
      }
    }
    for (auto& page : pages_) {
      for (HWND control : page) {
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
      }
    }
    if (footer_close_) SendMessageW(footer_close_, WM_SETFONT,
                                    reinterpret_cast<WPARAM>(font_), TRUE);
    if (footer_exit_) SendMessageW(footer_exit_, WM_SETFONT,
                                   reinterpret_cast<WPARAM>(font_), TRUE);
    if (old_font) DeleteObject(old_font);
  }

  void PaintGroup(HWND group, HDC context) {
    RECT bounds{};
    GetClientRect(group, &bounds);
    wchar_t label[128]{};
    GetWindowTextW(group, label, ARRAYSIZE(label));
    HFONT previous_font = reinterpret_cast<HFONT>(
        SelectObject(context, font_));
    SIZE text_size{};
    GetTextExtentPoint32W(context, label, lstrlenW(label), &text_size);
    const int line_y = text_size.cy / 2;
    HPEN pen = CreatePen(PS_SOLID, 1, dark_ ? RGB(108, 108, 108)
                                            : GetSysColor(COLOR_3DLIGHT));
    HPEN previous_pen = reinterpret_cast<HPEN>(SelectObject(context, pen));
    MoveToEx(context, 0, line_y, nullptr);
    LineTo(context, 8, line_y);
    MoveToEx(context, 18 + text_size.cx, line_y, nullptr);
    LineTo(context, bounds.right - 1, line_y);
    LineTo(context, bounds.right - 1, bounds.bottom - 1);
    LineTo(context, 0, bounds.bottom - 1);
    LineTo(context, 0, line_y);
    SelectObject(context, previous_pen);
    DeleteObject(pen);
    SetBkMode(context, TRANSPARENT);
    SetTextColor(context, dark_ ? RGB(242, 242, 242)
                                : GetSysColor(COLOR_WINDOWTEXT));
    RECT text_rect{10, 0, bounds.right - 8, text_size.cy + 2};
    DrawTextW(context, label, -1, &text_rect, DT_LEFT | DT_SINGLELINE);
    if (group == groups_[0][0]) {
      const int icon_size = MulDiv(44, dpi_, 96);
      DrawIconEx(context, MulDiv(14, dpi_, 96), MulDiv(25, dpi_, 96),
                 ThemeIcon(icon_size), icon_size, icon_size, 0, nullptr,
                 DI_NORMAL);
    }
    SelectObject(context, previous_font);
  }

  void PaintTabs(HDC context) {
    RECT bounds{};
    GetClientRect(tabs_, &bounds);
    HBRUSH outer = dark_ ? dark_brush_ : GetSysColorBrush(COLOR_BTNFACE);
    HBRUSH inner = dark_ ? page_brush_ : GetSysColorBrush(COLOR_WINDOW);
    FillRect(context, &bounds, outer);
    RECT first_tab{};
    if (!TabCtrl_GetItemRect(tabs_, 0, &first_tab)) return;
    RECT page{0, first_tab.bottom - 1, bounds.right, bounds.bottom};
    FillRect(context, &page, inner);
    HBRUSH border = CreateSolidBrush(dark_ ? RGB(78, 78, 78)
                                         : GetSysColor(COLOR_3DLIGHT));
    FrameRect(context, &page, border);
    HFONT previous_font = reinterpret_cast<HFONT>(
        SelectObject(context, font_));
    SetBkMode(context, TRANSPARENT);
    SetTextColor(context, dark_ ? RGB(242, 242, 242)
                                : GetSysColor(COLOR_WINDOWTEXT));
    const int selected = TabCtrl_GetCurSel(tabs_);
    for (int index = 0; index < TabCtrl_GetItemCount(tabs_); ++index) {
      if (index == selected) continue;
      RECT tab{};
      TabCtrl_GetItemRect(tabs_, index, &tab);
      FillRect(context, &tab, outer);
      FrameRect(context, &tab, border);
      wchar_t label[64]{};
      TCITEMW item{};
      item.mask = TCIF_TEXT;
      item.pszText = label;
      item.cchTextMax = ARRAYSIZE(label);
      TabCtrl_GetItem(tabs_, index, &item);
      DrawTextW(context, label, -1, &tab,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    if (selected >= 0) {
      RECT tab{};
      TabCtrl_GetItemRect(tabs_, selected, &tab);
      const int extension = MulDiv(2, dpi_, 96);
      tab.left = selected == 0 ? 0 : tab.left - extension;
      tab.top = tab.top > extension ? tab.top - extension : 0;
      tab.right += extension;
      tab.bottom = page.top + 1;
      FillRect(context, &tab, inner);
      FrameRect(context, &tab, border);
      RECT join{tab.left + 1, page.top, tab.right - 1, page.top + 1};
      FillRect(context, &join, inner);
      wchar_t label[64]{};
      TCITEMW item{};
      item.mask = TCIF_TEXT;
      item.pszText = label;
      item.cchTextMax = ARRAYSIZE(label);
      TabCtrl_GetItem(tabs_, selected, &item);
      DrawTextW(context, label, -1, &tab,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    SelectObject(context, previous_font);
    DeleteObject(border);
  }

  static LRESULT CALLBACK GroupSubclassProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam,
                                             UINT_PTR subclass_id,
                                             DWORD_PTR app_pointer) {
    auto* app = reinterpret_cast<Application*>(app_pointer);
    if (message == WM_NCDESTROY) {
      RemoveWindowSubclass(hwnd, GroupSubclassProc, subclass_id);
    } else if (message == WM_ERASEBKGND) {
      return 1;
    } else if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      HDC context = BeginPaint(hwnd, &paint);
      app->PaintGroup(hwnd, context);
      EndPaint(hwnd, &paint);
      return 0;
    } else if (message == WM_PRINTCLIENT) {
      app->PaintGroup(hwnd, reinterpret_cast<HDC>(wparam));
      return 0;
    }
    return DefSubclassProc(hwnd, message, wparam, lparam);
  }

  static LRESULT CALLBACK TabSubclassProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           UINT_PTR subclass_id,
                                           DWORD_PTR app_pointer) {
    auto* app = reinterpret_cast<Application*>(app_pointer);
    if (message == WM_NCDESTROY) {
      RemoveWindowSubclass(hwnd, TabSubclassProc, subclass_id);
    } else if (message == WM_ERASEBKGND) {
      return 1;
    } else if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      HDC context = BeginPaint(hwnd, &paint);
      app->PaintTabs(context);
      EndPaint(hwnd, &paint);
      return 0;
    } else if (message == WM_PRINTCLIENT) {
      app->PaintTabs(reinterpret_cast<HDC>(wparam));
      return 0;
    }
    return DefSubclassProc(hwnd, message, wparam, lparam);
  }

  void PaintPortFrame(HWND frame, HDC context) {
    RECT bounds{};
    GetClientRect(frame, &bounds);
    FillRect(context, &bounds,
             dark_ ? page_brush_ : GetSysColorBrush(COLOR_WINDOW));
    HPEN border = CreatePen(PS_SOLID, 1,
                           IsChild(frame, GetFocus())
                               ? GetSysColor(COLOR_HIGHLIGHT)
                               : dark_ ? RGB(108, 108, 108)
                                       : GetSysColor(COLOR_3DSHADOW));
    HPEN previous_pen = reinterpret_cast<HPEN>(SelectObject(context, border));
    HBRUSH previous_brush = reinterpret_cast<HBRUSH>(SelectObject(
        context, dark_ ? edit_brush_ : GetSysColorBrush(COLOR_WINDOW)));
    const int diameter = MulDiv(8, dpi_, 96);
    RoundRect(context, 0, 0, bounds.right, bounds.bottom, diameter, diameter);
    SelectObject(context, previous_brush);
    SelectObject(context, previous_pen);
    DeleteObject(border);
  }

  static LRESULT CALLBACK PortFrameSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR app_pointer) {
    auto* app = reinterpret_cast<Application*>(app_pointer);
    if (message == WM_NCDESTROY) {
      RemoveWindowSubclass(hwnd, PortFrameSubclassProc, subclass_id);
    } else if (message == WM_ERASEBKGND) {
      return 1;
    } else if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      HDC context = BeginPaint(hwnd, &paint);
      app->PaintPortFrame(hwnd, context);
      EndPaint(hwnd, &paint);
      return 0;
    } else if (message == WM_PRINTCLIENT) {
      app->PaintPortFrame(hwnd, reinterpret_cast<HDC>(wparam));
      return 0;
    } else if (message == WM_LBUTTONDOWN) {
      SetFocus(GetWindow(hwnd, GW_CHILD));
      return 0;
    } else if (message == WM_COMMAND &&
               (HIWORD(wparam) == EN_SETFOCUS ||
                HIWORD(wparam) == EN_KILLFOCUS)) {
      InvalidateRect(hwnd, nullptr, FALSE);
    } else if (message == WM_CTLCOLOREDIT || message == WM_CTLCOLORSTATIC) {
      HDC context = reinterpret_cast<HDC>(wparam);
      SetTextColor(context, app->dark_ ? RGB(242, 242, 242)
                                       : GetSysColor(COLOR_WINDOWTEXT));
      SetBkColor(context, app->dark_ ? RGB(45, 45, 45)
                                     : GetSysColor(COLOR_WINDOW));
      return reinterpret_cast<LRESULT>(
          app->dark_ ? app->edit_brush_ : GetSysColorBrush(COLOR_WINDOW));
    }
    return DefSubclassProc(hwnd, message, wparam, lparam);
  }

  bool CreateControls() {
    dpi_ = GetDpiForWindow(hwnd_);
    CreateFontForDpi();
    tabs_ = CreateWindowExW(0, WC_TABCONTROLW, L"",
                            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS |
                                WS_TABSTOP | TCS_TABS,
                            0, 0, 0, 0, hwnd_,
                            reinterpret_cast<HMENU>(static_cast<INT_PTR>(kTab)),
                            instance_, nullptr);
    if (!tabs_) return false;
    SendMessageW(tabs_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    SetWindowSubclass(tabs_, TabSubclassProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
    const std::array<std::wstring, 3> names = {
        Tr(L"Overview", L"概览"), Tr(L"Diagnostics", L"诊断"),
        Tr(L"Settings", L"设置")};
    for (int index = 0; index < 3; ++index) {
      TCITEMW item{};
      item.mask = TCIF_TEXT;
      item.pszText = const_cast<wchar_t*>(names[index].c_str());
      if (TabCtrl_InsertItem(tabs_, index, &item) < 0) return false;
    }

    Group(0, Tr(L"Connection status", L"连接状态"));
    Group(0, Tr(L"Connection information", L"连接信息"));
    Group(0, Tr(L"Pairing", L"设备配对"));
    Group(1, Tr(L"Tests", L"测试方式"));
    Group(1, Tr(L"Logs and reports", L"日志与报告"));
    Group(2, Tr(L"Connection", L"连接"));
    Group(2, Tr(L"Windows startup", L"Windows 启动"));

    status_ = Control(0, L"STATIC", L"", SS_LEFT, 0);
    status_detail_ = Control(0, L"STATIC", L"",
                             SS_LEFT, 0);
    computer_ = Control(0, L"STATIC", L"", SS_LEFT, 0);
    wchar_t computer_name[MAX_COMPUTERNAME_LENGTH + 1]{};
    DWORD computer_name_length = ARRAYSIZE(computer_name);
    if (GetComputerNameW(computer_name, &computer_name_length)) {
      std::wstring label = Tr(L"This PC: ", L"这台电脑：") +
                           std::wstring(computer_name);
      const std::wstring address = LocalIPv4();
      if (!address.empty()) label += L"  ·  " + address;
      SetWindowTextW(computer_, label.c_str());
    }
    audio_ = Control(0, L"STATIC", Tr(L"Audio source: Windows default output",
                                            L"音频来源：Windows 默认输出设备"),
                     SS_LEFT, 0);
    listen_port_ = Control(0, L"STATIC", L"", SS_LEFT, 0);
    pin_ = Control(0, L"STATIC", L"", SS_LEFT, 0);
    Control(0, L"BUTTON", Tr(L"Pair new iPad", L"配对新 iPad"),
            WS_TABSTOP | BS_PUSHBUTTON, kPair);
    toggle_ = Control(0, L"BUTTON", L"", WS_TABSTOP | BS_PUSHBUTTON, kToggle);

    Control(1, L"BUTTON", Tr(L"Live diagnostics…", L"实时诊断…"), WS_TABSTOP | BS_PUSHBUTTON, kDiagnostics);
    Control(1, L"BUTTON", Tr(L"Network test…", L"网络测试…"), WS_TABSTOP | BS_PUSHBUTTON, kNetworkProbe);
    Control(1, L"BUTTON", Tr(L"Music compression test…", L"音乐压缩对比测试…"), WS_TABSTOP | BS_PUSHBUTTON, kMusicTest);
    Control(1, L"STATIC", Tr(L"Capture the PC audio output and diagnose the current connection.", L"采集电脑当前声音，诊断实际播放链路。"), SS_LEFT, 0);
    Control(1, L"STATIC", Tr(L"Compare transport with random data; no audio playback.", L"随机数据对比传输组合，不播放音频。"), SS_LEFT, 0);
    Control(1, L"STATIC", Tr(L"Compare PCM and Opus using one excerpt, both transports and repeated rounds.", L"同一片段比较 PCM／Opus，两种传输自动交叉重复。"), SS_LEFT, 0);
    diagnostic_status_ = Control(1, L"STATIC", L"", SS_LEFT, 0);
    Control(1, L"BUTTON", Tr(L"Open sender log", L"打开运行日志"), WS_TABSTOP | BS_PUSHBUTTON, kLog);
    Control(1, L"BUTTON", Tr(L"Open report folder", L"打开报告文件夹"), WS_TABSTOP | BS_PUSHBUTTON, kReports);
    Control(1, L"BUTTON", Tr(L"Recommendation results", L"推荐结果"), WS_TABSTOP | BS_PUSHBUTTON, kCalibrationResults);
    detailed_logging_ = Control(1, L"BUTTON", Tr(L"Detailed logging (up to 128 MiB)", L"详细日志（最多 128 MiB）"),
                                WS_TABSTOP | BS_AUTOCHECKBOX, kDetailedLogging);

    Control(2, L"STATIC", Tr(L"Connection settings", L"连接设置"), SS_LEFT, 0);
    certificate_ = Control(2, L"STATIC", L"", SS_LEFT, 0);
    Control(2, L"STATIC", Tr(L"Listening UDP port", L"监听 UDP 端口"),
            SS_LEFT | SS_CENTERIMAGE, 0);
    port_frame_ = CreateWindowExW(WS_EX_CONTROLPARENT, L"STATIC", L"",
                                  WS_CHILD | WS_CLIPCHILDREN | SS_NOTIFY,
                                  0, 0, 0, 0,
                                  hwnd_, nullptr, instance_, nullptr);
    if (port_frame_) {
      SetWindowSubclass(port_frame_, PortFrameSubclassProc, 1,
                        reinterpret_cast<DWORD_PTR>(this));
      port_edit_ = CreateWindowExW(
          0, L"EDIT", std::to_wstring(port_).c_str(),
          WS_CHILD | WS_TABSTOP | ES_NUMBER | ES_AUTOHSCROLL,
          0, 0, 0, 0, port_frame_,
          reinterpret_cast<HMENU>(static_cast<INT_PTR>(kPort)), instance_,
          nullptr);
      if (port_edit_) {
        pages_[2].push_back(port_edit_);
        SendMessageW(port_edit_, WM_SETFONT,
                     reinterpret_cast<WPARAM>(font_), TRUE);
      }
    }
    Control(2, L"BUTTON", Tr(L"Apply", L"应用"),
            WS_TABSTOP | BS_PUSHBUTTON, kSavePort);
    auto_start_ = Control(2, L"BUTTON",
                          Tr(L"Run when I sign in to Windows",
                             L"登录 Windows 后自动运行"),
                          WS_TABSTOP | BS_AUTOCHECKBOX, kAutoStart);
    SendMessageW(auto_start_, BM_SETCHECK,
                 AutoStartEnabled() ? BST_CHECKED : BST_UNCHECKED, 0);
    Control(2, L"STATIC",
            Tr(L"The TLS certificate is created locally and reused. Replacing it requires pairing again.",
               L"连接证书由程序在本机创建并复用；更换证书后需要重新配对。"),
            SS_LEFT, 0);

    footer_close_ = CreateWindowExW(
        0, L"BUTTON", Tr(L"Minimize to tray", L"最小化到托盘").c_str(),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        0, 0, 0, 0, hwnd_,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kCloseWindow)),
        instance_, nullptr);
    footer_exit_ = CreateWindowExW(
        0, L"BUTTON", Tr(L"Exit", L"退出程序").c_str(),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        0, 0, 0, 0, hwnd_,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kExitApplication)),
        instance_, nullptr);
    SendMessageW(footer_close_, WM_SETFONT,
                 reinterpret_cast<WPARAM>(font_), TRUE);
    SendMessageW(footer_exit_, WM_SETFONT,
                 reinterpret_cast<WPARAM>(font_), TRUE);
    if (groups_[0].size() != 3 || groups_[1].size() != 2 ||
        groups_[2].size() != 2 || pages_[0].size() != 8 ||
        pages_[1].size() != 11 || pages_[2].size() != 7 ||
        !port_frame_ || !port_edit_ || !footer_close_ || !footer_exit_) {
      return false;
    }

    SelectPage(0);
    Layout();
    UpdateStatus();
    SetWindowTextW(diagnostic_status_, Tr(L"No diagnostic session is running.",
                                           L"当前没有进行中的诊断。")
                                               .c_str());
    return true;
  }

  void Layout() {
    if (!tabs_) return;
    RECT client{};
    GetClientRect(hwnd_, &client);
    const int width = MulDiv(client.right - client.left, 96, dpi_);
    const int group_width = width - 64;
    Place(tabs_, 16, 12, width - 32, 405);
    Place(groups_[0][0], 32, 55, group_width, 96);
    Place(groups_[0][1], 32, 163, group_width, 112);
    Place(groups_[0][2], 32, 287, group_width, 114);
    Place(groups_[1][0], 32, 55, group_width, 170);
    Place(groups_[1][1], 32, 237, group_width, 164);
    Place(groups_[2][0], 32, 55, group_width, 220);
    Place(groups_[2][1], 32, 287, group_width, 114);

    auto& overview = pages_[0];
    Place(overview[0], 100, 78, group_width - 80, 24);
    Place(overview[1], 100, 105, std::max(100, width - 282), 42);
    Place(overview[2], 44, 185, group_width - 24, 24);
    Place(overview[3], 44, 213, group_width - 24, 24);
    Place(overview[4], 44, 241, group_width - 24, 24);
    Place(overview[5], 44, 312, group_width - 24, 45);
    Place(overview[6], width - 162, 359, 118, 29);
    Place(overview[7], width - 162, 108, 118, 29);

    auto& diagnostics = pages_[1];
    const int column = (group_width - 40) / 3;
    for (int i = 0; i < 3; ++i) {
      Place(diagnostics[i], 44 + i * (column + 8), 83, column, 32);
      Place(diagnostics[i + 3], 44 + i * (column + 8), 130, column, 68);
    }
    Place(diagnostics[6], 44, 263, group_width - 24, 64);
    Place(diagnostics[7], width - 288, 359, 118, 29);
    Place(diagnostics[8], width - 162, 359, 118, 29);
    Place(diagnostics[9],44,359,118,29);
    Place(diagnostics[10],44,326,group_width - 24,26);

    auto& settings = pages_[2];
    Place(settings[0], 44, 82, group_width - 24, 28);
    Place(settings[1], 44, 120, group_width - 24, 32);
    Place(settings[2], 44, 160, 180, 29);
    Place(port_frame_, 246, 160, 88, 29);
    Place(settings[3], 5, 5, 78, 20);
    Place(settings[4], width - 162, 160, 118, 29);
    Place(settings[5], 44, 312, group_width - 24, 29);
    Place(settings[6], 44, 211, group_width - 24, 51);

    Place(footer_close_, width - 250, 428, 132, 29);
    Place(footer_exit_, width - 110, 428, 100, 29);
  }

  void SelectPage(int page) {
    for (int index = 0; index < 3; ++index) {
      for (HWND group : groups_[index]) {
        ShowWindow(group, index == page ? SW_SHOW : SW_HIDE);
      }
      if (index == 2) {
        ShowWindow(port_frame_, index == page ? SW_SHOW : SW_HIDE);
      }
      for (HWND control : pages_[index]) {
        ShowWindow(control, index == page ? SW_SHOW : SW_HIDE);
      }
    }
    TabCtrl_SetCurSel(tabs_, page);
    InvalidateRect(tabs_, nullptr, TRUE);
  }

  void ApplyTheme() {
    if (!tabs_) return;
    const bool was_dark = dark_;
    dark_ = SystemDarkMode();
    const BOOL dark_frame = dark_ ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_frame,
                          sizeof(dark_frame));
    SetWindowTheme(tabs_, dark_ ? L"DarkMode_Explorer" : nullptr, nullptr);
    InvalidateRect(tabs_, nullptr, TRUE);
    for (auto& page : groups_) {
      for (HWND group : page) {
        SetWindowTheme(group, dark_ ? L"DarkMode_Explorer" : nullptr, nullptr);
        InvalidateRect(group, nullptr, TRUE);
      }
    }
    for (auto& page : pages_) {
      for (HWND control : page) {
        SetWindowTheme(control, dark_ ? L"DarkMode_Explorer" : nullptr,
                       nullptr);
        InvalidateRect(control, nullptr, TRUE);
      }
    }
    InvalidateRect(port_frame_, nullptr, TRUE);
    for (HWND button : {footer_close_, footer_exit_}) {
      SetWindowTheme(button, dark_ ? L"DarkMode_Explorer" : nullptr, nullptr);
      InvalidateRect(button, nullptr, TRUE);
    }
    InvalidateRect(hwnd_, nullptr, TRUE);
    if (tray_ready_ && dark_ != was_dark) {
      NOTIFYICONDATAW icon{};
      icon.cbSize = sizeof(icon);
      icon.hWnd = hwnd_;
      icon.uID = kTrayIcon;
      icon.uFlags = NIF_ICON;
      icon.hIcon = ThemeIcon(GetSystemMetrics(SM_CXSMICON));
      Shell_NotifyIconW(NIM_MODIFY, &icon);
    }
  }

  HICON ThemeIcon(int size) const {
    return reinterpret_cast<HICON>(LoadImageW(
        instance_, MAKEINTRESOURCEW(dark_ ? IDI_HEARPORT_TRAY_DARK
                                         : IDI_HEARPORT_TRAY_LIGHT),
        IMAGE_ICON, size, size, LR_SHARED));
  }

  void AddTrayIcon() {
    NOTIFYICONDATAW icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = hwnd_;
    icon.uID = kTrayIcon;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    icon.uCallbackMessage = kTrayMessage;
    icon.hIcon = ThemeIcon(GetSystemMetrics(SM_CXSMICON));
    lstrcpynW(icon.szTip, L"HearPort", ARRAYSIZE(icon.szTip));
    tray_ready_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
    EnableWindow(footer_close_, tray_ready_);
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
    ShowWindow(hwnd_, SW_RESTORE);
    SetForegroundWindow(hwnd_);
  }

  void ShowTrayMenu() {
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

  void UpdateStatus() {
    std::wstring heading;
    std::wstring detail;
    std::wstring audio_label = Tr(L"Audio source: Windows default output",
                                  L"音频来源：Windows 默认输出设备");
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
      detail = reliable_ ? Tr(L"Audio: reliable stream", L"音频：稳定性模式")
                         : Tr(L"Audio: low latency", L"音频：低延迟模式");
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
    SetWindowTextW(status_, heading.c_str());
    SetWindowTextW(status_detail_, detail.c_str());
    SetWindowTextW(audio_, audio_label.c_str());
    std::wstring toggle = running_ ? Tr(L"Stop sender", L"停止发送服务")
                                   : Tr(L"Start sender", L"启动发送服务");
    SetWindowTextW(toggle_, toggle.c_str());
    if (pages_[0].size() > 6) EnableWindow(pages_[0][6], running_ && !connected_);
    SetWindowTextW(certificate_,
                   certificate_ready_
                       ? Tr(L"Secure connection: certificate ready",
                            L"安全连接：证书已自动配置").c_str()
                       : Tr(L"Secure connection: preparing certificate",
                            L"安全连接：正在准备证书").c_str());
    const std::wstring port_text = Tr(L"Listening port: UDP ", L"监听端口：UDP ") +
                                   std::to_wstring(port_);
    SetWindowTextW(listen_port_, port_text.c_str());
    if (pin_expires_ && Clock::now() >= *pin_expires_) pin_expires_.reset();
    if (pin_expires_) {
      const auto seconds = std::chrono::ceil<std::chrono::seconds>(
          *pin_expires_ - Clock::now()).count();
      const std::string pin = host_->pairing_pin();
      const std::wstring digits(pin.begin(), pin.end());
      const std::wstring countdown = std::to_wstring(seconds / 60) + L":" +
                                     (seconds % 60 < 10 ? L"0" : L"") +
                                     std::to_wstring(seconds % 60);
      const std::wstring label = Tr(L"Pairing PIN: ", L"配对码：") +
                                 digits.substr(0, 3) + L" " + digits.substr(3) +
                                 Tr(L"  ·  Time left ", L"  ·  剩余 ") + countdown;
      SetWindowTextW(pin_, label.c_str());
    }
    if (!pin_expires_) {
      const std::wstring pairing_hint =
          !running_ ? Tr(L"Start the sender to enable pairing.",
                         L"启动发送服务后可以开始配对。")
                    : connected_ ? Tr(L"An iPad is connected.",
                                      L"当前有 iPad 已连接。")
                                 : Tr(L"Choose Pair new iPad to show a code.",
                                      L"点击“配对新 iPad”显示配对码。");
      SetWindowTextW(pin_, pairing_hint.c_str());
    }
    InvalidateRect(status_, nullptr, TRUE);
  }

  void StartService(std::optional<std::chrono::seconds> diagnostics = std::nullopt,
                    bool network_probe = false,
                    std::optional<hearport::windows::MusicExcerpt> music = std::nullopt,
                    bool calibration = false) {
    if (running_) return;
    error_.clear();
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
      SetWindowTextW(diagnostic_status_,
                     Tr(L"The sender log could not be opened.",
                        L"无法打开运行日志。")
                         .c_str());
    }
    identity->diagnostic_log = [this](std::string_view line) {
      logger_.TryLog(line);
    };
    host_ = std::make_unique<hearport::windows::SenderHost>(*identity, data_dir_ / L"diagnostics");
    host_->Configure([&](SenderService& service) {
      service.ConfigureNetworkProbe(network_probe);
      service.ConfigureDebugDuration(diagnostics);
      if (calibration) service.ConfigureCalibration({static_cast<std::uint16_t>(calibration_seconds_), static_cast<std::uint16_t>(calibration_maximum_), calibration_goal_});
      if (music) service.ConfigureMusicTest(*music);
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
    reliable_ = false;
    diagnostic_duration_ = service_->debug_duration();
    network_probe_active_ = network_probe;
    music_test_active_ = music.has_value();
    if (diagnostics) {
      diagnostic_started_ = Clock::now();
      const auto message = network_probe
          ? Tr(L"Connect the iPad to begin the automatic network test.",
               L"请连接 iPad，开始自动网络测试。")
          : Tr(L"Waiting for iPad and its diagnostic report…",
               L"正在等待 iPad 连接并传回诊断报告……");
      SetWindowTextW(diagnostic_status_, message.c_str());
    }
    UpdateStatus();
  }

  void StopService() {
    const auto session_directory = service_ ? service_->debug_session_directory()
                                             : std::filesystem::path{};
    if (host_) host_->Stop();
    host_.reset();
    service_ = nullptr;
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
    reliable_ = false;
    diagnostic_duration_.reset();
    network_probe_active_ = false;
    music_test_active_ = false;
    pin_expires_.reset();
    UpdateStatus();
  }

  void OpenPairing() {
    if (!running_ || !host_) return;
    if (!host_->OpenPairingWindow()) {
      MessageBoxW(hwnd_, Tr(L"Could not open pairing. Check the security provider.",
                             L"无法开启配对，请检查安全组件。")
                             .c_str(), L"HearPort", MB_OK | MB_ICONERROR);
      return;
    }
    pin_expires_ = Clock::now() + std::chrono::minutes(2);
    UpdateStatus();
  }

  void ConfirmExit() {
    if (MessageBoxW(hwnd_,
                    Tr(L"Exit HearPort and stop sending audio?",
                       L"确定退出 HearPort 并停止发送声音吗？")
                        .c_str(),
                    L"HearPort", MB_YESNO | MB_ICONQUESTION |
                                     MB_DEFBUTTON2) == IDYES) {
      DestroyWindow(hwnd_);
    }
  }

  void StartDiagnostics() {
    StopService();
    StartService(std::chrono::seconds(std::stoul(live_seconds_)));
    SelectPage(0);
  }

  void StartNetworkProbe() {
    StopService();
    StartService(std::chrono::seconds(
                     hearport::windows::kCoordinatedProbeDurationSeconds), true, std::nullopt, calibration_selected_);
    if (!running_) {
      SetWindowTextW(diagnostic_status_,
                     Tr(L"Could not start the network test. Check the overview and log.",
                        L"无法启动网络测试，请查看概览和运行日志。")
                         .c_str());
    }
    SelectPage(0);
  }

  static LRESULT CALLBACK TestSettingsProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* app = reinterpret_cast<Application*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      app = static_cast<Application*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    }
    if (!app) return DefWindowProcW(window, message, wparam, lparam);
    if (message == WM_COMMAND) {
      if (LOWORD(wparam) == kMusicFile) app->ChooseMusicFile();
      else if (LOWORD(wparam) == IDOK) {
        const auto read = [](HWND control) {
          std::wstring text(GetWindowTextLengthW(control) + 1, L'\0');
          text.resize(GetWindowTextW(control, text.data(), static_cast<int>(text.size())));
          return text;
        };
        const auto number = [](const std::wstring& text, unsigned long ceiling) {
          wchar_t* end = nullptr;
          const auto value = wcstoull(text.c_str(), &end, 10);
          return !text.empty() && *end == L'\0' && value <= ceiling;
        };
        if (app->settings_kind_ == kNetworkProbe) {
          app->calibration_goal_ = 0;
          app->calibration_selected_ = SendMessageW(app->settings_purpose_, CB_GETCURSEL,0,0) == 0;
          const auto maximum = read(app->settings_maximum_);
          const auto seconds = SendMessageW(app->settings_duration_,CB_GETCURSEL,0,0);
          if (!number(maximum,2000) || std::stoul(maximum) < 20 || seconds < 0 || seconds > 2) {
            MessageBoxW(window,Tr(L"Enter a maximum from 20 to 2000 ms.",L"请输入 20 至 2000 毫秒的上限。").c_str(),L"HearPort",MB_OK | MB_ICONWARNING); return 0;
          }
          app->calibration_maximum_ = std::stoul(maximum);
          app->calibration_seconds_ = seconds == 0 ? 30 : seconds == 1 ? 60 : 120;
        } else {
          const auto seconds = read(app->settings_duration_);
          const unsigned limit = app->settings_kind_ == kMusicTest ? 300 : 3600;
          if (!number(seconds, limit) || std::stoul(seconds) < 60) {
            MessageBoxW(window, (Tr(L"Enter a duration from 60 to ", L"请输入 60 至 ") +
                std::to_wstring(limit) + Tr(L" seconds.", L" 秒的时长。 ")).c_str(), L"HearPort", MB_OK | MB_ICONWARNING);
            return 0;
          }
          if (app->settings_kind_ == kMusicTest) {
            const auto start = read(app->settings_start_);
            if (read(app->settings_file_).empty() || !number(start, UINT32_MAX)) {
              MessageBoxW(window, Tr(L"Select an audio file and a valid start time.", L"请选择音频文件并填写有效起点。").c_str(), L"HearPort", MB_OK | MB_ICONWARNING);
              return 0;
            }
            app->music_path_ = read(app->settings_file_);
            app->music_start_seconds_ = start;
            app->music_seconds_ = seconds;
          } else app->live_seconds_ = seconds;
        }
        app->settings_start_requested_ = true;
        DestroyWindow(window);
      } else if (LOWORD(wparam) == IDCANCEL) DestroyWindow(window);
      return 0;
    }
    if (message == WM_CLOSE) { DestroyWindow(window); return 0; }
    if (message == WM_ERASEBKGND) {
      RECT rect{}; GetClientRect(window, &rect);
      FillRect(reinterpret_cast<HDC>(wparam), &rect, app->dark_ ? app->page_brush_ : GetSysColorBrush(COLOR_WINDOW));
      return 1;
    }
    if (message == WM_CTLCOLORSTATIC || message == WM_CTLCOLORBTN) {
      SetBkMode(reinterpret_cast<HDC>(wparam), TRANSPARENT);
      SetTextColor(reinterpret_cast<HDC>(wparam), app->dark_ ? RGB(242,242,242) : GetSysColor(COLOR_WINDOWTEXT));
      return reinterpret_cast<LRESULT>(app->dark_ ? app->page_brush_ : GetSysColorBrush(COLOR_WINDOW));
    }
    if (message == WM_DESTROY) { app->settings_window_ = nullptr; return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  void ShowTestSettings(int kind) {
    if (settings_window_) return;
    settings_kind_ = kind; settings_start_requested_ = false;
    WNDCLASSEXW type{sizeof(type)};
    type.lpfnWndProc = TestSettingsProc; type.hInstance = instance_;
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.lpszClassName = L"HearPortTestSettings";
    RegisterClassExW(&type);
    const auto title = kind == kMusicTest ? Tr(L"Music test", L"音乐测试") :
        kind == kNetworkProbe ? Tr(L"Network test", L"网络测试") : Tr(L"Live diagnostics", L"实时诊断");
    const int height = kind == kMusicTest ? 352 : kind == kNetworkProbe ? 370 : 225;
    RECT owner{}; GetWindowRect(hwnd_, &owner);
    settings_window_ = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT,
        type.lpszClassName, title.c_str(), WS_POPUP | WS_CAPTION | WS_SYSMENU,
        owner.left + MulDiv(20, dpi_, 96), owner.top + MulDiv(40, dpi_, 96),
        MulDiv(480, dpi_, 96), MulDiv(height, dpi_, 96), hwnd_, nullptr, instance_, this);
    if (!settings_window_) return;
    const BOOL dark = dark_;
    DwmSetWindowAttribute(settings_window_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    const auto control = [&](const wchar_t* type, const std::wstring& label, DWORD style,
                             int id, int x, int y, int width, int height) {
      const auto result = CreateWindowExW(0, type, label.c_str(), WS_CHILD | WS_VISIBLE | style,
          0,0,0,0,settings_window_,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),instance_,nullptr);
      SendMessageW(result, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
      SetWindowTheme(result, dark_ ? L"DarkMode_Explorer" : nullptr, nullptr);
      Place(result, x,y,width,height);
      return result;
    };
    const auto edit = [&](const std::wstring& text, DWORD style, int x, int y, int width) {
      const auto frame = control(L"STATIC", L"", WS_CLIPCHILDREN | SS_NOTIFY, 0, x,y,width,29);
      SetWindowLongPtrW(frame, GWL_EXSTYLE, WS_EX_CONTROLPARENT);
      SetWindowSubclass(frame, PortFrameSubclassProc, 1, reinterpret_cast<DWORD_PTR>(this));
      const auto input = CreateWindowExW(0,L"EDIT",text.c_str(),WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL | style,
          0,0,0,0,frame,nullptr,instance_,nullptr);
      SendMessageW(input, WM_SETFONT,reinterpret_cast<WPARAM>(font_),TRUE);
      Place(input,8,5,width-16,20);
      return input;
    };
    const auto explanation = kind == kMusicTest ?
        Tr(L"32 rounds: Float32, PCM16 and Opus 192/256 kbps at 2.5/5/10 ms; both transports, twice. Default: 66 min 45 s plus setup/upload. Same excerpt each round.",
           L"32 组：Float32、PCM16、Opus 192／256 kbps（2.5／5／10 ms），两种传输各两次。同一片段；默认约 66 分 45 秒，另加协商与回传。") :
        kind == kNetworkProbe ? Tr(L"Automatic recommendation samples both transports, replays identical input, then validates recommendations twice. Existing transport comparisons remain available. No audio playback.",
           L"自动测试并推荐参数会采样两种传输，以同一轨迹比较预算，再对推荐参数复核两次。也可选择原传输对比测试。全程不播放音频。") :
        Tr(L"Capture the PC's current audio output. The iPad report is returned automatically when the chosen duration ends.",
           L"采集电脑当前输出声音，指定时长结束后自动回传 iPad 诊断报告。");
    control(L"STATIC",explanation,SS_LEFT,0,20,18,430,64);
    if (kind == kMusicTest) {
      settings_file_ = edit(music_path_,ES_READONLY,20,94,310);
      control(L"BUTTON",Tr(L"Select file…",L"选择文件…"),WS_TABSTOP | BS_PUSHBUTTON,kMusicFile,338,94,112,29);
      control(L"STATIC",Tr(L"Start (seconds)",L"起点（秒）"),SS_LEFT | SS_CENTERIMAGE,0,20,143,150,29);
      settings_start_ = edit(music_start_seconds_,ES_NUMBER,180,143,100);
      control(L"STATIC",Tr(L"Round (seconds)",L"每组时长（秒）"),SS_LEFT | SS_CENTERIMAGE,0,20,186,150,29);
      settings_duration_ = edit(music_seconds_,ES_NUMBER,180,186,100);
      control(L"STATIC",Tr(L"Connect once. Transport switches automatically. Reports include round boundaries.",
          L"只需连接一次；总传输时间约 32 × 每组秒数 + 165 秒。"),SS_LEFT,0,20,233,430,40);
    } else if (kind == kNetworkProbe) {
      control(L"STATIC",Tr(L"Purpose",L"测试用途"),SS_LEFT | SS_CENTERIMAGE,0,20,94,150,29);
      settings_purpose_ = control(WC_COMBOBOX,L"",CBS_DROPDOWNLIST | WS_TABSTOP,0,180,94,260,100);
      SendMessageW(settings_purpose_,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(Tr(L"Automatic test and parameter recommendations",L"自动测试并推荐参数").c_str()));
      SendMessageW(settings_purpose_,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(Tr(L"Compression traffic comparison (40 rounds)",L"压缩传输负载对比（40 组）").c_str()));
      SendMessageW(settings_purpose_,CB_SETCURSEL,calibration_selected_ ? 0 : 1,0);
      control(L"STATIC",Tr(L"Recommendation maximum (ms)",L"自动推荐：延迟上限（毫秒）"),SS_LEFT | SS_CENTERIMAGE,0,20,137,205,29);
      settings_maximum_ = edit(std::to_wstring(calibration_maximum_),ES_NUMBER,240,137,100);
      control(L"STATIC",Tr(L"Recommendation round (seconds)",L"自动推荐：每组时长（秒）"),SS_LEFT | SS_CENTERIMAGE,0,20,180,205,29);
      settings_duration_ = control(WC_COMBOBOX,L"",CBS_DROPDOWNLIST | WS_TABSTOP,0,240,180,100,120);
      for (const auto* seconds : {L"30",L"60",L"120"}) SendMessageW(settings_duration_,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(seconds));
      SendMessageW(settings_duration_,CB_SETCURSEL,calibration_seconds_ == 30 ? 0 : calibration_seconds_ == 60 ? 1 : 2,0);
      control(L"STATIC",Tr(L"Recommendations: 4 sampling + up to 6 validation rounds. Compression traffic: 10 payload/rate profiles × 2 transports × 2 repeats, 30 s each, total 23 min 25 s. No audio or codec runs in traffic tests.",
          L"自动推荐：4 组采样，最多 6 组复核。压缩负载：10 种大小／频率 × 两种传输 × 两次重复，固定每组 30 秒，共 23 分 25 秒；不播放音频、不运行编码器。"),SS_LEFT,0,20,223,430,62);
    } else if (kind == kDiagnostics) {
      control(L"STATIC",Tr(L"Duration (seconds)",L"时长（秒）"),SS_LEFT | SS_CENTERIMAGE,0,20,94,150,29);
      settings_duration_ = edit(live_seconds_,ES_NUMBER,180,94,100);
    }
    control(L"BUTTON",Tr(L"Start",L"开始测试"),WS_TABSTOP | BS_DEFPUSHBUTTON,IDOK,230,height-73,104,29);
    control(L"BUTTON",Tr(L"Cancel",L"取消"),WS_TABSTOP | BS_PUSHBUTTON,IDCANCEL,346,height-73,104,29);
    EnableWindow(hwnd_,FALSE);
    ShowWindow(settings_window_,SW_SHOW);
    MSG message{}; bool quit = false;
    while (settings_window_) {
      const auto result = GetMessageW(&message,nullptr,0,0);
      if (result <= 0) { quit = result == 0; break; }
      if (!IsDialogMessageW(settings_window_,&message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (settings_window_) DestroyWindow(settings_window_);
    settings_file_ = settings_start_ = settings_duration_ = settings_maximum_ = settings_purpose_ = nullptr;
    EnableWindow(hwnd_,TRUE); SetForegroundWindow(hwnd_);
    if (quit) { PostQuitMessage(static_cast<int>(message.wParam)); return; }
    if (!settings_start_requested_) return;
    if (kind == kMusicTest) StartMusicTest();
    else if (kind == kNetworkProbe) StartNetworkProbe();
    else StartDiagnostics();
  }

  static LRESULT CALLBACK CalibrationResultsProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* app = reinterpret_cast<Application*>(GetWindowLongPtrW(window,GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      app = static_cast<Application*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(app));
    }
    if (!app) return DefWindowProcW(window,message,wparam,lparam);
    if (message == WM_SIZE) {
      RECT area{}; GetClientRect(window,&area);
      MoveWindow(GetDlgItem(window,1),16,260,std::max(1L,area.right-32),std::max(1L,area.bottom-276),TRUE);
    }
    if (message == WM_PAINT) {
      PAINTSTRUCT paint{}; const auto dc = BeginPaint(window,&paint);
      RECT area{}; GetClientRect(window,&area);
      FillRect(dc,&area,app->dark_ ? app->page_brush_ : GetSysColorBrush(COLOR_WINDOW));
      SelectObject(dc,app->font_); SetBkMode(dc,TRANSPARENT);
      SetTextColor(dc,app->dark_ ? RGB(242,242,242) : RGB(30,30,30));
      const auto label = [&](int x,int y,const std::wstring& text) { TextOutW(dc,x,y,text.c_str(),static_cast<int>(text.size())); };
      label(20,12,Tr(L"Sampling replay: source age P95 (x, ms) / gaps (y, %)",L"采样回放：横轴为源年龄 P95（毫秒），纵轴为缺口占比（%）"));
      const int left = 78, right = std::max(100L,area.right-35), top = 52, bottom = 213;
      auto axes = CreatePen(PS_SOLID,1,app->dark_ ? RGB(190,190,190) : RGB(70,70,70));
      const auto previous = SelectObject(dc,axes);
      MoveToEx(dc,left,top,nullptr); LineTo(dc,left,bottom); LineTo(dc,right,bottom);
      double maximum_age = 1, maximum_gap = .001;
      if (app->calibration_report_) for (const auto& point : app->calibration_report_->curve) if (point.valid && point.age_p95_ms) {
        maximum_age = std::max(maximum_age,*point.age_p95_ms); maximum_gap = std::max(maximum_gap,point.gap_ratio);
      }
      wchar_t gap[64]{}; swprintf_s(gap,L"%.2f%%",maximum_gap*100);
      label(10,top,gap); label(35,bottom-10,L"0"); label(right-65,bottom+8,std::to_wstring(static_cast<unsigned>(maximum_age))+L" ms");
      if (app->calibration_report_) for (const auto& point : app->calibration_report_->curve) if (point.valid && point.age_p95_ms) {
        auto brush = CreateSolidBrush(point.reliable ? RGB(225,135,50) : RGB(55,145,230));
        const auto old_brush = SelectObject(dc,brush);
        const int x = left + static_cast<int>((right-left) * *point.age_p95_ms / maximum_age);
        const int y = bottom - static_cast<int>((bottom-top) * point.gap_ratio / maximum_gap);
        Ellipse(dc,x-3,y-3,x+4,y+4); SelectObject(dc,old_brush); DeleteObject(brush);
      }
      SelectObject(dc,previous); DeleteObject(axes);
      label(85,235,Tr(L"Blue: Datagram · orange: Reliable. Each point is one target/maximum budget.",L"蓝色 Datagram · 橙色 Reliable；每个点对应一组目标／最大预算。"));
      EndPaint(window,&paint); return 0;
    }
    if (message == WM_CLOSE) { DestroyWindow(window); return 0; }
    if (message == WM_DESTROY) { app->calibration_window_ = nullptr; return 0; }
    return DefWindowProcW(window,message,wparam,lparam);
  }

  void ShowCalibrationResults() {
    if (calibration_window_) { SetForegroundWindow(calibration_window_); return; }
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
      MessageBoxW(hwnd_,Tr(L"No recommendation report is available. Select Automatic test and parameter recommendations in Network test settings.",
          L"尚无推荐参数报告，请在网络测试设置中选择“自动测试并推荐参数”。").c_str(),L"HearPort",MB_OK); return;
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
    WNDCLASSEXW type{sizeof(type)}; type.lpfnWndProc = CalibrationResultsProc; type.hInstance = instance_;
    type.hCursor = LoadCursorW(nullptr,IDC_ARROW); type.lpszClassName = L"HearPortCalibrationResults"; RegisterClassExW(&type);
    calibration_window_ = CreateWindowExW(0,type.lpszClassName,Tr(L"Automatic test and parameter recommendations",L"自动测试并推荐参数结果").c_str(),
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,CW_USEDEFAULT,900,820,hwnd_,nullptr,instance_,this);
    if (!calibration_window_) return;
    const auto edit = CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",text.str().c_str(),WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
        16,260,852,500,calibration_window_,reinterpret_cast<HMENU>(1),instance_,nullptr);
    SendMessageW(edit,WM_SETFONT,reinterpret_cast<WPARAM>(font_),TRUE);
    ShowWindow(calibration_window_,SW_SHOW);
  }

  void ChooseMusicFile() {
    std::wstring path(32'768,L'\0');
    OPENFILENAMEW dialog{sizeof(dialog)};
    dialog.hwndOwner = settings_window_;
    dialog.lpstrFile = path.data(); dialog.nMaxFile = static_cast<DWORD>(path.size());
    dialog.lpstrFilter = L"Audio\0*.flac;*.mp3;*.wav;*.m4a;*.aac;*.wma\0All files\0*.*\0";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&dialog)) SetWindowTextW(settings_file_,path.c_str());
  }

  void StartMusicTest() {
    try {
      SetCursor(LoadCursorW(nullptr,IDC_WAIT));
      auto clip = hearport::windows::LoadMusicExcerpt(music_path_,std::stoul(music_start_seconds_),std::stoul(music_seconds_));
      StopService();
      StartService(std::nullopt,false,std::move(clip));
      SelectPage(0);
      SetCursor(LoadCursorW(nullptr,IDC_ARROW));
    } catch (const std::exception& error) {
      SetCursor(LoadCursorW(nullptr,IDC_ARROW));
      const std::string message = error.what();
      const auto text = Tr(L"Could not decode the complete excerpt. Check the file and selected time range.\n",L"无法解码完整片段，请检查文件及所选时间范围。\n") +
          std::wstring(message.begin(),message.end());
      MessageBoxW(hwnd_,text.c_str(),L"HearPort",MB_OK | MB_ICONERROR);
    }
  }

  void SavePortFromControl() {
    wchar_t text[16]{};
    GetWindowTextW(port_edit_, text, ARRAYSIZE(text));
    wchar_t* end = nullptr;
    const unsigned long value = wcstoul(text, &end, 10);
    if (text[0] == L'\0' || *end != L'\0' || value == 0 || value > 65535) {
      MessageBoxW(hwnd_, Tr(L"Enter a UDP port from 1 to 65535.",
                             L"请输入 1 至 65535 之间的 UDP 端口。")
                             .c_str(), L"HearPort", MB_OK | MB_ICONWARNING);
      return;
    }
    if (!SavePort(static_cast<std::uint16_t>(value))) {
      MessageBoxW(hwnd_, Tr(L"Could not save the port.", L"无法保存端口。")
                             .c_str(), L"HearPort", MB_OK | MB_ICONERROR);
      return;
    }
    const bool restart = running_ && value != port_;
    port_ = static_cast<std::uint16_t>(value);
    if (restart) {
      const auto diagnostics = diagnostic_duration_;
      const bool network_probe = network_probe_active_;
      const bool music = music_test_active_;
      StopService();
      if (music) StartMusicTest(); else StartService(diagnostics, network_probe);
      if (diagnostics && !running_) {
        SetWindowTextW(diagnostic_status_,
                       Tr(L"Diagnostics stopped because the sender could not restart on the new port.",
                          L"诊断已中断：无法使用新端口重启发送服务。")
                           .c_str());
      }
    } else {
      UpdateStatus();
    }
  }

  void OnTimer() {
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
      SetWindowTextW(diagnostic_status_,
                     (local_calibration ? Tr(L"Automatic test completed; results are available on iPad.",L"自动测试已完成；结果在 iPad 上查看和应用。") : Tr(L"Diagnostic report saved in the report folder.",
                        L"诊断报告已保存到报告文件夹。"))
                         .c_str());
      RedrawWindow(hwnd_, nullptr, nullptr,
                   RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
      StopService();
      StartService();
      completed_test_ = running_ && succeeded && !local_calibration ? completed_test : 0;
      UpdateStatus();
      if (!succeeded) SetWindowTextW(diagnostic_status_,
          Tr(L"Test interrupted; the available report was saved. It is not a complete comparison.",
             L"测试已中断，现有报告已保存；本次不是完整对照。").c_str());
    } else if (Clock::now() - diagnostic_started_ >
               *diagnostic_duration_ + std::chrono::minutes(7)) {
      StopService();
      StartService();
      SetWindowTextW(diagnostic_status_,
                     Tr(L"Diagnostic session ended without a completed report. Check the log.",
                        L"诊断未收到完整报告，请查看运行日志。")
                         .c_str());
    }
  }

  void OpenPath(const std::filesystem::path& path) {
    if (reinterpret_cast<INT_PTR>(ShellExecuteW(
            hwnd_, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <=
        32) {
      MessageBoxW(hwnd_, Tr(L"Could not open this location.",
                             L"无法打开此位置。")
                             .c_str(), L"HearPort", MB_OK | MB_ICONERROR);
    }
  }

  LRESULT Handle(UINT message, WPARAM wparam, LPARAM lparam) {
    if (taskbar_created_ != 0 && message == taskbar_created_) {
      AddTrayIcon();
      return 0;
    }
    switch (message) {
      case WM_CREATE:
        if (!CreateControls()) return -1;
        ApplyTheme();
        taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
        AddTrayIcon();
        SetTimer(hwnd_, kTimer, 1000, nullptr);
        PostMessageW(hwnd_, kStartMessage, 0, 0);
        return 0;
      case kStartMessage:
        StartService();
        return 0;
      case kCalibrationRequestMessage:
        if (running_ && service_ && !service_->debug_duration() &&
            !service_->network_probe() && !service_->music_test() && !service_->environment_calibration() &&
            ((LOWORD(wparam) == 15 && HIWORD(wparam)) || LOWORD(wparam) == 30 || LOWORD(wparam) == 60 || LOWORD(wparam) == 120) && lparam >= 20 && lparam <= 2000) {
          calibration_seconds_ = LOWORD(wparam);
          calibration_goal_ = static_cast<std::uint8_t>(HIWORD(wparam));
          calibration_maximum_ = static_cast<unsigned>(lparam);
          StopService();
          StartService(std::nullopt, true, std::nullopt, true);
          SelectPage(0);
        }
        return 0;
      case kConnectionMessage:
        connected_ = wparam != 0;
        reliable_ = (lparam & 1) != 0;
        usb_connected_ = (lparam & 2) != 0;
        if (host_) service_ = &host_->service();
        if (connected_) {
          pin_expires_.reset();
        }
        UpdateStatus();
        return 0;
      case WM_TIMER:
        if (wparam == kTimer) OnTimer();
        return 0;
      case WM_SIZE:
        if (wparam == SIZE_MINIMIZED) {
          if (tray_ready_) ShowWindow(hwnd_, SW_HIDE);
        } else {
          Layout();
        }
        return 0;
      case WM_DPICHANGED: {
        dpi_ = HIWORD(wparam);
        const RECT* suggested = reinterpret_cast<const RECT*>(lparam);
        SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        CreateFontForDpi();
        Layout();
        return 0;
      }
      case WM_SETTINGCHANGE:
      case WM_THEMECHANGED:
        ApplyTheme();
        return 0;
      case WM_ERASEBKGND: {
        RECT client{};
        GetClientRect(hwnd_, &client);
        FillRect(reinterpret_cast<HDC>(wparam), &client,
                 dark_ ? dark_brush_ : GetSysColorBrush(COLOR_BTNFACE));
        if (tabs_) {
          RECT tab_bounds{};
          RECT first_tab{};
          GetWindowRect(tabs_, &tab_bounds);
          MapWindowPoints(nullptr, hwnd_,
                          reinterpret_cast<POINT*>(&tab_bounds), 2);
          if (TabCtrl_GetItemRect(tabs_, 0, &first_tab)) {
            RECT page{tab_bounds.left,
                      tab_bounds.top + first_tab.bottom - 1,
                      tab_bounds.right, tab_bounds.bottom};
            FillRect(reinterpret_cast<HDC>(wparam), &page,
                     dark_ ? page_brush_ : GetSysColorBrush(COLOR_WINDOW));
          }
        }
        return 1;
      }
      case WM_NOTIFY:
        if (reinterpret_cast<NMHDR*>(lparam)->idFrom == kTab &&
            reinterpret_cast<NMHDR*>(lparam)->code == TCN_SELCHANGE) {
          SelectPage(TabCtrl_GetCurSel(tabs_));
        }
        return 0;
      case WM_COMMAND:
        switch (LOWORD(wparam)) {
          case kPair: OpenPairing(); break;
          case kToggle:
            if (running_) {
              if (MessageBoxW(hwnd_,
                              Tr(L"Stop sending audio to the iPad?",
                                 L"停止向 iPad 发送声音吗？")
                                  .c_str(),
                              L"HearPort", MB_YESNO | MB_ICONQUESTION) == IDYES) {
                const bool diagnostic_active = diagnostic_duration_.has_value();
                StopService();
                if (diagnostic_active) {
                  SetWindowTextW(diagnostic_status_,
                                 Tr(L"Diagnostic session stopped.",
                                    L"诊断已停止。")
                                     .c_str());
                }
              }
            } else {
              StartService();
            }
            break;
          case kDiagnostics: ShowTestSettings(kDiagnostics); break;
          case kNetworkProbe: ShowTestSettings(kNetworkProbe); break;
          case kMusicTest: ShowTestSettings(kMusicTest); break;
          case kLog: OpenPath(data_dir_ / L"HearPort-sender.log"); break;
          case kReports: OpenPath(data_dir_ / L"diagnostics"); break;
          case kCalibrationResults: ShowCalibrationResults(); break;
          case kDetailedLogging:
            logger_.SetDetailedLogging(SendMessageW(detailed_logging_, BM_GETCHECK, 0, 0) == BST_CHECKED);
            break;
          case kSavePort: SavePortFromControl(); break;
          case kAutoStart:
            if (!SetAutoStart(SendMessageW(auto_start_, BM_GETCHECK, 0, 0) ==
                              BST_CHECKED)) {
              SendMessageW(auto_start_, BM_SETCHECK,
                           AutoStartEnabled() ? BST_CHECKED : BST_UNCHECKED, 0);
              MessageBoxW(hwnd_, Tr(L"Could not change startup settings.",
                                     L"无法修改开机启动设置。")
                                     .c_str(), L"HearPort", MB_OK | MB_ICONERROR);
            }
            break;
          case kTrayOpen: ShowWindowFromTray(); break;
          case kTrayExit: ConfirmExit(); break;
          case kCloseWindow: SendMessageW(hwnd_, WM_CLOSE, 0, 0); break;
          case kExitApplication: ConfirmExit(); break;
        }
        return 0;
      case kTrayMessage:
        if (LOWORD(lparam) == WM_LBUTTONDBLCLK ||
            LOWORD(lparam) == NIN_SELECT) {
          ShowWindowFromTray();
        } else if (LOWORD(lparam) == WM_RBUTTONUP ||
                   LOWORD(lparam) == WM_CONTEXTMENU) {
          ShowTrayMenu();
        }
        return 0;
      case WM_CLOSE:
        if (tray_ready_) {
          ShowWindow(hwnd_, SW_HIDE);
        } else {
          ConfirmExit();
        }
        return 0;
      case WM_CTLCOLORBTN:
      case WM_CTLCOLORSTATIC: {
        HDC context = reinterpret_cast<HDC>(wparam);
        HWND control = reinterpret_cast<HWND>(lparam);
        SetBkMode(context, TRANSPARENT);
        SetTextColor(context, dark_ ? RGB(242, 242, 242)
                                    : GetSysColor(COLOR_WINDOWTEXT));
        if (control == status_ && running_) {
          SetTextColor(context, dark_ ? RGB(105, 202, 138)
                                      : RGB(32, 128, 72));
        }
        const bool footer = control == footer_close_ || control == footer_exit_;
        HBRUSH background = dark_
            ? (footer ? dark_brush_ : page_brush_)
            : GetSysColorBrush(footer ? COLOR_BTNFACE : COLOR_WINDOW);
        return reinterpret_cast<LRESULT>(background);
      }
      case WM_CTLCOLOREDIT:
      case WM_CTLCOLORLISTBOX: {
        if (!dark_) return DefWindowProcW(hwnd_, message, wparam, lparam);
        HDC context = reinterpret_cast<HDC>(wparam);
        SetTextColor(context, RGB(242, 242, 242));
        SetBkColor(context, RGB(45, 45, 45));
        return reinterpret_cast<LRESULT>(edit_brush_);
      }
      case WM_DESTROY:
        KillTimer(hwnd_, kTimer);
        RemoveTrayIcon();
        StopService();
        if (font_) DeleteObject(font_);
        DeleteObject(dark_brush_);
        DeleteObject(page_brush_);
        DeleteObject(edit_brush_);
        PostQuitMessage(0);
        return 0;
      default:
        return DefWindowProcW(hwnd_, message, wparam, lparam);
    }
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    if (message == WM_NCCREATE) {
      auto* app = static_cast<Application*>(
          reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      app->hwnd_ = hwnd;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    }
    auto* app = reinterpret_cast<Application*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    return app ? app->Handle(message, wparam, lparam)
               : DefWindowProcW(hwnd, message, wparam, lparam);
  }

  HINSTANCE instance_ = nullptr;
  HWND hwnd_ = nullptr;
  HWND tabs_ = nullptr;
  std::array<std::vector<HWND>, 3> groups_;
  HWND footer_close_ = nullptr;
  HWND footer_exit_ = nullptr;
  HWND status_ = nullptr;
  HWND status_detail_ = nullptr;
  HWND computer_ = nullptr;
  HWND audio_ = nullptr;
  HWND listen_port_ = nullptr;
  HWND pin_ = nullptr;
  HWND toggle_ = nullptr;
  HWND diagnostic_status_ = nullptr;
  HWND detailed_logging_ = nullptr;
  HWND certificate_ = nullptr;
  HWND port_frame_ = nullptr;
  HWND port_edit_ = nullptr;
  HWND auto_start_ = nullptr;
  HFONT font_ = nullptr;
  UINT dpi_ = 96;
  UINT taskbar_created_ = 0;
  std::array<std::vector<HWND>, 3> pages_;
  HWND settings_window_ = nullptr, settings_file_ = nullptr, settings_start_ = nullptr, settings_duration_ = nullptr;
  HWND calibration_window_ = nullptr;
  HWND settings_maximum_ = nullptr, settings_purpose_ = nullptr;
  bool calibration_selected_ = true;
  std::uint8_t calibration_goal_ = 0;
  unsigned calibration_seconds_ = 30, calibration_maximum_ = 100;
  std::filesystem::path calibration_report_path_;
  std::optional<hearport::windows::CalibrationReport> calibration_report_;
  int settings_kind_ = 0;
  bool settings_start_requested_ = false;
  std::wstring music_path_, music_start_seconds_ = L"0", music_seconds_ = L"120", live_seconds_ = L"60";
  bool music_test_active_ = false;
  bool start_hidden_ = false;
  bool running_ = false;
  bool connected_ = false;
  bool reliable_ = false;
  bool usb_connected_ = false;
  bool certificate_ready_ = false;
  bool tray_ready_ = false;
  bool dark_ = false;
  std::uint16_t port_ = 52137;
  std::wstring error_;
  std::filesystem::path data_dir_;
  std::optional<Clock::time_point> pin_expires_;
  std::optional<std::chrono::seconds> diagnostic_duration_;
  bool network_probe_active_ = false;
  int completed_test_ = 0;
  Clock::time_point diagnostic_started_{};
  SenderDiagnosticLogger logger_;
  HBRUSH dark_brush_ = CreateSolidBrush(RGB(32, 32, 32));
  HBRUSH page_brush_ = CreateSolidBrush(RGB(42, 42, 42));
  HBRUSH edit_brush_ = CreateSolidBrush(RGB(45, 45, 45));
  std::unique_ptr<hearport::windows::SenderHost> host_;
  SenderService* service_ = nullptr;
};

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR command_line,
                    int show_command) {
  HANDLE singleton = CreateMutexW(nullptr, TRUE, L"Local\\HearPortSenderGui");
  if (singleton && GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = FindWindowW(kWindowClass, nullptr)) {
      ShowWindow(existing, SW_RESTORE);
      SetForegroundWindow(existing);
    }
    CloseHandle(singleton);
    return 0;
  }
  Application app(command_line &&
                  std::wstring_view(command_line).find(L"--background") !=
                      std::wstring_view::npos);
  const int result = app.Run(instance, show_command);
  if (singleton) CloseHandle(singleton);
  return result;
}
