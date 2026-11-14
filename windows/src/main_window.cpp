#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include "main_window.h"
#include "winui_runtime.h"
#include <shobjidl.h>

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
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

#include <array>
#include <algorithm>
#include <cmath>
#include <utility>
#include <filesystem>

namespace {
using namespace winrt::Microsoft::UI;
using namespace Xaml;
using namespace Controls;
// CMake builds the UI in C++ so there is no XAML compiler generated provider.
struct HearPortXamlApp : ApplicationT<HearPortXamlApp, Markup::IXamlMetadataProvider> {
  explicit HearPortXamlApp(std::function<void()> start) : launched(std::move(start)) {}
  void OnLaunched(LaunchActivatedEventArgs const&) {
    XamlTypeInfo::XamlControlsXamlMetaDataProvider::Initialize();
    auto resources = Resources();
    if (!resources) {
      resources = ResourceDictionary();
      Resources(resources);
    }
    resources.MergedDictionaries().Append(XamlControlsResources());
    launched();
  }
  Markup::IXamlType GetXamlType(winrt::Windows::UI::Xaml::Interop::TypeName const& type) {
    return Provider().GetXamlType(type);
  }
  Markup::IXamlType GetXamlType(winrt::hstring const& name) {
    return Provider().GetXamlType(name);
  }
  winrt::com_array<Markup::XmlnsDefinition> GetXmlnsDefinitions() {
    return Provider().GetXmlnsDefinitions();
  }

 private:
  XamlTypeInfo::XamlControlsXamlMetaDataProvider Provider() {
    if (!provider) provider = XamlTypeInfo::XamlControlsXamlMetaDataProvider();
    return provider;
  }
  XamlTypeInfo::XamlControlsXamlMetaDataProvider provider{nullptr};
  std::function<void()> launched;
};

const wchar_t* Tr(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? chinese : english;
}

TextBlock Label(std::wstring_view value = {}, double size = 14, bool bold = false) {
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
  Dispatching::DispatcherQueue dispatcher{nullptr};
  Window window{nullptr};
  HWND hwnd = nullptr;
  bool sending = false;
  ContentControl page_host{nullptr};
  ContentDialog active_dialog{nullptr};
  NavigationView navigation{nullptr};
  std::array<NavigationViewItem, 3> destinations{nullptr, nullptr, nullptr};
  std::array<StackPanel, 3> pages{nullptr, nullptr, nullptr};
  TextBlock status{nullptr}, detail{nullptr}, computer{nullptr}, audio{nullptr}, port_status{nullptr};
  TextBlock pairing{nullptr}, certificate{nullptr}, diagnostic{nullptr}, percentage{nullptr};
  Button sender{nullptr}, pair{nullptr}, hide{nullptr};
  Grid volume_row{nullptr};
  Border volume_card{nullptr};
  Slider volume{nullptr};
  ComboBox capture_source{nullptr};
  TextBlock port{nullptr};
  ToggleSwitch logging{nullptr}, startup{nullptr};
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
    const bool dark = theme == ElementTheme::Dark;
    const auto high_contrast = winrt::Windows::UI::ViewManagement::AccessibilitySettings().HighContrast();
    auto chrome = window.AppWindow().TitleBar();
    if (high_contrast) {
      chrome.ResetToDefault();
      return;
    }
    using winrt::Windows::UI::Color;
    chrome.ButtonForegroundColor(dark ? Color{255, 255, 255, 255} : Color{255, 0, 0, 0});
    chrome.ButtonBackgroundColor(Color{0, 0, 0, 0});
    chrome.ButtonInactiveBackgroundColor(Color{0, 0, 0, 0});
    chrome.ButtonHoverBackgroundColor(dark ? Color{24, 255, 255, 255} : Color{20, 0, 0, 0});
    chrome.ButtonPressedBackgroundColor(dark ? Color{40, 255, 255, 255} : Color{32, 0, 0, 0});
  }

  Style AccentButton() {
    return Application::Current().Resources().Lookup(winrt::box_value(L"AccentButtonStyle")).as<Style>();
  }

