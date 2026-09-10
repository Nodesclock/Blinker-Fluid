// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_

class GURL;

namespace content {

class WebContents;

// The user agent sent while desktop mode is on. Shared so the toggle and the
// per-navigation restore below cannot drift apart.
extern const char kBlinkDesktopUserAgent[];

// Applies the per-host page-zoom (stored under "BlinkZoom_<host>" in user
// defaults) to `contents` by setting the root element's CSS zoom. Called on
// every committed navigation.
void BlinkApplyPageZoom(WebContents* contents, const GURL& url);

// Applies `percent` to `contents` immediately, without reading the stored pref
// (used when the user picks a zoom, to avoid a stale cfprefsd read-after-write).
void BlinkSetPageZoom(WebContents* contents, int percent);

// Injects the content filter's element-hiding CSS (cosmetic ad/tracker filtering)
// for the page's host. Called on every committed navigation.
void BlinkInjectCosmeticFilters(WebContents* contents, const GURL& url);

// Applies the per-host desktop-mode choice (stored under
// "BlinkDesktopMode_<host>") to `contents`. The toggle already recorded the
// preference per host but nothing read it back, so desktop mode was lost on
// the next navigation and on relaunch. Called on every committed navigation.
void BlinkApplySiteMode(WebContents* contents, const GURL& url);

// Clears cookies, storage and cache for a single origin, leaving every other
// site signed in. Backs the per-site "Clear Data" action.
void BlinkClearSiteData(WebContents* contents, const GURL& url);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
