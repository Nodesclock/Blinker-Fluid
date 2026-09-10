// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_PRIVATE_LOGGING_H_
#define CONTENT_SHELL_COMMON_BLINKER_PRIVATE_LOGGING_H_

#include <string>
#include <string_view>

#include "build/build_config.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#endif

namespace content::blinker_logging {

// The boot log lives at /var/mobile/Documents/blink_boot.log — outside the app
// container, readable by anything else on a jailbroken device, and it survives
// across launches. A private session must never write page URLs or hosts into
// it. The rest of each line (memory counters, frame/layer counts) still works
// for the crash forensics the log exists for.
//
// Read once: Private Browsing is fixed for the life of the process, because the
// browser context is chosen at startup and changing the setting requires a
// restart.
inline bool IsPrivateSession() {
#if BUILDFLAG(IS_IOS)
  static const bool active = [] {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    Boolean valid = false;
    const Boolean enabled = CFPreferencesGetAppBooleanValue(
        CFSTR("BlinkPrivateBrowsing"), kCFPreferencesCurrentApplication,
        &valid);
    return static_cast<bool>(valid && enabled);
  }();
  return active;
#else
  return false;
#endif
}

// EVERY boot-log site that formats a URL must route through this rather than
// calling GURL::spec() directly. It lives in a shared header, not in one .cc,
// specifically so that this is possible from any file in the shell — an earlier
// copy was file-local to shell.cc, which meant new log sites in other files had
// no way to honor the rule and silently leaked full URLs.
inline std::string LoggableURLSpec(const GURL& url) {
  return IsPrivateSession() ? std::string("[private]") : url.spec();
}

// Same rule for a bare host, which is just as identifying as a full URL.
inline std::string LoggableHost(std::string_view host) {
  return IsPrivateSession() ? std::string("[private]") : std::string(host);
}

}  // namespace content::blinker_logging

#endif  // CONTENT_SHELL_COMMON_BLINKER_PRIVATE_LOGGING_H_
