// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_content_filter.h"

#include <atomic>
#include <cctype>
#include <cstdio>
#include <string_view>

#include "base/no_destructor.h"
#include "build/build_config.h"
#include "net/base/net_errors.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/path_service.h"
#endif

extern "C" void BlinkBootLog(const char* stage);

namespace content {

namespace {

std::atomic<bool> g_enabled{false};
std::atomic<uint64_t> g_blocked_count{0};

// Built-in starter blocklist. Curated for impact-per-entry: the ad, analytics
// and tracking hosts that appear on the largest share of pages. A host entry
// covers all of its subdomains (see ShouldBlock), so "doubleclick.net" also
// blocks "stats.g.doubleclick.net". A full hosts-format list can be dropped in
// at Documents/blinker_blocklist.txt to extend this (see LoadUserListFromDisk).
constexpr const char* kBuiltinBlocklist[] = {
    // Google advertising / analytics.
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "google-analytics.com", "googletagmanager.com", "googletagservices.com",
    "adservice.google.com", "pagead2.googlesyndication.com",
    "partner.googleadservices.com", "analytics.google.com",
    "ampproject.org", "2mdn.net", "app-measurement.com",
    // Facebook / Meta tracking.
    "connect.facebook.net", "pixel.facebook.com",
    "an.facebook.com", "graph.facebook.com",
    // Amazon ads.
    "amazon-adsystem.com", "assoc-amazon.com", "aax.amazon-adsystem.com",
    // Major ad exchanges / SSPs / DSPs.
    "criteo.com", "criteo.net", "adnxs.com", "rubiconproject.com",
    "pubmatic.com", "openx.net", "casalemedia.com", "adform.net",
    "smartadserver.com", "spotxchange.com", "spotx.tv", "3lift.com",
    "sharethrough.com", "districtm.io", "gumgum.com", "indexww.com",
    "media.net", "yieldmo.com", "adcolony.com", "applovin.com",
    "unityads.unity3d.com", "inmobi.com", "mopub.com", "vungle.com",
    // Tracking / analytics / tag managers.
    "scorecardresearch.com", "quantserve.com", "quantcount.com",
    "chartbeat.com", "chartbeat.net", "hotjar.com", "mouseflow.com",
    "fullstory.com", "mixpanel.com", "segment.com", "segment.io",
    "amplitude.com", "branch.io", "adjust.com", "appsflyer.com",
    "kochava.com", "bugsnag.com", "sentry.io", "newrelic.com",
    "nr-data.net", "optimizely.com", "crazyegg.com", "clicktale.net",
    "bizographics.com", "demdex.net", "omtrdc.net", "everesttech.net",
    "adobedtm.com", "krxd.net", "bluekai.com", "agkn.com", "rlcdn.com",
    "crwdcntrl.net", "exelator.com", "mathtag.com", "bidswitch.net",
    "rfihub.com", "tapad.com", "eyeota.net", "adsrvr.org",
    // Content-recommendation / native ad networks.
    "taboola.com", "outbrain.com", "revcontent.com", "mgid.com",
    "zergnet.com", "content-ad.net", "adblade.com",
    // Push / popunder / misc ad tech.
    "onesignal.com", "pushcrew.com", "propellerads.com", "popads.net",
    "popcash.net", "adsterra.com", "hilltopads.net", "exoclick.com",
    "juicyads.com", "trafficjunky.net",
    // Yandex / VK / other regional trackers.
    "mc.yandex.ru", "an.yandex.ru", "top-fwz1.mail.ru", "vk.com/rtrg",
    // Microsoft / Bing ads + LinkedIn.
    "bat.bing.com", "clarity.ms", "ads.linkedin.com", "px.ads.linkedin.com",
    // Twitter/X ads.
    "ads-twitter.com", "analytics.twitter.com", "static.ads-twitter.com",
    // TikTok.
    "analytics.tiktok.com", "ads.tiktok.com", "business-api.tiktok.com",
};

// Extracts the registrable-ish host and tests it and each parent domain against
// the set. Stops before the bare TLD so a blocklist entry never accidentally
// blocks an entire TLD.
bool HostOrParentInSet(const std::unordered_set<std::string>& set,
                       std::string_view host) {
  if (host.empty() || set.empty()) {
    return false;
  }
  // Count labels so we don't test a bare TLD.
  std::string_view cursor = host;
  for (;;) {
    if (set.find(std::string(cursor)) != set.end()) {
      return true;
    }
    size_t dot = cursor.find('.');
    if (dot == std::string_view::npos) {
      break;
    }
    std::string_view remainder = cursor.substr(dot + 1);
    // Stop when only the TLD would remain (no dot left).
    if (remainder.find('.') == std::string_view::npos) {
      break;
    }
    cursor = remainder;
  }
  return false;
}

// Lowercases and strips a leading "www."/dot and any path — the same
// normalization AddHost applies, exposed for cosmetic-rule domain keys.
std::string NormalizeHost(std::string_view host) {
  std::string h(host);
  for (char& c : h) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  while (!h.empty() && h.front() == '.') {
    h.erase(h.begin());
  }
  if (h.rfind("www.", 0) == 0) {
    h = h.substr(4);
  }
  size_t slash = h.find('/');
  if (slash != std::string::npos) {
    h = h.substr(0, slash);
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
    if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-' ||
          c == '_')) {
      return false;
    }
  }
  return true;
}

