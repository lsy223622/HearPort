#pragma once

#include "link_presentation.h"

#include <cstdint>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.ViewManagement.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <numbers>

struct ConnectionLogo {
  winrt::Microsoft::UI::Xaml::Controls::Viewbox view{nullptr};
  winrt::Microsoft::UI::Xaml::Media::GradientStop tint{nullptr};

  void Create(const winrt::Microsoft::UI::Xaml::Window& window) {
    using namespace winrt::Microsoft::UI::Xaml;
    using namespace Controls;
    view = Markup::XamlReader::Load(LR"(
      <Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
        <Canvas Width="950" Height="760" RenderTransformOrigin="0,0">
          <Canvas.RenderTransform><TranslateTransform X="-220" Y="-278"/></Canvas.RenderTransform>
          <Path Stroke="{ThemeResource TextFillColorPrimaryBrush}" StrokeThickness="48"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
            <Path.Data>
              <PathGeometry>
                <PathFigure StartPoint="369,570">
                  <LineSegment Point="369,405"/>
                  <QuadraticBezierSegment Point1="369,333" Point2="441,333"/>
                  <LineSegment Point="927,333"/>
                  <QuadraticBezierSegment Point1="999,333" Point2="999,405"/>
                  <LineSegment Point="999,740"/>
                </PathFigure>
                <PathFigure StartPoint="999,739">
                  <LineSegment Point="999,914"/>
                  <QuadraticBezierSegment Point1="999,984" Point2="929,984"/>
                  <LineSegment Point="819,984"/>
                </PathFigure>
              </PathGeometry>
            </Path.Data>
          </Path>
          <Path Stroke="{ThemeResource TextFillColorPrimaryBrush}" StrokeThickness="48"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                Data="M318,646 H686 Q751,646 751,711 V921 Q751,986 686,986 H318 Q253,986 253,921 V711 Q253,646 318,646 Z"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M823,703 C839,730 839,764 823,791"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M885,666 C915,716 915,778 885,828"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M950,627 C995,701 995,793 950,867"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        </Canvas>
      </Viewbox>)").as<Viewbox>();
    const auto children = view.Child().as<Canvas>().Children();
    const auto outline = children.GetAt(0).as<Shapes::Path>().Data().as<Media::PathGeometry>();
    top_edge_ = outline.Figures().GetAt(0).Segments().GetAt(4).as<Media::LineSegment>();
    bottom_edge_ = outline.Figures().GetAt(1);
    ink_ = Media::SolidColorBrush();
    for (std::uint32_t i = 0; i < marks_.size(); ++i)
      marks_[i] = children.GetAt(i + 2).as<Shapes::Path>();
    for (const auto& mark : marks_) {
      mark.Stroke(ink_);
      mark.Opacity(0);
    }
    Media::PathGeometry geometry;
    Media::PathFigure figure;
    figure.StartPoint({751, 816});
    cable_ = Media::BezierSegment();
    figure.Segments().Append(cable_);
    geometry.Figures().Append(figure);
    marks_.back().Data(geometry);
    timer_ = view.DispatcherQueue().CreateTimer();
    timer_.Interval(std::chrono::milliseconds(16));
    tick_ = timer_.Tick(winrt::auto_revoke, [this](auto&&, auto&&) { Advance(); });
    visibility_ = window.VisibilityChanged(winrt::auto_revoke, [this](auto&&, const WindowVisibilityChangedEventArgs& args) {
      window_visible_ = args.Visible();
      RefreshActivity();
    });
    loaded_event_ = view.Loaded(winrt::auto_revoke, [this](auto&&, auto&&) {
      loaded_ = true;
      RefreshActivity();
    });
    unloaded_event_ = view.Unloaded(winrt::auto_revoke, [this](auto&&, auto&&) {
      loaded_ = false;
      RefreshActivity();
    });
  }

  ~ConnectionLogo() { if (timer_) timer_.Stop(); }

  void Update(bool running, bool connected, bool usb, LinkStability stability,
              winrt::Windows::UI::Color ink, winrt::Windows::UI::Color background = {}) {
    const Appearance next{running ? 1.0 : 0.0, connected && usb ? 1.0 : 0.0,
                          connected && !usb ? 1.0 : 0.0,
                          connected && stability == LinkStability::unknown ? 1.0 : 0.0,
                          static_cast<double>(LinkBars(stability)), ink, background};
    if (next == target_) return;
    if (next.breath && !current_.breath) breath_start_ = Clock::now();
    from_ = current_;
    target_ = next;
    transition_start_ = Clock::now();
    RefreshActivity();
  }

