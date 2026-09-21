#include "hearport/wire/control_framing.h"

#include <algorithm>
#include <cstdint>
#include <stdexcept>

namespace hearport::wire {
namespace {

std::uint32_t ReadBigEndian32(const std::array<std::byte, 4>& bytes) {
  return (static_cast<std::uint32_t>(bytes[0]) << 24) |
         (static_cast<std::uint32_t>(bytes[1]) << 16) |
         (static_cast<std::uint32_t>(bytes[2]) << 8) |
         static_cast<std::uint32_t>(bytes[3]);
}

std::array<std::byte, 4> WriteBigEndian32(std::uint32_t value) {
  return {std::byte{static_cast<unsigned char>((value >> 24) & 0xffu)},
          std::byte{static_cast<unsigned char>((value >> 16) & 0xffu)},
          std::byte{static_cast<unsigned char>((value >> 8) & 0xffu)},
          std::byte{static_cast<unsigned char>(value & 0xffu)}};
}

}  // namespace

std::vector<std::byte> EncodeControlFrame(std::span<const std::byte> payload) {
  if (payload.empty() || payload.size() > kControlMessageMaxBytes) {
    throw std::invalid_argument("control message length is outside v1 bounds");
  }

  const auto header = WriteBigEndian32(static_cast<std::uint32_t>(payload.size()));
  std::vector<std::byte> encoded;
  encoded.reserve(header.size() + payload.size());
  encoded.insert(encoded.end(), header.begin(), header.end());
  encoded.insert(encoded.end(), payload.begin(), payload.end());
  return encoded;
}

ControlFrameDecoder::ControlFrameDecoder(std::size_t max_message)
    : max_message_(max_message) {
  if (max_message_ == 0 || max_message_ > kControlMessageMaxBytes) {
    throw std::invalid_argument("max control message is outside v1 bounds");
  }
}

bool ControlFrameDecoder::Push(
    std::span<const std::byte> bytes,
    std::vector<std::vector<std::byte>>& complete_messages) {
  if (failed_) {
    return false;
  }

  std::size_t offset = 0;
  while (offset < bytes.size()) {
    if (expected_payload_size_ == 0) {
      const auto header_copy =
          std::min<std::size_t>(4 - header_size_, bytes.size() - offset);
      std::copy_n(bytes.begin() + static_cast<std::ptrdiff_t>(offset),
                  header_copy, header_.begin() +
                                   static_cast<std::ptrdiff_t>(header_size_));
      header_size_ += header_copy;
      offset += header_copy;
      if (header_size_ < header_.size()) {
        continue;
      }

      const auto length = ReadBigEndian32(header_);
      if (length == 0 || length > max_message_) {
        failed_ = true;
        payload_.clear();
        return false;
      }
      expected_payload_size_ = length;
      payload_.clear();
      payload_.reserve(expected_payload_size_);
    }

    const auto remaining = expected_payload_size_ - payload_.size();
    const auto payload_copy = std::min<std::size_t>(remaining, bytes.size() - offset);
    payload_.insert(payload_.end(),
                    bytes.begin() + static_cast<std::ptrdiff_t>(offset),
                    bytes.begin() + static_cast<std::ptrdiff_t>(offset + payload_copy));
    offset += payload_copy;
    if (payload_.size() < expected_payload_size_) {
      continue;
    }

    complete_messages.push_back(std::move(payload_));
    payload_.clear();
    expected_payload_size_ = 0;
    header_size_ = 0;
  }

  return true;
}

}  // namespace hearport::wire
