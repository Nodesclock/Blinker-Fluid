// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_content_filter.h"

#include <cstdio>
#include <string_view>

#include "base/no_destructor.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "build/build_config.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_private_logging.h"
#include "content/shell/common/blinker_site_policy.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#endif

#if BUILDFLAG(IS_IOS)
// Resolved once in shell_main.cc.
extern "C" const char* BlinkDocumentsDir();
#endif

namespace content {

namespace {

#if BUILDFLAG(IS_IOS)
// Reads a list the user dropped in. /var/mobile/Documents is the documented
// place, but a sandboxed install cannot reach it, so also accept the app's own
// Documents directory -- the same directory the diagnostics fall back to.
bool ReadBlinkerUserFile(const char* leaf, std::string* contents) {
  if (base::ReadFileToString(
          base::FilePath("/var/mobile/Documents").Append(leaf), contents)) {
    return true;
  }
  const char* dir = BlinkDocumentsDir();
  return dir &&
         base::ReadFileToString(base::FilePath(dir).Append(leaf), contents);
}
#endif

// Built-in starter blocklist. Curated for impact-per-entry: the ad, analytics
// and tracking hosts that appear on the largest share of pages. A host entry
// covers all of its subdomains (see ShouldBlock), so "doubleclick.net" also
// blocks "stats.g.doubleclick.net". A full hosts-format list can be dropped in
// at Documents/blinker_blocklist.txt to extend this (see LoadUserListFromDisk).
constexpr const char* kBuiltinBlocklist[] = {
    // Google advertising / analytics.
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "google-analytics.com",
    "googletagmanager.com",
    "googletagservices.com",
    "adservice.google.com",
    "pagead2.googlesyndication.com",
    "partner.googleadservices.com",
    "analytics.google.com",
    "2mdn.net",
    "app-measurement.com",
    // Facebook / Meta tracking.
    "connect.facebook.net",
    "pixel.facebook.com",
    "an.facebook.com",
    // Amazon ads.
    "amazon-adsystem.com",
    "assoc-amazon.com",
    "aax.amazon-adsystem.com",
    // Major ad exchanges / SSPs / DSPs.
    "criteo.com",
    "criteo.net",
    "adnxs.com",
    "rubiconproject.com",
    "pubmatic.com",
    "openx.net",
    "casalemedia.com",
    "adform.net",
    "smartadserver.com",
    "spotxchange.com",
    "spotx.tv",
    "3lift.com",
    "sharethrough.com",
    "districtm.io",
    "gumgum.com",
    "indexww.com",
    "media.net",
    "yieldmo.com",
    "adcolony.com",
    "applovin.com",
    "unityads.unity3d.com",
    "inmobi.com",
    "mopub.com",
    "vungle.com",
    // Tracking / analytics / tag managers.
    "scorecardresearch.com",
    "quantserve.com",
    "quantcount.com",
    "chartbeat.com",
    "chartbeat.net",
    "hotjar.com",
    "mouseflow.com",
    "fullstory.com",
    "mixpanel.com",
    "segment.com",
    "segment.io",
    "amplitude.com",
    "branch.io",
    "adjust.com",
    "appsflyer.com",
    "kochava.com",
    "bugsnag.com",
    "newrelic.com",
    "nr-data.net",
    "optimizely.com",
    "crazyegg.com",
    "clicktale.net",
    "bizographics.com",
    "demdex.net",
    "omtrdc.net",
    "everesttech.net",
    "adobedtm.com",
    "krxd.net",
    "bluekai.com",
    "agkn.com",
    "rlcdn.com",
    "crwdcntrl.net",
    "exelator.com",
    "mathtag.com",
    "bidswitch.net",
    "rfihub.com",
    "tapad.com",
    "eyeota.net",
    "adsrvr.org",
    // Content-recommendation / native ad networks.
    "taboola.com",
    "outbrain.com",
    "revcontent.com",
    "mgid.com",
    "zergnet.com",
    "content-ad.net",
    "adblade.com",
    // Push / popunder / misc ad tech.
    "onesignal.com",
    "pushcrew.com",
    "propellerads.com",
    "popads.net",
    "popcash.net",
    "adsterra.com",
    "hilltopads.net",
    "exoclick.com",
    "juicyads.com",
    "trafficjunky.net",
    // Yandex / VK / other regional trackers.
    "mc.yandex.ru",
    "an.yandex.ru",
    "top-fwz1.mail.ru",
    "vk.com/rtrg",
    // Microsoft / Bing ads + LinkedIn.
    "bat.bing.com",
    "clarity.ms",
    "ads.linkedin.com",
    "px.ads.linkedin.com",
    // Twitter/X ads.
    "ads-twitter.com",
    "analytics.twitter.com",
    "static.ads-twitter.com",
    // TikTok.
    "analytics.tiktok.com",
    "ads.tiktok.com",
    "business-api.tiktok.com",
};

// A rule may cover a registrable domain and its children, but never unrelated
// tenants of a public suffix such as co.uk or github.io.
template <typename Fn>
void ForEachHostAndParent(std::string_view host, Fn fn) {
  const std::string registered =
      net::registry_controlled_domains::GetDomainAndRegistry(
          host, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (registered.empty()) {
    return;
  }
  std::string_view cursor = host;
  for (;;) {
    fn(std::string(cursor));
    if (cursor.size() <= registered.size()) {
      break;
    }
    const size_t dot = cursor.find('.');
    if (dot == std::string_view::npos) {
      break;
    }
    cursor.remove_prefix(dot + 1);
  }
}

// Preserve subdomain scope, including www: an exception for www.example.com
// must not allow every other host under example.com.
std::string NormalizeHost(std::string_view host) {
  std::string h = base::ToLowerASCII(host);
  while (!h.empty() && h.front() == '.') {
    h.erase(h.begin());
  }
  if (!h.empty() && h.back() == '.') {
    h.pop_back();
  }
  return h;
}

// A cosmetic selector is only used if it can't break out of the <style> or the
// rule it is placed in.
bool IsSafeSelector(std::string_view sel) {
  if (sel.empty() || sel.size() > 400) {
    return false;
  }
  for (char c : sel) {
    if (c == '{' || c == '}' || c == '\\' || c == '<' || c == '\n' ||
        c == '\r') {
      return false;
    }
  }
  return true;
}

// True for a bare domain token (no wildcards / path / regex): decides whether a
// network filter rule can be reduced to a host block.
bool LooksLikeDomain(std::string_view s) {
  if (s.size() < 3 || s.find('.') == std::string_view::npos) {
    return false;
  }
  for (char c : s) {
    if (!(base::IsAsciiAlphaNumeric(c) || c == '.' || c == '-' || c == '_')) {
      return false;
    }
  }
  return true;
}

// Invokes `fn` for each comma-separated, trimmed, non-negated domain in `list`.
template <typename Fn>
void ForEachDomain(std::string_view list, Fn fn) {
  for (std::string_view d : base::SplitStringPiece(
           list, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (!d.empty() && d.front() != '~') {  // '~domain' = negated, unsupported
      fn(d);
    }
  }
}

// A few unambiguous ad-container selectors so cosmetic hiding does something
// out of the box; users extend this with a real filter list (see
// LoadFilterListsFromDisk). Kept conservative to avoid hiding real content.
constexpr const char* kBuiltinCosmetic[] = {
    ".adsbygoogle",
    "ins.adsbygoogle",
    "[id^=\"google_ads_iframe\"]",
    "[id^=\"div-gpt-ad\"]",
    "[id^=\"google_ads_frame\"]",
    "iframe[src*=\"doubleclick.net\"]",
    "iframe[src*=\"googlesyndication.com\"]",
    "iframe[src*=\"adnxs.com\"]",
    "[class^=\"adsbox\"]",
    ".trc_related_container",
    ".OUTBRAIN",
    ".taboola-placeholder",
};

}  // namespace

// static
BlinkerContentFilter& BlinkerContentFilter::GetInstance() {
  static base::NoDestructor<BlinkerContentFilter> instance;
  return *instance;
}

BlinkerContentFilter::BlinkerContentFilter() = default;
BlinkerContentFilter::~BlinkerContentFilter() = default;

void BlinkerContentFilter::AddHost(std::string_view host) {
  std::string h = NormalizeHost(host);
  if (LooksLikeDomain(h)) {
    blocked_hosts_.insert(std::move(h));
  }
}

void BlinkerContentFilter::LoadBuiltinList() {
  for (const char* entry : kBuiltinBlocklist) {
    AddHost(entry);
  }
  for (const char* selector : kBuiltinCosmetic) {
    generic_hide_selectors_.emplace_back(selector);
  }
}

void BlinkerContentFilter::AddAllowedHost(std::string_view host) {
  const std::string normalized = NormalizeHost(host);
  if (LooksLikeDomain(normalized)) {
    allowed_hosts_.insert(normalized);
  }
}

void BlinkerContentFilter::LoadUserListFromDisk() {
#if BUILDFLAG(IS_IOS)
  // Optional power-user extension: a hosts-format file. Each line is either a
  // bare domain or "0.0.0.0 domain" / "127.0.0.1 domain"; '#' begins a comment.
  std::string contents;
  if (!ReadBlinkerUserFile("blinker_blocklist.txt", &contents)) {
    return;
  }
  size_t added = 0;
  std::string_view text(contents);
  size_t pos = 0;
  while (pos < text.size()) {
    size_t eol = text.find('\n', pos);
    std::string_view line =
        text.substr(pos, eol == std::string_view::npos ? std::string_view::npos
                                                       : eol - pos);
    pos = (eol == std::string_view::npos) ? text.size() : eol + 1;
    // Trim, drop comments.
    size_t hash = line.find('#');
    if (hash != std::string_view::npos) {
      line = line.substr(0, hash);
    }
    while (!line.empty() && (line.front() == ' ' || line.front() == '\t' ||
                             line.front() == '\r')) {
      line.remove_prefix(1);
    }
    while (!line.empty() &&
           (line.back() == ' ' || line.back() == '\t' || line.back() == '\r')) {
      line.remove_suffix(1);
    }
    if (line.empty()) {
      continue;
    }
    // Strip a leading IP (hosts format).
    size_t sp = line.find_first_of(" \t");
    if (sp != std::string_view::npos) {
      std::string_view first = line.substr(0, sp);
      if (first == "0.0.0.0" || first == "127.0.0.1" || first == "::1") {
        line = line.substr(sp + 1);
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t')) {
          line.remove_prefix(1);
        }
      }
    }
    const size_t before = blocked_hosts_.size();
    AddHost(line);
    if (blocked_hosts_.size() != before) {
      ++added;
    }
  }
  if (added) {
    BLINKER_DIAGF("ADBLOCK: loaded %zu extra host rules from user list", added);
  }
#endif
}

void BlinkerContentFilter::ParseFilterLine(std::string_view line) {
  while (!line.empty() && (line.front() == ' ' || line.front() == '\t' ||
                           line.front() == '\r')) {
    line.remove_prefix(1);
  }
  while (!line.empty() &&
         (line.back() == ' ' || line.back() == '\t' || line.back() == '\r')) {
    line.remove_suffix(1);
  }
  if (line.empty() || line.front() == '!' || line.front() == '[') {
    return;  // blank / comment / "[Adblock Plus ...]" header
  }

  // Cosmetic allow (un-hide): domains#@#selector
  if (size_t p = line.find("#@#"); p != std::string_view::npos) {
    std::string_view sel = line.substr(p + 3);
    if (IsSafeSelector(sel)) {
      ForEachDomain(line.substr(0, p), [&](std::string_view d) {
        host_hide_exceptions_[NormalizeHost(d)].emplace_back(sel);
      });
    }
    return;
  }
  // Procedural / scriptlet cosmetics (uBO extensions) are unsupported.
  if (line.find("#?#") != std::string_view::npos ||
      line.find("#$#") != std::string_view::npos ||
      line.find("#%#") != std::string_view::npos) {
    return;
  }
  // Cosmetic hide: [domains]##selector
  if (size_t p = line.find("##"); p != std::string_view::npos) {
    std::string_view sel = line.substr(p + 2);
    if (!IsSafeSelector(sel)) {
      return;
    }
    std::string_view domains = line.substr(0, p);
    if (domains.empty()) {
      generic_hide_selectors_.emplace_back(sel);
    } else {
      ForEachDomain(domains, [&](std::string_view d) {
        host_hide_selectors_[NormalizeHost(d)].emplace_back(sel);
      });
    }
    return;
  }
  // Only host-wide network rules are supported. Do not discard path, request
  // type, wildcard, or domain constraints: doing so broadens the rule.
  const bool exception = line.starts_with("@@");
  if (exception) {
    line.remove_prefix(2);
    if (!line.starts_with("||")) {
      return;
    }
  }
  if (line.starts_with("||")) {
    line.remove_prefix(2);
  }
  if (line.ends_with('^')) {
    line.remove_suffix(1);
  }
  if (!LooksLikeDomain(line)) {
    return;
  }
  if (exception) {
    AddAllowedHost(line);
  } else {
    AddHost(line);
  }
}

void BlinkerContentFilter::LoadFilterListsFromDisk() {
#if BUILDFLAG(IS_IOS)
  // Optional: an Adblock Plus / uBO / EasyList file the user drops in. Network
  // (`||host^`) and element-hiding (`##`) rules are honored.
  std::string contents;
  if (ReadBlinkerUserFile("blinker_filters.txt", &contents)) {
    const size_t hosts_before = blocked_hosts_.size();
    std::string_view text(contents);
    size_t pos = 0;
    while (pos < text.size()) {
      size_t eol = text.find('\n', pos);
      std::string_view line = text.substr(pos, eol == std::string_view::npos
                                                   ? std::string_view::npos
                                                   : eol - pos);
      pos = (eol == std::string_view::npos) ? text.size() : eol + 1;
      ParseFilterLine(line);
    }
    BLINKER_DIAGF(
        "ADBLOCK: filter list +%zu net, %zu generic + %zu host cosmetic",
        blocked_hosts_.size() - hosts_before, generic_hide_selectors_.size(),
        host_hide_selectors_.size());
  }
#endif
}

void BlinkerContentFilter::BuildGenericCSS() {
  // Pre-join the generic selectors once (capped so a full EasyList can't
  // produce a pathologically large style recalculated on every page).
  constexpr size_t kMaxGeneric = 30000;
  size_t n = 0;
  for (const std::string& s : generic_hide_selectors_) {
    if (n++ >= kMaxGeneric) {
      break;
    }
    if (!generic_hide_css_.empty()) {
      generic_hide_css_ += ',';
    }
    generic_hide_css_ += s;
  }
}

std::string BlinkerContentFilter::CosmeticCSSFor(std::string_view host) const {
  if (!enabled()) {
    return std::string();
  }
  const std::string h = NormalizeHost(host);
  // Walk host and each parent domain, gathering host-scoped selectors and
  // exceptions.
  std::unordered_set<std::string> exceptions;
  std::vector<const std::string*> host_specific;
  ForEachHostAndParent(h, [&](const std::string& key) {
    if (auto it = host_hide_exceptions_.find(key);
        it != host_hide_exceptions_.end()) {
      for (const std::string& s : it->second) {
        exceptions.insert(s);
      }
    }
    if (auto it = host_hide_selectors_.find(key);
        it != host_hide_selectors_.end()) {
      for (const std::string& s : it->second) {
        host_specific.push_back(&s);
      }
    }
  });

  std::string css;
  if (exceptions.empty()) {
    css = generic_hide_css_;  // fast path: use the cached join
  } else {
    for (const std::string& s : generic_hide_selectors_) {
      if (exceptions.count(s)) {
        continue;
      }
      if (!css.empty()) {
        css += ',';
      }
      css += s;
    }
  }
  for (const std::string* s : host_specific) {
    if (exceptions.count(*s)) {
      continue;
    }
    if (!css.empty()) {
      css += ',';
    }
    css += *s;
  }
  if (css.empty()) {
    return std::string();
  }
  css += "{display:none!important}";
  return css;
}

void BlinkerContentFilter::EnsureLoaded() {
  if (loaded_) {
    return;
  }
  loaded_ = true;
  LoadBuiltinList();
  LoadUserListFromDisk();
  LoadFilterListsFromDisk();
  BuildGenericCSS();

#if BUILDFLAG(IS_IOS)
  // The persisted toggle defaults to enabled.
  bool persisted_enabled = true;
  if (CFPropertyListRef v = CFPreferencesCopyAppValue(
          CFSTR("BlinkAdBlock"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
      persisted_enabled = CFBooleanGetValue(static_cast<CFBooleanRef>(v));
    }
    CFRelease(v);
  }
  SetEnabled(persisted_enabled);
#endif

  BLINKER_DIAGF("ADBLOCK: %zu host rules loaded, enabled=%d",
                blocked_hosts_.size(), enabled() ? 1 : 0);
}

bool BlinkerContentFilter::ShouldBlock(const GURL& url) const {
  if (!enabled()) {
    return false;
  }
  if (!url.has_host() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  // Never let an ad/tracker list break a legitimate human-verification or
  // authentication flow. This is an availability exemption, not a CAPTCHA
  // bypass: the provider still decides whether and how to challenge the user.
  const std::string host = NormalizeHost(url.host());
  const std::string path(url.path());
  const bool verification_host =
      blinker_sites::HasTrait(host, blinker_sites::kVerificationResource);
  const bool google_verification_path =
      (url.DomainIs("google.com") || url.DomainIs("gstatic.com")) &&
      (path.find("/recaptcha/") != std::string::npos ||
       path.find("/captcha/") != std::string::npos);
  if (verification_host || google_verification_path) {
    return false;
  }
  bool allowed = false;
  bool blocked = false;
  ForEachHostAndParent(host, [&](const std::string& domain) {
    allowed |= allowed_hosts_.contains(domain);
    blocked |= blocked_hosts_.contains(domain);
  });
  return blocked && !allowed;
}

bool BlinkerContentFilter::enabled() const {
  return enabled_.load(std::memory_order_relaxed);
}

void BlinkerContentFilter::SetEnabled(bool enabled) {
  enabled_.store(enabled, std::memory_order_relaxed);
}

uint64_t BlinkerContentFilter::blocked_count() const {
  return blocked_count_.load(std::memory_order_relaxed);
}

void BlinkerContentFilter::RecordBlocked() {
  blocked_count_.fetch_add(1, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------

BlinkerContentFilterThrottle::BlinkerContentFilterThrottle() = default;
BlinkerContentFilterThrottle::~BlinkerContentFilterThrottle() = default;

void BlinkerContentFilterThrottle::DetachFromCurrentSequence() {}

void BlinkerContentFilterThrottle::WillStartRequest(
    network::ResourceRequest* request,
    bool* defer) {
  if (BlinkerContentFilter::GetInstance().ShouldBlock(request->url)) {
    BlinkerContentFilter::GetInstance().RecordBlocked();
    // Log the first several blocks as direct evidence the filter is live.
    // Third-party request URLs identify the page being visited just as well as
    // the page URL does, so this goes through LoggableURLSpec like every other
    // URL-bearing log site.
    uint64_t n = BlinkerContentFilter::GetInstance().blocked_count();
    if (n <= 12) {
      BLINKER_DIAGF("ADBLOCK_HIT #%llu: %.200s",
                    static_cast<unsigned long long>(n),
                    blinker_logging::LoggableURLSpec(request->url).c_str());
    }
    delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT,
                               "Blocked by Blinker Fluid content filter");
  }
}

void BlinkerContentFilterThrottle::WillRedirectRequest(
    net::RedirectInfo* redirect_info,
    const network::mojom::URLResponseHead& response_head,
    bool* defer,
    std::vector<std::string>* /*to_be_removed_request_headers*/,
    net::HttpRequestHeaders* /*modified_request_headers*/,
    net::HttpRequestHeaders* /*modified_cors_exempt_request_headers*/) {
  // A tracker can hop through a redirect; check the destination too.
  if (redirect_info &&
      BlinkerContentFilter::GetInstance().ShouldBlock(redirect_info->new_url)) {
    BlinkerContentFilter::GetInstance().RecordBlocked();
    delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT,
                               "Blocked by Blinker Fluid content filter");
  }
}

}  // namespace content

// C bridge for the Objective-C Settings UI.
extern "C" bool BlinkAdBlockEnabled() {
  return content::BlinkerContentFilter::GetInstance().enabled();
}

extern "C" void BlinkAdBlockSetEnabled(bool enabled) {
  content::BlinkerContentFilter::GetInstance().SetEnabled(enabled);
}

extern "C" unsigned long long BlinkAdBlockBlockedCount() {
  return content::BlinkerContentFilter::GetInstance().blocked_count();
}

extern "C" unsigned long BlinkAdBlockRuleCount() {
  return static_cast<unsigned long>(
      content::BlinkerContentFilter::GetInstance().rule_count());
}
