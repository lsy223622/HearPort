#include <cassert>
#include "hearport/windows/auto_start.h"

int main() {
  using namespace hearport::windows;
  const auto path = L"C:\\Apps With Spaces\\HearPort.exe";
  assert(AutoStartCommand(path) == L"\"C:\\Apps With Spaces\\HearPort.exe\" --background");
  assert(!ShouldRepairAutoStart({}, path));
  assert(!ShouldRepairAutoStart(AutoStartCommand(path), path));
  assert(ShouldRepairAutoStart(L"\"D:\\Old Build\\HearPort.exe\" --background", path));
  assert(ShouldRepairAutoStart(L"C:\\Old\\hearport_sender_gui.exe", path));
  assert(!ShouldRepairAutoStart(L"\"C:\\Other.exe\" --background", path));
  assert(!ShouldRepairAutoStart(L"\"C:\\HearPort.exe\" --unexpected", path));
  assert(!ShouldRepairAutoStart(L"C:\\Apps With Spaces\\HearPort.exe --background", path));
  assert(AutoStartCommand(L"C:\\Bad\"Path.exe").empty());
}