// Invokes `fn` for each comma-separated, trimmed, non-negated domain in `list`.
template <typename Fn>
void ForEachDomain(std::string_view list, Fn fn) {
  size_t pos = 0;
  while (pos <= list.size()) {
    size_t comma = list.find(',', pos);
    std::string_view d = list.substr(
        pos, comma == std::string_view::npos ? std::string_view::npos
                                             : comma - pos);
    pos = (comma == std::string_view::npos) ? list.size() + 1 : comma + 1;
    if (!d.empty() && d.front() != '~') {  // '~domain' = negated, unsupported
      fn(d);
    }
  }
}

// A few unambiguous ad-container selectors so cosmetic hiding does something out
// of the box; users extend this with a real filter list (see
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
  if (host.empty()) {
    return;
  }
  // Normalize: lowercase, strip a leading "www." and any leading dot.
  std::string h(host);
  for (char& c : h) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  while (!h.empty() && h.front() == '.') {
    h.erase(h.begin());
  }
  if (h.rfind("www.", 0) == 0) {
    h = h.substr(4);
  }
  // Path rules require URL matching and must not be promoted to whole hosts.
  if (h.find('/') != std::string::npos) {
    return;
  }
  if (!h.empty()) {
    blocked_hosts_.insert(std::move(h));
  }
}

void BlinkerContentFilter::LoadBuiltinList() {
  for (const char* entry : kBuiltinBlocklist) {
    AddHost(entry);
  }
}

