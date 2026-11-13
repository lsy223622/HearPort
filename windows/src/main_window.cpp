#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include "main_window.h"
#include "winui_runtime.h"
#include <dwmapi.h>

#undef GetCurrentTime
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.ViewManagement.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

#include <array>
#include <algorithm>
#include <cmath>
#include <utility>

namespace {
using namespace winrt::Microsoft::UI;
using namespace Xaml;
using namespace Controls;
using Controls::Primitives::ToggleButton;

const wchar_t* Tr(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? chinese : english;
}

TextBlock Label(winrt::hstring value = {}, double size = 14, bool bold = false) {
  TextBlock text;
  text.Text(value);
  text.TextWrapping(TextWrapping::Wrap);
  text.FontSize(size);
  if (bold) text.FontWeight({600});
  return text;
}

void SetText(const TextBlock& text, const std::wstring& value) {
  if (text.Text() != std::wstring_view(value)) text.Text(value);
  const auto visibility = value.empty() ? Visibility::Collapsed : Visibility::Visible;
  if (text.Visibility() != visibility) text.Visibility(visibility);
}

StackPanel Column(double gap = 12) {
  StackPanel panel;
  panel.Spacing(gap);
  return panel;
}

StackPanel Row(double gap = 8) {
  auto panel = Column(gap);
  panel.Orientation(Orientation::Horizontal);
  return panel;
}

}  // namespace

