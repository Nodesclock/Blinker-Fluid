// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_ua.h"

#include <CoreFoundation/CoreFoundation.h>

#include <array>
#include <string>
#include <string_view>

#include "base/strings/string_printf.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"

namespace content::blinker_ua {

namespace {

// The engine this tree is synced to (see BASE_COMMIT.txt). Hardcoded on
// purpose so this module does not depend on the content_shell placeholder
// version leaking into the UA.
constexpr char kEngineVersion[] = "149.0.7821.0";
constexpr char kEngineMajor[] = "149";

// Versions below are chosen to be *plausible real-world combinations* for the
// platform each preset claims, all on the 149 series so the engine, the UA
// string and the client hints agree with each other.
constexpr char kIPhoneUA[] =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.7821.0 "
    "Mobile/15E148 Safari/604.1";
constexpr char kIPadUA[] =
    "Mozilla/5.0 (iPad; CPU OS 15_4 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.7821.0 "
    "Mobile/15E148 Safari/604.1";
constexpr char kMacUA[] =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
constexpr char kWindowsUA[] =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
constexpr char kAndroidUA[] =
    "Mozilla/5.0 (Linux; Android 13; Pixel 7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile "
    "Safari/537.36";

// Base metadata shared by every preset: the brand list is identical for all
// (Chromium/149 + Google Chrome/149), only the platform fields vary.
blink::UserAgentMetadata BaseMetadata() {
  blink::UserAgentMetadata metadata;
  metadata.brand_version_list.emplace_back("Chromium", kEngineMajor);
  metadata.brand_version_list.emplace_back("Google Chrome", kEngineMajor);
  metadata.brand_version_list.emplace_back("Not.A.Brand", "99");
  metadata.brand_full_version_list.emplace_back("Chromium", kEngineVersion);
  metadata.brand_full_version_list.emplace_back("Google Chrome",
                                               kEngineVersion);
  metadata.brand_full_version_list.emplace_back("Not.A.Brand", "99.0.0.0");
  metadata.full_version = kEngineVersion;
  metadata.architecture = "";
  metadata.bitness = "";
  metadata.wow64 = false;
  metadata.form_factors = {"Desktop"};
  return metadata;
}

std::optional<blink::UserAgentMetadata> MetadataFor(Preset preset) {
  blink::UserAgentMetadata metadata = BaseMetadata();
  switch (preset) {
    case Preset::kIPhone:
      metadata.platform = "iOS";
      metadata.platform_version = "15.4.0";
      metadata.model = "iPhone";
      metadata.mobile = true;
      metadata.form_factors = {"Mobile"};
      return metadata;
    case Preset::kIPad:
      metadata.platform = "iOS";
      metadata.platform_version = "15.4.0";
      metadata.model = "iPad";
      metadata.mobile = true;
      metadata.form_factors = {"Mobile"};
      return metadata;
    case Preset::kMac:
      metadata.platform = "macOS";
      metadata.platform_version = "10.15.7";
      metadata.model = "";
      metadata.mobile = false;
      return metadata;
    case Preset::kWindows:
      metadata.platform = "Windows";
      metadata.platform_version = "10.0.0";
      metadata.model = "";
      metadata.mobile = false;
      return metadata;
    case Preset::kAndroid:
      metadata.platform = "Android";
      metadata.platform_version = "13.0.0";
      metadata.model = "Pixel 7";
      metadata.mobile = true;
      metadata.form_factors = {"Mobile"};
      return metadata;
    case Preset::kCustom:
      // No way to derive metadata from an arbitrary string; reuse the iPhone
      // profile (mobile) so the client hints at least stay plausible. The UI
      // tells the user this.
      metadata.platform = "iOS";
      metadata.platform_version = "15.4.0";
      metadata.model = "iPhone";
      metadata.mobile = true;
      metadata.form_factors = {"Mobile"};
      return metadata;
    case Preset::kDefault:
      return std::nullopt;
  }
  return std::nullopt;
}

// Small CFPreferences helpers, mirroring blinker_extensions.cc so all Blinker
// settings live in the app's user defaults domain.
CFStringRef KeyFor(const char* suffix) {
  return CFStringCreateWithCString(kCFAllocatorDefault, suffix,
                                   kCFStringEncodingUTF8);
}

int ReadIntSetting(const char* key, int fallback) {
  CFStringRef cf_key = KeyFor(key);
  int value = fallback;
  if (CFPropertyListRef stored =
          CFPreferencesCopyAppValue(cf_key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(stored) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(stored), kCFNumberIntType,
                       &value);
    }
    CFRelease(stored);
  }
  CFRelease(cf_key);
  return value;
}

std::string ReadStringSetting(const char* key) {
  CFStringRef cf_key = KeyFor(key);
  std::string value;
  if (CFPropertyListRef stored =
          CFPreferencesCopyAppValue(cf_key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(stored) == CFStringGetTypeID()) {
      const CFIndex len = CFStringGetLength(static_cast<CFStringRef>(stored));
      char buffer[1024];
      if (len < static_cast<CFIndex>(sizeof(buffer)) &&
          CFStringGetCString(static_cast<CFStringRef>(stored), buffer,
                             sizeof(buffer), kCFStringEncodingUTF8)) {
        value = buffer;
      }
    }
    CFRelease(stored);
  }
  CFRelease(cf_key);
  return value;
}

void WriteIntSetting(const char* key, int value) {
  CFStringRef cf_key = KeyFor(key);
  CFPreferencesSetAppValue(cf_key, CFNumberCreate(kCFAllocatorDefault,
                                                  kCFNumberIntType, &value),
                           kCFPreferencesCurrentApplication);
  CFRelease(cf_key);
}

void WriteStringSetting(const char* key, const std::string& value) {
  CFStringRef cf_key = KeyFor(key);
  CFStringRef cf_value = CFStringCreateWithCString(
      kCFAllocatorDefault, value.c_str(), kCFStringEncodingUTF8);
  CFPreferencesSetAppValue(cf_key, cf_value, kCFPreferencesCurrentApplication);
  CFRelease(cf_value);
  CFRelease(cf_key);
}

}  // namespace