void BlinkerContentFilter::LoadUserListFromDisk() {
#if BUILDFLAG(IS_IOS)
  // Optional power-user extension: a hosts-format file. Each line is either a
  // bare domain or "0.0.0.0 domain" / "127.0.0.1 domain"; '#' begins a comment.
  base::FilePath dir;
  if (!base::PathService::Get(base::DIR_TEMP, &dir)) {
    return;
  }
  // DIR_TEMP resolves under the app's tmp; the shared Documents path is where
  // users drop files, so look there instead.
  base::FilePath path("/var/mobile/Documents/blinker_blocklist.txt");
  std::string contents;
  if (!base::ReadFileToString(path, &contents)) {
    return;
  }
  size_t added = 0;
  std::string_view text(contents);
  size_t pos = 0;
  while (pos < text.size()) {
    size_t eol = text.find('\n', pos);
    std::string_view line = text.substr(
        pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
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
    while (!line.empty() && (line.back() == ' ' || line.back() == '\t' ||
                             line.back() == '\r')) {
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
    char buf[96];
    snprintf(buf, sizeof(buf),
             "ADBLOCK: loaded %zu extra host rules from user list", added);
    BlinkBootLog(buf);
  }
#endif
}

void BlinkerContentFilter::ParseFilterLine(std::string_view line) {
  while (!line.empty() && (line.front() == ' ' || line.front() == '\t' ||
                           line.front() == '\r')) {
    line.remove_prefix(1);
  }
  while (!line.empty() && (line.back() == ' ' || line.back() == '\t' ||
                           line.back() == '\r')) {
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
  // Network allowlist (`@@`) is not supported in v1.
  if (line.substr(0, 2) == "@@") {
    return;
  }
  // Network block rule: reduce `||host^...`, `|host...`, `host...` to a host.
  std::string_view net = line;
  if (net.substr(0, 2) == "||") {
    net.remove_prefix(2);
  } else if (net.front() == '|') {
    net.remove_prefix(1);
  }
  if (net.empty()) {
    return;
  }
  size_t cut = net.find_first_of("^/$*?|");
  if (cut != std::string_view::npos && net[cut] == '/') {
    return;
  }
  std::string_view host =
      (cut == std::string_view::npos) ? net : net.substr(0, cut);
  if (LooksLikeDomain(host)) {
    AddHost(host);
  }
}

void BlinkerContentFilter::LoadFilterListsFromDisk() {
  for (const char* s : kBuiltinCosmetic) {
    generic_hide_selectors_.emplace_back(s);
  }
#if BUILDFLAG(IS_IOS)
  // Optional: an Adblock Plus / uBO / EasyList file the user drops in. Network
  // (`||host^`) and element-hiding (`##`) rules are honored.
  base::FilePath path("/var/mobile/Documents/blinker_filters.txt");
  std::string contents;
  if (base::ReadFileToString(path, &contents)) {
    const size_t hosts_before = blocked_hosts_.size();
    std::string_view text(contents);
    size_t pos = 0;
    while (pos < text.size()) {
      size_t eol = text.find('\n', pos);
      std::string_view line = text.substr(
          pos,
          eol == std::string_view::npos ? std::string_view::npos : eol - pos);
      pos = (eol == std::string_view::npos) ? text.size() : eol + 1;
      ParseFilterLine(line);
    }
    char buf[128];
    snprintf(buf, sizeof(buf),
             "ADBLOCK: filter list +%zu net, %zu generic + %zu host cosmetic",
             blocked_hosts_.size() - hosts_before, generic_hide_selectors_.size(),
             host_hide_selectors_.size());
    BlinkBootLog(buf);
  }
#endif
  // Pre-join the generic selectors once (capped so a full EasyList can't produce
  // a pathologically large style recalculated on every page).
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
  if (!g_enabled.load(std::memory_order_relaxed)) {
    return std::string();
  }
  const std::string h = NormalizeHost(host);
  // Walk host and each parent domain, gathering host-scoped selectors and
  // exceptions.
  std::unordered_set<std::string> exceptions;
  std::vector<const std::string*> host_specific;
  std::string_view cursor = h;
  for (;;) {
    const std::string key(cursor);
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
    size_t dot = cursor.find('.');
    if (dot == std::string_view::npos) {
      break;
    }
    std::string_view remainder = cursor.substr(dot + 1);
    if (remainder.find('.') == std::string_view::npos) {
      break;
    }
    cursor = remainder;
  }

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

#if BUILDFLAG(IS_IOS)
  // The persisted toggle defaults to enabled.
  bool enabled = true;
  if (CFPropertyListRef v = CFPreferencesCopyAppValue(
          CFSTR("BlinkAdBlock"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
      enabled = CFBooleanGetValue(static_cast<CFBooleanRef>(v));
    }
    CFRelease(v);
  }
  g_enabled.store(enabled, std::memory_order_relaxed);
#endif

  char buf[96];
  snprintf(buf, sizeof(buf), "ADBLOCK: %zu host rules loaded, enabled=%d",
           blocked_hosts_.size(),
           g_enabled.load(std::memory_order_relaxed) ? 1 : 0);
  BlinkBootLog(buf);
}

bool BlinkerContentFilter::ShouldBlock(const GURL& url) const {
  if (!g_enabled.load(std::memory_order_relaxed)) {
    return false;
  }
  if (!url.has_host() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  return HostOrParentInSet(blocked_hosts_, url.host());
}

bool BlinkerContentFilter::enabled() const {
  return g_enabled.load(std::memory_order_relaxed);
}

void BlinkerContentFilter::SetEnabled(bool enabled) {
  g_enabled.store(enabled, std::memory_order_relaxed);
}

uint64_t BlinkerContentFilter::blocked_count() const {
  return g_blocked_count.load(std::memory_order_relaxed);
}

void BlinkerContentFilter::RecordBlocked() {
  g_blocked_count.fetch_add(1, std::memory_order_relaxed);
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
    uint64_t n = g_blocked_count.load(std::memory_order_relaxed);
    if (n <= 12) {
      char buf[256];
      snprintf(buf, sizeof(buf), "ADBLOCK_HIT #%llu: %.200s",
               static_cast<unsigned long long>(n), request->url.spec().c_str());
      BlinkBootLog(buf);
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