  Button Command(const wchar_t* label, MainAction command, bool accent = false) {
    Button button;
    button.Content(winrt::box_value(label));
    if (accent) button.Style(AccentButton());
    button.Click([this, command](auto&&, auto&&) {
      dispatcher.TryEnqueue([this, command, life = alive] {
        if (*life) action(command);
      });
    });
    return button;
  }

  Border Surface() {
    return Markup::XamlReader::Load(LR"(
      <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        CornerRadius="8" BorderThickness="1" Background="{ThemeResource CardBackgroundFillColorDefaultBrush}"
        BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}" />)").as<Border>();
  }

  Grid Columns(std::initializer_list<GridLength> widths) {
    Grid row;
    row.ColumnSpacing(14);
    for (const auto width : widths) {
      ColumnDefinition column;
      column.Width(width);
      row.ColumnDefinitions().Append(column);
    }
    return row;
  }

  void SettingRow(const StackPanel& page, Symbol symbol, const wchar_t* name,
                  const FrameworkElement& control, const TextBlock& detail = nullptr) {
    auto card = Surface();
    card.Padding({16, 10, 16, 10});
    card.MinHeight(58);
    auto row = Columns({{24, GridUnitType::Pixel}, {1, GridUnitType::Star}, {1, GridUnitType::Auto}});
    SymbolIcon icon(symbol);
    icon.VerticalAlignment(VerticalAlignment::Center);
    row.Children().Append(icon);
    auto labels = Column(3);
    labels.VerticalAlignment(VerticalAlignment::Center);
    labels.Children().Append(Label(name, 14, true));
    if (detail) labels.Children().Append(detail);
    Grid::SetColumn(labels, 1);
    row.Children().Append(labels);
    control.VerticalAlignment(VerticalAlignment::Center);
    Grid::SetColumn(control, 2);
    row.Children().Append(control);
    card.Child(row);
    page.Children().Append(card);
  }

  void CommandRow(const StackPanel& page, Symbol symbol, const wchar_t* label,
                  const wchar_t* verb, MainAction command) {
    auto button = Command(verb, command);
    Automation::AutomationProperties::SetName(button, label);
    SettingRow(page, symbol, label, button);
  }

  void Dialog(std::wstring title, UIElement content, const wchar_t* primary,
              std::function<void()> accepted = {}, std::function<bool()> validate = {}) {
    if (active_dialog) return;
    if (!IsWindowVisible(hwnd)) window.Activate();
    ContentDialog dialog;
    dialog.XamlRoot(window.Content().XamlRoot());
    dialog.Title(winrt::box_value(title));
    dialog.Content(content);
    dialog.CloseButtonText(primary ? Tr(L"Cancel", L"取消") : Tr(L"Close", L"关闭"));
    dialog.DefaultButton(validate ? ContentDialogButton::Primary : ContentDialogButton::Close);
    if (primary) {
      dialog.PrimaryButtonText(primary);
      if (validate) dialog.PrimaryButtonClick([validate = std::move(validate)](
          auto&&, const ContentDialogButtonClickEventArgs& args) { args.Cancel(!validate()); });
    }
    active_dialog = dialog;
    dialog.ShowAsync().Completed([this, accepted = std::move(accepted), life = alive](
        const auto& operation, auto state) {
      if (!*life) return;
      const bool confirmed = state == winrt::Windows::Foundation::AsyncStatus::Completed &&
                             operation.GetResults() == ContentDialogResult::Primary;
      dispatcher.TryEnqueue([this, life, accepted, confirmed] {
        if (!*life) return;
        active_dialog = nullptr;
        if (confirmed && accepted) accepted();
      });
    });
  }

  std::optional<std::wstring> PickAudio() const {
    winrt::com_ptr<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                               IID_PPV_ARGS(dialog.put())))) return {};
    const COMDLG_FILTERSPEC filters[]{{Tr(L"Audio", L"音频"), L"*.flac;*.mp3;*.wav;*.m4a;*.aac;*.wma"},
                                    {Tr(L"All files", L"所有文件"), L"*.*"}};
    dialog->SetFileTypes(ARRAYSIZE(filters), filters);
    if (FAILED(dialog->Show(hwnd))) return {};
    winrt::com_ptr<IShellItem> selected;
    if (FAILED(dialog->GetResult(selected.put()))) return {};
    PWSTR file;
    if (FAILED(selected->GetDisplayName(SIGDN_FILESYSPATH, &file))) return {};
    std::wstring path(file);
    CoTaskMemFree(file);
    return path;
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
          dispatcher.TryEnqueue([this, alive = alive] {
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
    // The device and connection are the focal point; shell and settings use standard Fluent surfaces.
    auto hero = Surface();
    auto tint = Markup::XamlReader::Load(LR"(
      <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          CornerRadius="8" Opacity="0.21" IsHitTestVisible="False">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="{ThemeResource CardBackgroundFillColorDefault}" Offset="0"/>
            <GradientStop Color="{ThemeResource CardBackgroundFillColorDefault}" Offset="0.45"/>
            <GradientStop Color="{ThemeResource SystemAccentColor}" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>)").as<Border>();
    auto hero_layout = Columns({{1, GridUnitType::Star}, {1, GridUnitType::Auto}});
    hero_layout.Padding({24, 22, 24, 22});
    auto connection = Column(8);
    connection.VerticalAlignment(VerticalAlignment::Center);
    status = Label({}, 27, true);
    detail = Label();
    sender = Command(Tr(L"Start sender", L"启动发送服务"), MainAction::sender, true);
    sender.Margin({0, 6, 0, 0});
    connection.Children().Append(status);
    connection.Children().Append(detail);
    connection.Children().Append(sender);
    hero_layout.Children().Append(connection);

    auto illustration = Markup::XamlReader::Load(LR"(
      <Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="172" Margin="12,0,8,0" IsHitTestVisible="False">
        <Canvas Width="180" Height="108">
          <Ellipse Canvas.Left="45" Canvas.Top="4" Width="110" Height="100"
                   Fill="{ThemeResource ControlFillColorDefaultBrush}" />
          <Path Stroke="{ThemeResource AccentTextFillColorPrimaryBrush}" StrokeThickness="2.5"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                Data="M29,77 H5 V25 Q5,20 10,20 H92 Q97,20 97,25 V77 H72 M50,78 V89 M34,90 H67
                      M121,15 H165 Q170,15 170,21 V86 Q170,92 165,92 H121 Q116,92 116,86 V21 Q116,15 121,15 Z
                      M134,82 H152 M21,49 H33 L39,40 L47,63 L55,33 L64,54 L69,49 H80 M101,48 H110 M138,50 H150 M144,43 V57"/>
        </Canvas>
      </Viewbox>)").as<Viewbox>();
    Grid::SetColumn(illustration, 1);
    hero_layout.Children().Append(illustration);
    hero_layout.SizeChanged([illustration](auto&&, const SizeChangedEventArgs& args) {
      illustration.Visibility(args.NewSize().Width >= 530 ? Visibility::Visible : Visibility::Collapsed);
    });
    Grid layer;
    layer.Children().Append(tint);
    layer.Children().Append(hero_layout);
    hero.Child(layer);
    pages[0].Children().Append(hero);

    auto devices = Column(5);
    pairing = Label();
    pair = Command(Tr(L"Pair new iPad", L"配对新 iPad"), MainAction::pair);
    SettingRow(devices, Symbol::CellPhone, L"iPad", pair, pairing);

    volume_row = Columns({{24, GridUnitType::Pixel}, {1, GridUnitType::Auto},
                          {1, GridUnitType::Star}, {48, GridUnitType::Pixel}});
    SymbolIcon volume_icon(Symbol::Volume);
    volume_icon.VerticalAlignment(VerticalAlignment::Center);
    volume_row.Children().Append(volume_icon);
    auto volume_title = Label(Tr(L"iPad volume", L"iPad 音量"), 14, true);
    volume_title.VerticalAlignment(VerticalAlignment::Center);
    Grid::SetColumn(volume_title, 1);
    volume_row.Children().Append(volume_title);
    volume = Slider();
    volume.Maximum(100);
    volume.StepFrequency(1);
    volume.IsThumbToolTipEnabled(false);
    volume.VerticalAlignment(VerticalAlignment::Center);
    Automation::AutomationProperties::SetName(volume, volume_title.Text());
    Grid::SetColumn(volume, 2);
    volume_row.Children().Append(volume);
    percentage = Label();
    percentage.VerticalAlignment(VerticalAlignment::Center);
    Grid::SetColumn(percentage, 3);
    volume_row.Children().Append(percentage);
    volume_card = Surface();
    volume_card.Padding({16, 8, 16, 8});
    volume_card.Child(volume_row);
    volume_card.Visibility(Visibility::Collapsed);
    devices.Children().Append(volume_card);
    VolumeInput();
    pages[0].Children().Append(devices);

    auto info = Column(5);
    info.Children().Append(Label(Tr(L"Connection", L"连接信息"), 16, true));
    computer = Label();
    audio = Label();
    port_status = Label();
    auto details = Column(5);
    for (const auto& field : {computer, audio, port_status}) details.Children().Append(field);
    auto card = Surface();
    card.Padding({16, 12, 16, 12});
    card.Child(details);
    info.Children().Append(card);
    pages[0].Children().Append(info);
  }

  void Diagnostics() {
    auto tests = Column(5);
    tests.Children().Append(Label(Tr(L"Tests", L"测试"), 16, true));
    diagnostic = Label();
    diagnostic.Visibility(Visibility::Collapsed);
    tests.Children().Append(diagnostic);
    const auto setup = Tr(L"Configure", L"配置");
    CommandRow(tests, Symbol::Audio, Tr(L"Live diagnostics", L"实时诊断"), setup, MainAction::live_test);
    CommandRow(tests, Symbol::World, Tr(L"Network test", L"网络测试"), setup, MainAction::network_test);
    CommandRow(tests, Symbol::MusicInfo, Tr(L"Music compression test", L"音乐压缩对比测试"), setup, MainAction::music_test);
    pages[1].Children().Append(tests);

    auto logs = Column(5);
    logs.Children().Append(Label(Tr(L"Logs and reports", L"日志与报告"), 16, true));
    logging = ToggleSwitch();
    const auto label = Tr(L"Detailed logging (up to 128 MiB)", L"详细日志（最多 128 MiB）");
    Automation::AutomationProperties::SetName(logging, label);
    logging.MinWidth(0);
    logging.Toggled([this](auto&&, auto&&) { action(MainAction::detailed_logging); });
    SettingRow(logs, Symbol::List, label, logging);
    const auto open = Tr(L"Open", L"打开");
    CommandRow(logs, Symbol::Document, Tr(L"Open sender log", L"打开运行日志"), open, MainAction::log);
    CommandRow(logs, Symbol::Folder, Tr(L"Open report folder", L"打开报告文件夹"), open, MainAction::reports);
    CommandRow(logs, Symbol::Preview, Tr(L"Recommendations", L"推荐结果"), Tr(L"View", L"查看"), MainAction::results);
    pages[1].Children().Append(logs);
  }

  void Settings(std::uint16_t port_number, bool endpoint, bool auto_start) {
    auto connection = Column(5);
    connection.Children().Append(Label(Tr(L"Audio and connection", L"音频与连接"), 16, true));
    capture_source = ComboBox();
    capture_source.Items().Append(winrt::box_value(Tr(L"Process loopback", L"进程回环")));
    capture_source.Items().Append(winrt::box_value(Tr(L"Default output device", L"默认输出设备")));
    capture_source.SelectedIndex(endpoint ? 1 : 0);
    capture_source.SelectionChanged([this](auto&&, auto&&) {
      if (!updating_capture) action(MainAction::capture);
    });
    const auto capture_label = Tr(L"Audio capture", L"音频采集");
    Automation::AutomationProperties::SetName(capture_source, capture_label);
    SettingRow(connection, Symbol::Audio, capture_label, capture_source);
    port = Label();
    port.Text(std::to_wstring(port_number));
    auto edit = Command(Tr(L"Edit", L"修改"), MainAction::port);
    Automation::AutomationProperties::SetAutomationId(edit, L"EditPort");
    SettingRow(connection, Symbol::World, Tr(L"Listening UDP port", L"监听 UDP 端口"), edit, port);
    certificate = Label();
    connection.Children().Append(certificate);
    pages[2].Children().Append(connection);

    auto behavior = Column(5);
    behavior.Children().Append(Label(Tr(L"Windows", L"Windows"), 16, true));
    startup = ToggleSwitch();
    startup.IsOn(auto_start);
    startup.MinWidth(0);
    const auto startup_label = Tr(L"Run when I sign in to Windows", L"登录 Windows 后自动运行");
    Automation::AutomationProperties::SetName(startup, startup_label);
    startup.Toggled([this](auto&&, auto&&) { if (!updating_startup) action(MainAction::auto_start); });
    SettingRow(behavior, Symbol::Clock, startup_label, startup);
    hide = Command(Tr(L"Minimize", L"最小化"), MainAction::hide);
    SettingRow(behavior, Symbol::BackToWindow, Tr(L"Minimize to tray", L"最小化到托盘"), hide);
    CommandRow(behavior, Symbol::Cancel, Tr(L"Exit HearPort", L"退出 HearPort"), Tr(L"Exit", L"退出"), MainAction::exit);
    pages[2].Children().Append(behavior);
  }

  void Create(std::uint16_t port_number, bool endpoint, bool auto_start) {
    dispatcher = Dispatching::DispatcherQueue::GetForCurrentThread();
    window = Window();
    window.Title(L"HearPort");
    Media::MicaBackdrop mica;
    mica.Kind(Composition::SystemBackdrops::MicaKind::BaseAlt);
    window.SystemBackdrop(mica);
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
      const int width = std::min<int>(MulDiv(960, dpi, 96), monitor.rcWork.right - monitor.rcWork.left);
      const int height = std::min<int>(MulDiv(680, dpi, 96), monitor.rcWork.bottom - monitor.rcWork.top);
      window.AppWindow().MoveAndResize({
          monitor.rcWork.left + (monitor.rcWork.right - monitor.rcWork.left - width) / 2,
          monitor.rcWork.top + (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2,
          width, height});
    }

    Grid root;
    RowDefinition title_row;
    title_row.Height({48, GridUnitType::Pixel});
    root.RowDefinitions().Append(title_row);
    root.RowDefinitions().Append(RowDefinition());

    auto title = Controls::TitleBar();
    title.Title(L"HearPort");
    SymbolIconSource icon;
    icon.Symbol(Symbol::Audio);
    title.IconSource(icon);
    title.IsPaneToggleButtonVisible(true);
    title.PaneToggleRequested([this](auto&&, auto&&) {
      navigation.IsPaneOpen(!navigation.IsPaneOpen());
    });
    root.Children().Append(title);
    window.ExtendsContentIntoTitleBar(true);
    window.SetTitleBar(title);
    window.AppWindow().TitleBar().PreferredHeightOption(Windowing::TitleBarHeightOption::Tall);

    navigation = NavigationView();
    navigation.PaneDisplayMode(NavigationViewPaneDisplayMode::Auto);
    navigation.CompactModeThresholdWidth(620);
    navigation.ExpandedModeThresholdWidth(840);
    navigation.OpenPaneLength(224);
    navigation.IsBackButtonVisible(NavigationViewBackButtonVisible::Collapsed);
    navigation.IsPaneToggleButtonVisible(false);
    navigation.IsSettingsVisible(false);
    Grid::SetRow(navigation, 1);
    root.Children().Append(navigation);

    const std::array labels{Tr(L"Overview", L"概览"), Tr(L"Diagnostics", L"诊断"), Tr(L"Settings", L"设置")};
    const std::array ids{L"OverviewPage", L"DiagnosticsPage", L"SettingsPage"};
    const std::array symbols{Symbol::Home, Symbol::ReportHacked, Symbol::Setting};
    for (int index = 0; index < 3; ++index) {
      auto& item = destinations[index];
      item = NavigationViewItem();
      item.Content(winrt::box_value(labels[index]));
      item.Icon(SymbolIcon(symbols[index]));
      Automation::AutomationProperties::SetAutomationId(item, ids[index]);
      (index == 2 ? navigation.FooterMenuItems() : navigation.MenuItems()).Append(item);
      pages[index] = Column(18);
      pages[index].Padding({32, 24, 32, 32});
      pages[index].MaxWidth(1000);
      pages[index].Children().Append(Label(labels[index], 32, true));
    }
    Overview();
    Diagnostics();
    Settings(port_number, endpoint, auto_start);
    navigation.ItemInvoked([this](auto&&, auto&&) {
      if (navigation.DisplayMode() == NavigationViewDisplayMode::Minimal) navigation.IsPaneOpen(false);
    });
    navigation.SelectionChanged([this](auto&&, const NavigationViewSelectionChangedEventArgs& args) {
      for (int i = 0; i < 3; ++i) {
        if (destinations[i] == args.SelectedItem() && i != current_page) Display(i);
      }
    });
    page_host = ContentControl();
    page_host.HorizontalContentAlignment(HorizontalAlignment::Stretch);
    page_host.VerticalContentAlignment(VerticalAlignment::Stretch);
    navigation.Content(page_host);
    Display(0);
    window.Content(root);
    UpdateTitleBar(root.ActualTheme());
    root.ActualThemeChanged([this](FrameworkElement const& element, auto&&) {
      UpdateTitleBar(element.ActualTheme());
    });
  }

  void Display(int page) {
    current_page = page;
    if (!scroll[page]) {
      scroll[page] = ScrollViewer();
      scroll[page].Content(pages[page]);
    }
    navigation.SelectedItem(destinations[page]);
    page_host.Content(scroll[page]);
  }
  std::array<ScrollViewer, 3> scroll{nullptr, nullptr, nullptr};
};

