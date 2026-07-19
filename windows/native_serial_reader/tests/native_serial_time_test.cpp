#include "../native_time_utils.h"

#include <cstdint>
#include <iostream>
#include <limits>

namespace {

bool expect_equal(const char* name, int64_t actual, int64_t expected) {
  if (actual == expected) return true;
  std::cerr << name << ": expected " << expected << ", got " << actual
            << std::endl;
  return false;
}

}  // namespace

int main() {
  using vscope::native_time::filetime_to_unix_microseconds;
  using vscope::native_time::kWindowsToUnixEpoch100ns;
  using vscope::native_time::qpc_ticks_to_microseconds;

  bool passed = true;
  constexpr int64_t frequency = 10000000LL;
  constexpr int64_t thirtyDaysSeconds = 30LL * 24 * 60 * 60;
  const int64_t thirtyDayTicks =
      thirtyDaysSeconds * frequency + frequency / 4;
  passed &= expect_equal(
      "thirty-day QPC conversion",
      qpc_ticks_to_microseconds(thirtyDayTicks, frequency),
      thirtyDaysSeconds * 1000000LL + 250000LL);

  const int64_t nearMaximumTicks = std::numeric_limits<int64_t>::max() - 123;
  const int64_t nearMaximumMicros =
      qpc_ticks_to_microseconds(nearMaximumTicks, frequency);
  passed &= nearMaximumMicros > 0;
  passed &= qpc_ticks_to_microseconds(nearMaximumTicks - 1, frequency) <=
            nearMaximumMicros;
  passed &= expect_equal(
      "invalid QPC frequency", qpc_ticks_to_microseconds(100, 0), 0);

  passed &= expect_equal(
      "Unix epoch", filetime_to_unix_microseconds(kWindowsToUnixEpoch100ns),
      0);
  constexpr int64_t thirtyDaysMicros = thirtyDaysSeconds * 1000000LL;
  passed &= expect_equal(
      "FILETIME after epoch",
      filetime_to_unix_microseconds(
          kWindowsToUnixEpoch100ns + thirtyDaysMicros * 10ULL),
      thirtyDaysMicros);

  return passed ? 0 : 1;
}
