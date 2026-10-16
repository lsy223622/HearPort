#include "hearport/windows/sender_host.h"
#include <iomanip>
#include <sstream>
namespace hearport::windows {
SenderHost::SenderHost(QuicServerOptions options,std::filesystem::path root)
    :pairing_(std::make_shared<SenderPairingState>()),options_(options) {
  for(unsigned i=0;i<2;++i) {
    auto endpoint=options; endpoint.loopback_only=i==1; if(i) endpoint.port=0;
    endpoint.diagnostic_log=[this,i](std::string_view line) {
      if(options_.diagnostic_log) options_.diagnostic_log(std::string(i?"path=usb ":"path=network ")+std::string(line));
    };
    services_[i]=std::make_unique<SenderService>(endpoint);
    authentications_[i]=std::make_unique<SenderAuthentication>(*services_[i],options.certificate_spki_sha256,ProtectedCredentialStore{},root,pairing_);
    services_[i]->SetControlHandler([this,i](auto bytes) { return authentications_[i]->HandleControlPayload(bytes); });
    services_[i]->SetClosedHandler([this,i] { authentications_[i]->Reset(); });
    services_[i]->SetResetHandler([this,i] { authentications_[i]->OnCaptureReset(); });
    services_[i]->SetDebugEndedHandler([this,i](auto id,auto reason) { authentications_[i]->OnDebugSessionEnded(id,reason); });
    services_[i]->SetActivationHandler([this,i] { return Activate(i); });
    if(i) services_[i]->SetBudgetHandler([this](std::uint32_t ms) { tunnel_.SetMaximumLatency(std::chrono::milliseconds(ms)); });
    authentications_[i]->SetConnectionHandler([this,i](bool connected,bool reliable) { Connected(i,connected,reliable); });
  }
}
SenderHost::~SenderHost() { Stop(); }
void SenderHost::Configure(const std::function<void(SenderService&)>& configure) {
  for(auto& service:services_) configure(*service);
  selection_.SetPinned(services_[0]->network_probe());
  selection_.SetKeepPath(services_[0]->debug_duration().has_value());
}
bool SenderHost::Start() {
  if(started_) return false;
  stopping_=false;
  if(!services_[0]->Start()) { stopping_=true; return false; }
  started_=true;
  if(services_[0]->network_probe()) {
    std::lock_guard lock(mutex_); usb_status_="Network test uses network connection";
  } else if(services_[1]->Start()) {
    tunnel_.Start(services_[1]->local_port(),[this](std::string status) {
      const bool available=status=="USB available";
      { std::lock_guard lock(mutex_); usb_status_=std::move(status); }
      if(!available) services_[1]->CloseConnection();
    },options_.diagnostic_log);
  } else { std::lock_guard lock(mutex_); usb_status_="USB listener unavailable"; }
  std::wostringstream identity; identity<<std::hex<<std::setfill(L'0');
  for(auto byte:options_.certificate_spki_sha256) identity<<std::setw(2)<<std::to_integer<unsigned>(byte);
  if(!discovery_.Start(services_[0]->local_port(),identity.str()) && options_.diagnostic_log) options_.diagnostic_log("network_discovery_unavailable");
  return true;
}
bool SenderHost::Activate(unsigned index) {
  std::lock_guard transition(activation_mutex_);
  if(stopping_) return false;
  std::optional<std::uint64_t> previous;
  {
    std::lock_guard lock(mutex_);
    previous=selection_.active();
    if(!selection_.Activate(index+1,index?PhysicalPath::usb:PhysicalPath::network,services_[index]->authenticated_peer())) return false;
    last_=index;
    has_selected_=true;
    selected_condition_.notify_all();
  }
  if(previous && *previous!=index+1) services_[*previous-1]->SuspendForHandover();
  return true;
}
void SenderHost::Connected(unsigned index,bool connected,bool reliable) {
  ConnectionHandler handler;
  {
    std::lock_guard lock(mutex_);
    if(selection_.active()!=index+1) return;
    if(!connected) selection_.Closed(index+1);
    handler=handler_;
  }
  if(handler && !stopping_) handler(connected,reliable,index?PhysicalPath::usb:PhysicalPath::network);
}
void SenderHost::Stop() {
  if(!started_) return;
  stopping_=true;
  selected_condition_.notify_all();
  for(auto& service:services_) service->NotifyUserStop();
  tunnel_.Stop(); discovery_.Stop();
  { std::lock_guard transition(activation_mutex_); }
  for(auto& service:services_) service->Stop();
  started_=false;
}
bool SenderHost::OpenPairingWindow() { return authentications_[0]->OpenPairingWindow(); }
std::string SenderHost::pairing_pin() const { return authentications_[0]->pairing_pin(); }
SenderService& SenderHost::service() { std::lock_guard lock(mutex_); return *services_[last_]; }
bool SenderHost::WaitForDebugCompletion(std::chrono::milliseconds timeout) {
  const auto until=std::chrono::steady_clock::now()+timeout;
  std::unique_lock lock(mutex_);
  if(!selected_condition_.wait_until(lock,until,[this] { return has_selected_ || stopping_; }) || stopping_) return false;
  auto* selected=services_[last_].get();
  lock.unlock();
  return selected->WaitForDebugCompletion(std::chrono::duration_cast<std::chrono::milliseconds>(until-std::chrono::steady_clock::now()));
}
std::string SenderHost::usb_status() const { std::lock_guard lock(mutex_); return usb_status_; }
}
