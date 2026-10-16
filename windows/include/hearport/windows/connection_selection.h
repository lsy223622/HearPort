#pragma once
#include <cstdint>
#include <optional>
#include <string>
namespace hearport::windows {
enum class PhysicalPath { network, usb };
class ConnectionSelection {
 public:
  void SetPinned(bool pinned) { pinned_ = pinned; }
  void SetKeepPath(bool pinned) { keep_path_ = pinned; }
  bool Activate(std::uint64_t id, PhysicalPath path, const std::string& peer) {
    if (active_ && *active_ == id) return true;
    if ((keep_path_ && used_) || (pinned_ && (active_ || path == PhysicalPath::usb)) ||
        (active_ && (path != PhysicalPath::usb || path_ == PhysicalPath::usb ||
                     peer.empty() || peer != peer_))) return false;
    used_ = true; active_ = id; path_ = path; peer_ = peer; return true;
  }
  void Closed(std::uint64_t id) { if (active_ == id) active_.reset(); }
  std::optional<std::uint64_t> active() const { return active_; }
 private:
  std::optional<std::uint64_t> active_;
  PhysicalPath path_ = PhysicalPath::network;
  std::string peer_;
  bool pinned_ = false;
  bool keep_path_ = false, used_ = false;
};
}