struct MainWindow::Impl {
  std::function<void(MainAction)> action;
  std::function<void(bool, bool, std::uint32_t)> change_volume;
  WinUiRuntime runtime;
  Dispatching::DispatcherQueueController dispatcher{nullptr};
  Hosting::WindowsXamlManager xaml{nullptr};
  Window window{nullptr};
  HWND hwnd = nullptr;
  ContentControl page_host{nullptr};
  std::array<ToggleButton, 3> navigation{nullptr, nullptr, nullptr};
  std::array<StackPanel, 3> pages{nullptr, nullptr, nullptr};
  TextBlock status{nullptr}, detail{nullptr}, computer{nullptr}, audio{nullptr}, port_status{nullptr};
  TextBlock pairing{nullptr}, certificate{nullptr}, diagnostic{nullptr}, percentage{nullptr};
  Button sender{nullptr}, pair{nullptr}, hide{nullptr};
  StackPanel volume_row{nullptr};
  Slider volume{nullptr};
  StackPanel capture_options{nullptr};
  std::array<RadioButton, 2> capture_buttons{nullptr, nullptr};
  int capture_index = 0;
  TextBlock port{nullptr};
  CheckBox logging{nullptr}, startup{nullptr};
  bool updating_capture = false;
  bool updating_startup = false;
  bool updating_volume = false;
  bool dragging = false;
  std::uint32_t drag_start = 0;
  std::uint32_t shown_volume = 0;
  std::optional<std::uint32_t> pending_volume;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);
  int current_page = 0;

  void UpdateTitleBar(ElementTheme theme) const {
    const BOOL dark = theme == ElementTheme::Dark;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
  }

  Button Command(const wchar_t* label, MainAction command) {
    Button button;
    button.Content(winrt::box_value(label));
    button.CornerRadius({6, 6, 6, 6});
    button.Click([this, command](auto&&, auto&&) {
      dispatcher.DispatcherQueue().TryEnqueue([this, command, alive = alive] {
        if (*alive) action(command);
      });
    });
    return button;
  }

  void Section(const StackPanel& page, const wchar_t* title, const StackPanel& body) {
    Border card;
    card.CornerRadius({8, 8, 8, 8});
    card.BorderThickness({1, 1, 1, 1});
    card.Padding({18, 14, 18, 14});
    const auto update = [](const Border& card, ElementTheme theme) {
      using winrt::Windows::UI::Color;
      const bool dark = theme == ElementTheme::Dark;
      if (winrt::Windows::UI::ViewManagement::AccessibilitySettings().HighContrast()) {
        const auto color = GetSysColor(COLOR_WINDOWTEXT);
        card.BorderBrush(Media::SolidColorBrush(Color{255, GetRValue(color), GetGValue(color), GetBValue(color)}));
        card.Background(nullptr);
        return;
      }
      card.BorderBrush(Media::SolidColorBrush(dark ? Color{31, 255, 255, 255} : Color{26, 0, 0, 0}));
      card.Background(Media::SolidColorBrush(dark ? Color{10, 255, 255, 255} : Color{140, 255, 255, 255}));
    };
    card.ActualThemeChanged([update](FrameworkElement const& root, auto&&) { update(root.as<Border>(), root.ActualTheme()); });
    update(card, card.ActualTheme());
    auto content = Column(10);
    if (title) content.Children().Append(Label(title, 16, true));
    content.Children().Append(body);
    card.Child(content);
    page.Children().Append(card);
  }

  std::uint32_t Position() const {
    return static_cast<std::uint32_t>(std::lround(volume.Value()));
  }

  void VolumeInput() {
    using Xaml::Input::PointerEventHandler;
    volume.AddHandler(UIElement::PointerPressedEvent(), winrt::box_value(PointerEventHandler(
        [this](auto&&, auto&&) {
          dragging = true;
          drag_start = shown_volume;
          pending_volume.reset();
          change_volume(true, false, Position());
        })), true);
    volume.AddHandler(UIElement::PointerReleasedEvent(), winrt::box_value(PointerEventHandler(
        [this](auto&&, auto&&) {
          if (!std::exchange(dragging, false)) return;
          change_volume(false, Position() != drag_start, Position());
        })), true);
    volume.PointerCanceled([this](auto&&, auto&&) {
      if (std::exchange(dragging, false)) change_volume(false, false, Position());
    });
    volume.ValueChanged([this](auto&&, auto&&) {
      if (updating_volume) return;
      SetText(percentage, std::to_wstring(Position()) + L"%");
      if (dragging) {
        change_volume(true, false, Position());
      } else {
        const bool queued = pending_volume.has_value();
        pending_volume = Position();
        if (!queued) {
          dispatcher.DispatcherQueue().TryEnqueue([this, alive = alive] {
            if (!*alive) return;
            if (const auto value = std::exchange(pending_volume, std::nullopt)) {
              if (*value != shown_volume) change_volume(false, true, *value);
            }
          });
        }
      }
    });
  }

  void Overview() {
    auto connection = Column(8);
    status = Label({}, 25, true);
    detail = Label();
    sender = Command(Tr(L"Start sender", L"启动发送服务"), MainAction::sender);
    connection.Children().Append(status);
    connection.Children().Append(detail);
    connection.Children().Append(sender);
    Section(pages[0], nullptr, connection);

    auto info = Column(6);
    computer = Label();
    audio = Label();
    port_status = Label();
    for (const auto& field : {computer, audio, port_status}) info.Children().Append(field);
    volume_row = Row(10);
    volume_row.Visibility(Visibility::Collapsed);
    auto volume_title = Label(Tr(L"iPad volume", L"iPad 音量"));
    volume_title.VerticalAlignment(VerticalAlignment::Center);
    volume = Slider();
    volume.Width(200);
    volume.Maximum(100);
    volume.StepFrequency(1);
    volume.IsThumbToolTipEnabled(false);
    Automation::AutomationProperties::SetName(volume, volume_title.Text());
    percentage = Label();
    percentage.VerticalAlignment(VerticalAlignment::Center);
    volume_row.Children().Append(volume_title);
    volume_row.Children().Append(volume);
    volume_row.Children().Append(percentage);
    info.Children().Append(volume_row);
    VolumeInput();
    Section(pages[0], Tr(L"Connection", L"连接信息"), info);

    auto device = Column(8);
    pairing = Label();
    pair = Command(Tr(L"Pair new iPad", L"配对新 iPad"), MainAction::pair);
    device.Children().Append(pairing);
    device.Children().Append(pair);
    Section(pages[0], Tr(L"Pairing", L"设备配对"), device);
  }

  void Diagnostics() {
    auto tests = Column(8);
    tests.Children().Append(Command(Tr(L"Live diagnostics…", L"实时诊断…"), MainAction::live_test));
    tests.Children().Append(Command(Tr(L"Network test…", L"网络测试…"), MainAction::network_test));
    tests.Children().Append(Command(Tr(L"Music compression test…", L"音乐压缩对比测试…"), MainAction::music_test));
    Section(pages[1], Tr(L"Tests", L"测试"), tests);
    auto logs = Column(10);
    diagnostic = Label(Tr(L"No diagnostic session is running.", L"当前没有进行中的诊断。"));
    logs.Children().Append(diagnostic);
    logging = CheckBox();
    logging.Content(winrt::box_value(Tr(L"Detailed logging (up to 128 MiB)", L"详细日志（最多 128 MiB）")));
    logging.Click([this](auto&&, auto&&) { action(MainAction::detailed_logging); });
    logs.Children().Append(logging);
    auto links = Row();
    links.Children().Append(Command(Tr(L"Open sender log", L"打开运行日志"), MainAction::log));
    links.Children().Append(Command(Tr(L"Open report folder", L"打开报告文件夹"), MainAction::reports));
    links.Children().Append(Command(Tr(L"Recommendations", L"推荐结果"), MainAction::results));
    logs.Children().Append(links);
    Section(pages[1], Tr(L"Logs and reports", L"日志与报告"), logs);
  }

  void Settings(std::uint16_t port_number, bool endpoint, bool auto_start) {
    auto connection = Column(12);
    certificate = Label();
    connection.Children().Append(certificate);
    auto port_row = Row();
    port = Label();
    port.Text(std::wstring(Tr(L"Listening UDP port: ", L"监听 UDP 端口：")) + std::to_wstring(port_number));
    port.VerticalAlignment(VerticalAlignment::Center);
    port_row.Children().Append(port);
    auto apply = Command(Tr(L"Edit", L"修改"), MainAction::port);
    apply.VerticalAlignment(VerticalAlignment::Bottom);
    port_row.Children().Append(apply);
    connection.Children().Append(port_row);
    capture_options = Column(2);
    capture_options.Children().Append(Label(Tr(L"Audio capture", L"音频采集")));
    capture_index = endpoint ? 1 : 0;
    const std::array sources{Tr(L"Process loopback", L"进程回环"),
                             Tr(L"Default output device", L"默认输出设备")};
    for (int index = 0; index < 2; ++index) {
      auto& option = capture_buttons[index];
      option = RadioButton();
      option.GroupName(L"AudioCapture");
      option.Content(winrt::box_value(sources[index]));
      option.IsChecked(winrt::box_value(index == capture_index).as<winrt::Windows::Foundation::IReference<bool>>());
      option.Checked([this, index](auto&&, auto&&) {
        if (updating_capture || capture_index == index) return;
        capture_index = index;
        action(MainAction::capture);
      });
      capture_options.Children().Append(option);
    }
    connection.Children().Append(capture_options);
    Section(pages[2], Tr(L"Connection", L"连接"), connection);

    auto behavior = Column(8);
    startup = CheckBox();
    startup.Content(winrt::box_value(Tr(L"Run when I sign in to Windows", L"登录 Windows 后自动运行")));
    startup.IsChecked(winrt::box_value(auto_start).as<winrt::Windows::Foundation::IReference<bool>>());
    startup.Click([this](auto&&, auto&&) { if (!updating_startup) action(MainAction::auto_start); });
    behavior.Children().Append(startup);
    Section(pages[2], Tr(L"Windows startup", L"Windows 启动"), behavior);
  }

  void Create(std::uint16_t port_number, bool endpoint, bool auto_start) {
    runtime.Load();
    dispatcher = Dispatching::DispatcherQueueController::CreateOnCurrentThread();
    xaml = Hosting::WindowsXamlManager::InitializeForCurrentThread();
    window = Window();
    window.Title(L"HearPort");
    window.SystemBackdrop(Media::MicaBackdrop());
    EnumThreadWindows(GetCurrentThreadId(), [](HWND candidate, LPARAM data) -> BOOL {
      wchar_t title[32]{};
      GetWindowTextW(candidate, title, ARRAYSIZE(title));
      if (std::wstring_view(title) != L"HearPort") return TRUE;
      *reinterpret_cast<HWND*>(data) = candidate;
      return FALSE;
    }, reinterpret_cast<LPARAM>(&hwnd));
    if (!hwnd) winrt::throw_hresult(E_HANDLE);
    const UINT dpi = GetDpiForWindow(hwnd);
    MONITORINFO monitor{sizeof(monitor)};
    if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
      const int width = std::min<int>(MulDiv(690, dpi, 96), monitor.rcWork.right - monitor.rcWork.left);
      const int height = std::min<int>(MulDiv(610, dpi, 96), monitor.rcWork.bottom - monitor.rcWork.top);
      window.AppWindow().MoveAndResize({
          monitor.rcWork.left + (monitor.rcWork.right - monitor.rcWork.left - width) / 2,
          monitor.rcWork.top + (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2,
          width, height});
    }

    auto tabs = Row(12);
    tabs.Padding({24, 10, 24, 0});
    const std::array labels{Tr(L"Overview", L"概览"), Tr(L"Diagnostics", L"诊断"), Tr(L"Settings", L"设置")};
    const std::array ids{L"OverviewPage", L"DiagnosticsPage", L"SettingsPage"};
    for (int index = 0; index < 3; ++index) {
      auto& item = navigation[index];
      item = ToggleButton();
      item.Content(winrt::box_value(labels[index]));
      item.CornerRadius({6, 6, 6, 6});
      item.Padding({15, 6, 15, 6});
      Automation::AutomationProperties::SetAutomationId(item, ids[index]);
      item.Checked([this, index](auto&&, auto&&) {
        if (current_page == index) return;
        dispatcher.DispatcherQueue().TryEnqueue([this, index, alive = alive] {
          if (*alive) Display(index);
        });
      });
      item.Unchecked([this, index](auto&&, auto&&) {
        if (current_page == index) {
          navigation[index].IsChecked(winrt::box_value(true).as<winrt::Windows::Foundation::IReference<bool>>());
        }
      });
      tabs.Children().Append(item);
      pages[index] = Column(12);
      pages[index].Padding({24, 12, 24, 20});
      pages[index].MaxWidth(820);
    }
    Overview();
    Diagnostics();
    Settings(port_number, endpoint, auto_start);
    auto root = Grid();
    RowDefinition page_row;
    page_row.Height({1, GridUnitType::Star});
    RowDefinition footer_row;
    footer_row.Height({1, GridUnitType::Auto});
    RowDefinition tabs_row;
    tabs_row.Height({1, GridUnitType::Auto});
    root.RowDefinitions().Append(tabs_row);
    root.RowDefinitions().Append(page_row);
    root.RowDefinitions().Append(footer_row);
    root.Children().Append(tabs);
    page_host = ContentControl();
    page_host.HorizontalContentAlignment(HorizontalAlignment::Stretch);
    page_host.VerticalContentAlignment(VerticalAlignment::Stretch);
    Grid::SetRow(page_host, 1);
    root.Children().Append(page_host);
    auto footer = Row();
    footer.Padding({24, 8, 24, 14});
    footer.HorizontalAlignment(HorizontalAlignment::Right);
    hide = Command(Tr(L"Minimize to tray", L"最小化到托盘"), MainAction::hide);
    footer.Children().Append(hide);
    footer.Children().Append(Command(Tr(L"Exit", L"退出程序"), MainAction::exit));
    Grid::SetRow(footer, 2);
    root.Children().Append(footer);
    Display(0);
    window.Content(root);
    UpdateTitleBar(root.ActualTheme());
    root.ActualThemeChanged([this](FrameworkElement const& element, auto&&) {
      UpdateTitleBar(element.ActualTheme());
    });
  }

  void Display(int page) {
    current_page = page;
    // Retain the scroll hosts with their page contents across navigation.
    if (!scroll[page]) {
      scroll[page] = ScrollViewer();
      scroll[page].Content(pages[page]);
    }
    for (int index = 0; index < 3; ++index) {
      navigation[index].IsChecked(winrt::box_value(index == page).as<winrt::Windows::Foundation::IReference<bool>>());
    }
    page_host.Content(nullptr);
    page_host.Content(scroll[page]);
  }
  std::array<ScrollViewer, 3> scroll{nullptr, nullptr, nullptr};
};

