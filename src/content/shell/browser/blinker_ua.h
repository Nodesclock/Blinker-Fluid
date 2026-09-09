// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_UA_H_
#define CONTENT_SHELL_BROWSER_BLINKER_UA_H_

#include <optional>
#include <string>

namespace blink {
struct UserAgentMetadata;
}

namespace content::blinker_ua {

// The single source of truth for user-configurable User-Agent overrides.
//
// Every UA decision in the browser goes through this module:
//   - ShellContentBrowserClient::GetUserAgent() / GetUserAgentMetadata()
//     (the default UA used when creating a browser context)
//   - BlinkApplyUserAgent() on every committed navigation (re-applies the
//     override to the WebContents, mirroring BlinkApplyPageZoom)
//   - toggleDesktopSite() (the desktop/mobile menu now only switches the
//     layout; the UA string itself comes from here when an override is set)
//
// Settings are stored in the app's user defaults (same mechanism as the
// per-host page zoom) under:
//   "BlinkUAPreset"  (NSInteger, values of Preset below)
//   "BlinkUACustom"  (NSString, the raw UA string when Preset == kCustom)
//
// Preset UAs are hardcoded to the 149 series on purpose: BASE_COMMIT.txt pins
// this tree to Chromium 149.0.7821.0, and a UA whose Chrome version does not
// match the real engine (or a placeholder like the upstream "999.77.34.5")
// makes Google Sign-In / reCAPTCHA reject the browser. Keep these in sync when
// the engine is rebased.

enum class Preset : int {
  kDefault = 0,  // No override: use the browser's built-in mobile UA.
  kIPhone,       // Chrome on iPhone (CriOS token).
  kIPad,         // Chrome on iPad.
  kMac,          // Chrome on macOS (desktop).
  kWindows,      // Chrome on Windows (desktop).
  kAndroid,      // Chrome on Android (mobile).
  kCustom,       // Raw user-supplied string (BlinkUACustom).
};

// Preset name, for the Settings UI and logs (kept in English on purpose;
// these are platform names, not UI copy).
const char* PresetName(Preset preset);

// The UA string a preset maps to. Empty for kDefault (means "no override").
std::string PresetUA(Preset preset);

// The Client-Hints metadata matching a preset's UA string. Empty for
// kDefault. For kCustom there is no way to derive metadata from an arbitrary
// string, so the iPhone metadata is returned and the UI warns the user.
std::optional<blink::UserAgentMetadata> PresetMetadata(Preset preset);

// --- Single entry points used by the rest of the browser -------------------

// The currently selected preset, read from user defaults (defaults to
// kDefault when never set).
Preset GetPreset();

// The raw custom string, valid only when GetPreset() == kCustom.
std::string GetCustomUA();

// The effective override UA: the preset's UA, or the custom string, or an
// empty string when no override is configured (kDefault + empty custom).
std::string EffectiveUAOverride();

// The effective override metadata, or nullopt when no override is configured.
std::optional<blink::UserAgentMetadata> EffectiveMetadataOverride();

// Persists a preset selection (and clears the custom string when not kCustom).
void SetPreset(Preset preset);

// Persists the custom UA string (does NOT change the preset).
void SetCustomUA(const std::string& ua);

}  // namespace content::blinker_ua

#endif  // CONTENT_SHELL_BROWSER_BLINKER_UA_H_
