#pragma once

#include <windows.h>

enum class LinkStability { unknown, poor, variable, stable };

inline COLORREF LinkColor(bool usb, LinkStability stability, bool dark) {
  switch (stability) {
    case LinkStability::stable: return usb ? RGB(0, 122, 255) : RGB(30, 210, 167);
    case LinkStability::variable: return RGB(255, 149, 0);
    case LinkStability::poor: return RGB(255, 59, 48);
    default: return dark ? RGB(172, 172, 177) : RGB(106, 106, 112);
  }
}

inline int LinkBars(LinkStability stability) {
  return stability == LinkStability::poor ? 1 : stability == LinkStability::variable ? 2 : 3;
}