HRESULT MainWindow::RunApp(std::function<void()> launched, std::function<void()> finished) {
  try {
    WinUiRuntime runtime;
    runtime.Load();
    Application app{nullptr};
    try {
      Application::Start([&](auto&&) { app = winrt::make<HearPortXamlApp>(std::move(launched)); });
    } catch (...) {
      finished();
      throw;
    }
    finished();
    return S_OK;
  } catch (const winrt::hresult_error& error) {
    return error.code();
  }
}
void MainWindow::ExitApp() { Application::Current().Exit(); }

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
  if (running != impl_->sending) {
    impl_->sending = running;
    impl_->sender.Style(running ? nullptr : impl_->AccentButton());
  }
  impl_->sender.Content(winrt::box_value(running ? Tr(L"Stop sender", L"停止发送服务") : Tr(L"Start sender", L"启动发送服务")));
  impl_->sender.IsEnabled(sender_enabled);
  impl_->pair.Content(winrt::box_value(paired ? Tr(L"Unpair iPad", L"取消配对") : Tr(L"Pair new iPad", L"配对新 iPad")));
  impl_->pair.IsEnabled(pair_enabled);
}
void MainWindow::SetPairing(const std::wstring& text) { SetText(impl_->pairing, text); }
void MainWindow::SetCertificate(const std::wstring& text) { SetText(impl_->certificate, text); }
void MainWindow::SetDiagnostic(const std::wstring& text) { SetText(impl_->diagnostic, text); }
void MainWindow::SetVolume(std::optional<std::uint32_t> value) {
  impl_->volume_card.Visibility(value ? Visibility::Visible : Visibility::Collapsed);
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
  impl_->capture_source.IsEnabled(enabled);
}
void MainWindow::SetCapture(int value) {
  impl_->updating_capture = true;
  impl_->capture_source.SelectedIndex(value);
  impl_->updating_capture = false;
}
int MainWindow::capture() const { return impl_->capture_source.SelectedIndex(); }
void MainWindow::SetPort(std::uint16_t value) {
  SetText(impl_->port, std::to_wstring(value));
}
bool MainWindow::detailed_logging() const { return impl_->logging.IsOn(); }
bool MainWindow::auto_start() const { return impl_->startup.IsOn(); }
void MainWindow::SetAutoStart(bool enabled) {
  impl_->updating_startup = true;
  impl_->startup.IsOn(enabled);
  impl_->updating_startup = false;
}
void MainWindow::EnableHide(bool enabled) { impl_->hide.IsEnabled(enabled); }


