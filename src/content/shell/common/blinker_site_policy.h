// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_SITE_POLICY_H_
#define CONTENT_SHELL_COMMON_BLINKER_SITE_POLICY_H_

#include <cstdint>
#include <string_view>

namespace content::blinker_sites {

// Hosts supplied by GURL are canonical ASCII. Match complete labels so an
// unrelated suffix or lookalike cannot inherit a site's policy.
inline bool HostMatchesDomain(std::string_view host, std::string_view domain) {
  if (host.ends_with('.')) {
    host.remove_suffix(1);
  }
  return host == domain ||
         (host.size() > domain.size() && host.ends_with(domain) &&
          host[host.size() - domain.size() - 1] == '.');
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

// The memory, keyboard, restore, and request exemptions remain independent.
// A site being heavy does not imply that it needs a keyboard fallback.
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
