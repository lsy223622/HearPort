#include "hearport/drift_controller.h"

#include <algorithm>
#include <stdexcept>

namespace hearport {

DriftController::DriftController(std::size_t target_frames)
    : target_frames_(target_frames) {
  if (target_frames_ == 0) {
    throw std::invalid_argument("drift target must be positive");
  }
}

double DriftController::Update(std::size_t fill_frames, bool valid_audio,
                                double nominal_ratio) {
  if (!valid_audio) {
    return last_ratio_.value_or(nominal_ratio);
  }

  const auto error = static_cast<double>(fill_frames) -
                     static_cast<double>(target_frames_);
  filtered_error_ = filtered_error_ * 0.95 + error * 0.05;
  const auto normalized = filtered_error_ / static_cast<double>(target_frames_);
  const auto correction = std::clamp(normalized * 0.001, -0.001, 0.001);
  last_ratio_ = nominal_ratio * (1.0 + correction);
  return last_ratio_.value();
}

void DriftController::Reset() noexcept {
  filtered_error_ = 0.0;
  last_ratio_.reset();
}

}  // namespace hearport
