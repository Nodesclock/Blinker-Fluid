// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extensions.h"

#include <CoreFoundation/CoreFoundation.h>

#include <string>
#include <string_view>

#include "base/apple/scoped_cftyperef.h"
#include "base/functional/callback_helpers.h"
#include "base/json/string_escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace content {

const char kBlinkDesktopUserAgent[] =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

namespace {

constexpr int32_t kBlinkerZoomWorld = ISOLATED_WORLD_ID_CONTENT_END + 2;
constexpr int32_t kBlinkerCosmeticWorld = ISOLATED_WORLD_ID_CONTENT_END + 3;

base::apple::ScopedCFTypeRef<CFStringRef> HostPreferenceKey(
    std::string_view prefix,
    std::string_view host) {
  const std::string name = std::string(prefix) + std::string(host);
  return base::apple::ScopedCFTypeRef<CFStringRef>(CFStringCreateWithCString(
      kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8));
}

// Per-host page-zoom percentage, stored in the app's user defaults under
// "BlinkZoom_<host>". Chromium's HostZoomMap is not applied by the renderer on
// this iOS content_shell, so zoom is driven directly via CSS instead.
int ReadHostZoom(std::string_view host) {
  int percent = 100;
  auto key = HostPreferenceKey("BlinkZoom_", host);
  if (!key) {
    return percent;
  }
  base::apple::ScopedCFTypeRef<CFPropertyListRef> value(
      CFPreferencesCopyAppValue(key.get(), kCFPreferencesCurrentApplication));
  if (value) {
    if (CFGetTypeID(value.get()) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(value.get()), kCFNumberIntType,
                       &percent);
    }
  }
  return percent;
}

// Per-host boolean stored the same way, e.g. "BlinkDesktopMode_<host>".
// Tri-state on purpose: an absent key means the user has expressed no opinion
// about this host, which is not the same as having chosen mobile. Collapsing
// the two clears a desktop override the moment a site redirects to a host the
// user never toggled -- m.youtube.com to www.youtube.com being exactly that.
enum class HostFlag { kUnset, kFalse, kTrue };

HostFlag ReadHostFlag(std::string_view prefix, std::string_view host) {
  HostFlag result = HostFlag::kUnset;
  auto key = HostPreferenceKey(prefix, host);
  if (!key) {
    return result;
  }
  base::apple::ScopedCFTypeRef<CFPropertyListRef> value(
      CFPreferencesCopyAppValue(key.get(), kCFPreferencesCurrentApplication));
  if (value) {
    if (CFGetTypeID(value.get()) == CFBooleanGetTypeID()) {
      result = CFBooleanGetValue(static_cast<CFBooleanRef>(value.get()))
                   ? HostFlag::kTrue
                   : HostFlag::kFalse;
    }
  }
  return result;
}

void WriteHostFlag(std::string_view prefix, std::string_view host, bool set) {
  auto key = HostPreferenceKey(prefix, host);
  if (!key) {
    return;
  }
  CFPreferencesSetAppValue(key.get(), set ? kCFBooleanTrue : kCFBooleanFalse,
                           kCFPreferencesCurrentApplication);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

}  // namespace

void BlinkSetPageZoom(WebContents* contents, int percent) {
  if (!contents) {
    return;
  }
  RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    return;
  }
  // Set the root element's CSS zoom. 100% clears it so sites that rely on the
  // default are unaffected. Runs in an isolated world (shares the page DOM) and
  // re-asserts on DOMContentLoaded in case the page replaces documentElement.
  std::string value =
      percent == 100 ? "''" : base::NumberToString(percent / 100.0);
  std::u16string script =
      base::UTF8ToUTF16("(()=>{const z=" + value +
                        ";const run=()=>{if(document.documentElement)"
                        "document.documentElement.style.zoom=z;};run();"
                        "document.readyState==='loading'?"
                        "document.addEventListener('DOMContentLoaded',run,{"
                        "once:true}):run();})()");
  frame->ExecuteJavaScriptInIsolatedWorld(script, base::NullCallback(),
                                          kBlinkerZoomWorld);
}

void BlinkApplyPageZoom(WebContents* contents, const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  // A private session neither stores nor restores per-site zoom, so it can't be
  // used to tell which sites were visited normally.
  if (contents && contents->GetBrowserContext() &&
      contents->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  BlinkSetPageZoom(contents, ReadHostZoom(url.host()));
}

void BlinkInjectCosmeticFilters(WebContents* contents, const GURL& url) {
  if (!contents || !url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  std::string css =
      BlinkerContentFilter::GetInstance().CosmeticCSSFor(url.host());
  if (css.empty()) {
    return;
  }
  RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    return;
  }
  std::string escaped;
  base::EscapeJSONString(css, /*put_in_quotes=*/true, &escaped);
  // Append the element-hiding rules as a <style>. Runs in an isolated world (it
  // shares the page DOM) and re-asserts on DOMContentLoaded in case <head> did
  // not exist yet at commit.
  std::u16string script = base::UTF8ToUTF16(
      "(()=>{const run=()=>{const s=document.createElement('style');"
      "s.dataset.blinkerCosmetic='1';s.textContent=" +
      escaped +
      ";(document.head||document.documentElement).appendChild(s);};run();"
      "document.readyState==='loading'?"
      "document.addEventListener('DOMContentLoaded',run,{once:true}):void "
      "0;})()");
  frame->ExecuteJavaScriptInIsolatedWorld(script, base::NullCallback(),
                                          kBlinkerCosmeticWorld);
}

void BlinkApplySiteMode(WebContents* contents, const GURL& url) {
  if (!contents || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) {
    return;
  }
  const HostFlag stored = ReadHostFlag("BlinkDesktopMode_", url.host());
  const bool active =
      !contents->GetUserAgentOverride().ua_string_override.empty();

  if (stored == HostFlag::kUnset) {
    // No opinion for this host. Leave the current override alone, and if one is
    // active, record it here so the choice survives the redirect that brought
    // us to this host and applies on a later direct visit.
    if (active) {
      WriteHostFlag("BlinkDesktopMode_", url.host(), true);
    }
    g_force_desktop_site = active ? 1 : 0;
    return;
  }

  const bool desktop = stored == HostFlag::kTrue;
  g_force_desktop_site = desktop ? 1 : 0;
  if (desktop == active) {
    // Already in the right mode; setting the override again would restart the
    // navigation that just committed.
    return;
  }
  blink::UserAgentOverride override;
  if (desktop) {
    override.ua_string_override = kBlinkDesktopUserAgent;
    override.ua_metadata_override =
        GetShellUserAgentMetadataForSiteMode(/*desktop=*/true);
  }
  contents->SetUserAgentOverride(override, /*override_in_new_tabs=*/true);
  contents->NotifyPreferencesChanged();
  BLINKER_DIAG(desktop ? "SITE_MODE: per-site desktop restored"
                       : "SITE_MODE: per-site mobile restored");
}

void BlinkClearSiteData(WebContents* contents, const GURL& url) {
  if (!contents || !url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  StoragePartition* partition =
      contents->GetBrowserContext()->GetDefaultStoragePartition();
  if (!partition) {
    return;
  }
  const url::Origin origin = url::Origin::Create(url);
  partition->ClearData(StoragePartition::REMOVE_DATA_MASK_ALL,
                       blink::StorageKey::CreateFirstParty(origin),
                       base::Time(), base::Time::Max(), base::DoNothing());
  BLINKER_DIAG("SITE_DATA: cleared data for current site");
}

}  // namespace content
