#pragma once

#include <cstdint>
#include <limits>

namespace vscope::native_time {

constexpr int64_t kMicrosPerSecond = 1000000LL;
constexpr uint64_t kWindowsToUnixEpoch100ns = 116444736000000000ULL;

/// 将 QPC 计数转换为微秒，避免直接执行 ticks * 1,000,000。
inline int64_t qpc_ticks_to_microseconds(
    int64_t ticks,
    int64_t frequency) noexcept {
  if (ticks <= 0 || frequency <= 0) return 0;
  const int64_t seconds = ticks / frequency;
  const int64_t remainder = ticks % frequency;
  if (seconds > std::numeric_limits<int64_t>::max() / kMicrosPerSecond) {
    return std::numeric_limits<int64_t>::max();
  }

  int64_t fractionalMicros = 0;
  if (remainder <=
      std::numeric_limits<int64_t>::max() / kMicrosPerSecond) {
    fractionalMicros = (remainder * kMicrosPerSecond) / frequency;
  } else {
    // 极端频率下使用浮点只计算不足一秒的余数，避免整数乘法溢出。
    fractionalMicros = static_cast<int64_t>(
        (static_cast<long double>(remainder) * kMicrosPerSecond) /
        static_cast<long double>(frequency));
  }
  return seconds * kMicrosPerSecond + fractionalMicros;
}

/// 将 Windows FILETIME 的 100ns 计数转换为 Unix epoch 微秒。
inline int64_t filetime_to_unix_microseconds(uint64_t ticks100ns) noexcept {
  if (ticks100ns <= kWindowsToUnixEpoch100ns) return 0;
  const uint64_t unixMicros =
      (ticks100ns - kWindowsToUnixEpoch100ns) / 10ULL;
  if (unixMicros >
      static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    return std::numeric_limits<int64_t>::max();
  }
  return static_cast<int64_t>(unixMicros);
}

}  // namespace vscope::native_time
