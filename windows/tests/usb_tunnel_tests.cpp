#include <cassert>
#include "hearport/windows/usb_tunnel.h"
using namespace hearport::windows;
int main() {
  const std::vector<std::byte> golden{std::byte{'H'},std::byte{'P'},std::byte{'U'},std::byte{'Q'},
    std::byte{1},std::byte{0},std::byte{0},std::byte{2},std::byte{7},std::byte{8}};
  const std::vector<std::byte> payload{std::byte{7}, std::byte{8}};
  assert(EncodeUsbPacket(payload) == golden);
  UsbPacketDecoder decoder;
  std::vector<std::vector<std::byte>> packets;
  for (auto byte : golden) assert(decoder.Push({&byte,1},packets));
  assert(packets.size()==1 && packets[0]==payload && decoder.Complete());
  auto twice=golden; twice.insert(twice.end(),golden.begin(),golden.end());
  packets.clear(); assert(decoder.Push(twice,packets) && packets.size()==2);
  for (int offset : {0,4,5,7}) {
    auto invalid=golden; invalid[offset]=std::byte{0};
    if(offset==5) invalid[offset]=std::byte{1};
    UsbPacketDecoder bad; packets.clear(); assert(!bad.Push(invalid,packets));
  }
  UsbPacketDecoder partial; packets.clear();
  assert(partial.Push(std::span(golden).first(9),packets) && !partial.Complete());
  UsbPacketQueue queue;
  const auto now=std::chrono::steady_clock::now();
  std::vector<std::byte> large(32768);
  assert(queue.Push(large,now) && queue.Push(large,now));
  assert(!queue.Push(payload,now) && queue.payload_bytes()==65536);
  queue.Consume(3); assert(queue.payload_bytes()==65536);
  assert(queue.Expired(now+std::chrono::milliseconds(101),std::chrono::milliseconds(100)));
  queue.Consume(queue.Front().size()); assert(queue.payload_bytes()==32768);
  assert(queue.Push(payload,now));
  const auto devices=ParseUsbDevices(R"(<plist version="1.0"><dict><key>DeviceList</key><array>
    <dict><key>DeviceID</key><integer>7</integer><key>Properties</key><dict><key>ConnectionType</key><string>Network</string></dict></dict>
    <dict><key>DeviceID</key><integer>8</integer><key>Properties</key><dict><key>ConnectionType</key><string>USB</string></dict></dict>
    </array></dict></plist>)");
  assert(devices.size()==1 && devices[0]==8);
  assert(ParseUsbDevices("<plist><broken>").empty());
}
