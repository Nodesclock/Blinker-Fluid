// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_MATCH_PATTERN_H_
#define CONTENT_SHELL_COMMON_BLINKER_MATCH_PATTERN_H_

#include <cstddef>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace content::blinker_extensions {

struct UrlParts {
  std::string_view scheme;
  std::string_view host;
  int port = -1;
  std::string_view path;
  std::string_view spec;
};

namespace internal {

// Побайтово з base/strings/pattern.cc разом з жадібним пошуком,
// щоб глоби вели себе як у Chrome
inline bool SearchForChars(std::string_view pattern,
                           size_t* p,
                           std::string_view text,
                           size_t* t,
                           int maximum_distance) {
  const size_t pattern_start = *p;
  size_t text_start = *t;
  bool escape = false;
  while (true) {
    if (*p == pattern.size()) {
      if (*t == text.size()) {
        return true;
      }
    } else {
      if (!escape && (pattern[*p] == '*' || pattern[*p] == '?')) {
        return true;
      }
      if (!escape && pattern[*p] == '\\') {
        escape = true;
        ++*p;
        continue;
      }
      escape = false;
      if (*t == text.size()) {
        return false;
      }
      if (pattern[*p] == text[*t]) {
        ++*p;
        ++*t;
        continue;
      }
    }
    if (maximum_distance == 0 || text_start >= text.size()) {
      return false;
    }
    --maximum_distance;
    *p = pattern_start;
    *t = ++text_start;
  }
}

inline bool BaseMatchPattern(std::string_view text, std::string_view pattern) {
  size_t p = 0;
  size_t t = 0;
  do {
    int question_marks = 0;
    bool has_asterisk = false;
    for (; p < pattern.size(); ++p) {
      if (pattern[p] == '?') {
        ++question_marks;
      } else if (pattern[p] == '*') {
        has_asterisk = true;
      } else {
        break;
      }
    }
    if (!SearchForChars(pattern, &p, text, &t,
                        has_asterisk ? -1 : question_marks)) {
      return false;
    }
  } while (p != pattern.size());
  return true;
}

}  // namespace internal

inline bool GlobMatches(std::string_view pattern, std::string_view text) {
  size_t p = 0, t = 0, star = std::string_view::npos, resume = 0;
  while (t < text.size()) {
    if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      resume = t;
    } else if (p < pattern.size() && pattern[p] == text[t]) {
      ++p;
      ++t;
    } else if (star != std::string_view::npos) {
      p = star + 1;
      t = ++resume;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') {
    ++p;
  }
  return p == pattern.size();
}

inline bool UrlGlobMatches(std::string_view glob, std::string_view url) {
  return internal::BaseMatchPattern(url, glob);
}

class MatchPattern {
 public:
  // any_scheme це URLPattern::SCHEME_ALL для tabs.query, там шаблон
  // тільки відбирає адреси
  explicit MatchPattern(bool any_scheme = false) : any_scheme_(any_scheme) {}

