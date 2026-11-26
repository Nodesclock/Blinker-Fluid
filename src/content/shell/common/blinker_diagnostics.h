// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_
#define CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_

// BLINKER_DIAG(F) зникає при blinker_enable_diagnostics=false
// BLINKER_LOG(F) лишається завжди

#if defined(BLINKER_DISABLE_DIAGNOSTICS)
#define BLINKER_ENABLE_DIAGNOSTICS 0
#else
#define BLINKER_ENABLE_DIAGNOSTICS 1
#endif

extern "C" void BlinkBootLog(const char* message);
extern "C" void BlinkBootLogf(const char* format, ...)
    __attribute__((format(printf, 1, 2)));

// Лишаються і в релізі, тому їх має бути мало
#define BLINKER_LOG(msg) ::BlinkBootLog(msg)
#define BLINKER_LOGF(...) ::BlinkBootLogf(__VA_ARGS__)

// Вирізається з релізу разом з аргументами, рядки в бінарник не попадуть
#if BLINKER_ENABLE_DIAGNOSTICS
#define BLINKER_DIAG(msg) ::BlinkBootLog(msg)
#define BLINKER_DIAGF(...) ::BlinkBootLogf(__VA_ARGS__)
#else
#define BLINKER_DIAG(msg) ((void)sizeof(msg))
#define BLINKER_DIAGF(...) ((void)sizeof((::BlinkBootLogf(__VA_ARGS__), 0)))
#endif

#endif  // CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_
