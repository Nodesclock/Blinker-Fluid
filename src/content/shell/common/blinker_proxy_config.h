// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_PROXY_CONFIG_H_
#define CONTENT_SHELL_COMMON_BLINKER_PROXY_CONFIG_H_

#include <string>
#include <string_view>

#include "build/build_config.h"
#include "net/base/proxy_string_util.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#endif

namespace content::blinker_proxy {

// Один явний проксі, без логіна і DIRECT. SOCKS4 резолвить адреси
// локально, для Tor не годиться
inline bool IsValid(std::string_view value) {
  for (unsigned char c : value) {
    if (c <= 0x20 || c == 0x7f)
      return false;
  }
  const size_t separator = value.find("://");
  if (separator == std::string_view::npos || value.size() > 1024)
    return false;
  const auto scheme = value.substr(0, separator);
  const auto authority = value.substr(separator + 3);
  if ((scheme != "socks5" && scheme != "http" && scheme != "https") ||
      authority.find_first_of("/@?#;,= \t\r\n\\") !=
          std::string_view::npos) {
    return false;
  }
  const size_t colon = authority.rfind(':');
  if (colon == std::string_view::npos || colon == 0 ||
      colon + 1 == authority.size())
    return false;
  unsigned port = 0;
  for (char c : authority.substr(colon + 1)) {
    if (c < '0' || c > '9' || port > 6553)
      return false;
    port = port * 10 + (c - '0');
  }
  return port > 0 && port <= 65535 &&
         net::ProxyUriToProxyServer(value, net::ProxyServer::SCHEME_HTTP)
             .is_valid();
}

// Битий запис не повинен тихо пустити приватну сесію напряму,
// ставимо мертвий проксі
inline std::string EffectiveServer(std::string_view saved) {
  if (saved.empty())
    return {};
  return IsValid(saved) ? std::string(saved) : "socks5://127.0.0.1:1";
}

inline std::string SavedServer() {
#if BUILDFLAG(IS_IOS)
  CFPropertyListRef value = CFPreferencesCopyAppValue(
      CFSTR("BlinkProxy"), kCFPreferencesCurrentApplication);
  if (!value)
    return {};
  UInt8 buffer[1024];
  CFIndex bytes = 0;
  bool readable = false;
  if (CFGetTypeID(value) == CFStringGetTypeID()) {
    const auto string = static_cast<CFStringRef>(value);
    const CFIndex length = CFStringGetLength(string);
    readable = CFStringGetBytes(string, CFRangeMake(0, length),
                                kCFStringEncodingUTF8, 0, false, buffer,
                                sizeof(buffer), &bytes) == length;
  }
  CFRelease(value);
  return readable ? EffectiveServer(std::string_view(
                        reinterpret_cast<const char*>(buffer), bytes))
                  : "socks5://127.0.0.1:1";
#else
  return {};
#endif
}

}  // namespace content::blinker_proxy

#endif  // CONTENT_SHELL_COMMON_BLINKER_PROXY_CONFIG_H_
