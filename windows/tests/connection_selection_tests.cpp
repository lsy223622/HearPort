#include <cassert>
#include "hearport/windows/connection_selection.h"
using namespace hearport::windows;
int main() {
  ConnectionSelection selection;
  assert(selection.Activate(1,PhysicalPath::network,"peer"));
  assert(!selection.Activate(2,PhysicalPath::usb,"stranger"));
  assert(selection.active()==1);
  assert(selection.Activate(2,PhysicalPath::usb,"peer"));
  selection.Closed(1); assert(selection.active()==2);
  assert(!selection.Activate(3,PhysicalPath::network,"peer"));
  selection.Closed(2); assert(!selection.active());
  selection.SetPinned(true);
  assert(selection.Activate(3,PhysicalPath::network,"peer"));
  assert(!selection.Activate(4,PhysicalPath::usb,"peer"));
  selection.Closed(3); assert(!selection.Activate(4,PhysicalPath::usb,"peer"));
}