const char* PresetName(Preset preset) {
  switch (preset) {
    case Preset::kDefault:
      return "Default";
    case Preset::kIPhone:
      return "iPhone";
    case Preset::kIPad:
      return "iPad";
    case Preset::kMac:
      return "Mac";
    case Preset::kWindows:
      return "Windows";
    case Preset::kAndroid:
      return "Android";
    case Preset::kCustom:
      return "Custom";
  }
  return "Default";
}

std::string PresetUA(Preset preset) {
  switch (preset) {
    case Preset::kIPhone:
      return kIPhoneUA;
    case Preset::kIPad:
      return kIPadUA;
    case Preset::kMac:
      return kMacUA;
    case Preset::kWindows:
      return kWindowsUA;
    case Preset::kAndroid:
      return kAndroidUA;
    case Preset::kDefault:
    case Preset::kCustom:
      return std::string();
  }
  return std::string();
}

std::optional<blink::UserAgentMetadata> PresetMetadata(Preset preset) {
  return MetadataFor(preset);
}

Preset GetPreset() {
  int value = ReadIntSetting("BlinkUAPreset", static_cast<int>(Preset::kDefault));
  if (value < static_cast<int>(Preset::kDefault) ||
      value > static_cast<int>(Preset::kCustom)) {
    return Preset::kDefault;
  }
  return static_cast<Preset>(value);
}

std::string GetCustomUA() {
  return ReadStringSetting("BlinkUACustom");
}

std::string EffectiveUAOverride() {
  const Preset preset = GetPreset();
  if (preset == Preset::kCustom) {
    // A custom string is only honored when non-empty; otherwise fall through
    // to no override so a half-configured setting cannot break browsing.
    const std::string custom = GetCustomUA();
    if (!custom.empty()) {
      return custom;
    }
    return std::string();
  }
  return PresetUA(preset);
}

std::optional<blink::UserAgentMetadata> EffectiveMetadataOverride() {
  const Preset preset = GetPreset();
  if (preset == Preset::kDefault) {
    return std::nullopt;
  }
  if (preset == Preset::kCustom && GetCustomUA().empty()) {
    return std::nullopt;
  }
  return MetadataFor(preset);
}

void SetPreset(Preset preset) {
  WriteIntSetting("BlinkUAPreset", static_cast<int>(preset));
  if (preset != Preset::kCustom) {
    WriteStringSetting("BlinkUACustom", std::string());
  }
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

void SetCustomUA(const std::string& ua) {
  WriteStringSetting("BlinkUACustom", ua);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

}  // namespace content::blinker_ua
