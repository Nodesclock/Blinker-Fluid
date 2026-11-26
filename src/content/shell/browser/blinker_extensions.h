// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_

#include <string>
#include <string_view>

class GURL;

namespace content {

class BrowserContext;
class WebContents;

const std::string& BlinkDesktopUserAgent();

enum BlinkUserAgentIdentityKind {
  kBlinkIdentityChromeAndroid = 0,
  kBlinkIdentitySafariIOS = 1,
  kBlinkIdentityChromeIOS = 2,
};

int BlinkUserAgentIdentity();

// Для Chrome на Android порожній рядок, це і так UA за замовчуванням
std::string BlinkIdentityUserAgent(int identity);

void BlinkApplyIdentity(WebContents* contents);

bool BlinkIsDesktopSite(WebContents* contents);

void BlinkSetSiteMode(WebContents* contents, const GURL& url, bool desktop);

GURL BlinkURLForSiteMode(const GURL& url, bool desktop);

void BlinkApplyPageZoom(WebContents* contents, const GURL& url);

// Не читає збережене значення, бо cfprefsd одразу після запису віддає старе
void BlinkSetPageZoom(WebContents* contents, int percent);
int BlinkDefaultZoomPercent();

int BlinkerPageZoomPercent(WebContents* contents);

// Ще й запам'ятовує для хоста, інакше наступна навігація скине
// chrome.tabs.setZoom
void BlinkerSetPageZoomPercent(WebContents* contents, int percent);

std::string BlinkerSearchURLForQuery(std::string_view query);

void BlinkInjectCosmeticFilters(WebContents* contents, const GURL& url);

// Приватні вкладки звичайний профіль не читають і не пишуть
void BlinkApplySiteMode(WebContents* contents, const GURL& url);

void BlinkClearSiteData(WebContents* contents, const GURL& url);
void BlinkClearAllSiteData(BrowserContext* context);

void BlinkerApplySecureDnsSetting();
bool BlinkerIsValidSecureDnsTemplate(const std::string& value);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
