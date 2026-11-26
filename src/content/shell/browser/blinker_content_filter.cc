// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_content_filter.h"

#include <atomic>

#include <algorithm>
#include <cstdio>
#include <optional>
#include <string_view>
#include <utility>

#include "base/files/file_util.h"
#include "base/no_destructor.h"
#include "base/strings/string_split.h"
#include "base/functional/bind.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/strings/string_util.h"
#include "build/build_config.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/browser/blinker_extension_net_actions.h"
#include "content/shell/browser/blinker_web_request.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "content/shell/common/blinker_filter_pattern.h"
#include "content/shell/common/blinker_private_logging.h"
#include "content/shell/common/blinker_site_policy.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "third_party/re2/src/re2/re2.h"
#include "url/gurl.h"
#include "url/origin.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>

#include "base/files/file_path.h"
#endif

#if BUILDFLAG(IS_IOS)
extern "C" const char* BlinkDocumentsDir();
#endif

namespace content {

namespace {

using ResourceType = BlinkerResourceType;

constexpr size_t kMaxListBytes = 8 * 1024 * 1024;
constexpr size_t kMaxCSSBytes = 1024 * 1024;
constexpr size_t kMaxGenericSelectors = 30000;

#if BUILDFLAG(IS_IOS)
// в пісочниці нема /var/mobile/Documents, пробуємо ще Documents застосунку
bool ReadBlinkerUserFile(const char* leaf, std::string* contents) {
  if (base::ReadFileToStringWithMaxSize(
          base::FilePath("/var/mobile/Documents").Append(leaf), contents,
          kMaxListBytes)) {
    return true;
  }
  const char* dir = BlinkDocumentsDir();
  return dir &&
         base::ReadFileToStringWithMaxSize(base::FilePath(dir).Append(leaf),
                                           contents, kMaxListBytes);
}
#endif

// Запис покриває піддомени. Свої хости через
// Documents/blinker_blocklist.txt
constexpr const char* kBuiltinBlocklist[] = {
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
    "connect.facebook.net",
    "pixel.facebook.com",
    "an.facebook.com",
    "amazon-adsystem.com",
    "assoc-amazon.com",
    "aax.amazon-adsystem.com",
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
    "taboola.com",
    "outbrain.com",
    "revcontent.com",
    "mgid.com",
    "zergnet.com",
    "content-ad.net",
    "adblade.com",
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
    "mc.yandex.ru",
    "an.yandex.ru",
    "top-fwz1.mail.ru",
    "bat.bing.com",
    "clarity.ms",
    "ads.linkedin.com",
    "px.ads.linkedin.com",
    "ads-twitter.com",
    "analytics.twitter.com",
    "static.ads-twitter.com",
    "analytics.tiktok.com",
    "ads.tiktok.com",
    "business-api.tiktok.com",
    "ads.reddit.com",
    "events.reddit.com",
    "events.redditmedia.com",
    "pixel.reddit.com",
    "alb.reddit.com",
};

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

// Реклама з того ж хоста що й сайт, тому що правила по домену
// googlevideo.com не чіпаємо
constexpr const char* kBuiltinScopedCosmetic[] = {
    "reddit.com##shreddit-ad-post",
    "reddit.com##shreddit-post[is-promoted]",
    "reddit.com##.promotedlink",
    "reddit.com##[data-promoted=\"true\"]",
    "reddit.com##[data-testid=\"ad-post-container\"]",
    "youtube.com##ytd-ad-slot-renderer",
    "youtube.com##ytd-display-ad-renderer",
    "youtube.com##ytd-promoted-sparkles-web-renderer",
    "youtube.com##ytd-promoted-video-renderer",
    "youtube.com##ytd-action-companion-ad-renderer",
    "youtube.com##ytm-promoted-sparkles-web-renderer",
    "youtube.com##ytm-companion-ad-renderer",
    "youtube.com###masthead-ad",
    "youtube.com###player-ads",
    "google.com###tads",
    "google.com###tadsb",
    "google.com##[data-text-ad]",
};

// Не чіпаємо чужі сайти під публічним суфіксом типу co.uk чи github.io
std::vector<std::string_view> HostSuffixes(std::string_view host) {
  std::vector<std::string_view> suffixes;
  blinker_filter::HostAndParents(
      host,
      net::registry_controlled_domains::GetDomainAndRegistry(
          host, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES),
      &suffixes);
  return suffixes;
}

// www не відрізаємо, інакше виняток для www.example.com пустить example.com
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

// селектор не повинен вирватись з <style> чи свого правила
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

template <typename Fn>
void ForEachDomain(std::string_view list, Fn fn) {
  // Без моделі заперечень правило зачепило б виключений піддомен,
  // тому такий список пропускаємо
  if (list.find('~') != std::string_view::npos) {
    return;
  }
  for (std::string_view d : base::SplitStringPiece(
           list, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (LooksLikeDomain(d)) {
      fn(d);
    }
  }
}

std::string_view TrimFilterLine(std::string_view line) {
  while (!line.empty() && (line.front() == ' ' || line.front() == '\t' ||
                           line.front() == '\r')) {
    line.remove_prefix(1);
  }
  while (!line.empty() &&
         (line.back() == ' ' || line.back() == '\t' || line.back() == '\r')) {
    line.remove_suffix(1);
  }
  return line;
}

template <typename Fn>
void ForEachLine(std::string_view text, Fn fn) {
  size_t pos = 0;
  while (pos < text.size()) {
    const size_t eol = text.find('\n', pos);
    std::string_view line = text.substr(
        pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
    pos = (eol == std::string_view::npos) ? text.size() : eol + 1;
    fn(line);
  }
}

using blinker_filter::ExtractPatternToken;
using blinker_filter::ExtractUrlTokens;
using blinker_filter::HostLabelStarts;
using blinker_filter::MatchPatternAt;

uint32_t ResourceTypeBitForOption(std::string_view name) {
  if (name == "script") {
    return static_cast<uint32_t>(ResourceType::kScript);
  }
  if (name == "image") {
    return static_cast<uint32_t>(ResourceType::kImage);
  }
  if (name == "stylesheet" || name == "css") {
    return static_cast<uint32_t>(ResourceType::kStylesheet);
  }
  if (name == "object" || name == "object-subrequest") {
    return static_cast<uint32_t>(ResourceType::kObject);
  }
  if (name == "xmlhttprequest" || name == "xhr") {
    return static_cast<uint32_t>(ResourceType::kXmlHttpRequest);
  }
  if (name == "subdocument" || name == "frame") {
    return static_cast<uint32_t>(ResourceType::kSubdocument);
  }
  if (name == "ping" || name == "beacon") {
    return static_cast<uint32_t>(ResourceType::kPing);
  }
  if (name == "media") {
    return static_cast<uint32_t>(ResourceType::kMedia);
  }
  if (name == "font") {
    return static_cast<uint32_t>(ResourceType::kFont);
  }
  if (name == "websocket") {
    return static_cast<uint32_t>(ResourceType::kWebSocket);
  }
  if (name == "document" || name == "doc") {
    return static_cast<uint32_t>(ResourceType::kDocument);
  }
  if (name == "other") {
    return static_cast<uint32_t>(ResourceType::kOther);
  }
  if (name == "popup") {
    return static_cast<uint32_t>(ResourceType::kPopup);
  }
  return 0;
}

// Опції що не міняють набір запитів. Звужувальну ігнорувати не можна
// правило стане ширшим
bool IsIgnorableOption(std::string_view name) {
  return name == "important" || name == "all";
}

}  // namespace

BlinkerContentFilter::NetworkRule::NetworkRule() = default;
BlinkerContentFilter::NetworkRule::NetworkRule(const NetworkRule&) = default;
BlinkerContentFilter::NetworkRule::NetworkRule(NetworkRule&&) = default;
BlinkerContentFilter::NetworkRule&
BlinkerContentFilter::NetworkRule::operator=(const NetworkRule&) = default;
BlinkerContentFilter::NetworkRule&
BlinkerContentFilter::NetworkRule::operator=(NetworkRule&&) = default;
BlinkerContentFilter::NetworkRule::~NetworkRule() = default;

BlinkerContentFilter::RuleSet::RuleSet() = default;
BlinkerContentFilter::RuleSet::~RuleSet() = default;

class BlinkerContentFilter::Builder {
 public:
  Builder() : set_(base::MakeRefCounted<RuleSet>()) {}

  // Біт 0 у браузера, у кожного розширення свій
  void SetSourceMask(uint32_t mask) { source_mask_ = mask; }

  void LoadBuiltins() {
    for (const char* entry : kBuiltinBlocklist) {
      AddBlockedHost(entry);
    }
    for (const char* selector : kBuiltinCosmetic) {
      set_->generic_hide_selectors.emplace_back(selector);
    }
    for (const char* rule : kBuiltinScopedCosmetic) {
      ParseLine(rule);
    }
  }

  size_t LoadHostsFile(std::string_view text) {
    size_t added = 0;
    ForEachLine(text, [&](std::string_view line) {
      const size_t hash = line.find('#');
      if (hash != std::string_view::npos) {
        line = line.substr(0, hash);
      }
      line = TrimFilterLine(line);
      if (line.empty()) {
        return;
      }
      const size_t sp = line.find_first_of(" \t");
      if (sp != std::string_view::npos) {
        const std::string_view first = line.substr(0, sp);
        if (first == "0.0.0.0" || first == "127.0.0.1" || first == "::1") {
          line = TrimFilterLine(line.substr(sp + 1));
        }
      }
      const size_t before = set_->blocked_hosts.size();
      AddBlockedHost(line);
      if (set_->blocked_hosts.size() != before) {
        ++added;
      }
    });
    return added;
  }

  void LoadFilterList(std::string_view text) {
    // Без обробки `!#if` застосувались би обидві гілки. Предикатів нема,
    // беремо тільки `!#else`
    int skip_depth = 0;
    int nest_depth = 0;
    ForEachLine(text, [&](std::string_view line) {
      const std::string_view trimmed = TrimFilterLine(line);
      if (trimmed.starts_with("!#if")) {
        ++nest_depth;
        if (skip_depth == 0) {
          skip_depth = nest_depth;
        }
        return;
      }
      if (trimmed.starts_with("!#else")) {
        if (nest_depth > 0 && skip_depth == nest_depth) {
          skip_depth = 0;
        } else if (nest_depth > 0 && skip_depth == 0) {
          skip_depth = nest_depth;
        }
        return;
      }
      if (trimmed.starts_with("!#endif")) {
        if (nest_depth > 0) {
          if (skip_depth == nest_depth) {
            skip_depth = 0;
          }
          --nest_depth;
        }
        return;
      }
      if (skip_depth != 0) {
        return;
      }
      ParseLine(trimmed);
    });
  }

  scoped_refptr<const RuleSet> Finish() {
    BuildGenericCSS();
    return std::move(set_);
  }

  void ParseLine(std::string_view line) {
    line = TrimFilterLine(line);
    if (line.empty() || line.front() == '!' || line.front() == '[') {
      return;
    }

    if (const size_t p = line.find("#@#"); p != std::string_view::npos) {
      const std::string_view sel = line.substr(p + 3);
      if (IsSafeSelector(sel)) {
        ForEachDomain(line.substr(0, p), [&](std::string_view d) {
          set_->host_hide_exceptions[NormalizeHost(d)].emplace_back(sel);
        });
      }
      return;
    }
    if (line.find("#?#") != std::string_view::npos ||
        line.find("#$#") != std::string_view::npos ||
        line.find("#%#") != std::string_view::npos) {
      return;
    }
    if (const size_t p = line.find("##"); p != std::string_view::npos) {
      const std::string_view sel = line.substr(p + 2);
      if (!IsSafeSelector(sel) || sel.starts_with("+js(") ||
          sel.find(":has-text(") != std::string_view::npos ||
          sel.find(":style(") != std::string_view::npos) {
        return;
      }
      const std::string_view domains = line.substr(0, p);
      if (domains.empty()) {
        set_->generic_hide_selectors.emplace_back(sel);
      } else {
        ForEachDomain(domains, [&](std::string_view d) {
          set_->host_hide_selectors[NormalizeHost(d)].emplace_back(sel);
        });
      }
      return;
    }

    ParseNetworkLine(line);
  }

 private:
  void AddBlockedHost(std::string_view host) {
    std::string h = NormalizeHost(host);
    if (LooksLikeDomain(h)) {
      set_->blocked_hosts[std::move(h)] |= source_mask_;
    }
  }

  void AddAllowedHost(std::string_view host) {
    std::string h = NormalizeHost(host);
    if (LooksLikeDomain(h)) {
      set_->allowed_hosts[std::move(h)] |= source_mask_;
    }
  }

  void ParseNetworkLine(std::string_view line) {
    const bool exception = line.starts_with("@@");
    if (exception) {
      line.remove_prefix(2);
    }

    // `$` всередині виразу не роздільник, тому опції шукаємо після останнього
    // `/`
    std::string_view regex;
    std::string_view options;
    if (line.size() >= 2 && line.front() == '/') {
      const size_t close = line.rfind('/');
      const std::string_view tail = line.substr(close + 1);
      if (close > 0 && (tail.empty() || tail.front() == '$')) {
        regex = line.substr(1, close - 1);
        options = tail.empty() ? tail : tail.substr(1);
        if (regex.empty()) {
          return;
        }
      }
    }
    if (regex.empty()) {
      if (const size_t dollar = line.rfind('$');
          dollar != std::string_view::npos) {
        options = line.substr(dollar + 1);
        line = line.substr(0, dollar);
      }
      if (line.empty()) {
        return;
      }
    }

    NetworkRule rule;
    if (!ParseOptions(options, &rule)) {
      return;
    }
    for (std::vector<std::string>* list :
         {&rule.domains, &rule.excluded_domains, &rule.request_domains,
          &rule.excluded_request_domains}) {
      std::ranges::sort(*list);
      list->erase(std::ranges::unique(*list).begin(), list->end());
    }

    if (!regex.empty()) {
      RE2::Options re_options;
      re_options.set_case_sensitive(rule.match_case);
      re_options.set_log_errors(false);
      auto compiled =
          std::make_shared<const RE2>(std::string(regex), re_options);
      if (!compiled->ok()) {
        return;
      }
      rule.regex = std::move(compiled);
      rule.source_mask = source_mask_;
      if (exception) {
        ++set_->exception_rule_count;
        set_->allow_rules_untokenized.push_back(std::move(rule));
      } else {
        set_->block_rules_untokenized.push_back(std::move(rule));
      }
      return;
    }

    if (line.starts_with("||")) {
      rule.hostname_anchor = true;
      line.remove_prefix(2);
    } else if (line.starts_with("|")) {
      rule.left_anchor = true;
      line.remove_prefix(1);
    }
    if (line.ends_with("|")) {
      rule.right_anchor = true;
      line.remove_suffix(1);
    }
    if (line.empty()) {
      return;
    }

    std::string_view bare = line;
    if (bare.ends_with('^')) {
      bare.remove_suffix(1);
    }
    // Правило на весь суфікс (com, co.uk) блокувало б усі сайти під ним
    // тому відкидаємо. IP адреси лишаються
    if (rule.hostname_anchor &&
        bare.find_first_of("/*^?=:|") == std::string_view::npos &&
        bare.find_first_not_of("0123456789.") != std::string_view::npos &&
        !net::registry_controlled_domains::HostHasRegistryControlledDomain(
            base::ToLowerASCII(bare),
            net::registry_controlled_domains::INCLUDE_UNKNOWN_REGISTRIES,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) {
      return;
    }
    const bool plain_host_rule =
        rule.hostname_anchor && !rule.right_anchor && rule.type_mask == 0 &&
        rule.excluded_type_mask == 0 && rule.party == NetworkRule::Party::kAny &&
        rule.domains.empty() && rule.excluded_domains.empty() &&
        rule.request_domains.empty() && rule.excluded_request_domains.empty() &&
        LooksLikeDomain(bare);
    if (plain_host_rule) {
      if (exception) {
        AddAllowedHost(bare);
      } else {
        AddBlockedHost(bare);
      }
      return;
    }

    rule.source_mask = source_mask_;
    rule.pattern = rule.match_case ? std::string(line)
                                   : base::ToLowerASCII(line);
    if (rule.pattern.find_first_not_of("*^|") == std::string::npos) {
      return;
    }

    const std::string token =
        rule.match_case ? std::string()
                        : ExtractPatternToken(rule.pattern, rule.hostname_anchor,
                                              rule.left_anchor,
                                              rule.right_anchor);
    if (exception) {
      ++set_->exception_rule_count;
      if (token.empty()) {
        set_->allow_rules_untokenized.push_back(std::move(rule));
      } else {
        set_->allow_rules[token].push_back(std::move(rule));
      }
    } else {
      ++set_->pattern_rule_count;
      if (token.empty()) {
        set_->block_rules_untokenized.push_back(std::move(rule));
      } else {
        set_->block_rules[token].push_back(std::move(rule));
      }
    }
  }

  static bool ParseOptions(std::string_view options, NetworkRule* rule) {
    if (options.empty()) {
      return true;
    }
    for (std::string_view opt : base::SplitStringPiece(
             options, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
      bool negated = false;
      if (opt.front() == '~') {
        negated = true;
        opt.remove_prefix(1);
      }
      if (opt.starts_with("domain=")) {
        if (negated) {
          return false;
        }
        for (std::string_view d :
             base::SplitStringPiece(opt.substr(7), "|", base::TRIM_WHITESPACE,
                                    base::SPLIT_WANT_NONEMPTY)) {
          if (d.front() == '~') {
            d.remove_prefix(1);
            if (!d.empty()) {
              rule->excluded_domains.push_back(NormalizeHost(d));
            }
          } else {
            rule->domains.push_back(NormalizeHost(d));
          }
        }
        continue;
      }
      if (opt.starts_with("to=")) {
        if (negated) {
          return false;
        }
        for (std::string_view d :
             base::SplitStringPiece(opt.substr(3), "|", base::TRIM_WHITESPACE,
                                    base::SPLIT_WANT_NONEMPTY)) {
          if (d.front() == '~') {
            d.remove_prefix(1);
            if (!d.empty()) {
              rule->excluded_request_domains.push_back(NormalizeHost(d));
            }
          } else {
            rule->request_domains.push_back(NormalizeHost(d));
          }
        }
        continue;
      }
      // 3p замість strict3p вужче або рівно, а 1p замість strict1p ширше
      // strict1p не беремо
      if (opt == "third-party" || opt == "3p" || opt == "strict3p") {
        rule->party = negated ? NetworkRule::Party::kFirstParty
                              : NetworkRule::Party::kThirdParty;
        continue;
      }
      if (opt == "first-party" || opt == "1p") {
        rule->party = negated ? NetworkRule::Party::kThirdParty
                              : NetworkRule::Party::kFirstParty;
        continue;
      }
      if (opt == "match-case") {
        rule->match_case = !negated;
        continue;
      }
      if (const uint32_t bit = ResourceTypeBitForOption(opt); bit != 0) {
        if (negated) {
          rule->excluded_type_mask |= bit;
        } else {
          rule->type_mask |= bit;
        }
        continue;
      }
      if (IsIgnorableOption(opt)) {
        continue;
      }
      return false;
    }
    return true;
  }

  void BuildGenericCSS() {
    std::string& css = set_->generic_hide_css;
    css.clear();
    size_t n = 0;
    for (const std::string& s : set_->generic_hide_selectors) {
      if (n++ >= kMaxGenericSelectors || css.size() >= kMaxCSSBytes) {
        break;
      }
      css += s;
      css += "{display:none!important}";
    }
  }

  scoped_refptr<RuleSet> set_;
  uint32_t source_mask_ = kLocalSourceMask;
};

namespace {

class RequestHosts {
 public:
  RequestHosts(std::string_view document, std::string_view request)
      : document_(document),
        request_(request),
        request_suffixes_(HostSuffixes(request)) {}

  std::string_view document() const { return document_; }
  std::string_view request() const { return request_; }
  const std::vector<std::string_view>& request_suffixes() const {
    return request_suffixes_;
  }
  const std::vector<std::string_view>& document_suffixes() {
    if (!document_suffixes_) {
      document_suffixes_ = HostSuffixes(document_);
    }
    return *document_suffixes_;
  }

 private:
  const std::string_view document_;
  const std::string_view request_;
  const std::vector<std::string_view> request_suffixes_;
  std::optional<std::vector<std::string_view>> document_suffixes_;
};

bool RuleApplies(const BlinkerContentFilter::NetworkRule& rule,
                 uint32_t type_bit,
                 bool third_party,
                 bool party_known,
                 RequestHosts& hosts) {
  using Party = BlinkerContentFilter::NetworkRule::Party;
  if (rule.type_mask == 0) {
    // Як в ABP, вікно блокує тільки явний $popup. DNR без resourceTypes
    // main_frame не чіпає
    if (type_bit == static_cast<uint32_t>(ResourceType::kPopup) ||
        (type_bit == static_cast<uint32_t>(ResourceType::kDocument) &&
         (rule.source_mask & BlinkerContentFilter::kLocalSourceMask) == 0)) {
      return false;
    }
  } else if ((rule.type_mask & type_bit) == 0) {
    return false;
  }
  if ((rule.excluded_type_mask & type_bit) != 0) {
    return false;
  }
  if (rule.party != Party::kAny) {
    if (!party_known) {
      return false;
    }
    if ((rule.party == Party::kThirdParty) != third_party) {
      return false;
    }
  }
  if ((!rule.domains.empty() || !rule.excluded_domains.empty()) &&
      (hosts.document().empty() ||
       !blinker_filter::DomainOptionsMatch(hosts.document_suffixes(),
                                           rule.domains,
                                           rule.excluded_domains))) {
    return false;
  }
  if ((!rule.request_domains.empty() ||
       !rule.excluded_request_domains.empty()) &&
      (hosts.request().empty() ||
       !blinker_filter::DomainOptionsMatch(hosts.request_suffixes(),
                                           rule.request_domains,
                                           rule.excluded_request_domains))) {
    return false;
  }
  return true;
}

bool PatternMatchesUrl(const BlinkerContentFilter::NetworkRule& rule,
                       std::string_view url,
                       std::string_view original_url,
                       const std::vector<size_t>& label_starts) {
  if (rule.regex) {
    return RE2::PartialMatch(rule.match_case ? original_url : url,
                             *rule.regex);
  }
  if (rule.hostname_anchor) {
    for (size_t start : label_starts) {
      if (MatchPatternAt(rule.pattern, url, start, rule.right_anchor)) {
        return true;
      }
    }
    return false;
  }
  if (rule.left_anchor) {
    return MatchPatternAt(rule.pattern, url, 0, rule.right_anchor);
  }
  for (size_t start = 0; start <= url.size(); ++start) {
    if (MatchPatternAt(rule.pattern, url, start, rule.right_anchor)) {
      return true;
    }
  }
  return false;
}

}  // namespace

// static
BlinkerContentFilter& BlinkerContentFilter::GetInstance() {
  static base::NoDestructor<BlinkerContentFilter> instance;
  return *instance;
}

BlinkerContentFilter::BlinkerContentFilter() = default;
BlinkerContentFilter::~BlinkerContentFilter() = default;

scoped_refptr<const BlinkerContentFilter::RuleSet> BlinkerContentFilter::rules()
    const {
  base::AutoLock guard(lock_);
  return rules_;
}

void BlinkerContentFilter::SetRules(scoped_refptr<const RuleSet> rules) {
  base::AutoLock guard(lock_);
  rules_ = std::move(rules);
}

void BlinkerContentFilter::EnsureLoaded() {
  if (loaded_) {
    return;
  }
  loaded_ = true;
  RebuildRules();

#if BUILDFLAG(IS_IOS)
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
}

void BlinkerContentFilter::LoadRulesForTesting(
    const std::vector<std::string>& lines) {
  LoadRulesForTesting(lines, {});
}

void BlinkerContentFilter::LoadRulesForTesting(
    const std::vector<std::string>& lines,
    const std::vector<ExtensionRules>& extensions) {
  Builder builder;
  builder.LoadBuiltins();
  std::string text;
  for (const std::string& line : lines) {
    text += line;
    text += '\n';
  }
  builder.LoadFilterList(text);
  uint32_t bit = 1;
  for (const ExtensionRules& source : extensions) {
    builder.SetSourceMask(1u << bit);
    for (const std::shared_ptr<const std::string>& chunk : source.chunks) {
      if (chunk) {
        builder.LoadFilterList(*chunk);
      }
    }
    if (bit + 1 < kMaxSourceBits) {
      ++bit;
    }
  }
  builder.SetSourceMask(kLocalSourceMask);
  SetRules(builder.Finish());
  loaded_ = true;
}

void BlinkerContentFilter::ReloadFromFiles(
    const std::vector<base::FilePath>& lists) {
  {
    base::AutoLock guard(lock_);
    list_paths_ = lists;
    ++rules_generation_;
  }
  RebuildRules();
}

void BlinkerContentFilter::SetExtensionRules(
    std::vector<ExtensionRules> rules) {
  {
    base::AutoLock guard(lock_);
    extension_rules_ =
        std::make_shared<const std::vector<ExtensionRules>>(std::move(rules));
    ++rules_generation_;
  }
  ScheduleRebuild();
}

void BlinkerContentFilter::ScheduleRebuild() {
  // На старті розширення шлють правила по одному, а розбір це до 200 тисяч
  // рядків, бо тому зливаємо в одну фонову перебудову
  if (!base::SequencedTaskRunner::HasCurrentDefault()) {
    RebuildRules();
    return;
  }
  {
    base::AutoLock guard(lock_);
    if (rebuild_pending_) {
      return;
    }
    rebuild_pending_ = true;
  }
  base::ThreadPool::PostDelayedTask(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce([] {
        BlinkerContentFilter& filter = BlinkerContentFilter::GetInstance();
        {
          base::AutoLock guard(filter.lock_);
          filter.rebuild_pending_ = false;
        }
        filter.RebuildRules();
      }),
      base::Milliseconds(250));
}

void BlinkerContentFilter::RebuildRules() {
  // Розбір без замка, тому публікуємо результат лише якщо входи не змінились
  std::vector<base::FilePath> lists;
  std::shared_ptr<const std::vector<ExtensionRules>> extension_rules;
  uint64_t generation = 0;
  {
    base::AutoLock guard(lock_);
    lists = list_paths_;
    extension_rules = extension_rules_;
    generation = rules_generation_;
  }

  Builder builder;
  builder.LoadBuiltins();
#if BUILDFLAG(IS_IOS)
  std::string contents;
  if (ReadBlinkerUserFile("blinker_blocklist.txt", &contents)) {
    builder.LoadHostsFile(contents);
  }
  if (ReadBlinkerUserFile("blinker_filters.txt", &contents)) {
    builder.LoadFilterList(contents);
  }
#endif
  for (const base::FilePath& path : lists) {
    std::string body;
    if (!base::ReadFileToStringWithMaxSize(path, &body, kMaxListBytes)) {
      continue;
    }
    builder.LoadFilterList(body);
  }
  size_t extension_bytes = 0;
  if (extension_rules) {
    // У кожного розширення свій біт, всього 31
    // ті що понад межу ділять останній
    uint32_t bit = 1;
    for (const ExtensionRules& source : *extension_rules) {
      builder.SetSourceMask(1u << bit);
      for (const std::shared_ptr<const std::string>& chunk : source.chunks) {
        if (!chunk) {
          continue;
        }
        builder.LoadFilterList(*chunk);
        extension_bytes += chunk->size();
      }
      if (bit + 1 < kMaxSourceBits) {
        ++bit;
      }
    }
    builder.SetSourceMask(kLocalSourceMask);
  }
  {
    base::AutoLock guard(lock_);
    if (generation != rules_generation_) {
      return;
    }
    rules_ = builder.Finish();
  }
  BLINKER_DIAGF(
      "ADBLOCK: rebuilt from %zu list(s) + %zu KiB of rules from %zu "
      "extension(s) -> %zu host + %zu pattern rules",
      lists.size(), extension_bytes / 1024,
      extension_rules ? extension_rules->size() : 0u, rule_count(),
      rule_stats().network_rules);
}

bool BlinkerContentFilter::ShouldBlock(const GURL& url) const {
  return ShouldBlock(url, GURL(), ResourceType::kOther);
}

bool BlinkerContentFilter::ShouldBlock(const GURL& url,
                                       const GURL& document_url,
                                       BlinkerResourceType type) const {
  return ShouldBlock(url, document_url, type, /*allowed_by_exception=*/nullptr);
}

bool BlinkerContentFilter::ShouldBlock(const GURL& url,
                                       const GURL& document_url,
                                       BlinkerResourceType type,
                                       bool* allowed_by_exception) const {
  if (allowed_by_exception) {
    *allowed_by_exception = false;
  }
  if (!enabled()) {
    return false;
  }
  if (!url.has_host() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  scoped_refptr<const RuleSet> set = rules();
  if (!set) {
    return false;
  }

  const std::string host = NormalizeHost(url.host());
  const std::string path(url.path());

  // Списки не ламають перевірку людини і вхід, капчу вирішує провайдер
  const bool verification_host =
      blinker_sites::HasTrait(host, blinker_sites::kVerificationResource);
  const bool google_verification_path =
      (url.DomainIs("google.com") || url.DomainIs("gstatic.com")) &&
      (path.find("/recaptcha/") != std::string::npos ||
       path.find("/captcha/") != std::string::npos);
  if (verification_host || google_verification_path) {
    return false;
  }

  const std::string document_host =
      document_url.is_valid() && document_url.has_host()
          ? NormalizeHost(document_url.host())
          : std::string();

  if (!document_host.empty() && IsHostAllowlisted(document_host)) {
    return false;
  }

  RequestHosts hosts(document_host, host);
  // Хости від розширень це DNR без resourceTypes, навігацію вони не чіпають
  const uint32_t host_source_filter =
      type == ResourceType::kDocument || type == ResourceType::kPopup
          ? kLocalSourceMask
          : ~0u;
  uint32_t block_mask = 0;
  uint32_t allow_mask = 0;
  for (std::string_view domain : hosts.request_suffixes()) {
    if (const auto it = set->allowed_hosts.find(domain);
        it != set->allowed_hosts.end()) {
      allow_mask |= it->second & host_source_filter;
    }
    if (const auto it = set->blocked_hosts.find(domain);
        it != set->blocked_hosts.end()) {
      block_mask |= it->second & host_source_filter;
    }
  }

  const std::string url_lower = base::ToLowerASCII(url.spec());
  const uint32_t type_bit = static_cast<uint32_t>(type);
  const bool party_known = !document_host.empty();
  const bool third_party =
      party_known &&
      !net::registry_controlled_domains::SameDomainOrHost(
          url, document_url,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);

  std::vector<size_t> label_starts;
  HostLabelStarts(url_lower, &label_starts);

  std::vector<std::string_view> tokens;
  ExtractUrlTokens(url_lower, &tokens);

  auto collect_mask =
      [&](const StringMap<std::vector<NetworkRule>>& buckets,
          const std::vector<NetworkRule>& untokenized, uint32_t* mask,
          auto stop) {
        for (const NetworkRule& rule : untokenized) {
          if (RuleApplies(rule, type_bit, third_party, party_known, hosts) &&
              PatternMatchesUrl(rule, url_lower, url.spec(), label_starts)) {
            *mask |= rule.source_mask;
            if (stop()) {
              return;
            }
          }
        }
        for (std::string_view token : tokens) {
          const auto it = buckets.find(token);
          if (it == buckets.end()) {
            continue;
          }
          for (const NetworkRule& rule : it->second) {
            if (RuleApplies(rule, type_bit, third_party, party_known, hosts) &&
                PatternMatchesUrl(rule, url_lower, url.spec(), label_starts)) {
              *mask |= rule.source_mask;
              if (stop()) {
                return;
              }
            }
          }
        }
      };

  collect_mask(set->block_rules, set->block_rules_untokenized, &block_mask,
               [] { return false; });

  if (block_mask == 0) {
    // Блоку нема але виняток шукаємо, бо він не дає розширенню
    // перенаправити запит
    uint32_t any_allow = allow_mask;
    if (any_allow == 0) {
      collect_mask(set->allow_rules, set->allow_rules_untokenized, &any_allow,
                   [&] { return any_allow != 0; });
    }
    if (any_allow != 0) {
      if (allowed_by_exception) {
        *allowed_by_exception = true;
      }
      return false;
    }
  } else {
    collect_mask(set->allow_rules, set->allow_rules_untokenized, &allow_mask,
                 [&] { return (block_mask & ~allow_mask) == 0; });
    // Виняток зі списків браузера це вибір користувача, він переважає все
    // Виняток розширення знімає тільки свій біт
    if ((allow_mask & kLocalSourceMask) != 0 ||
        (block_mask & ~allow_mask) == 0) {
      if (allowed_by_exception) {
        *allowed_by_exception = true;
      }
      return false;
    }
    return true;
  }

  // Тільки відомі рекламні адреси, блок цілого хоста зламав би пошук і вхід
  const bool youtube_ad =
      blinker_sites::HostMatchesDomain(host, "youtube.com") &&
      (path.starts_with("/pagead/") || path == "/api/stats/ads" ||
       path == "/api/stats/atr");
  const bool google_ad = blinker_sites::HostMatchesDomain(host, "google.com") &&
                         path.starts_with("/pagead/");
  return youtube_ad || google_ad;
}

std::string BlinkerContentFilter::CosmeticCSSFor(std::string_view host) const {
  if (!enabled()) {
    return std::string();
  }
  scoped_refptr<const RuleSet> set = rules();
  if (!set) {
    return std::string();
  }
  const std::string h = NormalizeHost(host);
  if (IsHostAllowlisted(h)) {
    return std::string();
  }
  std::unordered_set<std::string_view> exceptions;
  std::vector<const std::string*> host_specific;
  for (std::string_view key : HostSuffixes(h)) {
    if (auto it = set->host_hide_exceptions.find(key);
        it != set->host_hide_exceptions.end()) {
      exceptions.insert(it->second.begin(), it->second.end());
    }
    if (auto it = set->host_hide_selectors.find(key);
        it != set->host_hide_selectors.end()) {
      for (const std::string& s : it->second) {
        host_specific.push_back(&s);
      }
    }
  }

  std::string css;
  if (exceptions.empty()) {
    css = set->generic_hide_css;
  } else {
    for (const std::string& s : set->generic_hide_selectors) {
      if (exceptions.count(s)) {
        continue;
      }
      if (css.size() >= kMaxCSSBytes) {
        break;
      }
      css += s;
      css += "{display:none!important}";
    }
  }
  for (const std::string* s : host_specific) {
    if (exceptions.count(*s)) {
      continue;
    }
    if (css.size() >= kMaxCSSBytes) {
      break;
    }
    css += *s;
    css += "{display:none!important}";
  }
  return css;
}

bool BlinkerContentFilter::enabled() const {
  return enabled_.load(std::memory_order_relaxed);
}

void BlinkerContentFilter::SetEnabled(bool enabled) {
  enabled_.store(enabled, std::memory_order_relaxed);
}

void BlinkerContentFilter::SetHostAllowlisted(std::string_view host,
                                              bool allowlisted) {
  const std::string h = NormalizeHost(host);
  if (h.empty()) {
    return;
  }
  base::AutoLock guard(lock_);
  if (allowlisted) {
    allowlisted_hosts_.insert(h);
  } else {
    allowlisted_hosts_.erase(h);
  }
}

bool BlinkerContentFilter::IsHostAllowlisted(std::string_view host) const {
  const std::string h = NormalizeHost(host);
  if (h.empty()) {
    return false;
  }
  base::AutoLock guard(lock_);
  if (allowlisted_hosts_.empty()) {
    return false;
  }
  for (std::string_view domain : HostSuffixes(h)) {
    if (allowlisted_hosts_.contains(domain)) {
      return true;
    }
  }
  return false;
}

uint64_t BlinkerContentFilter::blocked_count() const {
  return blocked_count_.load(std::memory_order_relaxed);
}

uint64_t BlinkerContentFilter::blocked_count_for_host(
    std::string_view host) const {
  const std::string h = NormalizeHost(host);
  base::AutoLock guard(lock_);
  const auto it = per_host_counts_.find(h);
  return it == per_host_counts_.end() ? 0 : it->second;
}

void BlinkerContentFilter::ResetHostCount(std::string_view host) {
  const std::string h = NormalizeHost(host);
  base::AutoLock guard(lock_);
  per_host_counts_.erase(h);
}

void BlinkerContentFilter::RecordBlocked() {
  RecordBlocked(std::string_view());
}

void BlinkerContentFilter::RecordBlocked(std::string_view document_host) {
  blocked_count_.fetch_add(1, std::memory_order_relaxed);
  if (document_host.empty()) {
    return;
  }
  const std::string h = NormalizeHost(document_host);
  base::AutoLock guard(lock_);
  constexpr size_t kMaxTrackedHosts = 64;
  if (per_host_counts_.size() >= kMaxTrackedHosts &&
      !per_host_counts_.contains(h)) {
    per_host_counts_.clear();
  }
  ++per_host_counts_[h];
}

BlinkerContentFilter::RuleStats BlinkerContentFilter::rule_stats() const {
  RuleStats stats;
  scoped_refptr<const RuleSet> set = rules();
  if (!set) {
    return stats;
  }
  stats.network_rules = set->pattern_rule_count;
  stats.exception_rules = set->exception_rule_count;
  stats.cosmetic_rules = set->generic_hide_selectors.size();
  for (const auto& entry : set->host_hide_selectors) {
    stats.cosmetic_rules += entry.second.size();
  }
  return stats;
}

size_t BlinkerContentFilter::rule_count() const {
  scoped_refptr<const RuleSet> set = rules();
  return set ? set->blocked_hosts.size() : 0;
}

namespace {

// Без відповідника у списках буде kOther, а його ловлять тільки правила без
// типу
BlinkerResourceType ResourceTypeForDestination(
    network::mojom::RequestDestination destination) {
  switch (destination) {
    case network::mojom::RequestDestination::kScript:
    case network::mojom::RequestDestination::kWorker:
    case network::mojom::RequestDestination::kSharedWorker:
    case network::mojom::RequestDestination::kServiceWorker:
    case network::mojom::RequestDestination::kAudioWorklet:
    case network::mojom::RequestDestination::kPaintWorklet:
      return ResourceType::kScript;
    case network::mojom::RequestDestination::kImage:
      return ResourceType::kImage;
    case network::mojom::RequestDestination::kStyle:
    case network::mojom::RequestDestination::kXslt:
      return ResourceType::kStylesheet;
    case network::mojom::RequestDestination::kFont:
      return ResourceType::kFont;
    case network::mojom::RequestDestination::kAudio:
    case network::mojom::RequestDestination::kVideo:
    case network::mojom::RequestDestination::kTrack:
      return ResourceType::kMedia;
    case network::mojom::RequestDestination::kObject:
    case network::mojom::RequestDestination::kEmbed:
      return ResourceType::kObject;
    case network::mojom::RequestDestination::kFrame:
    case network::mojom::RequestDestination::kIframe:
    case network::mojom::RequestDestination::kFencedframe:
      return ResourceType::kSubdocument;
    case network::mojom::RequestDestination::kDocument:
      return ResourceType::kDocument;
    case network::mojom::RequestDestination::kReport:
      return ResourceType::kPing;
    case network::mojom::RequestDestination::kEmpty:
      // fetch() і XHR лишають destination пустим, це `xmlhttprequest`
      return ResourceType::kXmlHttpRequest;
    default:
      return ResourceType::kOther;
  }
}

BlinkerResourceType ResourceTypeForRequest(
    const network::ResourceRequest& request) {
  return ResourceTypeForDestination(request.destination);
}

GURL DocumentUrlForRequest(const network::ResourceRequest& request) {
  if (request.request_initiator && !request.request_initiator->opaque()) {
    return request.request_initiator->GetURL();
  }
  if (request.destination == network::mojom::RequestDestination::kDocument) {
    return request.url;
  }
  return GURL();
}

}  // namespace

BlinkerContentFilterThrottle::BlinkerContentFilterThrottle() = default;
BlinkerContentFilterThrottle::~BlinkerContentFilterThrottle() = default;

void BlinkerContentFilterThrottle::DetachFromCurrentSequence() {}

BlinkerResourceType BlinkerResourceTypeForDestination(
    network::mojom::RequestDestination destination) {
  return ResourceTypeForDestination(destination);
}

BlinkerResourceType BlinkerResourceTypeForRequest(
    const network::ResourceRequest& request) {
  return ResourceTypeForRequest(request);
}

GURL BlinkerDocumentUrlForRequest(const network::ResourceRequest& request) {
  return DocumentUrlForRequest(request);
}

void BlinkerContentFilterThrottle::NotifyWebRequestStart(
    const network::ResourceRequest& request) {
  if (!BlinkerWebRequestHasListeners()) {
    return;
  }
  static std::atomic<uint64_t> next_id{1};
  web_request_id_ = next_id.fetch_add(1, std::memory_order_relaxed);
  BlinkerWebRequestNotifyStart(web_request_id_, request, document_url_, type_,
                               tab_id_);
}

void BlinkerContentFilterThrottle::WillStartRequest(
    network::ResourceRequest* request,
    bool* defer) {
  document_url_ = DocumentUrlForRequest(*request);
  request_url_ = request->url;
  type_ = ResourceTypeForRequest(*request);
  NotifyWebRequestStart(*request);
  BlinkerContentFilter& filter = BlinkerContentFilter::GetInstance();
  bool allowed_by_exception = false;
  if (!filter.ShouldBlock(request->url, document_url_, type_,
                          &allowed_by_exception)) {
    if (!allowed_by_exception) {
      ApplyExtensionActions(request);
    }
    return;
  }
  filter.RecordBlocked(document_url_.has_host() ? document_url_.host()
                                                : std::string());
  // URL видає сторінку, тому в лог тільки через LoggableURLSpec
  const uint64_t n = filter.blocked_count();
  if (n <= 12) {
    BLINKER_DIAGF("ADBLOCK_HIT #%llu: %.200s",
                  static_cast<unsigned long long>(n),
                  blinker_logging::LoggableURLSpec(request->url).c_str());
  }
  BlinkerWebRequestNotifyError(web_request_id_, request->url,
                               "net::ERR_BLOCKED_BY_CLIENT", document_url_,
                               type_, tab_id_);
  delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT,
                             "Blocked by Blinker Fluid content filter");
}

void BlinkerContentFilterThrottle::ApplyExtensionActions(
    network::ResourceRequest* request) {
  BlinkerExtensionNetActions& actions =
      BlinkerExtensionNetActions::GetInstance();
  if (actions.empty()) {
    return;
  }

  std::vector<BlinkerHeaderOp> ops;
  actions.CollectHeaderOps(request->url, document_url_, type_,
                           /*response=*/false, &ops);
  for (const BlinkerHeaderOp& op : ops) {
    switch (op.op) {
      case BlinkerHeaderOp::Op::kRemove:
        request->headers.RemoveHeader(op.name);
        break;
      case BlinkerHeaderOp::Op::kSet:
      case BlinkerHeaderOp::Op::kAppend:
        request->headers.SetHeader(op.name, op.value);
        break;
    }
  }

  const GURL target =
      actions.FindRedirect(request->url, document_url_, type_);
  // Тільки http(s), ThrottlingURLLoader має NOTREACHED для решти
  if (!target.is_valid() || !target.SchemeIsHTTPOrHTTPS() ||
      !request->url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  // `redirected_from_` не дає правилу зациклитись на власній цілі
  if (target == redirected_from_) {
    return;
  }
  redirected_from_ = request->url;
  request->url = target;
  request_url_ = target;
}

void BlinkerContentFilterThrottle::WillOnCompleteWithError(
    const network::URLLoaderCompletionStatus& status) {
  BlinkerWebRequestNotifyError(web_request_id_, request_url_,
                               net::ErrorToString(status.error_code),
                               document_url_, type_, tab_id_);
}

void BlinkerContentFilterThrottle::WillProcessResponse(
    const GURL& response_url,
    network::mojom::URLResponseHead* response_head,
    bool* /*defer*/) {
  BlinkerWebRequestNotifyResponse(
      web_request_id_, response_url,
      response_head ? response_head->headers.get() : nullptr, document_url_,
      type_, tab_id_,
      response_head ? response_head->was_fetched_via_cache : false);
  BlinkerExtensionNetActions& actions =
      BlinkerExtensionNetActions::GetInstance();
  if (actions.empty() || !response_head || !response_head->headers) {
    return;
  }
  std::vector<BlinkerHeaderOp> ops;
  actions.CollectHeaderOps(response_url, document_url_, type_,
                           /*response=*/true, &ops);
  for (const BlinkerHeaderOp& op : ops) {
    switch (op.op) {
      case BlinkerHeaderOp::Op::kRemove:
        response_head->headers->RemoveHeader(op.name);
        break;
      case BlinkerHeaderOp::Op::kSet:
        response_head->headers->SetHeader(op.name, op.value);
        break;
      case BlinkerHeaderOp::Op::kAppend:
        // Append, бо другий Content-Security-Policy діє разом з першим
        response_head->headers->AddHeader(op.name, op.value);
        break;
    }
  }
}

void BlinkerContentFilterThrottle::WillRedirectRequest(
    net::RedirectInfo* redirect_info,
    const network::mojom::URLResponseHead& response_head,
    bool* defer,
    network::HttpRequestHeadersUpdateParams* /*headers_update_params*/) {
  if (!redirect_info) {
    return;
  }
  BlinkerWebRequestNotifyRedirect(
      web_request_id_, request_url_, redirect_info->new_url,
      response_head.headers ? response_head.headers->response_code() : 0,
      document_url_, type_, tab_id_);
  request_url_ = redirect_info->new_url;
  BlinkerContentFilter& filter = BlinkerContentFilter::GetInstance();
  if (!filter.ShouldBlock(redirect_info->new_url, document_url_, type_)) {
    return;
  }
  filter.RecordBlocked(document_url_.has_host() ? document_url_.host()
                                                : std::string());
  delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT,
                             "Blocked by Blinker Fluid content filter");
}

}  // namespace content

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

extern "C" unsigned long long BlinkAdBlockBlockedCountForHost(
    const char* host) {
  return host ? content::BlinkerContentFilter::GetInstance()
                    .blocked_count_for_host(host)
              : 0;
}

extern "C" void BlinkAdBlockResetHostCount(const char* host) {
  if (host) {
    content::BlinkerContentFilter::GetInstance().ResetHostCount(host);
  }
}

extern "C" bool BlinkAdBlockHostAllowlisted(const char* host) {
  return host && content::BlinkerContentFilter::GetInstance().IsHostAllowlisted(
                     host);
}

extern "C" void BlinkAdBlockSetHostAllowlisted(const char* host,
                                               bool allowlisted) {
  if (host) {
    content::BlinkerContentFilter::GetInstance().SetHostAllowlisted(
        host, allowlisted);
  }
}
