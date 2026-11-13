#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include "tray_popup.h"

#include <appmodel.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shellscalingapi.h>
#undef GetCurrentTime

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.System.h>
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

const wchar_t* Translate(const wchar_t* english, const wchar_t* chinese) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? chinese : english;
}

// Windows 11's package graph makes the installed, serviced WinUI runtime
// available to the portable executable without registering HearPort itself.
struct Runtime {
  PACKAGEDEPENDENCY_CONTEXT context{};
  PWSTR dependency = nullptr;

  void Load() {
    const auto kernel = GetModuleHandleW(L"kernelbase.dll");
    const auto create = reinterpret_cast<decltype(&TryCreatePackageDependency)>(
        GetProcAddress(kernel, "TryCreatePackageDependency"));
    const auto add = reinterpret_cast<decltype(&AddPackageDependency)>(
        GetProcAddress(kernel, "AddPackageDependency"));
    if (!create || !add) winrt::throw_hresult(E_NOTIMPL);
    PACKAGE_VERSION minimum{};
    minimum.Major = 2;
    minimum.Minor = 6;
    minimum.Build = 5;
    winrt::check_hresult(create(nullptr, L"Microsoft.WindowsAppRuntime.2_8wekyb3d8bbwe",
        minimum, PackageDependencyProcessorArchitectures_None, PackageDependencyLifetimeKind_Process,
        nullptr, CreatePackageDependencyOptions_None, &dependency));
    winrt::check_hresult(add(dependency, 0, AddPackageDependencyOptions_None, &context, nullptr));
  }

  ~Runtime() {
    const auto kernel = GetModuleHandleW(L"kernelbase.dll");
    if (context) {
      const auto remove = reinterpret_cast<decltype(&RemovePackageDependency)>(
          GetProcAddress(kernel, "RemovePackageDependency"));
      if (remove) remove(context);
    }
    if (dependency) {
      const auto erase = reinterpret_cast<decltype(&DeletePackageDependency)>(
          GetProcAddress(kernel, "DeletePackageDependency"));
      if (erase) erase(dependency);
      HeapFree(GetProcessHeap(), 0, dependency);
    }
  }
};
}  // namespace

struct TrayPopup::Impl {
  std::function<void()> open;
  std::function<void(std::uint32_t)> preview;
  std::function<void(std::uint32_t)> commit;
  std::function<void()> cancel;
  Runtime runtime;
  Dispatching::DispatcherQueueController dispatcher{nullptr};
  Hosting::WindowsXamlManager xaml{nullptr};
  Window window{nullptr};
  Windowing::AppWindow app_window{nullptr};
  HWND hwnd = nullptr;
  HWND opening_foreground = nullptr;
  Dispatching::DispatcherQueueTimer dismiss_timer{nullptr};
  bool pointer_was_down = false;
  DesktopAcrylicController acrylic{nullptr};
  SystemBackdropConfiguration backdrop{nullptr};
  StackPanel content{nullptr};
  StackPanel volume_row{nullptr};
  TextBlock state{nullptr};
  TextBlock percent{nullptr};
  Button open_button{nullptr};
  Slider slider{nullptr};
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
  }

  void CancelDrag() {
    if (!std::exchange(dragging, false)) return;
    cancel();
  }

  void Hide() {
    if (app_window && app_window.IsVisible()) {
      dismiss_timer.Stop();
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

  void Animate(float from_y) {
    if (!winrt::Windows::UI::ViewManagement::UISettings().AnimationsEnabled()) return;
    using namespace std::chrono_literals;
    const auto visual = Hosting::ElementCompositionPreview::GetElementVisual(content);
    const auto compositor = visual.Compositor();
    Hosting::ElementCompositionPreview::SetIsTranslationEnabled(content, true);
    const auto slide = compositor.CreateScalarKeyFrameAnimation();
    slide.Duration(170ms);
    slide.InsertKeyFrame(0, from_y);
    slide.InsertKeyFrame(1, 0, compositor.CreateCubicBezierEasingFunction({0.16f, 1}, {0.3f, 1}));
    visual.Properties().StartAnimation(L"Translation.Y", slide);
    const auto fade = compositor.CreateScalarKeyFrameAnimation();
    fade.Duration(145ms);
    fade.InsertKeyFrame(0, 0.35f);
    fade.InsertKeyFrame(1, 1);
    visual.StartAnimation(L"Opacity", fade);
  }

  void Create() {
    runtime.Load();
    dispatcher = Dispatching::DispatcherQueueController::CreateOnCurrentThread();
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
    dismiss_timer = dispatcher.DispatcherQueue().CreateTimer();
    dismiss_timer.Interval(std::chrono::milliseconds(25));
    dismiss_timer.Tick([this](auto&&, auto&&) { CheckDismiss(); });

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
    slider.Width(196);
    slider.Minimum(0);
    slider.Maximum(100);
    slider.StepFrequency(1);
    slider.IsThumbToolTipEnabled(false);
    Automation::AutomationProperties::SetName(slider, Translate(L"iPad volume", L"iPad 音量"));
    volume_row.Children().Append(speaker);
    volume_row.Children().Append(slider);
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
        dispatcher.DispatcherQueue().TryEnqueue([this, alive = alive] {
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
    window.Content(content);
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
  impl_->app_window.MoveAndResize({x, y, width, height});
  impl_->opening_foreground = GetForegroundWindow();
  impl_->pointer_was_down = Impl::PointerDown();
  impl_->window.Activate();
  SetForegroundWindow(impl_->hwnd);
  impl_->Animate(preferred_y == above ? 9.0f : -9.0f);
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
