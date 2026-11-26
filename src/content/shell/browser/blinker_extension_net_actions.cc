// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extension_net_actions.h"

#include <algorithm>

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "content/shell/browser/blinker_extension_url_loader_factory.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/public/cpp/resource_request.h"
#include "content/shell/common/blinker_filter_pattern.h"
#include "third_party/blink/public/common/loader/blinker_request_redirect.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_private_logging.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/url_constants.h"

namespace content {

namespace {

using blinker_filter::HostLabelStarts;
using blinker_filter::MatchPatternAt;

uint32_t TypeBitForDnr(std::string_view type) {
  if (type == "script") return static_cast<uint32_t>(BlinkerResourceType::kScript);
  if (type == "image") return static_cast<uint32_t>(BlinkerResourceType::kImage);
  if (type == "stylesheet")
    return static_cast<uint32_t>(BlinkerResourceType::kStylesheet);
  if (type == "object") return static_cast<uint32_t>(BlinkerResourceType::kObject);
  if (type == "xmlhttprequest")
    return static_cast<uint32_t>(BlinkerResourceType::kXmlHttpRequest);
  if (type == "sub_frame")
    return static_cast<uint32_t>(BlinkerResourceType::kSubdocument);
  if (type == "main_frame")
    return static_cast<uint32_t>(BlinkerResourceType::kDocument);
  if (type == "ping" || type == "csp_report")
    return static_cast<uint32_t>(BlinkerResourceType::kPing);
  if (type == "media") return static_cast<uint32_t>(BlinkerResourceType::kMedia);
  if (type == "font") return static_cast<uint32_t>(BlinkerResourceType::kFont);
  if (type == "websocket")
    return static_cast<uint32_t>(BlinkerResourceType::kWebSocket);
  if (type == "other") return static_cast<uint32_t>(BlinkerResourceType::kOther);
  return 0;
}

std::string NormalizeHost(std::string_view host) {
  std::string out = base::ToLowerASCII(host);
  if (!out.empty() && out.front() == '.') {
    out.erase(out.begin());
  }
  return out;
}

// Правило для example.com покриває і a.b.example.com, як $domain=
template <typename F>
void ForEachHostAndParent(std::string_view host, F&& fn) {
  std::string_view rest = host;
  while (!rest.empty()) {
    fn(std::string(rest));
    const size_t dot = rest.find('.');
    if (dot == std::string_view::npos) {
      return;
    }
    rest = rest.substr(dot + 1);
  }
}

bool DomainListMatches(const std::vector<std::string>& included,
                       const std::vector<std::string>& excluded,
                       std::string_view host) {
  if (included.empty() && excluded.empty()) {
    return true;
  }
  if (host.empty()) {
    return false;
  }
  bool is_included = included.empty();
  bool is_excluded = false;
  ForEachHostAndParent(host, [&](const std::string& candidate) {
    if (!is_included && std::find(included.begin(), included.end(),
                                  candidate) != included.end()) {
      is_included = true;
    }
    if (std::find(excluded.begin(), excluded.end(), candidate) !=
        excluded.end()) {
      is_excluded = true;
    }
  });
  return is_included && !is_excluded;
}

bool Applies(const BlinkerNetActionRule& rule,
             const GURL& url,
             const std::string& url_lower,
             const std::vector<size_t>& label_starts,
             const GURL& document_url,
             BlinkerResourceType type) {
  const uint32_t type_bit = static_cast<uint32_t>(type);
  if (rule.type_mask != 0 && (rule.type_mask & type_bit) == 0) {
    return false;
  }
  if ((rule.excluded_type_mask & type_bit) != 0) {
    return false;
  }
  if (rule.party != BlinkerNetActionRule::Party::kAny) {
    if (!document_url.has_host()) {
      return false;
    }
    const bool third_party = !net::registry_controlled_domains::SameDomainOrHost(
        url, document_url,
        net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
    if ((rule.party == BlinkerNetActionRule::Party::kThirdParty) !=
        third_party) {
      return false;
    }
  }
  if (!DomainListMatches(rule.domains, rule.excluded_domains,
                         base::ToLowerASCII(document_url.host()))) {
    return false;
  }
  if (!DomainListMatches(rule.request_domains, rule.excluded_request_domains,
                         base::ToLowerASCII(url.host()))) {
    return false;
  }
  if (rule.pattern.empty()) {
    return true;
  }
  if (rule.hostname_anchor) {
    for (size_t start : label_starts) {
      if (MatchPatternAt(rule.pattern, url_lower, start, rule.right_anchor)) {
        return true;
      }
    }
    return false;
  }
  if (rule.left_anchor) {
    return MatchPatternAt(rule.pattern, url_lower, 0, rule.right_anchor);
  }
  for (size_t start = 0; start <= url_lower.size(); ++start) {
    if (MatchPatternAt(rule.pattern, url_lower, start, rule.right_anchor)) {
      return true;
    }
  }
  return false;
}

GURL TransformUrl(const BlinkerNetActionRule& rule, const GURL& url) {
  if (rule.upgrade_scheme) {
    const bool http = url.SchemeIs(url::kHttpScheme);
    if (!http && !url.SchemeIs(url::kWsScheme)) {
      return GURL();
    }
    GURL::Replacements replacements;
    replacements.SetSchemeStr(http ? url::kHttpsScheme : url::kWssScheme);
    return url.ReplaceComponents(replacements);
  }
  if (rule.redirect_url.is_valid()) {
    return rule.redirect_url;
  }
  GURL::Replacements replacements;
  std::string query;
  if (rule.has_replace_query) {
    query = rule.replace_query;
    if (!query.empty() && query.front() == '?') {
      query.erase(query.begin());
    }
    replacements.SetQueryStr(query);
    return url.ReplaceComponents(replacements);
  }
  if (rule.remove_params.empty() || !url.has_query()) {
    return GURL();
  }
  std::vector<std::string> kept;
  for (std::string_view pair : base::SplitStringPiece(
           url.query(), "&", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL)) {
    const size_t eq = pair.find('=');
    const std::string name(pair.substr(0, eq == std::string_view::npos
                                              ? pair.size()
                                              : eq));
    if (std::find(rule.remove_params.begin(), rule.remove_params.end(), name) !=
        rule.remove_params.end()) {
      continue;
    }
    kept.emplace_back(pair);
  }
  query = base::JoinString(kept, "&");
  if (query == url.query()) {
    return GURL();
  }
  if (query.empty()) {
    replacements.ClearQuery();
  } else {
    replacements.SetQueryStr(query);
  }
  return url.ReplaceComponents(replacements);
}

bool ParseHeaderOps(const base::ListValue* list,
                    std::vector<BlinkerHeaderOp>* out) {
  if (!list) {
    return true;
  }
  for (const base::Value& entry : *list) {
    const base::DictValue* item = entry.GetIfDict();
    if (!item) {
      return false;
    }
    const std::string* name = item->FindString("header");
    const std::string* operation = item->FindString("operation");
    if (!name || !operation) {
      return false;
    }
    BlinkerHeaderOp op;
    op.name = base::ToLowerASCII(*name);
    if (*operation == "remove") {
      op.op = BlinkerHeaderOp::Op::kRemove;
    } else if (*operation == "set") {
      op.op = BlinkerHeaderOp::Op::kSet;
    } else if (*operation == "append") {
      op.op = BlinkerHeaderOp::Op::kAppend;
    } else {
      return false;
    }
    if (op.op != BlinkerHeaderOp::Op::kRemove) {
      const std::string* value = item->FindString("value");
      if (!value) {
        return false;
      }
      op.value = *value;
    }
    out->push_back(std::move(op));
  }
  return true;
}

}  // namespace

BlinkerNetActionRule::BlinkerNetActionRule() = default;
BlinkerNetActionRule::BlinkerNetActionRule(const BlinkerNetActionRule&) =
    default;
BlinkerNetActionRule::BlinkerNetActionRule(BlinkerNetActionRule&&) = default;
BlinkerNetActionRule& BlinkerNetActionRule::operator=(
    BlinkerNetActionRule&&) = default;
BlinkerNetActionRule::~BlinkerNetActionRule() = default;

bool BlinkerNetActionRuleFromDnr(const base::DictValue& rule,
                                 const std::string& extension_id,
                                 BlinkerNetActionRule* out) {
  const base::DictValue* action = rule.FindDict("action");
  const base::DictValue* condition = rule.FindDict("condition");
  if (!action || !condition) {
    return false;
  }
  const std::string* type = action->FindString("type");
  if (!type) {
    return false;
  }

  if (*type == "redirect") {
    out->kind = BlinkerNetActionRule::Kind::kRedirect;
    const base::DictValue* redirect = action->FindDict("redirect");
    if (!redirect) {
      return false;
    }
    if (const std::string* path = redirect->FindString("extensionPath")) {
      std::string relative = *path;
      if (!relative.empty() && relative.front() == '/') {
        relative.erase(relative.begin());
      }
      out->redirect_url = GURL(base::StrCat(
          {kBlinkerExtensionScheme, "://", extension_id, "/", relative}));
      if (!out->redirect_url.is_valid()) {
        return false;
      }
    } else if (const std::string* url = redirect->FindString("url")) {
      out->redirect_url = GURL(*url);
      // Тільки туди, куди сторінка і так могла б перейти
      if (!out->redirect_url.is_valid() ||
          (!out->redirect_url.SchemeIsHTTPOrHTTPS() &&
           !out->redirect_url.SchemeIs(kBlinkerExtensionScheme))) {
        return false;
      }
    } else if (const base::DictValue* transform =
                   redirect->FindDict("transform")) {
      // Тільки query, зміна хоста чи шляху це вже інший запит
      for (const auto [key, value] : *transform) {
        if (key != "query" && key != "queryTransform") {
          return false;
        }
      }
      if (const std::string* query = transform->FindString("query")) {
        out->has_replace_query = true;
        out->replace_query = *query;
      }
      if (const base::DictValue* qt = transform->FindDict("queryTransform")) {
        for (const auto [key, value] : *qt) {
          if (key != "removeParams") {
            return false;
          }
        }
        const base::ListValue* remove = qt->FindList("removeParams");
        if (!remove) {
          return false;
        }
        for (const base::Value& entry : *remove) {
          if (const std::string* name = entry.GetIfString()) {
            out->remove_params.push_back(*name);
          }
        }
      }
      if (!out->has_replace_query && out->remove_params.empty()) {
        return false;
      }
    } else {
      return false;
    }
  } else if (*type == "allow" || *type == "allowAllRequests") {
    out->kind = BlinkerNetActionRule::Kind::kAllow;
  } else if (*type == "upgradeScheme") {
    out->kind = BlinkerNetActionRule::Kind::kRedirect;
    out->upgrade_scheme = true;
  } else if (*type == "modifyHeaders") {
    out->kind = BlinkerNetActionRule::Kind::kModifyHeaders;
    if (!ParseHeaderOps(action->FindList("requestHeaders"),
                        &out->request_headers) ||
        !ParseHeaderOps(action->FindList("responseHeaders"),
                        &out->response_headers)) {
      return false;
    }
    if (out->request_headers.empty() && out->response_headers.empty()) {
      return false;
    }
  } else {
    return false;
  }

  if (condition->FindString("regexFilter")) {
    return false;
  }
  out->priority = rule.FindInt("priority").value_or(1);
  out->match_case =
      condition->FindBool("isUrlFilterCaseSensitive").value_or(false);
  if (const std::string* url_filter = condition->FindString("urlFilter")) {
    std::string pattern = *url_filter;
    if (pattern.starts_with("||")) {
      out->hostname_anchor = true;
      pattern.erase(0, 2);
    } else if (pattern.starts_with("|")) {
      out->left_anchor = true;
      pattern.erase(0, 1);
    }
    if (pattern.ends_with("|")) {
      out->right_anchor = true;
      pattern.pop_back();
    }
    out->pattern = out->match_case ? pattern : base::ToLowerASCII(pattern);
    if (out->pattern.find_first_not_of("*^|") == std::string::npos) {
      out->pattern.clear();
    }
  }

  const auto collect = [&condition](const char* key,
                                    std::vector<std::string>* out_list,
                                    bool* bad) {
    const base::ListValue* list = condition->FindList(key);
    if (!list) {
      return;
    }
    for (const base::Value& entry : *list) {
      const std::string* value = entry.GetIfString();
      if (!value) {
        *bad = true;
        return;
      }
      out_list->push_back(NormalizeHost(*value));
    }
  };
  bool bad = false;
  collect("initiatorDomains", &out->domains, &bad);
  collect("domains", &out->domains, &bad);
  collect("excludedInitiatorDomains", &out->excluded_domains, &bad);
  collect("excludedDomains", &out->excluded_domains, &bad);
  // Те саме що й у статичних правилах, ініціатор править за верхню сторінку
  collect("topDomains", &out->domains, &bad);
  collect("excludedTopDomains", &out->excluded_domains, &bad);
  collect("requestDomains", &out->request_domains, &bad);
  collect("excludedRequestDomains", &out->excluded_request_domains, &bad);
  if (bad) {
    return false;
  }

  if (const std::string* domain_type = condition->FindString("domainType")) {
    if (*domain_type == "thirdParty") {
      out->party = BlinkerNetActionRule::Party::kThirdParty;
    } else if (*domain_type == "firstParty") {
      out->party = BlinkerNetActionRule::Party::kFirstParty;
    } else {
      return false;
    }
  }

  const auto types = [&condition](const char* key, uint32_t* mask,
                                  bool* bad_types) {
    const base::ListValue* list = condition->FindList(key);
    if (!list) {
      return;
    }
    for (const base::Value& entry : *list) {
      const std::string* value = entry.GetIfString();
      if (!value) {
        *bad_types = true;
        return;
      }
      const uint32_t bit = TypeBitForDnr(*value);
      if (bit == 0) {
        *bad_types = true;  // невідомий тип, викидаємо правило цілком
        return;
      }
      *mask |= bit;
    }
  };
  bool bad_types = false;
  types("resourceTypes", &out->type_mask, &bad_types);
  types("excludedResourceTypes", &out->excluded_type_mask, &bad_types);
  if (bad_types) {
    return false;
  }

  // Правило без шаблону і без хостів переписало б весь веб, не приймаємо
  if (out->pattern.empty() && out->request_domains.empty() &&
      out->domains.empty()) {
    return false;
  }
  return true;
}

BlinkerExtensionNetActions::RuleSet::RuleSet() = default;
BlinkerExtensionNetActions::RuleSet::~RuleSet() = default;

BlinkerExtensionNetActions::BlinkerExtensionNetActions()
    : rules_(base::MakeRefCounted<RuleSet>()) {}
BlinkerExtensionNetActions::~BlinkerExtensionNetActions() = default;

// static
BlinkerExtensionNetActions& BlinkerExtensionNetActions::GetInstance() {
  static base::NoDestructor<BlinkerExtensionNetActions> instance;
  return *instance;
}

void BlinkerExtensionNetActions::SetRules(
    std::vector<BlinkerNetActionRule> rules) {
  auto set = base::MakeRefCounted<RuleSet>();
  set->rules = std::move(rules);
  // Вищий пріоритет першим, щоб перший збіг був той що вибрав би Chrome
  std::stable_sort(set->rules.begin(), set->rules.end(),
                   [](const BlinkerNetActionRule& a,
                      const BlinkerNetActionRule& b) {
                     return a.priority > b.priority;
                   });
  bool any_extension_target = false;
  for (const BlinkerNetActionRule& rule : set->rules) {
    if (rule.kind == BlinkerNetActionRule::Kind::kRedirect &&
        rule.redirect_url.SchemeIs(kBlinkerExtensionScheme)) {
      any_extension_target = true;
      break;
    }
  }
  base::AutoLock guard(lock_);
  rules_ = std::move(set);
  has_extension_resource_redirects_ = any_extension_target;
}

scoped_refptr<BlinkerExtensionNetActions::RuleSet>
BlinkerExtensionNetActions::Snapshot() const {
  base::AutoLock guard(lock_);
  return rules_;
}

bool BlinkerExtensionNetActions::empty() const {
  base::AutoLock guard(lock_);
  return !rules_ || rules_->rules.empty();
}

bool BlinkerExtensionNetActions::has_extension_resource_redirects() const {
  base::AutoLock guard(lock_);
  return has_extension_resource_redirects_;
}

int BlinkerExtensionNetActions::MaxAllowPriority(
    const GURL& url,
    const GURL& document_url,
    BlinkerResourceType type) const {
  scoped_refptr<RuleSet> set = Snapshot();
  if (!set || set->rules.empty() || !url.is_valid()) {
    return -1;
  }
  const std::string url_lower = base::ToLowerASCII(url.spec());
  std::vector<size_t> label_starts;
  HostLabelStarts(url_lower, &label_starts);
  int highest = -1;
  for (const BlinkerNetActionRule& rule : set->rules) {
    if (rule.kind == BlinkerNetActionRule::Kind::kAllow &&
        rule.priority > highest &&
        Applies(rule, url, url_lower, label_starts, document_url, type)) {
      highest = rule.priority;
    }
  }
  return highest;
}

bool BlinkerExtensionNetActions::ExceptionBeatsRedirect(
    const GURL& url,
    const GURL& document_url,
    BlinkerResourceType type,
    int redirect_priority) const {
  bool from_filters = false;
  BlinkerContentFilter::GetInstance().ShouldBlock(url, document_url, type,
                                                  &from_filters);
  if (!from_filters) {
    return false;
  }
  // Виняток є, а allow або нема, або він не вищий за redirect. Тоді
  // виняток сильніший
  const int allow = MaxAllowPriority(url, document_url, type);
  return allow < 0 || allow >= redirect_priority;
}

GURL BlinkerExtensionNetActions::FindRedirect(
    const GURL& url,
    const GURL& document_url,
    BlinkerResourceType type,
    int* priority) const {
  scoped_refptr<RuleSet> set = Snapshot();
  if (!set || set->rules.empty() || !url.is_valid()) {
    return GURL();
  }
  const std::string url_lower = base::ToLowerASCII(url.spec());
  std::vector<size_t> label_starts;
  HostLabelStarts(url_lower, &label_starts);
  for (const BlinkerNetActionRule& rule : set->rules) {
    if (rule.kind != BlinkerNetActionRule::Kind::kRedirect) {
      continue;
    }
    if (!Applies(rule, url, url_lower, label_starts, document_url, type)) {
      continue;
    }
    const GURL target = TransformUrl(rule, url);
    // Перетворення що нічого не змінило це не редірект, бо буде петля
    if (target.is_valid() && target != url) {
      if (priority) {
        *priority = rule.priority;
      }
      return target;
    }
  }
  return GURL();
}

void BlinkerExtensionNetActions::CollectHeaderOps(
    const GURL& url,
    const GURL& document_url,
    BlinkerResourceType type,
    bool response,
    std::vector<BlinkerHeaderOp>* out) const {
  scoped_refptr<RuleSet> set = Snapshot();
  if (!set || set->rules.empty() || !url.is_valid()) {
    return;
  }
  const std::string url_lower = base::ToLowerASCII(url.spec());
  std::vector<size_t> label_starts;
  HostLabelStarts(url_lower, &label_starts);
  for (const BlinkerNetActionRule& rule : set->rules) {
    if (rule.kind != BlinkerNetActionRule::Kind::kModifyHeaders) {
      continue;
    }
    const std::vector<BlinkerHeaderOp>& ops =
        response ? rule.response_headers : rule.request_headers;
    if (ops.empty()) {
      continue;
    }
    if (!Applies(rule, url, url_lower, label_starts, document_url, type)) {
      continue;
    }
    out->insert(out->end(), ops.begin(), ops.end());
  }
}

namespace {

// Сюди тільки фабрики навігації, підресурси обробляє
// BlinkerInstallSubresourceRedirectHook
class DnrRedirectInterceptor : public network::mojom::URLLoaderFactory {
 public:
  DnrRedirectInterceptor(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target)
      : target_(std::move(target)),
        extension_factory_(BlinkerExtensionURLLoaderFactory::Create()) {
    receivers_.Add(this, std::move(receiver));
    receivers_.set_disconnect_handler(base::BindRepeating(
        &DnrRedirectInterceptor::OnDisconnect, base::Unretained(this)));
  }

