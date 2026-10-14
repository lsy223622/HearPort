#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include "hearport/windows/reliable_audio_lag.h"

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  std::ofstream report(argv[1]);
  if (!report) return 2;
  report << "{\"model\":\"feedback_snapshot_audit\",\"rows\":[";
  bool first = true;
  for (const int budget : {89, 149, 229}) {
    for (const int age : {0, 5, 10, 15, 20, 25, 30, 35, 40, 60, 80, 100, 150}) {
      int ignored = 0, old_false_positive = 0, corrected_false_positive = 0;
      int old_true_positive = 0, corrected_true_positive = 0, corrected_false_negative = 0;
      int cases = 0;
      for (int distance = 0; distance * 2.5 <= budget + 150; ++distance) {
        ++cases;
        const bool actually_behind = distance * 2.5 > budget;
        const std::uint32_t received = 1000;
        const std::uint32_t produced = received + distance + age * 400 / 1000;
        hearport::windows::ReliableAudioLag lag;
        const auto start = hearport::windows::ReliableAudioLag::Clock::time_point{};
        lag.Begin(7, 1, start, std::chrono::milliseconds(budget));
        lag.Produced(produced);
        const bool corrected = lag.Observe(7, 1, received,
            start + std::chrono::seconds(10), std::chrono::milliseconds(age));
        if (age > budget / 2) {
          ++ignored;
          if (corrected) throw std::runtime_error("stale feedback triggered recovery");
          continue;
        }
        const bool old = (produced - received) * 2.5 > budget;
        old_false_positive += old && !actually_behind;
        corrected_false_positive += corrected && !actually_behind;
        old_true_positive += old && actually_behind;
        corrected_true_positive += corrected && actually_behind;
        corrected_false_negative += !corrected && actually_behind;
      }
      if (corrected_false_positive || corrected_false_negative) {
        throw std::runtime_error("recovery disagrees with the feedback generation time");
      }
      if (!first) report << ',';
      first = false;
      report << "{\"budget_ms\":" << budget << ",\"feedback_age_ms\":" << age
             << ",\"cases\":" << cases << ",\"ignored\":" << ignored
             << ",\"old_false_positive\":" << old_false_positive
             << ",\"corrected_false_positive\":" << corrected_false_positive
             << ",\"old_true_positive\":" << old_true_positive
             << ",\"corrected_true_positive\":" << corrected_true_positive
             << ",\"corrected_false_negative\":" << corrected_false_negative << '}';
    }
  }
  report << "]}\n";
  std::cout << "recovery_snapshot_checks_passed\n";
  return report ? 0 : 2;
}
