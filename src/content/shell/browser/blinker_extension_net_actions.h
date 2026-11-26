// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_NET_ACTIONS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_NET_ACTIONS_H_

#include <stdint.h>

#include <string>
#include <vector>

#include "base/memory/ref_counted.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "url/gurl.h"

namespace base {
class DictValue;
}

namespace content {

// DNR redirect і modifyHeaders рядком фільтра не виразити, тому вони тут.
// Заглушки треба, бо голий блок трекера ламає сторінку

struct BlinkerHeaderOp {
  enum class Op { kSet, kAppend, kRemove };
  Op op = Op::kRemove;
  std::string name;
  std::string value;
};

struct BlinkerNetActionRule {
  BlinkerNetActionRule();
  BlinkerNetActionRule(const BlinkerNetActionRule&);
  BlinkerNetActionRule(BlinkerNetActionRule&&);
  BlinkerNetActionRule& operator=(BlinkerNetActionRule&&);
  ~BlinkerNetActionRule();

  std::string pattern;
  bool hostname_anchor = false;
  bool left_anchor = false;
  bool right_anchor = false;
  bool match_case = false;
  uint32_t type_mask = 0;
  uint32_t excluded_type_mask = 0;
  enum class Party { kAny, kFirstParty, kThirdParty };
  Party party = Party::kAny;
  std::vector<std::string> domains;
  std::vector<std::string> excluded_domains;
  std::vector<std::string> request_domains;
  std::vector<std::string> excluded_request_domains;
  int priority = 1;

  // kAllow лишається лише щоб порівняти пріоритет з redirect
  enum class Kind { kRedirect, kModifyHeaders, kAllow };
  Kind kind = Kind::kRedirect;

  GURL redirect_url;
  std::vector<std::string> remove_params;
  std::string replace_query;
  bool has_replace_query = false;
  bool upgrade_scheme = false;

  std::vector<BlinkerHeaderOp> request_headers;
  std::vector<BlinkerHeaderOp> response_headers;
};

bool BlinkerNetActionRuleFromDnr(const base::DictValue& rule,
                                 const std::string& extension_id,
                                 BlinkerNetActionRule* out);

// Читається в мережевій послідовності, міняється в UI, тому незмінний
// знімок під замком
class BlinkerExtensionNetActions {
 public:
  static BlinkerExtensionNetActions& GetInstance();

  BlinkerExtensionNetActions(const BlinkerExtensionNetActions&) = delete;
  BlinkerExtensionNetActions& operator=(const BlinkerExtensionNetActions&) =
      delete;

  void SetRules(std::vector<BlinkerNetActionRule> rules);

  bool empty() const;

  // Такий redirect потребує перехоплювача фабрики, а не throttle
  bool has_extension_resource_redirects() const;

  GURL FindRedirect(const GURL& url,
                    const GURL& document_url,
                    BlinkerResourceType type,
                    int* priority = nullptr) const;

  // У DNR allow перемагає redirect лише з не нижчим пріоритетом
  int MaxAllowPriority(const GURL& url,
                       const GURL& document_url,
                       BlinkerResourceType type) const;

  bool ExceptionBeatsRedirect(const GURL& url,
                              const GURL& document_url,
                              BlinkerResourceType type,
                              int redirect_priority) const;

  void CollectHeaderOps(const GURL& url,
                        const GURL& document_url,
                        BlinkerResourceType type,
                        bool response,
                        std::vector<BlinkerHeaderOp>* out) const;

 private:
  friend class base::NoDestructor<BlinkerExtensionNetActions>;

  class RuleSet : public base::RefCountedThreadSafe<RuleSet> {
   public:
    RuleSet();
    std::vector<BlinkerNetActionRule> rules;

   private:
    friend class base::RefCountedThreadSafe<RuleSet>;
    ~RuleSet();
  };

  BlinkerExtensionNetActions();
  ~BlinkerExtensionNetActions();

  scoped_refptr<RuleSet> Snapshot() const;

  mutable base::Lock lock_;
  scoped_refptr<RuleSet> rules_ GUARDED_BY(lock_);
  bool has_extension_resource_redirects_ GUARDED_BY(lock_) = false;
};

// URLLoaderThrottle не перенаправить http(s) на іншу схему (NOTREACHED у
// ThrottlingURLLoader), тому для навігацій фабрика
void BlinkerInstallDnrRedirectInterceptor(
    network::URLLoaderFactoryBuilder& factory_builder);

bool BlinkerHasExtensionResourceRedirects();

// Підресурси не йдуть через фабрики вбудовувача, тому Blink питає хук
// перед завантажувачем
void BlinkerInstallSubresourceRedirectHook();

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_NET_ACTIONS_H_