  DnrRedirectInterceptor(const DnrRedirectInterceptor&) = delete;
  DnrRedirectInterceptor& operator=(const DnrRedirectInterceptor&) = delete;

 private:
  ~DnrRedirectInterceptor() override = default;

  void OnDisconnect() {
    if (receivers_.empty()) {
      delete this;
    }
  }

  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation) override {
    BlinkerExtensionNetActions& actions =
        BlinkerExtensionNetActions::GetInstance();
    if (!actions.empty() && request.url.SchemeIsHTTPOrHTTPS()) {
      int priority = 0;
      const GURL target = actions.FindRedirect(
          request.url, BlinkerDocumentUrlForRequest(request),
          BlinkerResourceTypeForRequest(request), &priority);
      if (!actions.ExceptionBeatsRedirect(
              request.url, BlinkerDocumentUrlForRequest(request),
              BlinkerResourceTypeForRequest(request), priority)) {
        if (target.is_valid() &&
            target.SchemeIs(kBlinkerExtensionScheme)) {
          // Розширення саме перевіряє web_accessible_resources, неопублікований
          // ресурс отримає відмову
          network::ResourceRequest rewritten = request;
          rewritten.url = target;
          extension_factory_->CreateLoaderAndStart(
              std::move(loader), request_id, options, rewritten,
              std::move(client), annotation);
          return;
        }
      }
    }
    target_->CreateLoaderAndStart(std::move(loader), request_id, options,
                                  request, std::move(client), annotation);
  }

  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver)
      override {
    receivers_.Add(this, std::move(receiver));
  }