  // Битий шаблон не ловить нічого, а не щось ширше
  bool Parse(std::string_view pattern) {
    *this = MatchPattern(any_scheme_);
    if (pattern == "<all_urls>") {
      all_urls_ = true;
      path_ = "/*";
      valid_ = true;
      return true;
    }
    size_t scheme_end = pattern.find("://");
    const bool standard_separator = scheme_end != std::string_view::npos;
    if (!standard_separator) {
      scheme_end = pattern.find(':');
    }
    if (scheme_end == std::string_view::npos) {
      return Fail("Missing scheme separator.");
    }
    scheme_ = std::string(pattern.substr(0, scheme_end));
    if (!IsSupportedScheme(scheme_) && scheme_ != "*" &&
        !(any_scheme_ && !scheme_.empty())) {
      return Fail("Invalid scheme.");
    }
    if (!standard_separator) {
      return Fail("Wrong scheme type.");
    }
    const size_t host_start = scheme_end + 3;
    if (host_start >= pattern.size()) {
      return Fail(kEmptyHost);
    }
    // Хост у схемі file ігнорується, "file://*" означає "file:///*"
    if (scheme_ == "file") {
      const size_t host_end = pattern.find('/', host_start);
      path_ = std::string(pattern.substr(
          host_end == std::string_view::npos ? host_start - 1 : host_end));
      valid_ = true;
      return true;
    }
    const size_t host_end = pattern.find('/', host_start);
    if (host_end == host_start) {
      return Fail(kEmptyHost);
    }
    if (host_end == std::string_view::npos) {
      return Fail("Empty path.");
    }
    const std::string_view host_and_port =
        pattern.substr(host_start, host_end - host_start);
    size_t port_separator = std::string_view::npos;
    if (host_and_port.front() != '[') {
      port_separator = host_and_port.find(':');
    } else {
      const size_t ipv6_end = host_and_port.find(']');
      if (ipv6_end == std::string_view::npos) {
        return Fail(kInvalidHost);
      }
      if (ipv6_end == 1) {
        return Fail(kEmptyHost);
      }
      if (ipv6_end < host_and_port.size() - 1) {
        if (host_and_port[ipv6_end + 1] != ':') {
          return Fail(kInvalidHost);
        }
        port_separator = ipv6_end + 1;
      }
    }
    if (port_separator != std::string_view::npos &&
        !ParsePort(host_and_port.substr(port_separator + 1))) {
      return Fail("Invalid port.");
    }
    std::string_view host = host_and_port.substr(0, port_separator);
    if (host.empty()) {
      return Fail(kEmptyHost);
    }
    if (host == "*") {
      any_host_ = true;
      host = std::string_view();
    } else if (host.starts_with("*.")) {
      if (host.size() == 2) {
        return Fail(kEmptyHost);
      }
      match_subdomains_ = true;
      host = host.substr(2);
    }
    host_ = std::string(host);
    for (char& c : host_) {
      if (c >= 'A' && c <= 'Z') {
        c = static_cast<char>(c - 'A' + 'a');
      }
    }
    path_ = std::string(pattern.substr(host_end));
    if (host_.find('*') != std::string::npos) {
      return Fail("Invalid host wildcard.");
    }
    valid_ = true;
    return true;
  }

  bool Matches(const UrlParts& url) const {
    if (!valid_) {
      return false;
    }
    if (all_urls_) {
      return any_scheme_ || IsSupportedScheme(url.scheme);
    }
    if (scheme_ == "*") {
      if (url.scheme != "http" && url.scheme != "https") {
        return false;
      }
    } else if (scheme_ != url.scheme) {
      return false;
    }
    if (port_ >= 0 && port_ != url.port) {
      return false;
    }
    return (scheme_ == "file" || HostMatches(url.host)) && PathMatches(url.path);
  }

  bool Contains(const MatchPattern& other) const {
    if (!valid_ || !other.valid_) {
      return false;
    }
    if (all_urls_) {
      return true;
    }
    if (other.all_urls_) {
      return false;
    }
    if (scheme_ == "*") {
      if (other.scheme_ != "*" && other.scheme_ != "http" &&
          other.scheme_ != "https") {
        return false;
      }
    } else if (scheme_ != other.scheme_) {
      return false;
    }
    if (!any_host_) {
      if (other.any_host_ || (other.match_subdomains_ && !match_subdomains_) ||
          !HostMatches(other.host_)) {
        return false;
      }
    }
    if (port_ >= 0 && port_ != other.port_) {
      return false;
    }
    std::string_view other_path = other.path_;
    if (other_path.ends_with('*')) {
      other_path.remove_suffix(1);
    }
    return PathMatches(other_path);
  }

  bool valid() const { return valid_; }
  const std::string& path() const { return path_; }
  void set_path(std::string path) { path_ = std::move(path); }
  std::string_view parse_error() const { return parse_error_; }

 private:
  static bool IsSupportedScheme(std::string_view scheme) {
    return scheme == "http" || scheme == "https" || scheme == "file" ||
           scheme == "ftp" || scheme == "ws" || scheme == "wss";
  }

  static constexpr char kEmptyHost[] = "Host can not be empty.";
  static constexpr char kInvalidHost[] = "Invalid host.";

  bool Fail(const char* error) {
    valid_ = false;
    parse_error_ = error;
    return false;
  }

  bool ParsePort(std::string_view port) {
    if (port == "*") {
      return true;
    }
    if (port.empty() || port.size() > 5) {
      return false;
    }
    int value = 0;
    for (char c : port) {
      if (c < '0' || c > '9') {
        return false;
      }
      value = value * 10 + (c - '0');
    }
    if (value > 65535) {
      return false;
    }
    port_ = value;
    return true;
  }

