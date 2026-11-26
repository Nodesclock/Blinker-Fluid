// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_client_hints.h"

#include "content/shell/browser/shell_content_browser_client.h"
#include "third_party/blink/public/common/client_hints/enabled_client_hints.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"

namespace content {

namespace {
constexpr size_t kMaxPersistedOrigins = 512;
}  // namespace

BlinkerClientHints::BlinkerClientHints(bool off_the_record)
    : off_the_record_(off_the_record) {}

BlinkerClientHints::~BlinkerClientHints() = default;

network::NetworkQualityTracker* BlinkerClientHints::GetNetworkQualityTracker() {
  return nullptr;
}

void BlinkerClientHints::GetAllowedClientHintsFromSource(
    const url::Origin& origin,
    blink::EnabledClientHints* client_hints) {
  if (const auto it = persisted_.find(origin); it != persisted_.end()) {
    for (network::mojom::WebClientHintsType type : it->second) {
      client_hints->SetIsEnabled(type, true);
    }
  }
  for (network::mojom::WebClientHintsType type : additional_) {
    client_hints->SetIsEnabled(type, true);
  }
}

bool BlinkerClientHints::IsJavaScriptAllowed(const GURL& url,
                                             RenderFrameHost* parent_rfh) {
  return true;
}

blink::UserAgentMetadata BlinkerClientHints::GetUserAgentMetadata() {
  return GetShellUserAgentMetadata();
}

void BlinkerClientHints::PersistClientHints(
    const url::Origin& primary_origin,
    RenderFrameHost* parent_rfh,
    const std::vector<network::mojom::WebClientHintsType>& client_hints) {
  if (off_the_record_ || primary_origin.opaque()) {
    return;
  }
  if (client_hints.empty()) {
    persisted_.erase(primary_origin);
    return;
  }
  if (persisted_.size() >= kMaxPersistedOrigins &&
      !persisted_.contains(primary_origin)) {
    persisted_.erase(persisted_.begin());
  }
  persisted_[primary_origin] = client_hints;
}

void BlinkerClientHints::SetAdditionalClientHints(
    const std::vector<network::mojom::WebClientHintsType>& hints) {
  additional_ = hints;
}

void BlinkerClientHints::ClearAdditionalClientHints() {
  additional_.clear();
}

void BlinkerClientHints::SetMostRecentMainFrameViewportSize(
    const gfx::Size& viewport_size) {
  viewport_size_ = viewport_size;
}

gfx::Size BlinkerClientHints::GetMostRecentMainFrameViewportSize() {
  return viewport_size_;
}

}  // namespace content
