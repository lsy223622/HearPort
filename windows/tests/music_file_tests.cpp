#include <windows.h>

#include <cassert>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

#include "hearport/windows/music_file.h"
#include "hearport/windows/music_test.h"
#include "hearport/windows/sender_service.h"

#undef assert
#define assert(condition) do { if (!(condition)) throw std::runtime_error(#condition); } while (false)

int wmain(int argc, wchar_t** argv) {
  using hearport::windows::LoadMusicExcerpt;
  const auto policies = hearport::windows::MakeMusicTestPolicies(123);
  assert(policies == hearport::windows::MakeMusicTestPolicies(123));
  assert(policies != hearport::windows::MakeMusicTestPolicies(124));
  assert(policies.size() == 32);
  int counts[8][2][2]{};
  for (const auto policy : policies) {
    assert(policy.profile < 8 && policy.repeat >= 1 && policy.repeat <= 2);
    assert(policy.adaptive);
    ++counts[policy.profile][policy.reliable ? 1 : 0][policy.repeat - 1];
  }
  for (const auto& profile : counts) for (const auto& mode : profile)
    assert(mode[0] == 1 && mode[1] == 1);
  for (std::size_t i = 0; i < 16; ++i) {
    assert(policies[i].profile == policies[31 - i].profile);
    assert(policies[i].reliable == policies[31 - i].reliable);
  }
  auto policy = hearport::windows::MusicTestPolicy{true, true, 4, 2, 480, 192};
  const auto round = hearport::windows::EncodeMusicTestRound(3, 120, 96'000, 4, policy, 120);
  assert(round.size() == 24 && round[0] == std::byte{4} && round[2] == std::byte{32});
  assert(round[6] == std::byte{4} && round[7] == std::byte{2});
  assert(round[16] == std::byte{1} && round[17] == std::byte{224});
  assert(round[19] == std::byte{192} && round[21] == std::byte{120});
  if (argc == 2) {
    const auto first = LoadMusicExcerpt(argv[1], 0, 120);
    const auto second = LoadMusicExcerpt(argv[1], 0, 120);
    assert(first.samples.size() == 120 * 48'000 * 2);
    assert(first.samples == second.samples);
    std::cout << "music_input_decode_repeatable frames=" << first.samples.size() / 2 << '\n';
    return 0;
  }
  {
    hearport::windows::SenderService service({});
    hearport::windows::MusicExcerpt clip;
    clip.duration_seconds = 60;
    clip.samples.resize(60 * 48'000 * 2);
    service.ConfigureMusicTest(std::move(clip));
    assert(service.debug_duration()->count() == 2265);
    assert(service.ObserveAudioProgress(7, 1, 0));
  }
  const auto path = std::filesystem::temp_directory_path() /
      (L"hearport-music-fixture-" + std::to_wstring(GetCurrentProcessId()) + L".wav");
  {
    std::ofstream file(path, std::ios::binary);
    const auto write = [&](std::uint32_t value, int bytes) {
      for (int i = 0; i < bytes; ++i) file.put(static_cast<char>(value >> (8 * i)));
    };
    file.write("RIFF", 4); write(36 + 3 * 48'000 * 2, 4); file.write("WAVEfmt ", 8);
    write(16, 4); write(1, 2); write(1, 2); write(48'000, 4); write(96'000, 4);
    write(2, 2); write(16, 2); file.write("data", 4); write(3 * 48'000 * 2, 4);
    for (int i = 0; i < 3 * 48'000; ++i) write(i < 48'000 ? 8192 : 16384, 2);
  }
  const auto first = LoadMusicExcerpt(path, 1, 1);
  const auto second = LoadMusicExcerpt(path, 1, 1);
  assert(first.samples.size() == 48'000 * 2);
  assert(first.samples == second.samples);
  for (const auto sample : first.samples) assert(std::abs(sample - 0.5f) < 0.0001f);
  bool short_file_rejected = false;
  try { (void)LoadMusicExcerpt(path, 2, 2); }
  catch (const std::exception&) { short_file_rejected = true; }
  assert(short_file_rejected);
  std::filesystem::remove(path);
  std::cout << "music_excerpt_tests_passed\n";
}
