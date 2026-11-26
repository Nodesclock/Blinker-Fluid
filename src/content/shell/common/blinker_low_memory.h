// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_LOW_MEMORY_H_
#define CONTENT_SHELL_COMMON_BLINKER_LOW_MEMORY_H_

#include "base/system/sys_info.h"

namespace content {

// Збірка для iOS 12 йде ще й як sideload для нових iPhone, тому 1 ГБ
// ловимо за справжньою памяттю а не за версією iOS
inline bool BlinkerLowMemoryDevice() {
#if defined(BLINKER_LEGACY_LOW_MEMORY)
  static const bool low =
      base::SysInfo::AmountOfTotalPhysicalMemory().InMiB() <= 1536;
  return low;
#else
  return false;
#endif
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_LOW_MEMORY_H_
