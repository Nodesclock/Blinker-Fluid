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
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/system/sys_info.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_site_policy.h"
#include "services/network/public/mojom/clear_data_filter.mojom.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace content {

const std::string& BlinkDesktopUserAgent() {
  static const base::NoDestructor<std::string> ua(base::StringPrintf(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36",
      CONTENT_SHELL_MAJOR_VERSION));
  return *ua;
}

int BlinkUserAgentIdentity() {
  Boolean valid = false;
  const CFIndex value = CFPreferencesGetAppIntegerValue(
      CFSTR("BlinkUserAgentIdentity"), kCFPreferencesCurrentApplication,
      &valid);
  return valid && value >= kBlinkIdentityChromeAndroid &&
                 value <= kBlinkIdentityChromeIOS
             ? static_cast<int>(value)
             : kBlinkIdentityChromeAndroid;
}

std::string BlinkIdentityUserAgent(int identity) {
  if (identity != kBlinkIdentitySafariIOS &&
      identity != kBlinkIdentityChromeIOS) {
    return std::string();
  }
  int32_t major = 0;
  int32_t minor = 0;
  int32_t bugfix = 0;
  base::SysInfo::OperatingSystemVersionNumbers(&major, &minor, &bugfix);
  const std::string os =
      bugfix ? base::StringPrintf("%d_%d_%d", major, minor, bugfix)
             : base::StringPrintf("%d_%d", major, minor);
  const std::string device =
      base::StartsWith(base::SysInfo::HardwareModelName(), "iPad")
          ? "iPad; CPU OS " + os
          : "iPhone; CPU iPhone OS " + os;
  const std::string browser =
      identity == kBlinkIdentitySafariIOS
          ? base::StringPrintf("Version/%d.%d", major, minor)
          : std::string("CriOS/") + CONTENT_SHELL_VERSION;
  return "Mozilla/5.0 (" + device +
         " like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " +
         browser + " Mobile/15E148 Safari/604.1";
}

namespace {

constexpr int32_t kBlinkerCosmeticWorld = ISOLATED_WORLD_ID_CONTENT_END + 3;

base::apple::ScopedCFTypeRef<CFStringRef> HostPreferenceKey(
    std::string_view prefix,
    std::string_view host) {
  const std::string name = std::string(prefix) + std::string(host);
  return base::apple::ScopedCFTypeRef<CFStringRef>(CFStringCreateWithCString(
      kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8));
}

}  // namespace

int BlinkDefaultZoomPercent() {
  const CFIndex value = CFPreferencesGetAppIntegerValue(
      CFSTR("BlinkDefaultZoom"), kCFPreferencesCurrentApplication, nullptr);
  return value >= 50 && value <= 300 ? static_cast<int>(value) : 100;
}

namespace {

// HostZoomMap рендерер на iOS не застосовує, тому зум через CSS
int ReadHostZoom(std::string_view host) {
  int percent = BlinkDefaultZoomPercent();
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

// Три стани навмисно, відсутній ключ значить що користувач не обирав
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

bool IsIdentityUserAgent(const std::string& ua) {
  return ua == BlinkIdentityUserAgent(kBlinkIdentitySafariIOS) ||
         ua == BlinkIdentityUserAgent(kBlinkIdentityChromeIOS);
}

// Ідентичність iOS без метаданих, щоб не слати UA client hints, як Safari
void ApplySiteModeOverride(WebContents* contents, bool desktop) {
  blink::UserAgentOverride override;
  if (desktop) {
    override.ua_string_override = BlinkDesktopUserAgent();
    override.ua_metadata_override =
        GetShellUserAgentMetadataForSiteMode(/*desktop=*/true);
  } else {
    override.ua_string_override =
        BlinkIdentityUserAgent(BlinkUserAgentIdentity());
  }
  if (contents->GetUserAgentOverride() == override) {
    return;
  }
  contents->SetUserAgentOverride(override, /*override_in_new_tabs=*/true);
  contents->NotifyPreferencesChanged();
}

}  // namespace

int BlinkerPageZoomPercent(WebContents* contents) {
  if (!contents) {
    return 100;
  }
  const GURL url = contents->GetLastCommittedURL();
  if (!url.has_host() || contents->GetBrowserContext()->IsOffTheRecord()) {
    return 100;
  }
  return ReadHostZoom(url.host());
}

void BlinkerSetPageZoomPercent(WebContents* contents, int percent) {
  if (!contents) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  // Ключ містить хост і лишав би слід, тому в приватній вкладці не пишемо
  if (url.has_host() && !contents->GetBrowserContext()->IsOffTheRecord()) {
    if (auto key = HostPreferenceKey("BlinkZoom_", url.host())) {
      base::apple::ScopedCFTypeRef<CFNumberRef> value(
          CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &percent));
      CFPreferencesSetAppValue(key.get(), value.get(),
                               kCFPreferencesCurrentApplication);
      CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }
  }
  BlinkSetPageZoom(contents, percent);
}

