#include <cassert>
#include "hearport/wire/control_message.h"
int main() {
  using namespace hearport::wire;
  const std::vector<std::byte> stop{std::byte{0xea},std::byte{2},std::byte{2},std::byte{8},std::byte{1}};
  const auto decoded=DecodeControlEnvelope(stop);
  assert(decoded && decoded->type==ControlMessageType::session_end && decoded->reason==1);
  assert(EncodeControlEnvelope(*decoded)==stop);
  const std::vector<std::byte> ack{std::byte{0xf2},std::byte{2},std::byte{0}};
  assert(DecodeControlEnvelope(ack)->type==ControlMessageType::session_end_ack);
  auto bad=stop; bad.back()=std::byte{3}; assert(!DecodeControlEnvelope(bad));
}
