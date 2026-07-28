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

// Derive thresholds from the process's runtime memory ceiling.
// os_proc_available_memory() returns the bytes this process may still grow by
// before jetsam kills it, so `phys_footprint + available` is the actual limit
// the kernel is enforcing — it automatically accounts for device RAM, the
// increased-memory-limit entitlement and the foreground/background band, none
// of which a compile-time constant can know.
//
// The result is clamped: the floor keeps a small/low-memory device no worse off
// than the old policy, and the cap keeps the app a well-behaved citizen (a
// browser that is *allowed* to reach 3 GB will happily do so and start evicting
// every other app on the phone) while still granting ~2x the old headroom.
inline constexpr uint64_t kCeilingFloor = 700 * kMiB;
inline constexpr uint64_t kCeilingCap = 1800 * kMiB;
inline constexpr uint64_t kFallbackCeiling = 900 * kMiB;

// Fractions of the ceiling at which each action fires.
inline constexpr uint64_t kModeratePercent = 55;
inline constexpr uint64_t kCriticalPercent = 72;
inline constexpr uint64_t kBlockNewContentsPercent = 82;

// Absolute floors for the remaining-headroom triggers. Headroom is the
// authoritative jetsam signal (footprint is only a secondary guard), so these
// stay generous no matter how large the ceiling turns out to be.
inline constexpr uint64_t kMinModerateAvailable = 280 * kMiB;
inline constexpr uint64_t kMinCriticalAvailable = 140 * kMiB;

// Installed RAM. Always answerable, including before the app is foreground,
// which is what makes it usable for decisions that have to be made during
// startup (V8's heap flags are fixed when the isolate is created).
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

// Returns the process footprint ceiling. Foreground readings are cached;
// unavailable startup readings use the fallback without caching it.
inline uint64_t MemoryCeiling() {
#if BUILDFLAG(IS_IOS)
  static std::atomic<uint64_t> cached{0};
  if (uint64_t value = cached.load(std::memory_order_relaxed)) {
    return value;
  }

  const uint64_t available = static_cast<uint64_t>(os_proc_available_memory());
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

// Footprint at which to ask Blink/V8/Skia to shed caches.
inline uint64_t ModerateFootprint() {
  return MemoryCeiling() * kModeratePercent / 100;
}

// Footprint at which to force an aggressive purge.
inline uint64_t CriticalFootprint() {
  return MemoryCeiling() * kCriticalPercent / 100;
}

// Footprint above which new WebContents are refused rather than risking a
// jetsam kill that would lose the user's session.
inline uint64_t BlockNewContentsFootprint() {
  return MemoryCeiling() * kBlockNewContentsPercent / 100;
}

// Remaining headroom below which to shed caches.
inline uint64_t ModerateAvailable() {
  return std::max(kMinModerateAvailable, MemoryCeiling() * 18 / 100);
}

// Remaining headroom below which a jetsam kill is imminent.
inline uint64_t CriticalAvailable() {
  return std::max(kMinCriticalAvailable, MemoryCeiling() * 9 / 100);
}

}  // namespace content::blinker_memory

#endif  // CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_
