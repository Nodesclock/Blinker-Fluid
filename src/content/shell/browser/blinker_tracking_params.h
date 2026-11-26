// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_TRACKING_PARAMS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_TRACKING_PARAMS_H_

#include "third_party/blink/public/common/loader/url_loader_throttle.h"

namespace content {

void BlinkerSetTrackingParamStripping(bool enabled);
bool BlinkerTrackingParamStrippingEnabled();

class BlinkerTrackingParamThrottle : public blink::URLLoaderThrottle {
 public:
  BlinkerTrackingParamThrottle();
  ~BlinkerTrackingParamThrottle() override;

  void DetachFromCurrentSequence() override;
  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override;
  void WillRedirectRequest(
      net::RedirectInfo* redirect_info,
      const network::mojom::URLResponseHead& response_head,
      bool* defer,
      network::HttpRequestHeadersUpdateParams* headers_update_params) override;

 private:
  bool is_document_ = false;
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_TRACKING_PARAMS_H_
