// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_
#define CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_

#include <algorithm>
#include <atomic>
#include <cstdint>

#include "build/build_config.h"

#if BUILDFLAG(IS_IOS)
#include <mach/mach.h>
#include <os/proc.h>
#include <sys/sysctl.h>
#endif

namespace content::blinker_memory {

inline constexpr uint64_t kMiB = 1024ULL * 1024ULL;

// Стеля це phys_footprint + os_proc_available_memory(), тобто ліміт jetsam
// знизу обмежена для слабких пристроїв
inline constexpr uint64_t kCeilingFloor = 700 * kMiB;
inline constexpr uint64_t kCeilingCap = 1800 * kMiB;
inline constexpr uint64_t kFallbackCeiling = 900 * kMiB;

inline constexpr uint64_t kModeratePercent = 55;
inline constexpr uint64_t kCriticalPercent = 72;
inline constexpr uint64_t kBlockNewContentsPercent = 82;

// Головний сигнал це запас до jetsam, footprint запасний, тому пороги
// лишаємо щедрими
inline constexpr uint64_t kMinModerateAvailable = 280 * kMiB;
inline constexpr uint64_t kMinCriticalAvailable = 140 * kMiB;

inline uint64_t DevicePhysicalMemory() {
#if BUILDFLAG(IS_IOS)
  static const uint64_t mem = [] {
    uint64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname("hw.memsize", &value, &size, nullptr, 0) != 0) {
      return static_cast<uint64_t>(2048) * kMiB;
    }
    return value;
  }();
  return mem;
#else
  return static_cast<uint64_t>(4096) * kMiB;
#endif
}

inline uint64_t MemoryCeiling() {
#if BUILDFLAG(IS_IOS)
  static std::atomic<uint64_t> cached{0};
  if (uint64_t value = cached.load(std::memory_order_relaxed)) {
    return value;
  }

  uint64_t available = 0;
  if (__builtin_available(iOS 13.0, *)) {
    available = static_cast<uint64_t>(os_proc_available_memory());
  } else {
    // iOS 11 і 12 не віддає запас до jetsam. Пристрій з 1GB вбиває десь між
    // 620 і 660MiB, тому нижня межа
    return DevicePhysicalMemory() < 1500 * kMiB ? kCeilingFloor
                                                 : kFallbackCeiling;
  }
  if (available == 0) {
    return kFallbackCeiling;
  }
  task_vm_info_data_t vm_info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  uint64_t footprint = 0;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&vm_info),
                &count) == KERN_SUCCESS) {
    footprint = static_cast<uint64_t>(vm_info.phys_footprint);
  }
  const uint64_t ceiling =
      std::clamp(footprint + available, kCeilingFloor, kCeilingCap);
  cached.store(ceiling, std::memory_order_relaxed);
  return ceiling;
#else
  return kFallbackCeiling;
#endif
}

inline uint64_t ModerateFootprint() {
  return MemoryCeiling() * kModeratePercent / 100;
}

inline uint64_t CriticalFootprint() {
  return MemoryCeiling() * kCriticalPercent / 100;
}

inline uint64_t BlockNewContentsFootprint() {
  return MemoryCeiling() * kBlockNewContentsPercent / 100;
}

inline uint64_t ModerateAvailable() {
  return std::max(kMinModerateAvailable, MemoryCeiling() * 18 / 100);
}

inline uint64_t CriticalAvailable() {
  return std::max(kMinCriticalAvailable, MemoryCeiling() * 9 / 100);
}

}  // namespace content::blinker_memory

#endif  // CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_
