#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <windows.h>
#include <windns.h>
#include "hearport/windows/service_discovery.h"
#include <atomic>

namespace hearport::windows {
struct ServiceDiscovery::Impl {
  struct Registration {
    DNS_SERVICE_REGISTER_REQUEST request{};
    DNS_SERVICE_CANCEL cancel{};
    HANDLE completed = CreateEventW(nullptr,TRUE,FALSE,nullptr);
    std::atomic<DWORD> result{DNS_REQUEST_PENDING};
    ~Registration() { if(request.pServiceInstance) DnsServiceFreeInstance(request.pServiceInstance); if(completed) CloseHandle(completed); }
    static void WINAPI Complete(DWORD status,void* context,DNS_SERVICE_INSTANCE* instance) {
      std::unique_ptr<std::shared_ptr<Registration>> retained(static_cast<std::shared_ptr<Registration>*>(context));
      auto state=*retained;
      if(instance && instance!=state->request.pServiceInstance) DnsServiceFreeInstance(instance);
      state->result=status; SetEvent(state->completed);
    }
  };
  std::shared_ptr<Registration> registration;
  static bool Submit(const std::shared_ptr<Registration>& state,bool remove) {
    auto* retained=new std::shared_ptr<Registration>(state);
    state->request.Version=DNS_QUERY_REQUEST_VERSION1;
    state->request.pRegisterCompletionCallback=&Registration::Complete;
    state->request.pQueryContext=retained;
    auto result=remove?DnsServiceDeRegister(&state->request,&state->cancel):DnsServiceRegister(&state->request,&state->cancel);
    if(result!=DNS_REQUEST_PENDING) { delete retained; state->result=result; SetEvent(state->completed); }
    return result==DNS_REQUEST_PENDING || result==ERROR_SUCCESS;
  }
};
ServiceDiscovery::ServiceDiscovery():impl_(std::make_unique<Impl>()) {}
ServiceDiscovery::~ServiceDiscovery() { Stop(); }
bool ServiceDiscovery::Start(std::uint16_t port,std::wstring identity) {
  if(impl_->registration) return false;
  wchar_t computer[256]{}; DWORD length=256;
  if(!GetComputerNameW(computer,&length)) return false;
  const auto host=std::wstring(computer)+L".local";
  const auto name=L"HearPort-"+identity.substr(0,12)+L"._hearport._udp.local";
  const wchar_t* keys[]{L"v",L"id"}; const wchar_t* values[]{L"1",identity.c_str()};
  auto state=std::make_shared<Impl::Registration>();
  state->request.pServiceInstance=DnsServiceConstructInstance(name.c_str(),host.c_str(),nullptr,nullptr,port,0,0,2,keys,values);
  if(!state->request.pServiceInstance || !state->completed) return false;
  impl_->registration=state; return Impl::Submit(state,false);
}
void ServiceDiscovery::Stop() {
  auto state=std::move(impl_->registration); if(!state) return;
  if(state->result==DNS_REQUEST_PENDING) {
    DnsServiceRegisterCancel(&state->cancel);
    WaitForSingleObject(state->completed,2000);
  }
  if(state->result==ERROR_SUCCESS) {
    auto removal=std::make_shared<Impl::Registration>();
    removal->request.pServiceInstance=DnsServiceCopyInstance(state->request.pServiceInstance);
    if(removal->request.pServiceInstance) Impl::Submit(removal,true);
  }
}
}
