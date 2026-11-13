#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include "tray_popup.h"

#include "winui_runtime.h"
#include <commctrl.h>
#include <dwmapi.h>
#include <shellscalingapi.h>
#undef GetCurrentTime

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.ViewManagement.h>
#include <winrt/Microsoft.UI.Composition.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <string>
#include <utility>

namespace {
using namespace winrt::Microsoft::UI;
using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;
using namespace winrt::Microsoft::UI::Xaml::Input;
using namespace winrt::Microsoft::UI::Composition::SystemBackdrops;

constexpr double kSliderWidth = 196;
constexpr double kThumbDiameter = 18;
constexpr double kTrackTravel = kSliderWidth - kThumbDiameter;

const wchar_t* Translate(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? chinese : english;
}

}  // namespace

struct TrayPopup::Impl {
  std::function<void()> open;
  std::function<void(std::uint32_t)> preview;
  std::function<void(std::uint32_t)> commit;
  std::function<void()> cancel;
  WinUiRuntime runtime;
  Dispatching::DispatcherQueue dispatcher{nullptr};
  Dispatching::DispatcherQueueController dispatcher_owner{nullptr};
  Hosting::WindowsXamlManager xaml{nullptr};
  Window window{nullptr};
  Windowing::AppWindow app_window{nullptr};
  HWND hwnd = nullptr;
  HWND opening_foreground = nullptr;
  Dispatching::DispatcherQueueTimer dismiss_timer{nullptr};
  Dispatching::DispatcherQueueTimer entrance_timer{nullptr};
  std::chrono::steady_clock::time_point entrance_start;
  int entrance_x = 0;
  int entrance_y = 0;
  int entrance_offset = 0;
  bool pointer_was_down = false;
  DesktopAcrylicController acrylic{nullptr};
  SystemBackdropConfiguration backdrop{nullptr};
  StackPanel content{nullptr};
  Border frame{nullptr};
  StackPanel volume_row{nullptr};
  TextBlock state{nullptr};
  TextBlock percent{nullptr};
  Button open_button{nullptr};
  Slider slider{nullptr};
  Border slider_fill{nullptr};
  Border slider_thumb{nullptr};
  Border slider_track{nullptr};
  bool updating = false;
  bool dragging = false;
  bool connected = false;
  std::optional<std::uint32_t> volume;
  std::optional<std::uint32_t> pending_value;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);
  std::uint32_t drag_start = 0;
  winrt::event_token closing;

  std::uint32_t Position() const {
    return static_cast<std::uint32_t>(std::lround(slider.Value()));
  }

  void UpdateLabel() const {
    percent.Text(std::to_wstring(Position()) + L"%");
    const double filled = kTrackTravel * slider.Value() / 100;
    slider_fill.Width(filled);
    Canvas::SetLeft(slider_thumb, filled);
  }

  void CancelDrag() {
    if (!std::exchange(dragging, false)) return;
    cancel();
  }

  void Hide() {
    if (app_window && app_window.IsVisible()) {
      dismiss_timer.Stop();
      entrance_timer.Stop();
      app_window.Hide();
      CancelDrag();
    }
  }

  bool HasForeground(HWND foreground) const {
    return foreground && GetAncestor(foreground, GA_ROOT) == hwnd;
  }

  static bool PointerDown() {
    return (GetAsyncKeyState(VK_LBUTTON) | GetAsyncKeyState(VK_RBUTTON) |
            GetAsyncKeyState(VK_MBUTTON)) & 0x8000;
  }

  void CheckDismiss() {
    if (!app_window.IsVisible()) return;
    const auto foreground = GetForegroundWindow();
    const bool pointer_down = PointerDown();
    const bool was_down = std::exchange(pointer_was_down, pointer_down);
    const bool pressed = pointer_down && !was_down;
    POINT cursor{};
    RECT rect{};
    if ((foreground && !HasForeground(foreground) && foreground != opening_foreground) ||
        (pressed && !dragging && GetCursorPos(&cursor) &&
         GetWindowRect(hwnd, &rect) && !PtInRect(&rect, cursor))) {
      Hide();
    } else if (HasForeground(foreground)) {
      opening_foreground = nullptr;
    }
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp,
                                      UINT_PTR id, DWORD_PTR data) {
    auto* self = reinterpret_cast<Impl*>(data);
    if (message == WM_NCCALCSIZE && wp) return 0;
    if (message == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE &&
        !self->HasForeground(reinterpret_cast<HWND>(lp))) {
      self->Hide();
    }
    if (message == WM_NCDESTROY) RemoveWindowSubclass(hwnd, WindowProc, id);
    return DefSubclassProc(hwnd, message, wp, lp);
  }

  void ApplyBackdrop(FrameworkElement const& root) {
    if (!DesktopAcrylicController::IsSupported()) return;
    backdrop = SystemBackdropConfiguration();
    backdrop.IsInputActive(true);
    acrylic = DesktopAcrylicController();
    acrylic.SetSystemBackdropConfiguration(backdrop);
    acrylic.AddSystemBackdropTarget(window.as<Composition::ICompositionSupportsSystemBackdrop>());
    const auto update_theme = [this](ElementTheme theme) {
      backdrop.Theme(theme == ElementTheme::Dark ? SystemBackdropTheme::Dark : SystemBackdropTheme::Light);
      const bool dark = theme == ElementTheme::Dark;
      acrylic.TintColor(dark ? winrt::Windows::UI::Color{255, 30, 29, 28}
                             : winrt::Windows::UI::Color{255, 250, 249, 247});
      acrylic.FallbackColor(dark ? winrt::Windows::UI::Color{255, 43, 42, 41}
                                 : winrt::Windows::UI::Color{255, 246, 245, 243});
      acrylic.TintOpacity(dark ? 0.32f : 0.42f);
      acrylic.LuminosityOpacity(dark ? 0.64f : 0.76f);
    };
    update_theme(root.ActualTheme());
    root.ActualThemeChanged([update_theme](FrameworkElement const& sender, auto&&) {
      update_theme(sender.ActualTheme());
    });
  }

  void AdvanceEntrance() {
    constexpr auto duration = std::chrono::milliseconds(500);
    const auto now = std::chrono::steady_clock::now();
    // WinUI can spend several frames creating its first surface.
    if (entrance_start == std::chrono::steady_clock::time_point{}) entrance_start = now;
    const double elapsed = std::chrono::duration<double>(now - entrance_start) / duration;
    // Quintic ease-out: the surface clears the tray quickly and settles at its anchor.
    const double remaining = 1 - std::clamp(elapsed, 0.0, 1.0);
    const int offset = static_cast<int>(std::lround(entrance_offset * std::pow(remaining, 5)));
    SetWindowPos(hwnd, nullptr, entrance_x, entrance_y + offset, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (!offset) entrance_timer.Stop();
  }

  void UpdateChrome(ElementTheme theme) const {
    using winrt::Windows::UI::Color;
    using Media::SolidColorBrush;
    const bool dark = theme == ElementTheme::Dark;
    const bool high_contrast = winrt::Windows::UI::ViewManagement::AccessibilitySettings().HighContrast();
    const auto system_color = [](int index) {
      const auto rgb = GetSysColor(index);
      return Color{255, GetRValue(rgb), GetGValue(rgb), GetBValue(rgb)};
    };
    const auto accent = winrt::Windows::UI::ViewManagement::UISettings().GetColorValue(
        dark ? winrt::Windows::UI::ViewManagement::UIColorType::AccentLight2
             : winrt::Windows::UI::ViewManagement::UIColorType::AccentDark1);
    frame.BorderBrush(SolidColorBrush(high_contrast ? system_color(COLOR_WINDOWTEXT)
        : dark ? Color{48, 255, 255, 255} : Color{42, 0, 0, 0}));
    slider_track.Background(SolidColorBrush(high_contrast ? system_color(COLOR_WINDOWTEXT)
        : dark ? Color{255, 157, 157, 157} : Color{255, 122, 122, 122}));
    slider_fill.Background(SolidColorBrush(high_contrast ? system_color(COLOR_HIGHLIGHT) : accent));
    slider_thumb.Background(slider_fill.Background());
    slider_thumb.BorderBrush(SolidColorBrush(high_contrast ? system_color(COLOR_WINDOW)
        : dark ? Color{255, 67, 67, 67} : Color{255, 234, 234, 234}));
  }

  void Create() {
    runtime.Load();
    dispatcher = Dispatching::DispatcherQueue::GetForCurrentThread();
    if (!dispatcher) {
      dispatcher_owner = Dispatching::DispatcherQueueController::CreateOnCurrentThread();
      dispatcher = dispatcher_owner.DispatcherQueue();
    }
    xaml = Hosting::WindowsXamlManager::InitializeForCurrentThread();
    window = Window();
    window.Title(L"HearPort Tray");
    app_window = window.AppWindow();
    // Find the native host on this UI thread. The standalone projection
    // contains WinRT metadata, while IWindowNative is a separate COM header.
    EnumThreadWindows(GetCurrentThreadId(), [](HWND candidate, LPARAM data) -> BOOL {
      wchar_t title[32]{};
      GetWindowTextW(candidate, title, ARRAYSIZE(title));
      if (std::wstring_view(title) != L"HearPort Tray") return TRUE;
      *reinterpret_cast<HWND*>(data) = candidate;
      return FALSE;
    }, reinterpret_cast<LPARAM>(&hwnd));
    if (!hwnd) winrt::throw_hresult(E_HANDLE);
    app_window.IsShownInSwitchers(false);
    auto presenter = app_window.Presenter().as<Windowing::OverlappedPresenter>();
    presenter.SetBorderAndTitleBar(false, false);
    presenter.IsResizable(false);
    presenter.IsAlwaysOnTop(true);
    SetWindowLongPtrW(hwnd, GWL_STYLE, GetWindowLongPtrW(hwnd, GWL_STYLE) &
        ~(WS_CAPTION | WS_THICKFRAME | WS_BORDER));
    const auto corners = DWMWCP_ROUND;
    const COLORREF border = DWMWA_COLOR_NONE;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
    DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &border, sizeof(border));
    SetWindowSubclass(hwnd, WindowProc, 1, reinterpret_cast<DWORD_PTR>(this));
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    dismiss_timer = dispatcher.CreateTimer();
    dismiss_timer.Interval(std::chrono::milliseconds(25));
    dismiss_timer.Tick([this](auto&&, auto&&) { CheckDismiss(); });
    entrance_timer = dispatcher.CreateTimer();
    entrance_timer.Interval(std::chrono::milliseconds(16));
    entrance_timer.Tick([this](auto&&, auto&&) { AdvanceEntrance(); });

    content = StackPanel();
    content.Padding({18, 15, 18, 12});
    content.Spacing(8);
    StackPanel header;
    header.Orientation(Orientation::Horizontal);
    header.Spacing(10);
    FontIcon icon;
    icon.Glyph(L"\uE70A");
    icon.FontSize(17);
    header.Children().Append(icon);
    state = TextBlock();
    state.FontSize(15);
    state.FontWeight({600});
    state.VerticalAlignment(VerticalAlignment::Center);
    header.Children().Append(state);
    content.Children().Append(header);

    volume_row = StackPanel();
    volume_row.Orientation(Orientation::Horizontal);
    volume_row.Spacing(10);
    volume_row.Visibility(Visibility::Collapsed);
    FontIcon speaker;
    speaker.Glyph(L"\uE767");
    speaker.FontSize(17);
    speaker.VerticalAlignment(VerticalAlignment::Center);
    percent = TextBlock();
    percent.Width(46);
    percent.TextAlignment(TextAlignment::Right);
    percent.VerticalAlignment(VerticalAlignment::Center);
    slider = Slider();
    slider.Width(kSliderWidth);
    slider.Minimum(0);
    slider.Maximum(100);
    slider.StepFrequency(1);
    slider.IsThumbToolTipEnabled(false);
    Automation::AutomationProperties::SetName(slider, Translate(L"iPad volume", L"iPad 音量"));
    Grid slider_surface;
    slider_surface.Width(kSliderWidth);
    slider_surface.Height(32);
    Canvas slider_art;
    slider_art.IsHitTestVisible(false);
    slider_track = Border();
    slider_track.Width(kTrackTravel);
    slider_track.Height(4);
    slider_track.CornerRadius({2, 2, 2, 2});
    Canvas::SetLeft(slider_track, kThumbDiameter / 2);
    Canvas::SetTop(slider_track, 14);
    slider_fill = Border();
    slider_fill.Height(4);
    slider_fill.CornerRadius({2, 2, 2, 2});
    Canvas::SetLeft(slider_fill, kThumbDiameter / 2);
    Canvas::SetTop(slider_fill, 14);
    slider_thumb = Border();
    slider_thumb.Width(kThumbDiameter);
    slider_thumb.Height(kThumbDiameter);
    slider_thumb.CornerRadius({9, 9, 9, 9});
    slider_thumb.BorderThickness({4, 4, 4, 4});
    Canvas::SetTop(slider_thumb, 7);
    slider_art.Children().Append(slider_track);
    slider_art.Children().Append(slider_fill);
    slider_art.Children().Append(slider_thumb);
    slider.Opacity(0);
    slider.GotFocus([this](auto&&, auto&&) { slider_thumb.BorderThickness({3, 3, 3, 3}); });
    slider.LostFocus([this](auto&&, auto&&) { slider_thumb.BorderThickness({4, 4, 4, 4}); });
    slider_surface.Children().Append(slider);
    slider_surface.Children().Append(slider_art);
    volume_row.Children().Append(speaker);
    volume_row.Children().Append(slider_surface);
    volume_row.Children().Append(percent);
    content.Children().Append(volume_row);

    open_button = Button();
    open_button.Content(winrt::box_value(Translate(L"Open HearPort", L"打开 HearPort")));
    open_button.HorizontalAlignment(HorizontalAlignment::Right);
    open_button.CornerRadius({6, 6, 6, 6});
    open_button.Click([this](auto&&, auto&&) { Hide(); open(); });
    content.Children().Append(open_button);

    slider.AddHandler(UIElement::PointerPressedEvent(), winrt::box_value(PointerEventHandler(
        [this](auto&&, const PointerRoutedEventArgs& args) {
          const auto point = args.GetCurrentPoint(slider);
          if (point.PointerDeviceType() == winrt::Microsoft::UI::Input::PointerDeviceType::Mouse &&
              !point.Properties().IsLeftButtonPressed()) return;
          dragging = true;
          drag_start = volume.value_or(Position());
          pending_value.reset();
          preview(Position());
        })), true);
    slider.AddHandler(UIElement::PointerReleasedEvent(), winrt::box_value(PointerEventHandler(
        [this](auto&&, auto&&) {
          if (!std::exchange(dragging, false)) return;
          if (Position() != drag_start) commit(Position());
          else cancel();
        })), true);
    slider.PointerCanceled([this](auto&&, auto&&) { CancelDrag(); });
    slider.ValueChanged([this](auto&&, auto&&) {
      UpdateLabel();
      if (updating) return;
      if (dragging) {
        preview(Position());
        return;
      }
      const bool queued = pending_value.has_value();
      pending_value = Position();
      if (!queued) {
        dispatcher.TryEnqueue([this, alive = alive] {
          if (!*alive) return;
          if (const auto value = std::exchange(pending_value, std::nullopt)) commit(*value);
        });
      }
    });
    content.AddHandler(UIElement::KeyDownEvent(), winrt::box_value(KeyEventHandler(
        [this](auto&&, const KeyRoutedEventArgs& args) {
          if (args.Key() != winrt::Windows::System::VirtualKey::Escape) return;
          args.Handled(true);
          Hide();
        })), true);
    closing = window.Closed([this](auto&&, const WindowEventArgs& args) {
      args.Handled(true);
      Hide();
    });
    frame = Border();
    frame.CornerRadius({8, 8, 8, 8});
    frame.BorderThickness({1, 1, 1, 1});
    frame.Child(content);
    window.Content(frame);
    UpdateChrome(frame.ActualTheme());
    frame.ActualThemeChanged([this](FrameworkElement const& root, auto&&) {
      UpdateChrome(root.ActualTheme());
    });
    ApplyBackdrop(content);
  }
};

