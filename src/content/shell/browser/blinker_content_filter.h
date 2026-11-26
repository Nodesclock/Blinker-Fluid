// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_
#define CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/ref_counted.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/thread_annotations.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "url/gurl.h"

namespace re2 {
class RE2;
}  // namespace re2

namespace content {

class BlinkerContentFilterTestPeer;

enum class BlinkerResourceType : uint32_t {
  kOther = 1u << 0,
  kScript = 1u << 1,
  kImage = 1u << 2,
  kStylesheet = 1u << 3,
  kObject = 1u << 4,
  kXmlHttpRequest = 1u << 5,
  kSubdocument = 1u << 6,
  kPing = 1u << 7,
  kMedia = 1u << 8,
  kFont = 1u << 9,
  kWebSocket = 1u << 10,
  kDocument = 1u << 11,
  kPopup = 1u << 12,
};

// Правило з незнайомою опцією відкидаємо, бо блокувало б ширше
// Набір незмінний, читачі шукають без замка
class BlinkerContentFilter {
 public:
  static constexpr uint32_t kLocalSourceMask = 1u;
  static constexpr size_t kMaxSourceBits = 32;

  // Шматки спільні, копія на сотні тисяч рядків це мегабайти
  struct ExtensionRules {
    std::string extension_id;
    std::vector<std::shared_ptr<const std::string>> chunks;
  };

  // Пошук по string_view без копії, іде на кожен запит
  struct StringHash {
    using is_transparent = void;
    size_t operator()(std::string_view value) const {
      return std::hash<std::string_view>()(value);
    }
  };
  template <typename Value>
  using StringMap =
      std::unordered_map<std::string, Value, StringHash, std::equal_to<>>;
  using StringSet = std::unordered_set<std::string, StringHash, std::equal_to<>>;

  struct RuleStats {
    size_t network_rules = 0;
    size_t cosmetic_rules = 0;
    size_t exception_rules = 0;
  };

  struct NetworkRule {
    NetworkRule();
    NetworkRule(const NetworkRule&);
    NetworkRule(NetworkRule&&);
    NetworkRule& operator=(const NetworkRule&);
    NetworkRule& operator=(NetworkRule&&);
    ~NetworkRule();

    std::string pattern;
    uint32_t type_mask = 0;
    uint32_t excluded_type_mask = 0;
    enum class Party { kAny, kFirstParty, kThirdParty };
    Party party = Party::kAny;
    // Виключений домен завжди виграє. Усі списки відсортовані для бінарного
    // пошуку
    std::vector<std::string> domains;
    std::vector<std::string> excluded_domains;
    std::vector<std::string> request_domains;
    std::vector<std::string> excluded_request_domains;
    bool hostname_anchor = false;
    bool left_anchor = false;
    bool right_anchor = false;
    bool match_case = false;
    std::shared_ptr<const re2::RE2> regex;
    // Виняток одного розширення не скасовує блок іншого
    uint32_t source_mask = kLocalSourceMask;
  };

  static BlinkerContentFilter& GetInstance();

  BlinkerContentFilter(const BlinkerContentFilter&) = delete;
  BlinkerContentFilter& operator=(const BlinkerContentFilter&) = delete;

  void EnsureLoaded();

  void ReloadFromFiles(const std::vector<base::FilePath>& lists);

  void SetExtensionRules(std::vector<ExtensionRules> rules);

  bool ShouldBlock(const GURL& url,
                   const GURL& document_url,
                   BlinkerResourceType type) const;
  bool ShouldBlock(const GURL& url,
                   const GURL& document_url,
                   BlinkerResourceType type,
                   bool* allowed_by_exception) const;
  bool ShouldBlock(const GURL& url) const;

  std::string CosmeticCSSFor(std::string_view host) const;

  bool enabled() const;
  void SetEnabled(bool enabled);

  // Діє по хосту документа, не запиту
  void SetHostAllowlisted(std::string_view host, bool allowlisted);
  bool IsHostAllowlisted(std::string_view host) const;

  uint64_t blocked_count() const;
  uint64_t blocked_count_for_host(std::string_view host) const;
  void ResetHostCount(std::string_view host);
  void RecordBlocked(std::string_view document_host);
  void RecordBlocked();

