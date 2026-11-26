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

// Лог запуску переживає перезапуски, тому в приватній сесії URL і хости
// не пишемо
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

// кожен лог з URL іде через цю функцію, не через GURL::spec()
inline std::string LoggableURLSpec(const GURL& url) {
  return IsPrivateSession() ? std::string("[private]") : url.spec();
}

inline std::string LoggableHost(std::string_view host) {
  return IsPrivateSession() ? std::string("[private]") : std::string(host);
}

}  // namespace content::blinker_logging

#endif  // CONTENT_SHELL_COMMON_BLINKER_PRIVATE_LOGGING_H_
