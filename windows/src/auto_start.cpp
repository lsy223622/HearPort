#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <filesystem>
#include "hearport/windows/auto_start.h"

namespace hearport::windows {
std::wstring AutoStartCommand(std::wstring_view executable) {
  if (executable.empty() || executable.find(L'"') != executable.npos) return {};
  return L"\"" + std::wstring(executable) + L"\" --background";
}

bool ShouldRepairAutoStart(std::wstring_view command, std::wstring_view executable) {
  const auto expected = AutoStartCommand(executable);
  if (expected.empty() || command.empty()) return false;
  int count = 0;
  auto* arguments = CommandLineToArgvW(std::wstring(command).c_str(), &count);
  if (!arguments) return false;
  bool owned = false;
  if (count == 1 || (count == 2 && std::wstring_view(arguments[1]) == L"--background")) {
    const auto name = std::filesystem::path(arguments[0]).filename().wstring();
    owned = _wcsicmp(name.c_str(), L"HearPort.exe") == 0 ||
            _wcsicmp(name.c_str(), L"hearport_sender_gui.exe") == 0;
  }
  LocalFree(arguments);
  return owned && _wcsicmp(std::wstring(command).c_str(), expected.c_str()) != 0;
}
}
