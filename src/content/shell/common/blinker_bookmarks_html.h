// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_BOOKMARKS_HTML_H_
#define CONTENT_SHELL_COMMON_BLINKER_BOOKMARKS_HTML_H_

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace content {

struct BlinkerBookmarkNode {
  std::string title;
  std::string url;
  int64_t add_date = 0;
  std::vector<BlinkerBookmarkNode> children;
  bool is_folder() const { return url.empty(); }
};

namespace blinker_bookmarks_internal {

inline char Lower(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

inline bool StartsWithTag(std::string_view text, size_t at,
                          std::string_view tag) {
  if (at + tag.size() > text.size()) {
    return false;
  }
  for (size_t i = 0; i < tag.size(); ++i) {
    if (Lower(text[at + i]) != tag[i]) {
      return false;
    }
  }
  const size_t after = at + tag.size();
  return after == text.size() || text[after] == '>' || text[after] == ' ' ||
         text[after] == '\t' || text[after] == '\n' || text[after] == '\r' ||
         text[after] == '/';
}

inline void AppendUtf8(std::string* out, uint32_t cp) {
  if (cp < 0x80) {
    out->push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x110000) {
    out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

inline std::string DecodeEntities(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] != '&') {
      out.push_back(text[i]);
      continue;
    }
    const size_t semi = text.find(';', i);
    if (semi == std::string_view::npos || semi - i > 10) {
      out.push_back('&');
      continue;
    }
    std::string_view name = text.substr(i + 1, semi - i - 1);
    if (name == "amp") {
      out.push_back('&');
    } else if (name == "lt") {
      out.push_back('<');
    } else if (name == "gt") {
      out.push_back('>');
    } else if (name == "quot") {
      out.push_back('"');
    } else if (name == "apos") {
      out.push_back('\'');
    } else if (name == "nbsp") {
      out.push_back(' ');
    } else if (name.size() > 1 && name[0] == '#') {
      uint32_t cp = 0;
      const bool hex = name[1] == 'x' || name[1] == 'X';
      bool ok = name.size() > (hex ? 2u : 1u);
      for (size_t k = hex ? 2 : 1; ok && k < name.size(); ++k) {
        const char c = name[k];
        uint32_t digit;
        if (c >= '0' && c <= '9') {
          digit = c - '0';
        } else if (hex && Lower(c) >= 'a' && Lower(c) <= 'f') {
          digit = Lower(c) - 'a' + 10;
        } else {
          ok = false;
          break;
        }
        cp = cp * (hex ? 16 : 10) + digit;
        if (cp > 0x10FFFF) {
          ok = false;
        }
      }
      if (!ok) {
        out.push_back('&');
        continue;
      }
      AppendUtf8(&out, cp);
    } else {
      out.push_back('&');
      continue;
    }
    i = semi;
  }
  return out;
}

inline std::string Trim(std::string_view text) {
  size_t start = 0;
  size_t end = text.size();
  while (start < end && static_cast<unsigned char>(text[start]) <= ' ') {
    ++start;
  }
  while (end > start && static_cast<unsigned char>(text[end - 1]) <= ' ') {
    --end;
  }
  return std::string(text.substr(start, end - start));
}

inline std::string Attribute(std::string_view tag, std::string_view name) {
  size_t i = 0;
  while (i < tag.size()) {
    while (i < tag.size() && tag[i] != ' ' && tag[i] != '\t' &&
           tag[i] != '\n' && tag[i] != '\r') {
      ++i;
    }
    while (i < tag.size() && (tag[i] == ' ' || tag[i] == '\t' ||
                              tag[i] == '\n' || tag[i] == '\r')) {
      ++i;
    }
    const size_t key_start = i;
    while (i < tag.size() && tag[i] != '=' && tag[i] != ' ' && tag[i] != '>') {
      ++i;
    }
    std::string key;
    for (size_t k = key_start; k < i; ++k) {
      key.push_back(Lower(tag[k]));
    }
    if (i >= tag.size() || tag[i] != '=') {
      continue;
    }
    ++i;
    std::string_view value;
    if (i < tag.size() && (tag[i] == '"' || tag[i] == '\'')) {
      const char quote = tag[i++];
      const size_t close = tag.find(quote, i);
      const size_t stop = close == std::string_view::npos ? tag.size() : close;
      value = tag.substr(i, stop - i);
      i = stop + 1;
    } else {
      const size_t start = i;
      while (i < tag.size() && tag[i] != ' ' && tag[i] != '>') {
        ++i;
      }
      value = tag.substr(start, i - start);
    }
    if (key == name) {
      return DecodeEntities(value);
    }
  }
  return std::string();
}

inline int64_t ParseInt(const std::string& text) {
  int64_t value = 0;
  for (char c : text) {
    if (c < '0' || c > '9' || value > 100000000000LL) {
      return 0;
    }
    value = value * 10 + (c - '0');
  }
  return value;
}

inline std::string TextUntil(std::string_view html, size_t* at,
                             std::string_view close_tag) {
  size_t i = *at;
  size_t end = html.size();
  // Незакритий тег не має з'їсти решту файлу
  for (size_t k = i; k + 1 < html.size(); ++k) {
    if (html[k] != '<') {
      continue;
    }
    if ((html[k + 1] == '/' && (StartsWithTag(html, k + 2, close_tag) ||
                                StartsWithTag(html, k + 2, "dl"))) ||
        StartsWithTag(html, k + 1, "dl") || StartsWithTag(html, k + 1, "dt")) {
      end = k;
      break;
    }
  }
  *at = end;
  return Trim(DecodeEntities(html.substr(i, end - i)));
}

inline std::string Escape(std::string_view text) {
  std::string out;
  for (char c : text) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out.push_back(c);
    }
  }
  return out;
}