TrayPopup::TrayPopup(std::function<void()> open, std::function<void(std::uint32_t)> preview,
                     std::function<void(std::uint32_t)> commit, std::function<void()> cancel)
    : impl_(new Impl{std::move(open), std::move(preview), std::move(commit), std::move(cancel)}) {}

TrayPopup::~TrayPopup() {
  *impl_->alive = false;
  if (impl_->window) {
    if (impl_->dismiss_timer) impl_->dismiss_timer.Stop();
    if (impl_->entrance_timer) impl_->entrance_timer.Stop();
    if (impl_->acrylic) impl_->acrylic.Close();
    if (impl_->hwnd) RemoveWindowSubclass(impl_->hwnd, Impl::WindowProc, 1);
    if (impl_->closing.value) impl_->window.Closed(impl_->closing);
    impl_->window.Close();
  }
}

HRESULT TrayPopup::Show(const RECT& anchor) {
  if (!impl_->window) {
    try {
      impl_->Create();
      Update(impl_->connected, impl_->volume);
    } catch (const winrt::hresult_error& error) {
      OutputDebugStringW(error.message().c_str());
      return error.code();
    }
  }
  const auto monitor = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{sizeof(monitor_info)};
  if (!GetMonitorInfoW(monitor, &monitor_info)) return HRESULT_FROM_WIN32(GetLastError());
  UINT dpi = 96;
  UINT dpi_y = 96;
  GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi, &dpi_y);
  const auto scale = [dpi](int size) { return MulDiv(size, dpi, 96); };
  const int width = scale(320);
  const int height = scale(impl_->volume_row.Visibility() == Visibility::Visible ? 142 : 104);
  const auto& work = monitor_info.rcWork;
  const int x = std::clamp<int>(anchor.right - width, work.left, std::max<int>(work.left, work.right - width));
  const int above = anchor.top - height - scale(8);
  const int preferred_y = above >= work.top ? above : anchor.bottom + scale(8);
  const int y = std::clamp<int>(preferred_y, work.top, std::max<int>(work.top, work.bottom - height));
  impl_->entrance_x = x;
  impl_->entrance_y = y;
  impl_->entrance_offset = winrt::Windows::UI::ViewManagement::UISettings().AnimationsEnabled()
      ? scale(preferred_y == above ? 32 : -32) : 0;
  impl_->app_window.MoveAndResize({x, y + impl_->entrance_offset, width, height});
  impl_->opening_foreground = GetForegroundWindow();
  impl_->pointer_was_down = Impl::PointerDown();
  impl_->window.Activate();
  SetForegroundWindow(impl_->hwnd);
  if (impl_->entrance_offset) {
    impl_->entrance_start = {};
    impl_->entrance_timer.Start();
  }
  impl_->dismiss_timer.Start();
  impl_->open_button.Focus(FocusState::Programmatic);
  return S_OK;
}

