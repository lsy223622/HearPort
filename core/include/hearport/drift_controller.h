#pragma once

#include <cstddef>
#include <optional>

namespace hearport {

class DriftController {
 public:
  explicit DriftController(std::size_t target_frames);

  double Update(std::size_t fill_frames, bool valid_audio,
                double nominal_ratio);
  void Freeze() noexcept {}
  void Reset() noexcept;

 private:
  std::size_t target_frames_;
  double filtered_error_ = 0.0;
  std::optional<double> last_ratio_;
};

}  // namespace hearport