namespace {
std::optional<unsigned> Number(winrt::hstring text, unsigned minimum, unsigned maximum) {
  if (text.empty() || std::wstring_view(text).find_first_not_of(L"0123456789") != std::wstring_view::npos) return {};
  wchar_t* end;
  const auto value = wcstoull(text.c_str(), &end, 10);
  if (value < minimum || value > maximum) return {};
  return static_cast<unsigned>(value);
}

TextBox TextInput(const StackPanel& panel, const wchar_t* header, std::wstring_view value) {
  TextBox input;
  input.Header(winrt::box_value(header));
  input.Text(value);
  panel.Children().Append(input);
  return input;
}
}  // namespace

void MainWindow::Notify(std::wstring message) {
  impl_->Dialog(L"HearPort", Label(message), nullptr);
}

void MainWindow::Confirm(std::wstring message, const wchar_t* primary, std::function<void()> accepted) {
  impl_->Dialog(L"HearPort", Label(message), primary, std::move(accepted));
}

void MainWindow::EditPort(std::function<std::wstring(std::uint16_t)> save) {
  auto panel = Column();
  const auto input = TextInput(panel, Tr(L"UDP port", L"UDP 端口"), impl_->port.Text());
  auto error = Label();
  error.Visibility(Visibility::Collapsed);
  panel.Children().Append(error);
  impl_->Dialog(Tr(L"Listening UDP port", L"监听 UDP 端口"), panel, Tr(L"Apply", L"应用"), {},
      [input, error, save = std::move(save)] {
        const auto value = Number(input.Text(), 1, 65535);
        const auto message = value ? save(static_cast<std::uint16_t>(*value)) :
            Tr(L"Enter a UDP port from 1 to 65535.", L"请输入 1 至 65535 之间的 UDP 端口。");
        SetText(error, message);
        return message.empty();
      });
}

