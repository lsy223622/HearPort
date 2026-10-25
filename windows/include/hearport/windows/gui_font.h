#pragma once
#include <windows.h>

namespace hearport::windows {
inline HFONT CreateGuiFont(UINT dpi, LANGID language) {
  const wchar_t* family = PRIMARYLANGID(language) == LANG_CHINESE
                              ? L"Microsoft YaHei UI" : L"Segoe UI";
  return CreateFontW(-MulDiv(12, dpi, 96), 0, 0, 0, FW_NORMAL, FALSE,
                     FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                     CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                     DEFAULT_PITCH, family);
}
}
