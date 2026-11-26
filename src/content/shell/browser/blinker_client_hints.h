// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_CLIENT_HINTS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_CLIENT_HINTS_H_

#include <map>
#include <vector>

#include "content/public/browser/client_hints_controller_delegate.h"
#include "ui/gfx/geometry/size.h"
#include "url/origin.h"

namespace content {

// Без делегата Chromium не шле Sec-CH-UA, хоча UA каже Chrome
// Accept-CH тримаємо тільки в пам'яті
class BlinkerClientHints : public ClientHintsControllerDelegate {
 public:
  explicit BlinkerClientHints(bool off_the_record);
  BlinkerClientHints(const BlinkerClientHints&) = delete;
  BlinkerClientHints& operator=(const BlinkerClientHints&) = delete;
  ~BlinkerClientHints() override;

  network::NetworkQualityTracker* GetNetworkQualityTracker() override;
  void GetAllowedClientHintsFromSource(
      const url::Origin& origin,
      blink::EnabledClientHints* client_hints) override;
  bool IsJavaScriptAllowed(const GURL& url,
                           RenderFrameHost* parent_rfh) override;
  blink::UserAgentMetadata GetUserAgentMetadata() override;
  void PersistClientHints(
      const url::Origin& primary_origin,
      RenderFrameHost* parent_rfh,
      const std::vector<network::mojom::WebClientHintsType>& client_hints)
      override;
  void SetAdditionalClientHints(
      const std::vector<network::mojom::WebClientHintsType>& hints) override;
  void ClearAdditionalClientHints() override;
  void SetMostRecentMainFrameViewportSize(
      const gfx::Size& viewport_size) override;
  gfx::Size GetMostRecentMainFrameViewportSize() override;

 private:
  const bool off_the_record_;
  std::map<url::Origin, std::vector<network::mojom::WebClientHintsType>>
      persisted_;
  std::vector<network::mojom::WebClientHintsType> additional_;
  gfx::Size viewport_size_;
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_CLIENT_HINTS_H_
