// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_DNR_RULE_H_
#define CONTENT_SHELL_COMMON_BLINKER_DNR_RULE_H_

#include <string>
#include <string_view>
#include <vector>

namespace content::blinker_extensions {

struct DnrRule {
  enum class Action {
    kBlock,
    kAllow,
    kAllowAllRequests,
    kUnsupported,
  };

  Action action = Action::kUnsupported;
  std::string url_filter;
  bool is_regex = false;
  bool case_sensitive = false;
  std::vector<std::string> resource_types;
  std::vector<std::string> excluded_resource_types;
  std::vector<std::string> initiator_domains;
  std::vector<std::string> excluded_initiator_domains;
  // Хост запиту, а не ініціатора. uBO Lite шле цілі списки хостів
  // одним правилом без urlFilter
  std::vector<std::string> request_domains;
  std::vector<std::string> excluded_request_domains;
  std::string domain_type;
};

inline std::string_view FilterOptionForResourceType(std::string_view type) {
  if (type == "script") return "script";
  if (type == "image") return "image";
  if (type == "stylesheet") return "stylesheet";
  if (type == "object") return "object";
  if (type == "xmlhttprequest") return "xmlhttprequest";
  if (type == "sub_frame") return "subdocument";
  if (type == "main_frame") return "document";
  if (type == "ping" || type == "csp_report") return "ping";
  if (type == "media") return "media";
  if (type == "font") return "font";
  if (type == "websocket") return "websocket";
  if (type == "other") return "other";
  return {};
}

// Правило що не виразити повністю відкидаємо, часткові умови зачепили б
// запити які автор виключив
inline std::string DnrRuleToFilterLine(const DnrRule& rule) {
  if (rule.url_filter.empty()) {
    return {};
  }
  std::string prefix;
  switch (rule.action) {
    case DnrRule::Action::kBlock:
      break;
    case DnrRule::Action::kAllow:
    case DnrRule::Action::kAllowAllRequests:
      prefix = "@@";
      break;
    case DnrRule::Action::kUnsupported:
      return {};
  }

  std::vector<std::string> options;
  for (const std::string& type : rule.resource_types) {
    const std::string_view option = FilterOptionForResourceType(type);
    if (option.empty()) {
      return {};
    }
    options.emplace_back(option);
  }
  for (const std::string& type : rule.excluded_resource_types) {
    const std::string_view option = FilterOptionForResourceType(type);
    if (option.empty()) {
      return {};
    }
    options.push_back("~" + std::string(option));
  }
  if (rule.domain_type == "thirdParty") {
    options.emplace_back("third-party");
  } else if (rule.domain_type == "firstParty") {
    options.emplace_back("first-party");
  } else if (!rule.domain_type.empty()) {
    return {};
  }
  if (!rule.initiator_domains.empty() ||
      !rule.excluded_initiator_domains.empty()) {
    std::string domains = "domain=";
    bool first = true;
    for (const std::string& d : rule.initiator_domains) {
      if (d.empty()) {
        return {};
      }
      if (!first) {
        domains += "|";
      }
      domains += d;
      first = false;
    }
    for (const std::string& d : rule.excluded_initiator_domains) {
      if (d.empty()) {
        return {};
      }
      if (!first) {
        domains += "|";
      }
      domains += "~" + d;
      first = false;
    }
    options.push_back(domains);
  }
  if (!rule.request_domains.empty() || !rule.excluded_request_domains.empty()) {
    std::string to = "to=";
    bool first = true;
    for (const std::string& d : rule.request_domains) {
      if (d.empty()) {
        return {};
      }
      if (!first) {
        to += "|";
      }
      to += d;
      first = false;
    }
    for (const std::string& d : rule.excluded_request_domains) {
      if (d.empty()) {
        return {};
      }
      if (!first) {
        to += "|";
      }
      to += "~" + d;
      first = false;
    }
    options.push_back(to);
  }
  if (rule.case_sensitive) {
    options.emplace_back("match-case");
  }

  if (rule.is_regex) {
    if (rule.url_filter.find('\n') != std::string::npos) {
      return {};
    }
  } else if (rule.url_filter.find('$') != std::string::npos) {
    // символ $ у шаблоні сприймався б як початок опцій
    return {};
  }
  std::string line =
      prefix + (rule.is_regex ? "/" + rule.url_filter + "/" : rule.url_filter);
  // Шаблон /ads/ фільтр прочитав би як регулярку
  if (!rule.is_regex && rule.url_filter.size() > 1 &&
      rule.url_filter.front() == '/' && rule.url_filter.back() == '/') {
    line += '*';
  }
  if (!options.empty()) {
    line += "$";
    for (size_t i = 0; i < options.size(); ++i) {
      if (i) {
        line += ",";
      }
      line += options[i];
    }
  }
  return line;
}

// Окремий рядок на кожен хост, щоб вони попали в індекс хостів
// а не в одну опцію на тисячі записів
inline std::vector<std::string> DnrRuleToFilterLines(const DnrRule& rule) {
  std::vector<std::string> lines;
  if (!rule.url_filter.empty() || rule.request_domains.empty()) {
    std::string line = DnrRuleToFilterLine(rule);
    if (!line.empty()) {
      lines.push_back(std::move(line));
    }
    return lines;
  }
  DnrRule per_host = rule;
  per_host.request_domains.clear();
  for (const std::string& host : rule.request_domains) {
    if (host.empty() || host.find_first_of("/*^|$") != std::string::npos) {
      return {};
    }
    per_host.url_filter = "||" + host + "^";
    std::string line = DnrRuleToFilterLine(per_host);
    if (line.empty()) {
      return {};
    }
    lines.push_back(std::move(line));
  }
  return lines;
}

}  // namespace content::blinker_extensions

#endif  // CONTENT_SHELL_COMMON_BLINKER_DNR_RULE_H_