  mojo::Remote<network::mojom::URLLoaderFactory> target_;
  mojo::Remote<network::mojom::URLLoaderFactory> extension_factory_;
  mojo::ReceiverSet<network::mojom::URLLoaderFactory> receivers_;
};

}  // namespace

bool BlinkerHasExtensionResourceRedirects() {
  return BlinkerExtensionNetActions::GetInstance()
      .has_extension_resource_redirects();
}

namespace {

GURL BlinkerSubresourceRedirect(
    const GURL& url,
    network::mojom::RequestDestination destination,
    const GURL& document_url) {
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return GURL();
  }
  BlinkerExtensionNetActions& actions =
      BlinkerExtensionNetActions::GetInstance();
  if (!actions.has_extension_resource_redirects()) {
    return GURL();
  }
  const BlinkerResourceType type =
      BlinkerResourceTypeForDestination(destination);

  int priority = 0;
  const GURL target = actions.FindRedirect(url, document_url, type, &priority);
  if (target.is_valid() &&
      actions.ExceptionBeatsRedirect(url, document_url, type, priority)) {
    return GURL();
  }
  // Тільки ресурси розширення. Редірект в тій же схемі робить throttle
  if (!target.is_valid() || !target.SchemeIs(kBlinkerExtensionScheme)) {
    return GURL();
  }
  static int logged = 0;
  if (++logged <= 8) {
    BLINKER_DIAGF("DNR_STUB %s -> %s",
                  blinker_logging::LoggableURLSpec(url).c_str(),
                  target.spec().c_str());
  }
  return target;
}

}  // namespace

void BlinkerInstallSubresourceRedirectHook() {
  blink::SetBlinkerRequestRedirectHook(&BlinkerSubresourceRedirect);
}

void BlinkerInstallDnrRedirectInterceptor(
    network::URLLoaderFactoryBuilder& factory_builder) {
  auto [receiver, remote] = factory_builder.Append();
  new DnrRedirectInterceptor(std::move(receiver), std::move(remote));
}

}  // namespace content
