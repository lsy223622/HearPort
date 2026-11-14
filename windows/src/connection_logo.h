#pragma once

#include "link_presentation.h"

#include <cstdint>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>

#include <array>

struct ConnectionLogo {
  winrt::Microsoft::UI::Xaml::Controls::Viewbox view{nullptr};

  void Create() {
    using namespace winrt::Microsoft::UI::Xaml;
    using namespace Controls;
    view = Markup::XamlReader::Load(LR"(
      <Viewbox xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
        <Canvas Width="950" Height="760" RenderTransformOrigin="0,0">
          <Canvas.RenderTransform><TranslateTransform X="-220" Y="-278"/></Canvas.RenderTransform>
          <Path Stroke="{ThemeResource TextFillColorPrimaryBrush}" StrokeThickness="48"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                Data="M369,570 V405 Q369,333 441,333 H927 Q999,333 999,405 V565 M999,914 Q999,984 929,984 H819
                      M318,646 H686 Q751,646 751,711 V921 Q751,986 686,986 H318 Q253,986 253,921 V711 Q253,646 318,646 Z"/>
          <Path Stroke="{ThemeResource TextFillColorPrimaryBrush}" StrokeThickness="48"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M999,565 V914"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M823,703 C839,730 839,764 823,791"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M885,666 C915,716 915,778 885,828"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M950,627 C995,701 995,793 950,867"/>
          <Path StrokeThickness="48" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M751,816 C1020,816 1100,650 999,565"/>
        </Canvas>
      </Viewbox>)").as<Viewbox>();
    const auto children = view.Child().as<Canvas>().Children();
    closed_edge_ = children.GetAt(1).as<Shapes::Path>();
    for (std::uint32_t i = 0; i < marks_.size(); ++i)
      marks_[i] = children.GetAt(i + 2).as<Shapes::Path>();
  }

  void Update(bool running, bool connected, bool usb, LinkStability stability,
              const winrt::Microsoft::UI::Xaml::Media::Brush& ink) {
    using namespace winrt::Microsoft::UI::Xaml;
    closed_edge_.Visibility(running ? Visibility::Collapsed : Visibility::Visible);
    const int bars = LinkBars(stability);
    for (int i = 0; i < 4; ++i) {
      const bool cable = i == 3;
      auto& mark = marks_[i];
      mark.Stroke(ink);
      mark.Visibility(connected && cable == usb ? Visibility::Visible : Visibility::Collapsed);
      mark.Opacity(!cable && stability == LinkStability::unknown ? .65 :
                   !cable && i >= bars ? .18 : 1);
    }
  }

 private:
  winrt::Microsoft::UI::Xaml::Shapes::Path closed_edge_{nullptr};
  std::array<winrt::Microsoft::UI::Xaml::Shapes::Path, 4> marks_{nullptr, nullptr, nullptr, nullptr};
};
