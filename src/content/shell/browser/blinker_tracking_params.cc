// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_tracking_params.h"

#include <atomic>

#include "content/shell/common/blinker_tracking_query.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "url/gurl.h"

namespace content {

namespace {

std::atomic<bool> g_strip_enabled{false};

bool CleanURL(GURL* url) {
  if (!url->is_valid() || !url->SchemeIsHTTPOrHTTPS() || !url->has_query()) {
    return false;
  }
  std::string query;
  if (!BlinkerStripTrackingParams(url->query(), &query)) {
    return false;
  }
  GURL::Replacements replacements;
  if (query.empty()) {
    replacements.ClearQuery();
  } else {
    replacements.SetQueryStr(query);
  }
  *url = url->ReplaceComponents(replacements);
  return true;
}

}  // namespace

void BlinkerSetTrackingParamStripping(bool enabled) {
  g_strip_enabled.store(enabled, std::memory_order_relaxed);
}

bool BlinkerTrackingParamStrippingEnabled() {
  return g_strip_enabled.load(std::memory_order_relaxed);
}

BlinkerTrackingParamThrottle::BlinkerTrackingParamThrottle() = default;
BlinkerTrackingParamThrottle::~BlinkerTrackingParamThrottle() = default;

void BlinkerTrackingParamThrottle::DetachFromCurrentSequence() {}

void BlinkerTrackingParamThrottle::WillStartRequest(
    network::ResourceRequest* request,
    bool* defer) {
  is_document_ =
      request->destination == network::mojom::RequestDestination::kDocument;
  if (is_document_ && BlinkerTrackingParamStrippingEnabled()) {
    CleanURL(&request->url);
  }
}

void BlinkerTrackingParamThrottle::WillRedirectRequest(
    net::RedirectInfo* redirect_info,
    const network::mojom::URLResponseHead& response_head,
    bool* defer,
    network::HttpRequestHeadersUpdateParams* headers_update_params) {
  // Посилання з пошуку і соцмереж часто додають мітки саме на редиректі
  if (is_document_ && BlinkerTrackingParamStrippingEnabled()) {
    CleanURL(&redirect_info->new_url);
  }
}

}  // namespace content
