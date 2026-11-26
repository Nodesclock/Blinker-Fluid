// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_WEB_COLORS_H_
#define CONTENT_SHELL_COMMON_BLINKER_WEB_COLORS_H_

#include <string>
#include <string_view>

#include "base/strings/string_util.h"
#include "url/gurl.h"

namespace content {

struct BlinkerWebColorOption {
  const char* name;
  const char* hex;
};

inline constexpr BlinkerWebColorOption kBlinkerWebColors[] = {
    {"Website Default", ""}, {"White", "#ffffff"},  {"Light Gray", "#c8c8cc"},
    {"Black", "#000000"},    {"Orange", "#ff7a3d"}, {"Red", "#ff453a"},
    {"Yellow", "#ffd60a"},   {"Green", "#32d74b"},  {"Blue", "#0a84ff"},
    {"Purple", "#bf5af2"},   {"Pink", "#ff375f"},
};

inline constexpr char kBlinkerWebTextColorKey[] = "BlinkWebTextColor";
inline constexpr char kBlinkerWebLinkColorKey[] = "BlinkWebLinkColor";
inline constexpr char kBlinkerWebColorsSheetKey[] = "blinker-web-colors";

// Лише #rrggbb, бо значення з налаштувань іде прямо в CSS
inline bool BlinkerIsWebColorHex(std::string_view hex) {
  if (hex.size() != 7 || hex[0] != '#') {
    return false;
  }
  for (size_t i = 1; i < hex.size(); ++i) {
    if (!base::IsHexDigit(hex[i])) {
      return false;
    }
  }
  return true;
}

inline bool BlinkerWebColorsApplyTo(const GURL& url) {
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIsFile();
}

// Важливі правила користувача сильніші за важливі правила сайту,
// колір тримається навіть проти !important
inline std::string BlinkerWebColorsCss(std::string_view text,
                                       std::string_view link) {
  std::string css;
  if (BlinkerIsWebColorHex(text)) {
    css += "html, html * { color: ";
    css += text;
    css += " !important; }\n";
  }
  if (BlinkerIsWebColorHex(link)) {
    css += "a:link, a:visited, a:link *, a:visited * { color: ";
    css += link;
    css += " !important; }\n";
  }
  return css;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_WEB_COLORS_H_