 private:
  using Clock = std::chrono::steady_clock;
  using Color = winrt::Windows::UI::Color;
  using Point = winrt::Windows::Foundation::Point;
  using Animations = winrt::Windows::UI::ViewManagement::UISettings;
  struct Appearance {
    double gap = 0, cable = 0, wifi = 0, breath = 0, bars = 3;
    Color ink{}, background{};
    bool operator==(const Appearance&) const = default;
  };

  static double Ease(double t) {
    t = std::clamp(t, 0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static Color Blend(Color a, Color b, double t) {
    const auto channel = [t](auto x, auto y) {
      return static_cast<std::uint8_t>(std::lround(std::lerp(double(x), double(y), t)));
    };
    return {channel(a.A, b.A), channel(a.R, b.R), channel(a.G, b.G), channel(a.B, b.B)};
  }

  void RefreshActivity() {
    if (!loaded_ || !window_visible_ || !Animations().AnimationsEnabled()) {
      timer_.Stop();
      current_ = target_;
      PaintGeometry();
      PaintOpacity(1);
    } else if ((current_ != target_ || target_.breath) && !timer_.IsRunning()) {
      timer_.Start();
    }
  }

  void PaintGeometry() {
    const auto gap = static_cast<float>(current_.gap);
    top_edge_.Point({999, std::lerp(740.f, 565.f, gap)});
    bottom_edge_.StartPoint({999, std::lerp(739.f, 914.f, gap)});
    // The first part of the existing Bézier grows from the iPad's right edge.
    const auto at = [t = static_cast<float>(current_.cable)](Point a, Point b) {
      return Point{std::lerp(a.X, b.X, t), std::lerp(a.Y, b.Y, t)};
    };
    const auto a = at({751, 816}, {1020, 816});
    const auto b = at({1020, 816}, {1100, 650});
    const auto c = at({1100, 650}, {999, 565});
    cable_.Point1(a);
    cable_.Point2(at(a, b));
    cable_.Point3(at(at(a, b), at(b, c)));
    ink_.Color(current_.ink);
  }

  void PaintOpacity(double pulse) {
    marks_[3].Opacity(pulse * Ease(current_.cable * 4));
    for (int i = 0; i < 3; ++i) {
      const auto appear = Ease(current_.wifi * 1.5 - i * .25);
      const auto signal = std::lerp(.18, 1.0, std::clamp(current_.bars - i, 0.0, 1.0));
      marks_[i].Opacity(pulse * appear * signal);
    }
    if (tint) {
      auto color = current_.background;
      color.A = static_cast<std::uint8_t>(std::lround(color.A * pulse));
      tint.Color(color);
    }
  }

  void Advance() {
    const auto now = Clock::now();
    if (current_ != target_) {
      const auto t = Ease(std::chrono::duration<double, std::milli>(now - transition_start_).count() / 280);
      current_ = {std::lerp(from_.gap, target_.gap, t), std::lerp(from_.cable, target_.cable, t),
                  std::lerp(from_.wifi, target_.wifi, t), std::lerp(from_.breath, target_.breath, t),
                  std::lerp(from_.bars, target_.bars, t), Blend(from_.ink, target_.ink, t),
                  Blend(from_.background, target_.background, t)};
      PaintGeometry();
    }
    const double seconds = std::chrono::duration<double>(now - breath_start_).count();
    PaintOpacity(1 - current_.breath * .28 * (1 - std::cos(seconds * 2 * std::numbers::pi / 1.65)));
    if (current_ == target_ && !target_.breath) timer_.Stop();
  }

  Appearance from_, current_, target_;
  Clock::time_point transition_start_{}, breath_start_{};
  bool loaded_ = false, window_visible_ = false;
  winrt::Microsoft::UI::Xaml::Media::LineSegment top_edge_{nullptr};
  winrt::Microsoft::UI::Xaml::Media::PathFigure bottom_edge_{nullptr};
  std::array<winrt::Microsoft::UI::Xaml::Shapes::Path, 4> marks_{nullptr, nullptr, nullptr, nullptr};
  winrt::Microsoft::UI::Xaml::Media::BezierSegment cable_{nullptr};
  winrt::Microsoft::UI::Xaml::Media::SolidColorBrush ink_{nullptr};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer timer_{nullptr};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer::Tick_revoker tick_;
  winrt::Microsoft::UI::Xaml::Window::VisibilityChanged_revoker visibility_;
  winrt::Microsoft::UI::Xaml::FrameworkElement::Loaded_revoker loaded_event_;
  winrt::Microsoft::UI::Xaml::FrameworkElement::Unloaded_revoker unloaded_event_;
};
