#pragma once

#include <algorithm>
#include <windows.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>

inline void EnableVolumeWheel(const winrt::Microsoft::UI::Xaml::UIElement& track,
                              const winrt::Microsoft::UI::Xaml::Controls::Slider& slider,
                              int& remainder, const bool& dragging) {
  using namespace winrt::Microsoft::UI::Xaml;
  track.AddHandler(UIElement::PointerWheelChangedEvent(),
      winrt::box_value(Input::PointerEventHandler(
          [weak_slider = winrt::make_weak(slider), &remainder, &dragging](
              const winrt::Windows::Foundation::IInspectable& sender,
              const Input::PointerRoutedEventArgs& args) {
            const auto wheel = args.GetCurrentPoint(sender.as<UIElement>()).Properties();
            if (wheel.IsHorizontalMouseWheel()) return;
            const auto control = weak_slider.get();
            if (!control || !control.IsEnabled()) return;
            args.Handled(true);
            if (dragging) return;
            remainder += wheel.MouseWheelDelta();
            const int notches = remainder / WHEEL_DELTA;
            remainder %= WHEEL_DELTA;
            if (notches) control.Value(std::clamp(control.Value() + notches * 5, 0.0, 100.0));
          })), true);
}
