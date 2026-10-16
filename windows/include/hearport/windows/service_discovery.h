#pragma once
#include <cstdint>
#include <memory>
#include <string>
namespace hearport::windows {
class ServiceDiscovery {
 public:
  ServiceDiscovery();
  ~ServiceDiscovery();
  bool Start(std::uint16_t port, std::wstring public_identity);
  void Stop();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
