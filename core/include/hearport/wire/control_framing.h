#pragma once

#include <array>
#include <cstddef>
#include <span>
#include <vector>

namespace hearport::wire {

inline constexpr std::size_t kControlMessageMaxBytes = 65536;

std::vector<std::byte> EncodeControlFrame(std::span<const std::byte> payload);

class ControlFrameDecoder {
 public:
  explicit ControlFrameDecoder(
      std::size_t max_message = kControlMessageMaxBytes);

  // Returns false only when the input contains an invalid length. A true
  // result may still have no complete messages when the input is fragmented.
  bool Push(std::span<const std::byte> bytes,
            std::vector<std::vector<std::byte>>& complete_messages);

  void Reset() noexcept;

 private:
  std::size_t max_message_;
  std::array<std::byte, 4> header_{};
  std::size_t header_size_ = 0;
  std::size_t expected_payload_size_ = 0;
  std::vector<std::byte> payload_;
  bool failed_ = false;
};

}  // namespace hearport::wire