  RuleStats rule_stats() const;
  size_t rule_count() const;

 private:
  friend class base::NoDestructor<BlinkerContentFilter>;
  friend class BlinkerContentFilterTestPeer;

  // Міняється цілком, щоб читачі не бачили напівзібраний набір
  class RuleSet : public base::RefCountedThreadSafe<RuleSet> {
   public:
    RuleSet();

    StringMap<uint32_t> blocked_hosts;
    StringMap<uint32_t> allowed_hosts;

    StringMap<std::vector<NetworkRule>> block_rules;
    std::vector<NetworkRule> block_rules_untokenized;
    StringMap<std::vector<NetworkRule>> allow_rules;
    std::vector<NetworkRule> allow_rules_untokenized;

    std::vector<std::string> generic_hide_selectors;
    StringMap<std::vector<std::string>> host_hide_selectors;
    StringMap<std::vector<std::string>> host_hide_exceptions;
    std::string generic_hide_css;

    size_t pattern_rule_count = 0;
    size_t exception_rule_count = 0;

   private:
    friend class base::RefCountedThreadSafe<RuleSet>;
    ~RuleSet();
  };

  class Builder;

  BlinkerContentFilter();
  ~BlinkerContentFilter();

  scoped_refptr<const RuleSet> rules() const;
  void SetRules(scoped_refptr<const RuleSet> rules);

  void RebuildRules();
  void ScheduleRebuild();

  void LoadRulesForTesting(const std::vector<std::string>& lines);

  void LoadRulesForTesting(const std::vector<std::string>& lines,
                           const std::vector<ExtensionRules>& extensions);

  std::atomic<bool> enabled_{false};
  std::atomic<uint64_t> blocked_count_{0};

  mutable base::Lock lock_;
  scoped_refptr<const RuleSet> rules_ GUARDED_BY(lock_);
  StringSet allowlisted_hosts_ GUARDED_BY(lock_);
  std::vector<base::FilePath> list_paths_ GUARDED_BY(lock_);
  std::shared_ptr<const std::vector<ExtensionRules>> extension_rules_
      GUARDED_BY(lock_);
  // щоб повільна перебудова не перезаписала новішу, яка закінчилась раніше
  uint64_t rules_generation_ GUARDED_BY(lock_) = 0;
  bool rebuild_pending_ GUARDED_BY(lock_) = false;
  std::unordered_map<std::string, uint64_t> per_host_counts_ GUARDED_BY(lock_);

  bool loaded_ = false;
};

// Його ж бере хук редиректу в Blink, щоб тип не розійшовся
BlinkerResourceType BlinkerResourceTypeForDestination(
    network::mojom::RequestDestination destination);

BlinkerResourceType BlinkerResourceTypeForRequest(
    const network::ResourceRequest& request);
GURL BlinkerDocumentUrlForRequest(const network::ResourceRequest& request);

class BlinkerContentFilterThrottle : public blink::URLLoaderThrottle {
 public:
  BlinkerContentFilterThrottle();
  ~BlinkerContentFilterThrottle() override;

  void DetachFromCurrentSequence() override;
  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override;
  void WillRedirectRequest(
      net::RedirectInfo* redirect_info,
      const network::mojom::URLResponseHead& response_head,
      bool* defer,
      network::HttpRequestHeadersUpdateParams* headers_update_params) override;
  void WillProcessResponse(const GURL& response_url,
                           network::mojom::URLResponseHead* response_head,
                           bool* defer) override;
  void WillOnCompleteWithError(
      const network::URLLoaderCompletionStatus& status) override;

 private:
  void ApplyExtensionActions(network::ResourceRequest* request);

  // Без слухачів webRequest це одне атомарне читання
  void NotifyWebRequestStart(const network::ResourceRequest& request);

  uint64_t web_request_id_ = 0;
  int tab_id_ = -1;

  GURL document_url_;
  GURL request_url_;
  GURL redirected_from_;
  BlinkerResourceType type_ = BlinkerResourceType::kOther;
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_CONTENT_FILTER_H_