MainWindow::MainWindow(std::function<void(MainAction)> action,
                       std::function<void(bool, bool, std::uint32_t)> volume)
    : impl_(new Impl{std::move(action), std::move(volume)}) {}
MainWindow::~MainWindow() {
  *impl_->alive = false;
  if (impl_->window && IsWindow(impl_->hwnd)) impl_->window.Close();
}
HRESULT MainWindow::Create(std::uint16_t port, bool endpoint, bool auto_start) {
  try {
    impl_->Create(port, endpoint, auto_start);
    return S_OK;
  } catch (const winrt::hresult_error& error) {
    OutputDebugStringW(error.message().c_str());
    return error.code();
  }
}
HWND MainWindow::handle() const { return impl_->hwnd; }
void MainWindow::Show() {
  ShowWindow(impl_->hwnd, SW_SHOW);
  impl_->window.Activate();
}
void MainWindow::SelectPage(int page) { impl_->Display(page); }
int MainWindow::page() const { return impl_->current_page; }
void MainWindow::SetStatus(const std::wstring& heading, const std::wstring& detail,
                           const std::wstring& audio, const std::wstring& port) {
  SetText(impl_->status, heading);
  SetText(impl_->detail, detail);
  SetText(impl_->audio, audio);
  SetText(impl_->port_status, port);
}
void MainWindow::SetComputer(const std::wstring& text) { SetText(impl_->computer, text); }
void MainWindow::SetActions(bool running, bool sender_enabled, bool paired, bool pair_enabled) {
  impl_->sender.Content(winrt::box_value(running ? Tr(L"Stop sender", L"停止发送服务") : Tr(L"Start sender", L"启动发送服务")));
  impl_->sender.IsEnabled(sender_enabled);
  impl_->pair.Content(winrt::box_value(paired ? Tr(L"Unpair iPad", L"取消配对") : Tr(L"Pair new iPad", L"配对新 iPad")));
  impl_->pair.IsEnabled(pair_enabled);
}
void MainWindow::SetPairing(const std::wstring& text) { SetText(impl_->pairing, text); }
void MainWindow::SetCertificate(const std::wstring& text) { SetText(impl_->certificate, text); }
void MainWindow::SetDiagnostic(const std::wstring& text) { SetText(impl_->diagnostic, text); }
void MainWindow::SetVolume(std::optional<std::uint32_t> value) {
  impl_->volume_row.Visibility(value ? Visibility::Visible : Visibility::Collapsed);
  if (!value) {
    impl_->dragging = false;
    impl_->pending_volume.reset();
    return;
  }
  impl_->shown_volume = *value;
  if (impl_->dragging) return;
  SetText(impl_->percentage, std::to_wstring(*value) + L"%");
  if (impl_->Position() == *value) return;
  impl_->updating_volume = true;
  impl_->volume.Value(*value);
  impl_->updating_volume = false;
}
void MainWindow::EnableCapture(bool enabled) {
  for (const auto& option : impl_->capture_buttons) option.IsEnabled(enabled);
}
void MainWindow::SetCapture(int value) {
  impl_->updating_capture = true;
  impl_->capture_index = value;
  impl_->capture_buttons[value].IsChecked(winrt::box_value(true).as<winrt::Windows::Foundation::IReference<bool>>());
  impl_->updating_capture = false;
}
int MainWindow::capture() const { return impl_->capture_index; }
void MainWindow::SetPort(std::uint16_t value) {
  SetText(impl_->port, std::wstring(Tr(L"Listening UDP port: ", L"监听 UDP 端口：")) + std::to_wstring(value));
}
bool MainWindow::detailed_logging() const { const auto checked = impl_->logging.IsChecked(); return checked && checked.Value(); }
bool MainWindow::auto_start() const { const auto checked = impl_->startup.IsChecked(); return checked && checked.Value(); }
void MainWindow::SetAutoStart(bool enabled) {
  impl_->updating_startup = true;
  impl_->startup.IsChecked(winrt::box_value(enabled).as<winrt::Windows::Foundation::IReference<bool>>());
  impl_->updating_startup = false;
}
void MainWindow::EnableHide(bool enabled) { impl_->hide.IsEnabled(enabled); }
