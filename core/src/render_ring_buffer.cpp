#include "hearport/render_ring_buffer.h"

#include <algorithm>
#include <stdexcept>

namespace hearport {

RenderRingBuffer::RenderRingBuffer(std::size_t capacity_frames)
    : storage_(capacity_frames) {
  if (capacity_frames == 0) {
    throw std::invalid_argument("render ring capacity must be positive");
  }
}

std::size_t RenderRingBuffer::Write(std::span<const float> frames) {
  const auto accepted =
      std::min(frames.size(), storage_.size() - size_);
  for (std::size_t index = 0; index < accepted; ++index) {
    storage_[write_index_] = frames[index];
    write_index_ = (write_index_ + 1) % storage_.size();
  }
  size_ += accepted;
  stats_.overflow_frames += frames.size() - accepted;
  return accepted;
}

std::size_t RenderRingBuffer::Read(std::span<float> frames) {
  const auto available = std::min(frames.size(), size_);
  for (std::size_t index = 0; index < available; ++index) {
    frames[index] = storage_[read_index_];
    read_index_ = (read_index_ + 1) % storage_.size();
  }
  size_ -= available;
  stats_.underflow_frames += frames.size() - available;
  return available;
}

}  // namespace hearport
