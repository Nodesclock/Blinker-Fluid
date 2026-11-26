// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_WEB_REQUEST_H_
#define CONTENT_SHELL_BROWSER_BLINKER_WEB_REQUEST_H_

#include <string>
#include <string_view>
#include <vector>

#include "base/values.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "url/gurl.h"

namespace net {
class HttpResponseHeaders;
}

namespace network {
struct ResourceRequest;
}

namespace content {

// chrome.webRequest без блокування, як у MV3, бо деякі розширення без нього
// падають на старті воркера. Фільтри зіставляє браузер, а не кожен слухач.

struct BlinkerWebRequestFilter {
  BlinkerWebRequestFilter();
  BlinkerWebRequestFilter(const BlinkerWebRequestFilter&);
  ~BlinkerWebRequestFilter();

  std::string extension_id;
  std::string event;  // "onBeforeRequest" тощо
  std::vector<std::string> urls;  // match patterns, пусто це всі URL
  std::vector<std::string> types;  // пусто це всі типи
  bool extra_headers = false;
};

void BlinkerWebRequestAddListener(const BlinkerWebRequestFilter& filter);
void BlinkerWebRequestRemoveListeners(std::string_view extension_id,
                                      std::string_view event);

// Перевіряється на кожен запит, тому коли ніхто не слухає це одне атомарне
// читання.
bool BlinkerWebRequestHasListeners();

// `request_id` зв'язує події одного запиту, як requestId у Chrome.
void BlinkerWebRequestNotifyStart(uint64_t request_id,
                                  const network::ResourceRequest& request,
                                  const GURL& document_url,
                                  BlinkerResourceType type,
                                  int tab_id);
void BlinkerWebRequestNotifyRedirect(uint64_t request_id,
                                     const GURL& from_url,
                                     const GURL& to_url,
                                     int status_code,
                                     const GURL& document_url,
                                     BlinkerResourceType type,
                                     int tab_id);
void BlinkerWebRequestNotifyResponse(uint64_t request_id,
                                     const GURL& url,
                                     const net::HttpResponseHeaders* headers,
                                     const GURL& document_url,
                                     BlinkerResourceType type,
                                     int tab_id,
                                     bool from_cache);
void BlinkerWebRequestNotifyError(uint64_t request_id,
                                  const GURL& url,
                                  const std::string& error,
                                  const GURL& document_url,
                                  BlinkerResourceType type,
                                  int tab_id);

std::string BlinkerWebRequestShim();

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_WEB_REQUEST_H_
