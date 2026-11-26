// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_FILTER_PATTERN_H_
#define CONTENT_SHELL_COMMON_BLINKER_FILTER_PATTERN_H_

#include <algorithm>
#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace content::blinker_filter {

// пари символів є майже в кожному URL, нічого не звужують
inline constexpr size_t kMinTokenLength = 3;

inline bool IsTokenChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9');
}

inline bool IsSeparatorChar(char c) {
  return !(IsTokenChar(c) || c == '_' || c == '-' || c == '.' || c == '%');
}

// ^ в кінці ловить і кінець URL, тому ||host^ ловить "https://host"
inline size_t MatchSegmentAt(std::string_view segment,
                             std::string_view text,
                             size_t tpos) {
  for (size_t i = 0; i < segment.size(); ++i) {
    const char pc = segment[i];
    if (pc == '^') {
      if (tpos >= text.size()) {
        return (i + 1 == segment.size()) ? tpos : std::string_view::npos;
      }
      if (!IsSeparatorChar(text[tpos])) {
        return std::string_view::npos;
      }
      ++tpos;
      continue;
    }
    if (tpos >= text.size() || text[tpos] != pc) {
      return std::string_view::npos;
    }
    ++tpos;
  }
  return tpos;
}

// Сегмент бере першу позицію що підходить, як в еталонних реалізаціях
// Без відкату промах блокує менше, а не більше
inline bool MatchPatternAt(std::string_view pattern,
                           std::string_view text,
                           size_t tpos,
                           bool right_anchor) {
  size_t p = 0;
  bool first = true;
  for (;;) {
    const size_t star = pattern.find('*', p);
    const bool last = (star == std::string_view::npos);
    std::string_view segment =
        pattern.substr(p, last ? std::string_view::npos : star - p);

    if (!segment.empty()) {
      if (first) {
        const size_t end = MatchSegmentAt(segment, text, tpos);
        if (end == std::string_view::npos) {
          return false;
        }
        tpos = end;
      } else if (last && right_anchor) {
        bool matched = false;
        for (size_t start = tpos; start <= text.size(); ++start) {
          if (MatchSegmentAt(segment, text, start) == text.size()) {
            tpos = text.size();
            matched = true;
            break;
          }
        }
        if (!matched) {
          return false;
        }
      } else {
        bool matched = false;
        for (size_t start = tpos; start <= text.size(); ++start) {
          const size_t end = MatchSegmentAt(segment, text, start);
          if (end != std::string_view::npos) {
            tpos = end;
            matched = true;
            break;
          }
        }
        if (!matched) {
          return false;
        }
      }
    }

    if (last) {
      const bool ends_with_star = !pattern.empty() && pattern.back() == '*';
      if (right_anchor && !ends_with_star && tpos != text.size()) {
        return false;
      }
      return true;
    }
    p = star + 1;
    first = false;
  }
}

inline void HostLabelStarts(std::string_view url, std::vector<size_t>* out) {
  out->clear();
  size_t host_start = url.find("://");
  host_start = (host_start == std::string_view::npos) ? 0 : host_start + 3;
  if (host_start >= url.size()) {
    return;
  }
  size_t host_end = url.find_first_of("/?#", host_start);
  if (host_end == std::string_view::npos) {
    host_end = url.size();
  }
  const size_t at = url.rfind('@', host_end);
  if (at != std::string_view::npos && at >= host_start && at < host_end) {
    host_start = at + 1;
  }
  out->push_back(host_start);
  for (size_t i = host_start; i < host_end; ++i) {
    if (url[i] == '.') {
      out->push_back(i + 1);
    }
  }
}

// Токен біля * чи на кінці без якоря не годиться, правило йде
// в загальний кошик
inline std::string ExtractPatternToken(std::string_view pattern,
                                       bool hostname_anchor,
                                       bool left_anchor,
                                       bool right_anchor) {
  std::string best;
  size_t i = 0;
  const size_t n = pattern.size();
  while (i < n) {
    if (!IsTokenChar(pattern[i])) {
      ++i;
      continue;
    }
    const size_t start = i;
    while (i < n && IsTokenChar(pattern[i])) {
      ++i;
    }
    const size_t end = i;
    if (end - start < kMinTokenLength) {
      continue;
    }
    const bool left_ok = (start > 0) ? (pattern[start - 1] != '*')
                                     : (hostname_anchor || left_anchor);
    const bool right_ok = (end < n) ? (pattern[end] != '*') : right_anchor;
    if (!left_ok || !right_ok) {
      continue;
    }
    if (end - start > best.size()) {
      best.assign(pattern, start, end - start);
    }
  }
  return best;
}

inline void ExtractUrlTokens(std::string_view url,
                             std::vector<std::string_view>* out) {
  out->clear();
  size_t i = 0;
  while (i < url.size()) {
    if (!IsTokenChar(url[i])) {
      ++i;
      continue;
    }
    const size_t start = i;
    while (i < url.size() && IsTokenChar(url[i])) {
      ++i;
    }
    const std::string_view token = url.substr(start, i - start);
    if (token.size() >= kMinTokenLength &&
        std::find(out->begin(), out->end(), token) == out->end()) {
      out->push_back(token);
    }
  }
}

// Для IP чи голого публічного суфікса список пустий, правила з доменами
// там не діють
inline void HostAndParents(std::string_view host,
                           std::string_view registered,
                           std::vector<std::string_view>* out) {
  out->clear();
  if (registered.empty()) {
    return;
  }
  std::string_view cursor = host;
  for (;;) {
    out->push_back(cursor);
    if (cursor.size() <= registered.size()) {
      return;
    }
    const size_t dot = cursor.find('.');
    if (dot == std::string_view::npos) {
      return;
    }
    cursor.remove_prefix(dot + 1);
  }
}

inline bool DomainOptionsMatch(const std::vector<std::string_view>& hosts,
                               const std::vector<std::string>& included,
                               const std::vector<std::string>& excluded) {
  bool found = included.empty();
  for (std::string_view host : hosts) {
    if (std::binary_search(excluded.begin(), excluded.end(), host,
                           std::less<>())) {
      return false;
    }
    found = found || std::binary_search(included.begin(), included.end(), host,
                                        std::less<>());
  }
  return found;
}

}  // namespace content::blinker_filter

#endif  // CONTENT_SHELL_COMMON_BLINKER_FILTER_PATTERN_H_
