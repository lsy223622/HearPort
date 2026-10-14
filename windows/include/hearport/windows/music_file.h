#pragma once

#include <cstdint>
#include <filesystem>
#include <vector>

namespace hearport::windows {

struct MusicExcerpt {
  std::filesystem::path source;
  std::uint32_t start_seconds = 0;
  std::uint32_t duration_seconds = 120;
  std::vector<float> samples;
};

MusicExcerpt LoadMusicExcerpt(const std::filesystem::path& source,
                             std::uint32_t start_seconds,
                             std::uint32_t duration_seconds);

}  // namespace hearport::windows