void MainWindow::ConfigureTest(MainAction test, TestSettings settings,
                               std::function<void(TestSettings)> start) {
  auto panel = Column();
  auto values = std::make_shared<TestSettings>(std::move(settings));
  auto error = Label();
  error.Visibility(Visibility::Collapsed);
  const auto submit = [values, start = std::move(start)] { start(*values); };
  const auto primary = Tr(L"Start test", L"开始测试");
  if (test == MainAction::network_test) {
    ComboBox purpose;
    purpose.Header(winrt::box_value(Tr(L"Test type", L"测试类型")));
    purpose.Items().Append(winrt::box_value(Tr(L"Automatic test and parameter recommendations", L"自动测试并推荐参数")));
    purpose.Items().Append(winrt::box_value(Tr(L"Compression traffic comparison (40 rounds)", L"压缩传输负载对比（40 组）")));
    purpose.SelectedIndex(values->recommendations ? 0 : 1);
    panel.Children().Append(purpose);
    auto options = Column();
    panel.Children().Append(options);
    const auto maximum = TextInput(options, Tr(L"Latency ceiling (ms)", L"延迟上限（毫秒）"), std::to_wstring(values->maximum));
    ComboBox round;
    round.Header(winrt::box_value(Tr(L"Round duration (seconds)", L"每组时长（秒）")));
    constexpr std::array durations{30u, 60u, 120u};
    for (auto seconds : durations) round.Items().Append(winrt::box_value(std::to_wstring(seconds)));
    round.SelectedIndex(values->round_seconds == 120 ? 2 : values->round_seconds == 60 ? 1 : 0);
    options.Children().Append(round);
    const auto select = [options](const ComboBox& combo) {
      options.Visibility(combo.SelectedIndex() == 0 ? Visibility::Visible : Visibility::Collapsed);
    };
    select(purpose);
    purpose.SelectionChanged([select](auto&& sender, auto&&) { select(sender.template as<ComboBox>()); });
    panel.Children().Append(Label(Tr(L"No audio is played during the network test.", L"网络测试不播放音频。")));
    panel.Children().Append(error);
    impl_->Dialog(Tr(L"Network test", L"网络测试"), panel, primary, submit, [=] {
      values->recommendations = purpose.SelectedIndex() == 0;
      if (values->recommendations) {
        const auto valid_max = Number(maximum.Text(), 20, 2000);
        if (!valid_max) {
          SetText(error, Tr(L"Enter a maximum from 20 to 2000 ms.", L"请输入 20 至 2000 毫秒的上限。"));
          return false;
        }
        values->maximum = *valid_max;
        values->round_seconds = durations[round.SelectedIndex()];
      }
      return true;
    });
    return;
  }

  const bool music = test == MainAction::music_test;
  TextBox offset{nullptr};
  if (music) {
    Button pick;
    pick.Content(winrt::box_value(Tr(L"Select audio file…", L"选择音频文件…")));
    auto file = Label(values->file);
    pick.Click([this, values, file](auto&&, auto&&) {
      if (auto path = impl_->PickAudio()) {
        values->file = std::move(*path);
        SetText(file, std::filesystem::path(values->file).filename().wstring());
      }
    });
    if (!values->file.empty()) file.Text(std::filesystem::path(values->file).filename().wstring());
    panel.Children().Append(pick);
    panel.Children().Append(file);
    offset = TextInput(panel, Tr(L"Start position (seconds)", L"起点（秒）"), values->start);
  }
  const auto duration = TextInput(panel, music ? Tr(L"Round duration (seconds)", L"每组时长（秒）") :
      Tr(L"Duration (seconds)", L"时长（秒）"), values->duration);
  if (music) panel.Children().Append(Label(Tr(L"32 rounds use the same excerpt. At 120 seconds per round, allow about 67 minutes plus setup and report transfer.",
      L"32 组使用同一音频片段。每组 120 秒时约需 67 分钟，另加协商和报告回传。")));
  panel.Children().Append(error);
  impl_->Dialog(music ? Tr(L"Music compression test", L"音乐压缩对比测试") :
                        Tr(L"Live diagnostics", L"实时诊断"), panel, primary, submit, [=] {
    const auto max = music ? 300 : 3600;
    if (!Number(duration.Text(), 60, max)) {
      SetText(error, Tr(L"Enter a duration from 60 to ", L"请输入 60 至 ") +
          std::to_wstring(max) + Tr(L" seconds.", L" 秒的时长。"));
      return false;
    }
    if (music && (values->file.empty() || !Number(offset.Text(), 0, UINT32_MAX))) {
      SetText(error, Tr(L"Select an audio file and a valid start time.", L"请选择音频文件并填写有效起点。"));
      return false;
    }
    values->duration = std::wstring_view(duration.Text());
    if (music) values->start = std::wstring_view(offset.Text());
    return true;
  });
}

