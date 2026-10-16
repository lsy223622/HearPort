#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <objbase.h>
#include <xmllite.h>
#include <shlwapi.h>
#include <wrl/client.h>
#include "hearport/windows/usb_tunnel.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <map>
#include <stdexcept>
#include <thread>
#include <utility>

namespace hearport::windows {
std::vector<std::byte> EncodeUsbPacket(std::span<const std::byte> payload) {
  if(payload.empty() || payload.size()>65535) throw std::invalid_argument("USB packet length");
  std::vector<std::byte> result{std::byte{'H'},std::byte{'P'},std::byte{'U'},std::byte{'Q'},
    std::byte{1},std::byte{0},std::byte(payload.size()>>8),std::byte(payload.size()&255)};
  result.insert(result.end(),payload.begin(),payload.end()); return result;
}
bool UsbPacketDecoder::Push(std::span<const std::byte> input, std::vector<std::vector<std::byte>>& out) {
  // Consume incrementally so a coalesced read cannot evade the frame memory bound.
  for(auto byte:input) {
    buffer_.push_back(byte);
    if(buffer_.size()<8) continue;
    const auto size=(std::to_integer<unsigned>(buffer_[6])<<8)|std::to_integer<unsigned>(buffer_[7]);
    if(buffer_[0]!=std::byte{'H'} || buffer_[1]!=std::byte{'P'} || buffer_[2]!=std::byte{'U'} ||
       buffer_[3]!=std::byte{'Q'} || buffer_[4]!=std::byte{1} || buffer_[5]!=std::byte{0} || !size) return false;
    if(buffer_.size()==size+8) { out.emplace_back(buffer_.begin()+8,buffer_.end()); buffer_.clear(); }
  }
  return true;
}
bool UsbPacketQueue::Push(std::span<const std::byte> bytes, Clock::time_point at) {
  if(bytes.empty() || bytes.size()>65535 || bytes_+bytes.size()>65536 || frames_.size()>=128) return false;
  frames_.push_back({EncodeUsbPacket(bytes),0,at}); bytes_+=bytes.size(); return true;
}
std::span<const std::byte> UsbPacketQueue::Front() const {
  if(frames_.empty()) return {};
  return std::span(frames_.front().bytes).subspan(frames_.front().offset);
}
void UsbPacketQueue::Consume(std::size_t size) {
  if(frames_.empty() || size>Front().size()) throw std::invalid_argument("USB write completion");
  auto& frame=frames_.front(); frame.offset+=size;
  if(frame.offset==frame.bytes.size()) { bytes_-=frame.bytes.size()-8; frames_.pop_front(); }
}
bool UsbPacketQueue::Expired(Clock::time_point now,std::chrono::milliseconds limit) const {
  return !frames_.empty() && now-frames_.front().at>=limit;
}
namespace {
using Microsoft::WRL::ComPtr;
struct Plist { std::wstring text; std::map<std::wstring,Plist> dict; std::vector<Plist> array; };
std::wstring Name(IXmlReader* reader) { const wchar_t* value=nullptr; reader->GetLocalName(&value,nullptr); return value?value:L""; }
bool Element(IXmlReader* reader,Plist& node,unsigned depth=0) {
  if(depth>16) return false;
  const auto tag=Name(reader); const bool dict=tag==L"dict", array=tag==L"array";
  if(reader->IsEmptyElement()) return true;
  XmlNodeType kind; std::wstring key;
  while(reader->Read(&kind)==S_OK) {
    if(kind==XmlNodeType_EndElement) return true;
    if(kind==XmlNodeType_Text || kind==XmlNodeType_CDATA) {
      const wchar_t* text=nullptr; UINT length=0;
      if(FAILED(reader->GetValue(&text,&length))) return false;
      node.text.append(text,length);
    } else if(kind==XmlNodeType_Element) {
      const auto child_tag=Name(reader); Plist child;
      if(!Element(reader,child,depth+1)) return false;
      if(dict) {
        if(child_tag==L"key") key=child.text;
        else { if(key.empty()) return false; node.dict.emplace(std::move(key),std::move(child)); key.clear(); }
      } else if(array) node.array.push_back(std::move(child));
      else if(tag==L"plist") node=std::move(child);
    }
  }
  return false;
}
Plist Parse(std::string_view xml) {
  if(xml.empty() || xml.size()>1048576) throw std::runtime_error("invalid Apple service plist length");
  std::string safe(xml);
  if(const auto start=safe.find("<!DOCTYPE"); start!=std::string::npos) {
    const auto end=safe.find('>',start);
    if(end==std::string::npos || safe.substr(start,end-start).find('[')!=std::string::npos) throw std::runtime_error("unexpected plist DTD");
    safe.erase(start,end-start+1);
  }
  ComPtr<IStream> stream; stream.Attach(SHCreateMemStream(reinterpret_cast<const BYTE*>(safe.data()),static_cast<UINT>(safe.size())));
  ComPtr<IXmlReader> reader;
  if(!stream || FAILED(CreateXmlReader(__uuidof(IXmlReader),reinterpret_cast<void**>(reader.GetAddressOf()),nullptr)) ||
     FAILED(reader->SetProperty(XmlReaderProperty_DtdProcessing,DtdProcessing_Prohibit)) ||
     FAILED(reader->SetInput(stream.Get()))) throw std::runtime_error("cannot parse Apple service plist");
  XmlNodeType kind;
  while(reader->Read(&kind)==S_OK) if(kind==XmlNodeType_Element) {
    Plist root; if(Name(reader.Get())!=L"plist" || !Element(reader.Get(),root)) break; return root;
  }
  throw std::runtime_error("malformed Apple service plist");
}
std::vector<std::uint32_t> Devices(const Plist& root) {
  std::vector<std::uint32_t> result;
  const auto add=[&](const Plist& item) {
    const auto id=item.dict.find(L"DeviceID"), props=item.dict.find(L"Properties");
    if(id==item.dict.end() || props==item.dict.end()) return;
    const auto type=props->second.dict.find(L"ConnectionType");
    if(type==props->second.dict.end() || type->second.text!=L"USB") return;
    try { auto number=std::stoul(id->second.text); if(number && number<=UINT32_MAX) result.push_back(static_cast<std::uint32_t>(number)); } catch(...) {}
  };
  if(auto items=root.dict.find(L"DeviceList"); items!=root.dict.end()) for(const auto& item:items->second.array) { if(result.size()==8) break; add(item); }
  else add(root);
  return result;
}
struct Socket {
  SOCKET fd=INVALID_SOCKET;
  Socket()=default; explicit Socket(SOCKET value):fd(value) {}
  ~Socket() { if(fd!=INVALID_SOCKET) closesocket(fd); }
  Socket(Socket&& other) noexcept:fd(std::exchange(other.fd,INVALID_SOCKET)) {}
  Socket& operator=(Socket&& other) noexcept { std::swap(fd,other.fd); return *this; }
  Socket(const Socket&)=delete;
};
sockaddr_in Address(std::uint16_t port) { sockaddr_in result{}; result.sin_family=AF_INET; result.sin_addr.s_addr=htonl(INADDR_LOOPBACK); result.sin_port=htons(port); return result; }
void Nonblocking(SOCKET socket) { u_long value=1; if(ioctlsocket(socket,FIONBIO,&value)) throw std::runtime_error("socket nonblocking failed"); }
bool Ready(SOCKET socket,bool write,int milliseconds=100) {
  fd_set set; FD_ZERO(&set); FD_SET(socket,&set); timeval wait{milliseconds/1000,(milliseconds%1000)*1000};
  return select(0,write?nullptr:&set,write?&set:nullptr,nullptr,&wait)>0;
}
}
std::vector<std::uint32_t> ParseUsbDevices(std::string_view xml) { try { return Devices(Parse(xml)); } catch(...) { return {}; } }
struct UsbTunnel::Impl {
  std::atomic<bool> stop{false}; std::atomic<long long> maximum_ms{100};
  std::thread worker; std::uint16_t port=0; StatusHandler status; LogHandler log;
  void Check() { if(stop) throw std::runtime_error("stopped"); }
  Socket Connect() {
    Socket socket(::socket(AF_INET,SOCK_STREAM,IPPROTO_TCP)); if(socket.fd==INVALID_SOCKET) throw std::runtime_error("USB socket unavailable");
    Nonblocking(socket.fd); auto address=Address(27015);
    if(connect(socket.fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))==SOCKET_ERROR && WSAGetLastError()!=WSAEWOULDBLOCK) throw std::runtime_error("Apple device service unavailable");
    auto end=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    while(!Ready(socket.fd,true)) { Check(); if(std::chrono::steady_clock::now()>=end) throw std::runtime_error("Apple device service unavailable"); }
    int error=0,len=sizeof(error); getsockopt(socket.fd,SOL_SOCKET,SO_ERROR,reinterpret_cast<char*>(&error),&len);
    if(error) throw std::runtime_error("Apple device service unavailable");
    int enabled=1; setsockopt(socket.fd,IPPROTO_TCP,TCP_NODELAY,reinterpret_cast<char*>(&enabled),sizeof(enabled));
    return socket;
  }
  void Transfer(SOCKET socket,std::span<std::byte> bytes,bool write) {
    auto end=std::chrono::steady_clock::now()+std::chrono::seconds(2);
    while(!bytes.empty()) {
      Check(); if(std::chrono::steady_clock::now()>=end) throw std::runtime_error("Apple service response timeout");
      if(!Ready(socket,write)) continue;
      int n=write?send(socket,reinterpret_cast<char*>(bytes.data()),static_cast<int>(bytes.size()),0):recv(socket,reinterpret_cast<char*>(bytes.data()),static_cast<int>(bytes.size()),0);
      if(n<0 && WSAGetLastError()==WSAEWOULDBLOCK) continue;
      if(n<=0) throw std::runtime_error("Apple device connection closed"); bytes=bytes.subspan(n);
    }
  }
  Plist Receive(SOCKET socket) {
    std::array<std::uint32_t,4> header{}; Transfer(socket,std::as_writable_bytes(std::span(header)),false);
    if(header[0]<16 || header[0]>1048576 || header[1]!=1 || header[2]!=8) throw std::runtime_error("invalid Apple service response");
    std::vector<std::byte> data(header[0]-16); Transfer(socket,data,false);
    return Parse({reinterpret_cast<char*>(data.data()),data.size()});
  }
  Plist Request(SOCKET socket,const std::string& fields) {
    auto xml="<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ClientVersionString</key><string>HearPort</string><key>ProgName</key><string>HearPort</string><key>kLibUSBMuxVersion</key><integer>3</integer>"+fields+"</dict></plist>";
    std::array<std::uint32_t,4> header{static_cast<std::uint32_t>(xml.size()+16),1,8,1};
    Transfer(socket,std::as_writable_bytes(std::span(header)),true);
    Transfer(socket,{reinterpret_cast<std::byte*>(xml.data()),xml.size()},true); return Receive(socket);
  }
  static void Success(const Plist& response) {
    auto number=response.dict.find(L"Number");
    if(number==response.dict.end() || number->second.text!=L"0") throw std::runtime_error("Open HearPort on iPad; unlock and trust this PC if prompted");
  }
  void Pump(Socket& tcp) {
    Socket udp(::socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)); Nonblocking(udp.fd); auto address=Address(port);
    if(connect(udp.fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))) throw std::runtime_error("USB QUIC entrance unavailable");
    UsbPacketDecoder decoder; UsbPacketQueue outgoing;
    std::array<std::byte,65536> data{};
    auto last=std::chrono::steady_clock::now();
    if(status) status("USB available"); if(log) log("usb_tunnel_connected");
    while(!stop) {
      fd_set read,write; FD_ZERO(&read); FD_ZERO(&write); FD_SET(tcp.fd,&read); FD_SET(udp.fd,&read);
      if(!outgoing.Front().empty()) FD_SET(tcp.fd,&write);
      timeval wait{0,10000}; if(select(0,&read,&write,nullptr,&wait)<0) throw std::runtime_error("USB socket failed");
      const auto now=std::chrono::steady_clock::now();
      if(outgoing.Expired(now,std::chrono::milliseconds(maximum_ms.load()))) throw std::runtime_error("USB queue deadline exceeded");
      if(now-last>std::chrono::seconds(15)) throw std::runtime_error("USB entrance idle; checking attached devices");
      if(FD_ISSET(tcp.fd,&read)) {
        int n=recv(tcp.fd,reinterpret_cast<char*>(data.data()),static_cast<int>(data.size()),0);
        if(n<=0) throw std::runtime_error(decoder.Complete()?"USB disconnected":"USB truncated packet");
        std::vector<std::vector<std::byte>> packets;
        if(!decoder.Push(std::span(data).first(n),packets)) throw std::runtime_error("USB invalid packet");
        for(const auto& packet:packets) if(send(udp.fd,reinterpret_cast<const char*>(packet.data()),static_cast<int>(packet.size()),0)!=packet.size()) throw std::runtime_error("USB UDP forwarding failed");
        last=now;
      }
      if(FD_ISSET(udp.fd,&read)) {
        int n=recv(udp.fd,reinterpret_cast<char*>(data.data()),static_cast<int>(data.size()),0);
        if(n<=0 || !outgoing.Push(std::span(data).first(n),now)) throw std::runtime_error("USB queue overflow");
        last=now;
      }
      if(FD_ISSET(tcp.fd,&write)) {
        auto bytes=outgoing.Front(); int n=send(tcp.fd,reinterpret_cast<const char*>(bytes.data()),static_cast<int>(bytes.size()),0);
        if(n>0) outgoing.Consume(n); else if(n==0 || WSAGetLastError()!=WSAEWOULDBLOCK) throw std::runtime_error("USB write failed");
      }
    }
  }
  void Run() {
    WSADATA data; if(WSAStartup(MAKEWORD(2,2),&data)) { if(status) status("USB socket unavailable"); return; }
    unsigned retry=1; std::size_t rotation=0;
    while(!stop) {
      try {
        auto query=Connect(); auto devices=Devices(Request(query.fd,"<key>MessageType</key><string>ListDevices</string>"));
        auto events=Connect(); Success(Request(events.fd,"<key>MessageType</key><string>Listen</string>"));
        if(!devices.empty()) {
          for(std::size_t i=0;i<devices.size() && !stop;++i) {
            try {
              auto tcp=Connect(); const auto id=devices[(rotation+i)%devices.size()];
              Success(Request(tcp.fd,"<key>MessageType</key><string>Connect</string><key>DeviceID</key><integer>"+std::to_string(id)+"</integer><key>PortNumber</key><integer>"+std::to_string(htons(52138))+"</integer>"));
              retry=1; Pump(tcp);
            } catch(const std::exception& e) { if(!stop && status) status(e.what()); }
          }
          ++rotation;
        } else if(status) status("Waiting for USB iPad");
        const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(retry);
        while(!stop && std::chrono::steady_clock::now()<until) if(Ready(events.fd,false)) { (void)Receive(events.fd); break; }
      } catch(const std::exception& e) {
        if(!stop && status) status(e.what());
        for(unsigned i=0;i<retry*10 && !stop;++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
      retry=std::min(10u,retry*2);
    }
    WSACleanup();
  }
};
UsbTunnel::UsbTunnel():impl_(std::make_unique<Impl>()) {}
UsbTunnel::~UsbTunnel() { Stop(); }
bool UsbTunnel::Start(std::uint16_t port,StatusHandler status,LogHandler log) {
  if(!port || impl_->worker.joinable()) return false;
  impl_->port=port; impl_->status=std::move(status); impl_->log=std::move(log); impl_->stop=false;
  impl_->worker=std::thread([this] { impl_->Run(); }); return true;
}
void UsbTunnel::SetMaximumLatency(std::chrono::milliseconds maximum) { impl_->maximum_ms=std::clamp<long long>(maximum.count(),1,60000); }
void UsbTunnel::Stop() { impl_->stop=true; if(impl_->worker.joinable()) impl_->worker.join(); }
}