  bool HostMatches(std::string_view host) const {
    if (any_host_ || host == host_) {
      return true;
    }
    return match_subdomains_ && host.size() > host_.size() &&
           host.ends_with(host_) &&
           host[host.size() - host_.size() - 1] == '.';
  }

  bool PathMatches(std::string_view path) const {
    if (path.size() + 2 == path_.size() && path_.ends_with("/*") &&
        path_.starts_with(path)) {
      return true;
    }
    return GlobMatches(path_, path);
  }

  std::string scheme_;
  std::string host_;
  std::string path_;
  int port_ = -1;
  bool all_urls_ = false;
  bool any_host_ = false;
  bool match_subdomains_ = false;
  bool valid_ = false;
  const char* parse_error_ = "";
  bool any_scheme_ = false;
};

class MatchPatternSet {
 public:
  void AddInclude(std::string_view pattern) {
    MatchPattern p;
    if (p.Parse(pattern)) {
      includes_.push_back(p);
    }
  }
  void AddExclude(std::string_view pattern) {
    MatchPattern p;
    if (p.Parse(pattern)) {
      excludes_.push_back(p);
    }
  }
  void AddIncludePattern(MatchPattern pattern) {
    if (pattern.valid()) {
      includes_.push_back(std::move(pattern));
    }
  }
  // Шлях у дозволі на хост не має значення, Chrome міняє його на "/*"
  void AddHostPermission(std::string_view pattern) {
    MatchPattern p;
    if (p.Parse(pattern)) {
      p.set_path("/*");
      includes_.push_back(std::move(p));
    }
  }

  bool Includes(const UrlParts& url) const {
    for (const MatchPattern& p : includes_) {
      if (p.Matches(url)) {
        return true;
      }
    }
    return false;
  }
  bool Excludes(const UrlParts& url) const {
    for (const MatchPattern& p : excludes_) {
      if (p.Matches(url)) {
        return true;
      }
    }
    return false;
  }
  bool Matches(const UrlParts& url) const {
    return Includes(url) && !Excludes(url);
  }

  bool ContainsPattern(const MatchPattern& pattern) const {
    for (const MatchPattern& p : includes_) {
      if (p.Contains(pattern)) {
        return true;
      }
    }
    return false;
  }

  // Для match_origin_as_fallback Chrome вимагає шлях /* у кожному шаблоні
  bool AllPathsAreWildcard() const {
    for (const MatchPattern& p : includes_) {
      if (p.path() != "/*") {
        return false;
      }
    }
    return true;
  }

  bool empty() const { return includes_.empty(); }
  size_t size() const { return includes_.size(); }

 private:
  std::vector<MatchPattern> includes_;
  std::vector<MatchPattern> excludes_;
};

class ScriptUrlFilter {
 public:
  MatchPatternSet& patterns() { return patterns_; }
  const MatchPatternSet& patterns() const { return patterns_; }
  void AddIncludeGlob(std::string glob) {
    include_globs_.push_back(std::move(glob));
  }
  void AddExcludeGlob(std::string glob) {
    exclude_globs_.push_back(std::move(glob));
  }
  // В chrome.userScripts include_globs додають сторінки до matches
  // а в content scripts звужують
  void set_globs_extend_patterns(bool extend) {
    globs_extend_patterns_ = extend;
  }

  bool Matches(const UrlParts& url) const {
    if (patterns_.Excludes(url) || AnyGlobMatches(exclude_globs_, url)) {
      return false;
    }
    if (globs_extend_patterns_) {
      return patterns_.Includes(url) || AnyGlobMatches(include_globs_, url);
    }
    return patterns_.Includes(url) &&
           (include_globs_.empty() || AnyGlobMatches(include_globs_, url));
  }

 private:
  static bool AnyGlobMatches(const std::vector<std::string>& globs,
                             const UrlParts& url) {
    for (const std::string& glob : globs) {
      if (UrlGlobMatches(glob, url.spec)) {
        return true;
      }
    }
    return false;
  }

  MatchPatternSet patterns_;
  std::vector<std::string> include_globs_;
  std::vector<std::string> exclude_globs_;
  bool globs_extend_patterns_ = false;
};

}  // namespace content::blinker_extensions

#endif  // CONTENT_SHELL_COMMON_BLINKER_MATCH_PATTERN_H_
