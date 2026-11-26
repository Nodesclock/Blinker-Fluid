// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_SELECTION_COLOR_H_
#define CONTENT_SHELL_COMMON_BLINKER_SELECTION_COLOR_H_

#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>

namespace content {

inline constexpr char kBlinkerSelectionColorKey[] = "BlinkSelectionColor";
inline constexpr char kBlinkerSelectionSheetKey[] = "blinker-selection-color";
inline constexpr char kBlinkerSelectionRainbow[] = "rgb";
inline constexpr uint32_t kBlinkerSelectionDefaultRgb = 0xe04728;

inline bool BlinkerSelectionRgb(std::string_view pref, uint32_t* rgb) {
  if (pref == kBlinkerSelectionRainbow) {
    return false;
  }
  *rgb = kBlinkerSelectionDefaultRgb;
  if (pref.size() != 7 || pref[0] != '#') {
    return true;
  }
  uint32_t value = 0;
  for (size_t i = 1; i < pref.size(); ++i) {
    const char c = pref[i];
    uint32_t digit = 0;
    if (c >= '0' && c <= '9') {
      digit = c - '0';
    } else if (c >= 'a' && c <= 'f') {
      digit = c - 'a' + 10;
    } else if (c >= 'A' && c <= 'F') {
      digit = c - 'A' + 10;
    } else {
      return true;
    }
    value = value * 16 + digit;
  }
  *rgb = value;
  return true;
}

// Для веселки стиль порожній, бо каретку тоді малює Blinker
inline std::string BlinkerSelectionCss(std::string_view pref) {
  uint32_t rgb = 0;
  if (!BlinkerSelectionRgb(pref, &rgb)) {
    return std::string();
  }
  char css[160];
  std::snprintf(css, sizeof(css),
                "* { caret-color: #%06x !important; }\n"
                "::selection { background-color: rgba(%u, %u, %u, 0.35) "
                "!important; }\n",
                static_cast<unsigned>(rgb), static_cast<unsigned>(rgb >> 16),
                static_cast<unsigned>((rgb >> 8) & 0xff),
                static_cast<unsigned>(rgb & 0xff));
  return css;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_SELECTION_COLOR_H_
