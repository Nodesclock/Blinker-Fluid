// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef THIRD_PARTY_BLINK_PUBLIC_COMMON_LOADER_BLINKER_REQUEST_REDIRECT_H_
#define THIRD_PARTY_BLINK_PUBLIC_COMMON_LOADER_BLINKER_REQUEST_REDIRECT_H_

#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "third_party/blink/public/common/common_export.h"
#include "url/gurl.h"

namespace blink {

// Хук для `redirect` з declarativeNetRequest. URLLoaderThrottle не вміє
// редіректити http(s) на іншу схему, тому підміна тут

using BlinkerRequestRedirectHook =
    GURL (*)(const GURL& url,
             network::mojom::RequestDestination destination,
             const GURL& document_url);

// Ставити один раз і рано, вказівник читають всі потоки що запускають fetch
BLINK_COMMON_EXPORT void SetBlinkerRequestRedirectHook(
    BlinkerRequestRedirectHook hook);

BLINK_COMMON_EXPORT GURL ApplyBlinkerRequestRedirect(
    const GURL& url,
    network::mojom::RequestDestination destination,
    const GURL& document_url);

}  // namespace blink

#endif  // THIRD_PARTY_BLINK_PUBLIC_COMMON_LOADER_BLINKER_REQUEST_REDIRECT_H_
