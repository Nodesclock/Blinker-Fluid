// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "third_party/blink/public/common/loader/blinker_request_redirect.h"

#include <atomic>

namespace blink {

namespace {

std::atomic<BlinkerRequestRedirectHook>& Hook() {
  static std::atomic<BlinkerRequestRedirectHook> hook{nullptr};
  return hook;
}

}  // namespace

void SetBlinkerRequestRedirectHook(BlinkerRequestRedirectHook hook) {
  Hook().store(hook, std::memory_order_relaxed);
}

GURL ApplyBlinkerRequestRedirect(
    const GURL& url,
    network::mojom::RequestDestination destination,
    const GURL& document_url) {
  BlinkerRequestRedirectHook hook = Hook().load(std::memory_order_relaxed);
  return hook ? hook(url, destination, document_url) : GURL();
}

}  // namespace blink
