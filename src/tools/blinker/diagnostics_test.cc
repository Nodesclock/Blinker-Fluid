// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Окремо, щоб тест мав свої приймачі логу і не підміняв запис застосунку.
#include "content/shell/common/blinker_diagnostics.h"

#include <cassert>

namespace {
int writes = 0;
int arguments = 0;
}

extern "C" void BlinkBootLog(const char*) { ++writes; }
extern "C" void BlinkBootLogf(const char*, ...) { ++writes; }

int main() {
  BLINKER_DIAG((++arguments, "trace"));
  BLINKER_DIAGF("value=%d", ++arguments);
  assert(writes == 2 * BLINKER_ENABLE_DIAGNOSTICS);
  assert(arguments == 2 * BLINKER_ENABLE_DIAGNOSTICS);
  BLINKER_LOG("critical");
  BLINKER_LOGF("value=%d", ++arguments);
  assert(writes == 2 * BLINKER_ENABLE_DIAGNOSTICS + 2);
  assert(arguments == 2 * BLINKER_ENABLE_DIAGNOSTICS + 1);
}