void TrayPopup::Hide() { impl_->Hide(); }

bool TrayPopup::visible() const { return impl_->app_window && impl_->app_window.IsVisible(); }

void TrayPopup::Update(bool connected, std::optional<std::uint32_t> volume) {
  impl_->connected = connected;
  impl_->volume = volume;
  if (!impl_->window) return;
  if (!volume) {
    impl_->dragging = false;
    impl_->pending_value.reset();
  }
  const auto title = connected ? Translate(L"iPad connected", L"iPad 已连接")
                               : Translate(L"iPad not connected", L"iPad 未连接");
  if (impl_->state.Text() != title) impl_->state.Text(title);
  const auto visibility = volume ? Visibility::Visible : Visibility::Collapsed;
  if (impl_->volume_row.Visibility() != visibility) {
    impl_->volume_row.Visibility(visibility);
    if (visible()) {
      if (impl_->entrance_timer.IsRunning()) {
        impl_->entrance_timer.Stop();
        SetWindowPos(impl_->hwnd, nullptr, impl_->entrance_x, impl_->entrance_y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      }
      auto size = impl_->app_window.Size();
      auto position = impl_->app_window.Position();
      const int height = MulDiv(volume ? 142 : 104, size.Width, 320);
      impl_->app_window.MoveAndResize({position.X, position.Y + size.Height - height, size.Width, height});
    }
  }
  if (volume && !impl_->dragging && impl_->Position() != *volume) {
    impl_->updating = true;
    impl_->slider.Value(*volume);
    impl_->updating = false;
  }
  if (volume) impl_->UpdateLabel();
}
