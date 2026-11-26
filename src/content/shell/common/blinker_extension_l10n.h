// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_EXTENSION_L10N_H_
#define CONTENT_SHELL_COMMON_BLINKER_EXTENSION_L10N_H_

#include <functional>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace content::blinker_extensions {

using L10nMessages = std::map<std::string, std::string, std::less<>>;

inline constexpr char kMessageBegin[] = "__MSG_";
inline constexpr char kMessageEnd[] = "__";

inline char ToLowerAscii(char c) {
  return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

inline std::string ToLowerAscii(std::string_view text) {
  std::string out(text);
  for (char& c : out) {
    c = ToLowerAscii(c);
  }
  return out;
}

inline bool IsValidMessageName(std::string_view name) {
  if (name.empty()) {
    return false;
  }
  for (char c : name) {
    const bool alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                       (c >= '0' && c <= '9');
    if (!alnum && c != '_' && c != '@') {
      return false;
    }
  }
  return true;
}

// На першій невідомій змінній вертає false, зроблені заміни лишаються
inline bool ReplaceVariables(const L10nMessages& variables,
                             std::string_view begin,
                             std::string_view end,
                             std::string* text) {
  size_t index = 0;
  while (true) {
    index = text->find(begin, index);
    if (index == std::string::npos) {
      return true;
    }
    index += begin.size();
    if (index >= text->size()) {
      return true;
    }
    const size_t end_index = text->find(end, index);
    if (end_index == std::string::npos) {
      return true;
    }
    const std::string_view name =
        std::string_view(*text).substr(index, end_index - index);
    if (!IsValidMessageName(name)) {
      continue;
    }
    const auto it = variables.find(ToLowerAscii(name));
    if (it == variables.end()) {
      return false;
    }
    const std::string value = it->second;
    text->replace(index - begin.size(),
                  end_index - index + begin.size() + end.size(), value);
    index += value.size() - begin.size();
  }
}

inline bool ReplaceMessages(const L10nMessages& messages, std::string* text) {
  return ReplaceVariables(messages, kMessageBegin, kMessageEnd, text);
}

inline std::vector<std::string> FallbackLocales(std::string_view app_locale,
                                                std::string_view default_locale) {
  std::vector<std::string> out;
  if (!app_locale.empty() && app_locale != default_locale) {
    std::string locale(app_locale);
    while (!locale.empty()) {
      out.push_back(locale);
      const size_t cut = locale.rfind('_');
      locale.resize(cut == std::string::npos ? 0 : cut);
    }
  }
  if (!default_locale.empty()) {
    bool seen = false;
    for (const std::string& locale : out) {
      seen |= locale == default_locale;
    }
    if (!seen) {
      out.emplace_back(default_locale);
    }
  }
  return out;
}

// ICU дає "zh-Hans-CN", а розширення кладуть переклади під "zh_CN"
inline std::string AppLocaleFromConfigured(std::string_view configured) {
  std::string locale(configured);
  for (char& c : locale) {
    if (c == '-') {
      c = '_';
    }
  }
  if (locale.starts_with("zh_Hans")) {
    return "zh_CN";
  }
  if (locale.starts_with("zh_Hant")) {
    return locale.ends_with("_HK") ? "zh_HK" : "zh_TW";
  }
  return locale;
}

}  // namespace content::blinker_extensions

#endif  // CONTENT_SHELL_COMMON_BLINKER_EXTENSION_L10N_H_