inline bool SafeUrl(const std::string& url) {
  std::string scheme;
  for (char c : url) {
    if (c == ':') {
      return scheme == "http" || scheme == "https" || scheme == "ftp" ||
             scheme == "file";
    }
    scheme.push_back(Lower(c));
    if (scheme.size() > 8) {
      return false;
    }
  }
  return false;
}

inline void Write(const std::vector<BlinkerBookmarkNode>& nodes, int depth,
                  std::string* out) {
  const std::string indent(4 * depth, ' ');
  for (const BlinkerBookmarkNode& node : nodes) {
    const std::string date =
        node.add_date > 0 ? " ADD_DATE=\"" + std::to_string(node.add_date) + "\""
                          : std::string();
    if (node.is_folder()) {
      *out += indent + "<DT><H3" + date + ">" + Escape(node.title) + "</H3>\n";
      *out += indent + "<DL><p>\n";
      Write(node.children, depth + 1, out);
      *out += indent + "</DL><p>\n";
    } else {
      *out += indent + "<DT><A HREF=\"" + Escape(node.url) + "\"" + date +
              ">" + Escape(node.title) + "</A>\n";
    }
  }
}

}  // namespace blinker_bookmarks_internal

// Лиш http, https, ftp і file, щоб javascript URL з чужого файлу
// не потрапив в закладки
inline std::vector<BlinkerBookmarkNode> BlinkerParseBookmarksHtml(
    std::string_view html) {
  namespace bi = blinker_bookmarks_internal;
  std::vector<BlinkerBookmarkNode> root;
  // шлях до теки як індекси, бо вектори переалоковуються
  std::vector<size_t> path;
  bool pending_folder = false;
  std::vector<bool> dl_opened_folder;
  auto current = [&]() -> std::vector<BlinkerBookmarkNode>& {
    std::vector<BlinkerBookmarkNode>* list = &root;
    for (size_t index : path) {
      list = &(*list)[index].children;
    }
    return *list;
  };
  size_t i = 0;
  while (i < html.size()) {
    const size_t open = html.find('<', i);
    if (open == std::string_view::npos) {
      break;
    }
    const size_t close = html.find('>', open);
    if (close == std::string_view::npos) {
      break;
    }
    std::string_view tag = html.substr(open + 1, close - open - 1);
    i = close + 1;
    if (bi::StartsWithTag(html, open + 1, "h3")) {
      BlinkerBookmarkNode folder;
      folder.add_date = bi::ParseInt(bi::Attribute(tag, "add_date"));
      folder.title = bi::TextUntil(html, &i, "h3");
      current().push_back(std::move(folder));
      pending_folder = true;
    } else if (bi::StartsWithTag(html, open + 1, "a")) {
      BlinkerBookmarkNode link;
      link.url = bi::Trim(bi::Attribute(tag, "href"));
      link.add_date = bi::ParseInt(bi::Attribute(tag, "add_date"));
      link.title = bi::TextUntil(html, &i, "a");
      if (bi::SafeUrl(link.url)) {
        if (link.title.empty()) {
          link.title = link.url;
        }
        current().push_back(std::move(link));
      }
      pending_folder = false;
    } else if (bi::StartsWithTag(html, open + 1, "dl")) {
      const bool opens = pending_folder && !current().empty() &&
                         current().back().is_folder();
      if (opens) {
        path.push_back(current().size() - 1);
      }
      dl_opened_folder.push_back(opens);
      pending_folder = false;
    } else if (tag.size() > 1 && tag[0] == '/' &&
               bi::StartsWithTag(html, open + 2, "dl")) {
      if (!dl_opened_folder.empty()) {
        if (dl_opened_folder.back() && !path.empty()) {
          path.pop_back();
        }
        dl_opened_folder.pop_back();
      }
    }
    // Глибоке дерево з чужого файлу далі не ростемо
    if (path.size() > 64) {
      break;
    }
  }
  return root;
}

inline std::string BlinkerWriteBookmarksHtml(
    const std::vector<BlinkerBookmarkNode>& nodes) {
  std::string out =
      "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
      "<!-- This is an automatically generated file.\n"
      "     It will be read and overwritten.\n"
      "     DO NOT EDIT! -->\n"
      "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; "
      "charset=UTF-8\">\n"
      "<TITLE>Bookmarks</TITLE>\n"
      "<H1>Bookmarks</H1>\n"
      "<DL><p>\n";
  blinker_bookmarks_internal::Write(nodes, 1, &out);
  out += "</DL><p>\n";
  return out;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_BOOKMARKS_HTML_H_
