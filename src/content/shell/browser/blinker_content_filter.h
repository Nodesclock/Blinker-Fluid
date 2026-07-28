// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_
#define CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "base/no_destructor.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"

class GURL;

namespace content {

class BlinkerContentFilterTestPeer;

// Blinker Fluid ad/tracker blocking (network + cosmetic).
//
// Network: a request is blocked when its host, or any parent domain, is on the
// blocklist. Fed by a built-in starter set, an optional hosts file, and the
// `||host^` rules of an optional Adblock Plus / uBO / EasyList filter file.
//
// Cosmetic: `##selector` element-hiding rules from the filter file (plus a small
// built-in starter) are compiled into per-host CSS (see CosmeticCSSFor) and
// injected as a <style>, which hides ad/tracker elements the network layer can't.
//
// Rules are immutable after EnsureLoaded(), so lookups need no lock. The enabled
// flag and blocked counter are atomics, flipped from the Settings UI.
class BlinkerContentFilter {
 public:
  static BlinkerContentFilter& GetInstance();

  BlinkerContentFilter(const BlinkerContentFilter&) = delete;
  BlinkerContentFilter& operator=(const BlinkerContentFilter&) = delete;

  // Populates the blocklist from the built-in starter set plus, if present, a
  // user-supplied hosts file. Safe to call more than once; only the first call
  // does work. Reads the enabled flag from persisted settings.
  void EnsureLoaded();

  // True if blocking is on AND the URL's host is covered by the blocklist.
  bool ShouldBlock(const GURL& url) const;

  // Cosmetic filtering: the CSS to hide ad/tracker elements on `host`, i.e. the
  // generic element-hiding rules plus any rules scoped to `host` (or a parent
  // domain), minus per-host exceptions. Empty when there is nothing to hide or
  // the filter is disabled. Injected as a <style> on each committed page.
  std::string CosmeticCSSFor(std::string_view host) const;

  bool enabled() const;
  void SetEnabled(bool enabled);

  // Total requests blocked this session, for the Settings UI.
  uint64_t blocked_count() const;
  void RecordBlocked();

  size_t rule_count() const { return blocked_hosts_.size(); }

 private:
  BlinkerContentFilter();
  ~BlinkerContentFilter();

  void AddHost(std::string_view host);
  void LoadBuiltinList();
  void LoadUserListFromDisk();
  // Parses one line of Adblock Plus / uBO / EasyList filter syntax: `||host^`
  // network rules feed AddHost, `##`/`#@#` cosmetic rules feed the hide maps.
  // Unsupported forms (regex, `$` options, procedural `#?#`) are ignored.
  void ParseFilterLine(std::string_view line);
  void LoadFilterListsFromDisk();

  std::unordered_set<std::string> blocked_hosts_;
  // Cosmetic element-hiding rules. Generic rules apply to every page; the maps
  // are keyed by the domain the rule is scoped to (`domain##sel` / `domain#@#sel`).
  std::vector<std::string> generic_hide_selectors_;
  std::unordered_map<std::string, std::vector<std::string>> host_hide_selectors_;
  std::unordered_map<std::string, std::vector<std::string>> host_hide_exceptions_;
  // The generic selectors pre-joined into a comma list once at load, so each
  // page only appends its (small) host-specific selectors.
  std::string generic_hide_css_;
  bool loaded_ = false;

  friend class base::NoDestructor<BlinkerContentFilter>;
  friend class BlinkerContentFilterTestPeer;
};

// URLLoaderThrottle that cancels requests the filter blocks. One is added per
// request by ShellContentBrowserClient::CreateURLLoaderThrottles.
class BlinkerContentFilterThrottle : public blink::URLLoaderThrottle {
 public:
  BlinkerContentFilterThrottle();
  ~BlinkerContentFilterThrottle() override;

  // blink::URLLoaderThrottle:
  void DetachFromCurrentSequence() override;
  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override;
  void WillRedirectRequest(
      net::RedirectInfo* redirect_info,
      const network::mojom::URLResponseHead& response_head,
      bool* defer,
      std::vector<std::string>* to_be_removed_request_headers,
      net::HttpRequestHeaders* modified_request_headers,
      net::HttpRequestHeaders* modified_cors_exempt_request_headers) override;
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_
