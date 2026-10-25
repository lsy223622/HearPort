#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cassert>
#include <cwchar>
#include <iostream>
#include "hearport/windows/gui_font.h"

int main() {
  HDC context = GetDC(nullptr);
  assert(context);
  // Establish font availability independently of the UI font selector.
  LOGFONTW candidate{};
  candidate.lfHeight = -12;
  wcscpy_s(candidate.lfFaceName, L"Microsoft YaHei UI");
  HFONT available = CreateFontIndirectW(&candidate);
  HGDIOBJ previous = SelectObject(context, available);
  wchar_t actual[LF_FACESIZE]{};
  assert(GetTextFaceW(context, LF_FACESIZE, actual) > 0);
  SelectObject(context, previous);
  DeleteObject(available);
  if (_wcsicmp(actual, L"Microsoft YaHei UI") != 0) {
    ReleaseDC(nullptr, context);
    std::cout << "Chinese glyph check skipped: Microsoft YaHei UI is not installed\n";
    return 77;
  }
  HFONT font = hearport::windows::CreateGuiFont(96, MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED));
  assert(font);
  previous = SelectObject(context, font);
  const wchar_t text[] = L"\u8fde\u63a5\u8bbe\u7f6e\u8bca\u65ad\u7535\u8111\u97f3\u9891";
  WORD glyphs[10]{};
  assert(GetGlyphIndicesW(context, text, 10, glyphs, GGI_MARK_NONEXISTING_GLYPHS) != GDI_ERROR);
  for (WORD glyph : glyphs) assert(glyph != 0xffff);
  LOGFONTW selected{};
  assert(GetObjectW(font, sizeof(selected), &selected));
  assert(selected.lfHeight == -12);
  SelectObject(context, previous);
  DeleteObject(font);
  font = hearport::windows::CreateGuiFont(192, MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US));
  assert(GetObjectW(font, sizeof(selected), &selected));
  assert(selected.lfHeight == -24);
  assert(_wcsicmp(selected.lfFaceName, L"Segoe UI") == 0);
  DeleteObject(font);
  ReleaseDC(nullptr, context);
  std::cout << "Chinese UI glyph coverage and DPI font sizing passed\n";
}
