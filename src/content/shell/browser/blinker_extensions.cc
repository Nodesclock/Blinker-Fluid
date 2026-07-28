// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extensions.h"

#include <CoreFoundation/CoreFoundation.h>

#include <string>
#include <string_view>

#include "base/functional/callback_helpers.h"
#include "base/json/string_escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "url/gurl.h"

extern "C" void BlinkBootLog(const char* stage);

namespace content {
namespace {

constexpr int32_t kBlinkerZoomWorld = ISOLATED_WORLD_ID_CONTENT_END + 2;
constexpr int32_t kBlinkerCosmeticWorld = ISOLATED_WORLD_ID_CONTENT_END + 3;

// Per-host page-zoom percentage, stored in the app's user defaults under
// "BlinkZoom_<host>". Chromium's HostZoomMap is not applied by the renderer on
// this iOS content_shell, so zoom is driven directly via CSS instead.
int ReadHostZoom(std::string_view host) {
  int percent = 100;
  const std::string key_str = "BlinkZoom_" + std::string(host);
  CFStringRef key = CFStringCreateWithCString(
      kCFAllocatorDefault, key_str.c_str(), kCFStringEncodingUTF8);
  if (CFPropertyListRef value =
          CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType,
                       &percent);
    }
    CFRelease(value);
  }
  CFRelease(key);
  return percent;
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
  std::string value = percent == 100 ? "''" : base::NumberToString(percent / 100.0);
  std::u16string script = base::UTF8ToUTF16(
      "(()=>{const z=" + value +
      ";const run=()=>{if(document.documentElement)"
      "document.documentElement.style.zoom=z;};run();"
      "document.readyState==='loading'?"
      "document.addEventListener('DOMContentLoaded',run,{once:true}):run();})()");
  frame->ExecuteJavaScriptInIsolatedWorld(script, base::NullCallback(),
                                          kBlinkerZoomWorld);
}

void BlinkApplyPageZoom(WebContents* contents, const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS()) {
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
      "document.addEventListener('DOMContentLoaded',run,{once:true}):void 0;})()");
  frame->ExecuteJavaScriptInIsolatedWorld(script, base::NullCallback(),
                                          kBlinkerCosmeticWorld);
}

}  // namespace content
