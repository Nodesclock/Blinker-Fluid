// Copyright 2026 the V8 project authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef V8_COMMON_IOS_CODE_MEMORY_ACCESS_H_
#define V8_COMMON_IOS_CODE_MEMORY_ACCESS_H_

#include "src/common/globals.h"

namespace v8::internal {

#if V8_HEAP_USE_IOS_MPROTECT_JIT_WRITE_PROTECT
// Знімаєм тільки дзеркало цієї купи
// інші ізоляти можуть ще виконувати код
void UnregisterIOSCodeRange(Address base);
#endif

}  // namespace v8::internal

#endif  // V8_COMMON_IOS_CODE_MEMORY_ACCESS_H_
