// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_
#define CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_

// Boot-log instrumentation gate.
//
// Blinker records launch and runtime diagnostics to blink_boot.log. The verbose
// tracing is compiled out of release builds (configured with the GN argument
// `blinker_enable_diagnostics = false`, which defines
// BLINKER_DISABLE_DIAGNOSTICS for the shell targets); a small, curated set of
// critical markers — crash, out-of-memory, and launch failure — always ships so
// that a user-reported crash can still be triaged from the log.
//
// Use BLINKER_DIAG / BLINKER_DIAGF for ordinary tracing. Reserve BLINKER_LOG /
// BLINKER_LOGF for genuinely critical events, and keep that set small.

#if defined(BLINKER_DISABLE_DIAGNOSTICS)
#define BLINKER_ENABLE_DIAGNOSTICS 0
#else
#define BLINKER_ENABLE_DIAGNOSTICS 1
#endif

// Underlying writers, always compiled in. Defined in shell_application_ios.mm.
extern "C" void BlinkBootLog(const char* message);
extern "C" void BlinkBootLogf(const char* format, ...)
    __attribute__((format(printf, 1, 2)));

// Critical events — always ship, even in release. Keep these few.
#define BLINKER_LOG(msg) ::BlinkBootLog(msg)
#define BLINKER_LOGF(...) ::BlinkBootLogf(__VA_ARGS__)

// Ordinary tracing — compiled out of release builds. The message and any
// formatting arguments are not evaluated when diagnostics are disabled, so no
// string literals from these sites reach the shipped binary.
#if BLINKER_ENABLE_DIAGNOSTICS
#define BLINKER_DIAG(msg) ::BlinkBootLog(msg)
#define BLINKER_DIAGF(...) ::BlinkBootLogf(__VA_ARGS__)
#else
#define BLINKER_DIAG(msg) ((void)0)
#define BLINKER_DIAGF(...) ((void)0)
#endif

#endif  // CONTENT_SHELL_COMMON_BLINKER_DIAGNOSTICS_H_