namespace {

// Справжній масштаб Chromium, як у Chrome на комп'ютері. CSS zoom на html
// множив і vw та vh, тож елемент на 100vh ставав більшим за екран, а так
// сторінка сама бачить менший вʼюпорт. Рівень хоста діє і на нові документи
// ще до першого кадру, і на інші вкладки того ж сайту. Рівень 0 стирає запис.
void SetHostZoom(WebContents* contents, const std::string& host, int percent) {
  HostZoomMap* zoom_map =
      contents ? HostZoomMap::GetForWebContents(contents) : nullptr;
  if (!zoom_map || host.empty()) {
    return;
  }
  const double level =
      percent == 100 ? 0.0 : blink::ZoomFactorToZoomLevel(percent / 100.0);
  zoom_map->SetZoomLevelForHost(host, level);
}

}  // namespace

void BlinkSetPageZoom(WebContents* contents, int percent) {
  if (!contents) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  if (url.SchemeIsHTTPOrHTTPS() && url.has_host()) {
    SetHostZoom(contents, std::string(url.host()), percent);
  }
}

void BlinkApplyPageZoom(WebContents* contents, const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS() || !url.has_host()) {
    return;
  }
  // В приватній сесії масштаб сайтів не читаємо, щоб не видавати звичайну
  // історію
  const int percent =
      contents && contents->GetBrowserContext() &&
              contents->GetBrowserContext()->IsOffTheRecord()
          ? BlinkDefaultZoomPercent()
          : ReadHostZoom(url.host());
  SetHostZoom(contents, std::string(url.host()), percent);
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
  // На коміті <head> може ще не бути, тому повтор на DOMContentLoaded
  std::u16string script = base::UTF8ToUTF16(
      "(()=>{const run=()=>{if(!document.documentElement)return;"
      "const s=document.querySelector('style[data-blinker-cosmetic]')||"
      "document.createElement('style');"
      "s.dataset.blinkerCosmetic='1';s.textContent=" +
      escaped +
      ";(document.head||document.documentElement).appendChild(s);};run();"
      "document.readyState==='loading'?"
      "document.addEventListener('DOMContentLoaded',run,{once:true}):void "
      "0;})()");
  frame->ExecuteJavaScriptInIsolatedWorld(script, base::NullCallback(),
                                          kBlinkerCosmeticWorld);
}

bool BlinkIsDesktopSite(WebContents* contents) {
  return contents && contents->GetUserAgentOverride().ua_string_override ==
                         BlinkDesktopUserAgent();
}

void BlinkApplyIdentity(WebContents* contents) {
  if (!contents) {
    return;
  }
  const std::string& current =
      contents->GetUserAgentOverride().ua_string_override;
  if (current.empty() || IsIdentityUserAgent(current)) {
    ApplySiteModeOverride(contents, /*desktop=*/false);
  }
}

GURL BlinkURLForSiteMode(const GURL& url, bool desktop) {
  if (!desktop || !url.SchemeIsHTTPOrHTTPS()) {
    return url;
  }
  const std::string host = blinker_sites::DesktopHost(url.host());
  if (host == url.host()) {
    return url;
  }
  GURL::Replacements replacements;
  replacements.SetHostStr(host);
  return url.ReplaceComponents(replacements);
}

void BlinkSetSiteMode(WebContents* contents, const GURL& url, bool desktop) {
  if (!contents) {
    return;
  }
  if (url.SchemeIsHTTPOrHTTPS() &&
      !contents->GetBrowserContext()->IsOffTheRecord()) {
    WriteHostFlag("BlinkDesktopMode_",
                  blinker_sites::SiteModePreferenceHost(url.host()),
                  desktop);
  }
  ApplySiteModeOverride(contents, desktop);
}

void BlinkApplySiteMode(WebContents* contents, const GURL& url) {
  if (!contents || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) {
    return;
  }
  HostFlag stored = HostFlag::kUnset;
  if (!contents->GetBrowserContext()->IsOffTheRecord()) {
    const std::string_view host = url.host();
    const std::string preference_host =
        blinker_sites::SiteModePreferenceHost(host);
    stored = ReadHostFlag("BlinkDesktopMode_", preference_host);
    if (stored == HostFlag::kUnset && preference_host != host) {
      stored = ReadHostFlag("BlinkDesktopMode_", host);
    }
  }
  if (stored == HostFlag::kUnset) {
    BlinkApplyIdentity(contents);
    return;
  }
  ApplySiteModeOverride(contents, stored == HostFlag::kTrue);
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

void BlinkClearAllSiteData(BrowserContext* context) {
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  if (!partition) {
    return;
  }
  partition->ClearData(StoragePartition::REMOVE_DATA_MASK_ALL,
                       /*filter_builder=*/nullptr,
                       StoragePartition::StorageKeyPolicyMatcherFunction(),
                       network::mojom::CookieDeletionFilter::New(),
                       /*perform_storage_cleanup=*/true, base::Time(),
                       base::Time::Max(), base::DoNothing());
  partition->GetNetworkContext()->ClearHttpCache(
      base::Time(), base::Time::Max(), nullptr, base::DoNothing());
  BLINKER_DIAG("SITE_DATA: cleared all site data");
}

}  // namespace content
