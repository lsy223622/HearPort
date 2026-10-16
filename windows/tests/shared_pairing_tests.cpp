#include "hearport/windows/sender_authentication.h"
#include <iostream>

int main() {
  using namespace hearport::windows;
  using namespace hearport;
  auto shared=std::make_shared<SenderPairingState>();
  SenderService network(QuicServerOptions{}), usb(QuicServerOptions{});
  SenderAuthentication a(network,{}, {},"HearPort-diagnostics",shared);
  SenderAuthentication b(usb,{}, {},"HearPort-diagnostics",shared);
  if(!a.OpenPairingWindow() || a.pairing_pin().size()!=6 || b.pairing_pin()!=a.pairing_pin()) return 1;

  // Each endpoint has its own SPAKE exchange, while rejected points consume the
  // same user-visible PIN window's attempt limit. No network or credential save.
  for(unsigned attempt=0;attempt<5;++attempt) {
    SenderService candidate(QuicServerOptions{});
    SenderAuthentication authentication(candidate,{}, {},"HearPort-diagnostics",shared);
    wire::ControlEnvelope connect; connect.type=wire::ControlMessageType::connect_request;
    connect.auth_mode=AuthMode::one_time;
    // The transport is intentionally absent; sending the challenge fails after
    // the authentication state machine has created its SPAKE exchange.
    (void)authentication.HandleControlPayload(wire::EncodeControlEnvelope(connect));
    wire::ControlEnvelope bad; bad.type=wire::ControlMessageType::pair_spake_b;
    bad.bytes1.resize(65);
    if(authentication.HandleControlPayload(wire::EncodeControlEnvelope(bad))) return 2;
    if(shared->window.failure_count()!=attempt+1) return 3;
  }
  if(shared->window.IsOpen(security::PairingWindow::Clock::now())) return 4;
  if(!b.OpenPairingWindow() || shared->window.failure_count()!=0 || a.pairing_pin()!=b.pairing_pin()) return 5;
  std::cout<<"PASS: both entrances share PIN and failed-attempt limits\n";
}
