#define _WIN32_WINNT 0x0A00
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <iphlpapi.h>
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <uxtheme.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cwchar>
#include <filesystem>
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
constexpr UINT kTimer = 1;
constexpr UINT kTrayIcon = 1;
constexpr int kTab = 100;
constexpr int kPair = 101;
constexpr int kToggle = 102;
constexpr int kLog = 103;
constexpr int kReports = 104;
constexpr int kDiagnostics = 105;
constexpr int kDuration = 106;
constexpr int kPort = 107;
constexpr int kSavePort = 108;
constexpr int kAutoStart = 109;
constexpr int kNetworkProbe = 110;
constexpr int kCloseWindow = 112;
constexpr int kExitApplication = 113;
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
    window_class.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_HEARPORT));
    window_class.hIconSm = reinterpret_cast<HICON>(LoadImageW(
        instance, MAKEINTRESOURCEW(IDI_HEARPORT), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_SHARED));
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
                           GetFocus() == port_edit_
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
      SetFocus(app->port_edit_);
      return 0;
    } else if (message == WM_COMMAND &&
               (HIWORD(wparam) == EN_SETFOCUS ||
                HIWORD(wparam) == EN_KILLFOCUS)) {
      InvalidateRect(hwnd, nullptr, FALSE);
    } else if (message == WM_CTLCOLOREDIT) {
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
    Group(1, Tr(L"Diagnostics and network test", L"诊断与网络测试"));
    Group(1, Tr(L"Logs and reports", L"日志与报告"));
    Group(2, Tr(L"Connection", L"连接"));
    Group(2, Tr(L"Windows startup", L"Windows 启动"));

    status_ = Control(0, L"STATIC", L"", SS_LEFT, 0);
    status_detail_ = Control(0, L"STATIC", L"",
                             SS_LEFT | SS_CENTERIMAGE, 0);
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

    Control(1, L"STATIC", Tr(L"Duration", L"诊断时长"),
            SS_LEFT | SS_CENTERIMAGE, 0);
    Control(1, L"STATIC",
            Tr(L"Diagnostics use audio. Network test runs eight 30-second groups without audio and uploads the iPad report.",
               L"诊断使用音频；网络测试无音频，连续运行八组各 30 秒并自动回传 iPad 报告。"),
            SS_LEFT, 0);
    duration_ = Control(1, L"BUTTON", Tr(L"1 minute...", L"1 分钟..."),
                        WS_TABSTOP | BS_PUSHBUTTON, kDuration);
    Control(1, L"BUTTON", Tr(L"Start diagnostics", L"开始诊断"),
            WS_TABSTOP | BS_PUSHBUTTON, kDiagnostics);
    Control(1, L"BUTTON", Tr(L"Network test", L"网络测试"),
            WS_TABSTOP | BS_PUSHBUTTON, kNetworkProbe);
    diagnostic_status_ = Control(1, L"STATIC", L"", SS_LEFT, 0);
    Control(1, L"BUTTON", Tr(L"Open sender log", L"打开运行日志"),
            WS_TABSTOP | BS_PUSHBUTTON, kLog);
    Control(1, L"BUTTON", Tr(L"Open report folder", L"打开报告文件夹"),
            WS_TABSTOP | BS_PUSHBUTTON, kReports);

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
        pages_[1].size() != 8 || pages_[2].size() != 7 ||
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
    Place(overview[1], 100, 108, group_width - 200, 29);
    Place(overview[2], 44, 185, group_width - 24, 24);
    Place(overview[3], 44, 213, group_width - 24, 24);
    Place(overview[4], 44, 241, group_width - 24, 24);
    Place(overview[5], 44, 312, group_width - 24, 45);
    Place(overview[6], width - 162, 359, 118, 29);
    Place(overview[7], width - 162, 108, 118, 29);

    auto& diagnostics = pages_[1];
    Place(diagnostics[0], 44, 79, 100, 29);
    Place(diagnostics[1], 44, 122, group_width - 24, 45);
    Place(diagnostics[2], 150, 79, 100, 29);
    Place(diagnostics[3], width - 162, 183, 118, 29);
    Place(diagnostics[4], width - 288, 183, 118, 29);
    Place(diagnostics[5], 44, 263, group_width - 24, 50);
    Place(diagnostics[6], width - 288, 359, 118, 29);
    Place(diagnostics[7], width - 162, 359, 118, 29);

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
    if (running_ && network_probe_active_ && connected_) {
      const std::uint32_t processed = service_->network_probe_packets_processed();
      std::uint32_t before_round = 0;
      std::size_t round_index = 0;
      for (; round_index < hearport::windows::kNetworkProbeRounds.size(); ++round_index) {
        const auto& round = hearport::windows::kNetworkProbeRounds[round_index];
        const auto round_packets = round.packets_per_second *
                                   hearport::windows::kNetworkProbeSecondsPerRound;
        if (processed < before_round + round_packets) break;
        before_round += round_packets;
      }
      if (round_index == hearport::windows::kNetworkProbeRounds.size()) {
        heading = Tr(L"Network test sent", L"网络测试发送完成");
        detail = Tr(L"Waiting for the iPad report.", L"正在等待 iPad 回传报告。");
      } else {
        const auto& round = hearport::windows::kNetworkProbeRounds[round_index];
        const auto round_seconds =
            (processed - before_round) / round.packets_per_second;
        const auto total_seconds =
            round_index * hearport::windows::kNetworkProbeSecondsPerRound +
            round_seconds;
        heading = Tr(L"Network test ", L"网络测试 ") +
                  std::to_wstring(round_index + 1) + L"/8 · " +
                  (round_index < 4 ? L"Datagram" : L"Reliable stream");
        detail = Tr(L"Round ", L"本组 ") + std::to_wstring(round_seconds) +
                 Tr(L"/30 s · Total ", L"/30 秒 · 总计 ") +
                 std::to_wstring(total_seconds) +
                 Tr(L"/240 s", L"/240 秒");
        audio_label = Tr(L"Packet: ", L"数据包：") +
                      std::to_wstring(round.payload_bytes) +
                      Tr(L" B · ", L" 字节 · ") +
                      std::to_wstring(round.packets_per_second) +
                      Tr(L" pkt/s · burst ", L" 包/秒 · 每批 ") +
                      std::to_wstring(round.burst_packets);
      }
    } else if (running_ && network_probe_active_) {
      heading = Tr(L"Network test ready", L"网络测试待连接");
      detail = Tr(L"Connect the iPad to begin eight rounds.",
                  L"连接 iPad 后开始八组测试。");
      audio_label = Tr(L"Test data only; no audio is sent.",
                       L"仅传输测试数据，不发送音频。");
    } else if (running_ && connected_) {
      heading = Tr(L"iPad connected", L"iPad 已连接");
      detail = reliable_ ? Tr(L"Audio: reliable stream", L"音频：稳定性模式")
                         : Tr(L"Audio: low latency", L"音频：低延迟模式");
    } else if (running_ && network_probe_completed_) {
      heading = Tr(L"Network test complete", L"网络测试已完成");
      detail = Tr(L"Report saved in the diagnostics folder.",
                  L"报告已保存到诊断文件夹。");
    } else if (running_) {
      heading = Tr(L"Ready for iPad", L"已就绪，等待 iPad 连接");
      detail = Tr(L"HearPort is listening on your local network.",
                  L"HearPort 正在局域网中等待连接。");
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
      const std::string pin = authentication_->pairing_pin();
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
                    bool network_probe = false) {
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
    service_ = std::make_unique<SenderService>(*identity);
    service_->ConfigureNetworkProbe(network_probe);
    service_->ConfigureDebugDuration(diagnostics);
    service_->SetDebugOutputDirectory(data_dir_ / L"diagnostics");
    hearport::security::Bytes32 spki = identity->certificate_spki_sha256;
    authentication_ = std::make_unique<SenderAuthentication>(
        *service_, spki, hearport::windows::ProtectedCredentialStore{},
        data_dir_ / L"diagnostics");
    authentication_->SetConnectionHandler([this](bool connected, bool reliable) {
      PostMessageW(hwnd_, kConnectionMessage, connected, reliable);
    });
    service_->SetControlHandler([this](std::span<const std::byte> payload) {
      return authentication_->HandleControlPayload(payload);
    });
    service_->SetResetHandler([this] { authentication_->OnCaptureReset(); });
    service_->SetClosedHandler([this] { authentication_->Reset(); });
    service_->SetDebugEndedHandler(
        [this](std::array<std::byte, 16> session, std::uint32_t reason) {
          authentication_->OnDebugSessionEnded(session, reason);
        });
    if (!service_->Start()) {
      authentication_.reset();
      service_.reset();
      logger_.Stop();
      error_ = network_probe
                   ? Tr(L"Could not start the network listener.", L"无法启动网络监听。")
                   : Tr(L"Could not start audio capture or the network listener.",
                        L"无法启动音频采集或网络监听。");
      UpdateStatus();
      return;
    }
    running_ = true;
    network_probe_completed_ = false;
    connected_ = false;
    reliable_ = false;
    diagnostic_duration_ = diagnostics;
    network_probe_active_ = network_probe;
    if (diagnostics) {
      diagnostic_started_ = Clock::now();
      const auto message = network_probe
          ? Tr(L"Connect the iPad to run eight 30-second tests.",
               L"请连接 iPad，开始八组各 30 秒的测试。")
          : Tr(L"Waiting for iPad and its diagnostic report…",
               L"正在等待 iPad 连接并传回诊断报告……");
      SetWindowTextW(diagnostic_status_, message.c_str());
    }
    UpdateStatus();
  }

  void StopService() {
    if (service_) service_->Stop();
    authentication_.reset();
    service_.reset();
    logger_.Stop();
    running_ = false;
    connected_ = false;
    reliable_ = false;
    diagnostic_duration_.reset();
    network_probe_active_ = false;
    pin_expires_.reset();
    UpdateStatus();
  }

  void OpenPairing() {
    if (!running_ || !authentication_) return;
    if (!authentication_->OpenPairingWindow()) {
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
    if (MessageBoxW(hwnd_,
                    Tr(L"Starting diagnostics briefly interrupts the current audio stream. Continue?",
                       L"开始诊断会短暂中断当前音频连接。继续吗？")
                        .c_str(),
                    L"HearPort", MB_YESNO | MB_ICONQUESTION) != IDYES) {
      return;
    }
    constexpr std::array<int, 4> minutes{1, 2, 5, 10};
    StopService();
    StartService(std::chrono::seconds(minutes[selected_duration_] * 60));
    if (!running_) {
      SetWindowTextW(diagnostic_status_,
                     Tr(L"Could not start diagnostics. Check the overview and log.",
                        L"无法开始诊断，请查看概览和运行日志。")
                         .c_str());
    }
  }

  void StartNetworkProbe() {
    StopService();
    StartService(std::chrono::seconds(
                     hearport::windows::kNetworkProbeDurationSeconds), true);
    if (!running_) {
      SetWindowTextW(diagnostic_status_,
                     Tr(L"Could not start the network test. Check the overview and log.",
                        L"无法启动网络测试，请查看概览和运行日志。")
                         .c_str());
    }
    SelectPage(0);
  }

  void ChooseDuration() {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    for (int minutes : {1, 2, 5, 10}) {
      const std::wstring label = std::to_wstring(minutes) +
                                 Tr(L" minutes", L" 分钟");
      AppendMenuW(menu, MF_STRING, 300 + minutes, label.c_str());
    }
    RECT button{};
    GetWindowRect(duration_, &button);
    SetForegroundWindow(hwnd_);
    const int chosen = TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
        button.left, button.bottom, 0, hwnd_, nullptr);
    DestroyMenu(menu);
    constexpr std::array<int, 4> minutes{1, 2, 5, 10};
    for (int index = 0; index < 4; ++index) {
      if (chosen == 300 + minutes[index]) {
        selected_duration_ = index;
        const std::wstring label = std::to_wstring(minutes[index]) +
                                   Tr(L" minutes...", L" 分钟...");
        SetWindowTextW(duration_, label.c_str());
        break;
      }
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
      StopService();
      StartService(diagnostics, network_probe);
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
    if (pin_expires_ || network_probe_active_) UpdateStatus();
    if (!diagnostic_duration_ || !service_) return;
    if (service_->WaitForDebugCompletion(std::chrono::milliseconds(0))) {
      const bool network_probe = network_probe_active_;
      StopService();
      StartService();
      network_probe_completed_ = network_probe && running_;
      UpdateStatus();
      SetWindowTextW(diagnostic_status_,
                     Tr(L"Diagnostic report saved in the report folder.",
                        L"诊断报告已保存到报告文件夹。")
                         .c_str());
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
      case kConnectionMessage:
        connected_ = wparam != 0;
        reliable_ = lparam != 0;
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
          case kDiagnostics: StartDiagnostics(); break;
          case kNetworkProbe: StartNetworkProbe(); break;
          case kDuration: ChooseDuration(); break;
          case kLog: OpenPath(data_dir_ / L"HearPort-sender.log"); break;
          case kReports: OpenPath(data_dir_ / L"diagnostics"); break;
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
  HWND duration_ = nullptr;
  int selected_duration_ = 0;
  HWND diagnostic_status_ = nullptr;
  HWND certificate_ = nullptr;
  HWND port_frame_ = nullptr;
  HWND port_edit_ = nullptr;
  HWND auto_start_ = nullptr;
  HFONT font_ = nullptr;
  UINT dpi_ = 96;
  UINT taskbar_created_ = 0;
  std::array<std::vector<HWND>, 3> pages_;
  bool start_hidden_ = false;
  bool running_ = false;
  bool connected_ = false;
  bool reliable_ = false;
  bool certificate_ready_ = false;
  bool tray_ready_ = false;
  bool dark_ = false;
  std::uint16_t port_ = 52137;
  std::wstring error_;
  std::filesystem::path data_dir_;
  std::optional<Clock::time_point> pin_expires_;
  std::optional<std::chrono::seconds> diagnostic_duration_;
  bool network_probe_active_ = false;
  bool network_probe_completed_ = false;
  Clock::time_point diagnostic_started_{};
  SenderDiagnosticLogger logger_;
  HBRUSH dark_brush_ = CreateSolidBrush(RGB(32, 32, 32));
  HBRUSH page_brush_ = CreateSolidBrush(RGB(42, 42, 42));
  HBRUSH edit_brush_ = CreateSolidBrush(RGB(45, 45, 45));
  std::unique_ptr<SenderService> service_;
  std::unique_ptr<SenderAuthentication> authentication_;
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
