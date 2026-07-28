// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_

class GURL;

namespace content {

class WebContents;

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

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSIONS_H_
