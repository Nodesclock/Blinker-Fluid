// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_
#define CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_

#include <cstdint>

namespace content::blinker_memory {

inline constexpr uint64_t kMiB = 1024ULL * 1024ULL;
inline constexpr uint64_t kModerateFootprint = 500 * kMiB;
inline constexpr uint64_t kCriticalFootprint = 650 * kMiB;
inline constexpr uint64_t kBlockNewContentsFootprint = 700 * kMiB;
inline constexpr uint64_t kModerateAvailable = 280 * kMiB;
inline constexpr uint64_t kCriticalAvailable = 140 * kMiB;

}  // namespace content::blinker_memory

#endif  // CONTENT_SHELL_COMMON_BLINKER_MEMORY_POLICY_H_