void MainWindow::ShowRecommendations(std::wstring report, const std::vector<RecommendationPoint>& points) {
  auto content = Column(12);
  auto chart = Canvas();
  chart.Height(120);
  chart.Width(270);
  chart.HorizontalAlignment(HorizontalAlignment::Left);
  double age_max = 1, gap_max = .001;
  for (const auto& point : points) {
    age_max = std::max(age_max, point.age_ms);
    gap_max = std::max(gap_max, point.gap_ratio);
  }
  auto axis = Shapes::Polyline();
  const auto foreground = Label().Foreground();
  axis.Stroke(foreground);
  axis.StrokeThickness(1);
  axis.Points().Append({4, 4});
  axis.Points().Append({4, 116});
  axis.Points().Append({266, 116});
  chart.Children().Append(axis);
  for (const auto& point : points) {
    Shapes::Ellipse mark;
    mark.Width(6);
    mark.Height(6);
    mark.Fill(winrt::Windows::UI::ViewManagement::AccessibilitySettings().HighContrast() ? foreground : Media::SolidColorBrush(point.reliable ?
        winrt::Windows::UI::Color{255, 222, 134, 46} : winrt::Windows::UI::Color{255, 55, 145, 230}));
    Canvas::SetLeft(mark, 1 + 262 * point.age_ms / age_max);
    Canvas::SetTop(mark, 113 - 112 * point.gap_ratio / gap_max);
    chart.Children().Append(mark);
  }
  if (!points.empty()) {
    content.Children().Append(Label(Tr(L"Sampling replay · X: source age P95 · Y: gaps", L"采样回放 · 横轴：源年龄 P95 · 纵轴：缺口占比")));
    wchar_t scale[128]{};
    swprintf_s(scale, L"X: 0–%.0f ms    Y: 0–%.2f%%", age_max, gap_max * 100);
    content.Children().Append(chart);
    content.Children().Append(Label(scale));
    content.Children().Append(Label(Tr(L"Blue: Datagram · Orange: Reliable", L"蓝色：Datagram · 橙色：Reliable")));
  }
  auto text = Label(report);
  text.IsTextSelectionEnabled(true);
  content.Children().Append(text);
  ScrollViewer scroll;
  scroll.MaxHeight(380);
  scroll.Content(content);
  impl_->Dialog(Tr(L"Recommendations", L"推荐结果"), scroll, nullptr);
}
