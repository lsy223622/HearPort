#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace hearport {

struct RenderRingStats {
  std::uint64_t overflow_frames = 0;
  std::uint64_t underflow_frames = 0;
};

class RenderRingBuffer {
 public:
  explicit RenderRingBuffer(std::size_t capacity_frames);

  std::size_t Write(std::span<const float> frames);
  std::size_t Read(std::span<float> frames);
  std::size_t size() const noexcept { return size_; }
  const RenderRingStats& stats() const noexcept { return stats_; }

 private:
  std::vector<float> storage_;
  std::size_t read_index_ = 0;
  std::size_t write_index_ = 0;
  std::size_t size_ = 0;
  RenderRingStats stats_{};
};

}  // namespace hearport
