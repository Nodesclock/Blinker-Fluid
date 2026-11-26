// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_TRACKING_QUERY_H_
#define CONTENT_SHELL_COMMON_BLINKER_TRACKING_QUERY_H_

#include <array>
#include <string>
#include <string_view>

namespace content {

namespace blinker_tracking_query {

// Тільки параметри що нічого не значать для сторінки. Загальні імена
// типу ref чи si не чіпаєм, сайти ними справді користуються
inline constexpr std::array<std::string_view, 30> kExactNames = {
    "fbclid",      "gclid",      "gclsrc",   "dclid",      "gbraid",
    "wbraid",      "msclkid",    "mc_cid",   "mc_eid",     "yclid",
    "igshid",      "twclid",     "ttclid",   "li_fat_id",  "_hsenc",
    "_hsmi",       "__hssc",     "__hstc",   "__hsfp",     "mkt_tok",
    "oly_anon_id", "oly_enc_id", "vero_id",  "rb_clickid", "s_cid",
    "srsltid",     "_openstat",  "wickedid", "epik",       "_kx",
};

inline constexpr std::array<std::string_view, 7> kPrefixes = {
    "utm_",   "mtm_",      "hsa_",     "pk_campaign",
    "pk_kwd", "pk_source", "pk_medium",
};

inline bool IsTrackingKey(std::string_view key) {
  std::string lower(key);
  for (char& c : lower) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  for (std::string_view name : kExactNames) {
    if (lower == name) {
      return true;
    }
  }
  for (std::string_view prefix : kPrefixes) {
    if (lower.starts_with(prefix)) {
      return true;
    }
  }
  return false;
}

}  // namespace blinker_tracking_query

inline bool BlinkerStripTrackingParams(std::string_view query,
                                       std::string* out) {
  std::string kept;
  bool removed = false;
  size_t start = 0;
  while (start <= query.size()) {
    size_t end = query.find('&', start);
    if (end == std::string_view::npos) {
      end = query.size();
    }
    std::string_view part = query.substr(start, end - start);
    std::string_view key = part.substr(0, part.find('='));
    if (!part.empty() && blinker_tracking_query::IsTrackingKey(key)) {
      removed = true;
    } else if (!part.empty()) {
      if (!kept.empty()) {
        kept += '&';
      }
      kept += part;
    }
    start = end + 1;
  }
  if (!removed) {
    return false;
  }
  *out = std::move(kept);
  return true;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_TRACKING_QUERY_H_
