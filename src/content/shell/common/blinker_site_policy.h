// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_SITE_POLICY_H_
#define CONTENT_SHELL_COMMON_BLINKER_SITE_POLICY_H_

#include <cstdint>
#include <string>
#include <string_view>

namespace content::blinker_sites {

inline bool HostMatchesDomain(std::string_view host, std::string_view domain) {
  if (host.ends_with('.')) {
    host.remove_suffix(1);
  }
  return host == domain ||
         (host.size() > domain.size() && host.ends_with(domain) &&
          host[host.size() - domain.size() - 1] == '.');
}

// m.site і mobile.site самі не переходять на десктоп навіть з десктопним UA
// Без крапки після префікса не чіпаєм, mobile.de це сам сайт
inline std::string DesktopHost(std::string_view host) {
  if (host == "m.youtube.com") {
    return "www.youtube.com";
  }
  for (std::string_view prefix : {"m.", "mobile."}) {
    if (host.starts_with(prefix) &&
        host.substr(prefix.size()).find('.') != std::string_view::npos) {
      return std::string(host.substr(prefix.size()));
    }
  }
  if (const size_t infix = host.find(".m.");
      infix != std::string_view::npos &&
      host.substr(infix + 3).find('.') != std::string_view::npos) {
    return std::string(host.substr(0, infix)) +
           std::string(host.substr(infix + 2));
  }
  return std::string(host);
}

inline std::string SiteModePreferenceHost(std::string_view host) {
  if (host.starts_with("www.") &&
      host.substr(4).find('.') != std::string_view::npos) {
    host.remove_prefix(4);
  }
  return DesktopHost(host) == "www.youtube.com" ? std::string("youtube.com")
                                                 : DesktopHost(host);
}

enum SiteTrait : uint32_t {
  kHeavy = 1 << 0,
  kAI = 1 << 1,
  kMonitorMemory = 1 << 2,
  kChatKeyboard = 1 << 3,
  kSkipSessionRestore = 1 << 4,
  kVerificationResource = 1 << 5,
};

struct SitePolicy {
  std::string_view host;
  bool include_subdomains;
  uint32_t traits;
};

inline constexpr SitePolicy kSitePolicies[] = {
    {"reddit.com", true, kHeavy | kSkipSessionRestore},
    {"youtube.com", true, kHeavy},
    {"github.com", true, kHeavy | kMonitorMemory},
    {"claude.ai", true, kHeavy | kAI | kMonitorMemory | kChatKeyboard},
    {"chatgpt.com", true, kHeavy | kAI | kMonitorMemory | kChatKeyboard},
    {"mail.google.com", false, kHeavy | kMonitorMemory | kSkipSessionRestore},
    {"gemini.google.com", false, kHeavy | kMonitorMemory | kChatKeyboard},
    {"accounts.google.com", false,
     kHeavy | kSkipSessionRestore | kVerificationResource},
    {"discord.com", true, kHeavy},
    {"homedepot.com", true, kHeavy},
    {"recaptcha.net", true, kVerificationResource},
    {"hcaptcha.com", true, kVerificationResource},
    {"challenges.cloudflare.com", false, kVerificationResource},
    {"arkoselabs.com", true, kVerificationResource},
    {"funcaptcha.com", true, kVerificationResource},
};

inline bool HasTrait(std::string_view host, SiteTrait trait) {
  for (const SitePolicy& policy : kSitePolicies) {
    if ((policy.traits & trait) &&
        (policy.include_subdomains ? HostMatchesDomain(host, policy.host)
                                   : host == policy.host)) {
      return true;
    }
  }
  return false;
}

}  // namespace content::blinker_sites

#endif  // CONTENT_SHELL_COMMON_BLINKER_SITE_POLICY_H_
