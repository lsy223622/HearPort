#pragma once
#include <string>
#include <string_view>

namespace hearport::windows {
std::wstring AutoStartCommand(std::wstring_view executable);
bool ShouldRepairAutoStart(std::wstring_view command, std::wstring_view executable);
}
