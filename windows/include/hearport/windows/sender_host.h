#pragma once
#include "hearport/windows/sender_authentication.h"
#include "hearport/windows/connection_selection.h"
#include "hearport/windows/usb_tunnel.h"
#include "hearport/windows/service_discovery.h"
namespace hearport::windows {
class SenderHost {
 public:
  using ConnectionHandler=std::function<void(bool,bool,PhysicalPath)>;
  SenderHost(QuicServerOptions options,std::filesystem::path report_root);
  ~SenderHost();
  void Configure(const std::function<void(SenderService&)>& configure);
  bool Start();
  void Stop();
  bool OpenPairingWindow();
  std::string pairing_pin() const;
  SenderService& service();
  void SetConnectionHandler(ConnectionHandler handler) { handler_=std::move(handler); }
  std::string usb_status() const;
 private:
  bool Activate(unsigned index);
  void Connected(unsigned index,bool connected,bool reliable);
  std::unique_ptr<SenderService> services_[2];
  std::unique_ptr<SenderAuthentication> authentications_[2];
  std::shared_ptr<SenderPairingState> pairing_;
  QuicServerOptions options_;
  mutable std::mutex mutex_;
  std::mutex activation_mutex_;
  ConnectionSelection selection_;
  unsigned last_=0;
  bool started_=false;
  std::atomic<bool> stopping_{true};
  ConnectionHandler handler_;
  std::string usb_status_="Waiting for USB iPad";
  UsbTunnel tunnel_;
  ServiceDiscovery discovery_;
};
}
