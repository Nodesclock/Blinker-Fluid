// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "content/shell/browser/blinker_filter_subscriptions.h"

#include <algorithm>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/uuid.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "net/base/load_flags.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace content {
namespace {
constexpr size_t kMaxListBytes = 8 * 1024 * 1024;
constexpr size_t kMaxLists = 16;
bool ValidURL(const GURL& url) {
  return url.is_valid() && url.SchemeIs("https") && url.has_host() &&
         !url.has_username() && !url.has_password() && !url.has_ref();
}
base::DictValue ReadState(const base::FilePath& path) {
  std::string data;
  if (!base::ReadFileToStringWithMaxSize(path, &data, 128 * 1024)) {
    return {};
  }
  auto state = base::JSONReader::ReadDict(data, base::JSON_PARSE_RFC)
                   .value_or(base::DictValue());
  if (auto* lists = state.FindList("lists")) {
    for (auto& item : *lists) {
      auto* dict = item.GetIfDict();
      const auto* id = dict ? dict->FindString("id") : nullptr;
      if (id && base::Uuid::ParseLowercase(*id).is_valid() &&
          !base::PathExists(path.DirName().AppendASCII(*id + ".txt"))) {
        dict->Set("updated", 0.0);
      }
    }
  }
  return state;
}
bool WriteCache(const base::FilePath& path, const std::string& body) {
  return base::CreateDirectory(path.DirName()) &&
         base::ImportantFileWriter::WriteFileAtomically(path, body);
}
// Сервер може віддати HTML логіну зі статусом 200, його не можна в кеш
bool LooksLikeList(std::string_view body) {
  if (body.starts_with("\xEF\xBB\xBF")) {
    body.remove_prefix(3);
  }
  body = base::TrimWhitespaceASCII(body, base::TRIM_ALL);
  if (body.empty() || body.find('\0') != std::string_view::npos) {
    return false;
  }
  const std::string lower = base::ToLowerASCII(body.substr(0, 1024));
  if (lower.find("<html") != std::string::npos ||
      lower.find("<!doctype") != std::string::npos) {
    return false;
  }
  return body.starts_with("[Adblock") || body.starts_with("[uBlock") ||
         body.starts_with("!") || body.starts_with("||") ||
         body.starts_with("@@") || body.starts_with("##") ||
         body.starts_with("0.0.0.0 ") || body.starts_with("127.0.0.1 ") ||
         (body.find('\n') != std::string_view::npos &&
          (body.find("##") != std::string_view::npos ||
           body.find("||") != std::string_view::npos));
}
}  // namespace

BlinkerFilterSubscriptions::List::List() = default;
BlinkerFilterSubscriptions::List::List(const List&) = default;
BlinkerFilterSubscriptions::List::List(List&&) = default;
BlinkerFilterSubscriptions::List& BlinkerFilterSubscriptions::List::operator=(
    const List&) = default;
BlinkerFilterSubscriptions::List& BlinkerFilterSubscriptions::List::operator=(
    List&&) = default;
BlinkerFilterSubscriptions::List::~List() = default;

BlinkerFilterSubscriptions& BlinkerFilterSubscriptions::GetInstance() {
  static base::NoDestructor<BlinkerFilterSubscriptions> instance;
  return *instance;
}
BlinkerFilterSubscriptions::BlinkerFilterSubscriptions() = default;
BlinkerFilterSubscriptions::~BlinkerFilterSubscriptions() = default;

void BlinkerFilterSubscriptions::Start(BrowserContext* context,
                                       const base::FilePath& documents) {
  // Приватний режим бере збережені правила, але підписки не качає
  if (!context->IsOffTheRecord() && !factory_) {
    factory_ = context->GetDefaultStoragePartition()
                   ->GetURLLoaderFactoryForBrowserProcess();
  }
  if (started_) {
    return;
  }
  started_ = true;
  directory_ = documents.AppendASCII("FilterSubscriptions");
  worker_ = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  worker_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ReadState, directory_.AppendASCII("lists.json")),
      base::BindOnce(&BlinkerFilterSubscriptions::Loaded,
                     base::Unretained(this)));
}

void BlinkerFilterSubscriptions::Loaded(base::DictValue state) {
  const base::ListValue* saved = state.FindList("lists");
  if (saved) {
    for (const auto& item : *saved) {
      const auto* dict = item.GetIfDict();
      if (!dict || lists_.size() >= kMaxLists) {
        continue;
      }
      const auto* id = dict->FindString("id");
      const auto* url = dict->FindString("url");
      const auto* name = dict->FindString("name");
      if (!id || !base::Uuid::ParseLowercase(*id).is_valid() || Find(*id) ||
          !url || !ValidURL(GURL(*url))) {
        continue;
      }
      List list;
      list.id = *id;
      list.url = GURL(*url);
      list.name =
          name && !name->empty() ? name->substr(0, 120) : list.url.host();
      list.enabled = dict->FindBool("enabled").value_or(true);
      list.updated = base::Time::FromSecondsSinceUnixEpoch(
          dict->FindDouble("updated").value_or(0));
      list.status =
          list.updated.is_null() || list.updated == base::Time::UnixEpoch()
              ? "Waiting for download"
              : "Cached";
      lists_.push_back(std::move(list));
    }
  } else {
    for (const auto& preset :
         {std::pair{"EasyList", "https://easylist.to/easylist/easylist.txt"},
          std::pair{"EasyPrivacy",
                    "https://easylist.to/easylist/easyprivacy.txt"}}) {
      List list;
      list.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
      list.name = preset.first;
      list.url = GURL(preset.second);
      list.status = "Waiting for download";
      lists_.push_back(std::move(list));
    }
  }
  ready_ = true;
  Save();
  Reload();
  timer_.Start(FROM_HERE, base::Hours(1),
               base::BindRepeating(&BlinkerFilterSubscriptions::Refresh,
                                   base::Unretained(this), false));
  Refresh(false);
}

BlinkerFilterSubscriptions::List* BlinkerFilterSubscriptions::Find(
    const std::string& id) {
  auto it = std::ranges::find(lists_, id, &List::id);
  return it == lists_.end() ? nullptr : &*it;
}
base::FilePath BlinkerFilterSubscriptions::CachePath(
    const std::string& id) const {
  return directory_.AppendASCII(id + ".txt");
}

std::string BlinkerFilterSubscriptions::Add(const GURL& url, std::string name) {
  if (!ready_) {
    return "Filter lists are still loading.";
  }
  if (!ValidURL(url)) {
    return "Enter an HTTPS list URL without a username, password or fragment.";
  }
  if (lists_.size() >= kMaxLists) {
    return "Remove a list before adding another (maximum 16).";
  }
  if (std::ranges::any_of(lists_,
                          [&](const List& list) { return list.url == url; })) {
    return "This list is already subscribed.";
  }
  List list;
  list.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  list.name = name.empty() ? url.host() : name.substr(0, 120);
  list.url = url;
  list.status = "Waiting for download";
  lists_.push_back(std::move(list));
  Save();
  Refresh(false);
  return {};
}

void BlinkerFilterSubscriptions::SetEnabled(const std::string& id,
                                            bool enabled) {
  List* list = Find(id);
  if (!list) {
    return;
  }
  list->enabled = enabled;
  if (!enabled && downloading_ == id && loader_) {
    loader_.reset();
    downloading_.clear();
    list->status = "Cached";
  }
  Save();
  Reload();
  Refresh(false);
}
void BlinkerFilterSubscriptions::Remove(const std::string& id) {
  if (downloading_ == id && loader_) {
    loader_.reset();
    downloading_.clear();
  }
  std::erase_if(lists_, [&](const List& list) { return list.id == id; });
  Save();
  Reload();
  worker_->PostTask(
      FROM_HERE,
      base::BindOnce([](base::FilePath path) { base::DeleteFile(path); },
                     CachePath(id)));
  Refresh(false);
}

void BlinkerFilterSubscriptions::Save() {
  base::ListValue items;
  for (const List& list : lists_) {
    items.Append(base::DictValue()
                     .Set("id", list.id)
                     .Set("name", list.name)
                     .Set("url", list.url.spec())
                     .Set("enabled", list.enabled)
                     .Set("updated", list.updated.InSecondsFSinceUnixEpoch()));
  }
  base::DictValue state;
  state.Set("lists", std::move(items));
  auto json = base::WriteJson(state);
  if (json) {
    worker_->PostTask(
        FROM_HERE,
        base::BindOnce([](base::FilePath path,
                          std::string data) { WriteCache(path, data); },
                       directory_.AppendASCII("lists.json"), std::move(*json)));
  }
}
void BlinkerFilterSubscriptions::Reload() {
  std::vector<base::FilePath> paths;
  for (const List& list : lists_) {
    if (list.enabled) {
      paths.push_back(CachePath(list.id));
    }
  }
  worker_->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::vector<base::FilePath> files) {
            BlinkerContentFilter::GetInstance().ReloadFromFiles(files);
          },
          std::move(paths)));
}

void BlinkerFilterSubscriptions::Refresh(bool force) {
  if (!ready_ || !factory_) {
    return;
  }
  if (force) {
    for (List& list : lists_) {
      if (list.id != downloading_) {
        list.attempted = base::Time();
        list.force_update = true;
      }
    }
  }
  if (!downloading_.empty()) {
    return;
  }
  const base::Time now = base::Time::Now();
  for (List& list : lists_) {
    if (!list.enabled ||
        (!list.force_update && now - list.updated < base::Days(1)) ||
        (!list.attempted.is_null() && now - list.attempted < base::Hours(1))) {
      continue;
    }
    list.force_update = false;
    list.attempted = now;
    list.status = "Downloading...";
    downloading_ = list.id;
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = list.url;
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->load_flags = net::LOAD_DISABLE_CACHE;
    constexpr auto annotation =
        net::DefineNetworkTrafficAnnotation("blinker_filter_subscription", R"(
          semantics {
            sender: "Blinker filter subscriptions"
            description: "Downloads enabled ad and tracker filter lists."
            trigger: "Startup, daily refresh or an explicit settings action."
            data: "The configured list URL; no cookies or browsing history."
            destination: OTHER
            destination_other: "Filter list publisher selected in settings."
          }
          policy {
            cookies_allowed: NO
            setting: "Disable or remove the list in Ad & Tracker Blocking."
            policy_exception_justification: "Content shell has no enterprise policy."
          })");
    loader_ = network::SimpleURLLoader::Create(std::move(request), annotation);
    loader_->SetTimeoutDuration(base::Seconds(45));
    loader_->SetOnRedirectCallback(base::BindRepeating(
        [](BlinkerFilterSubscriptions* subscriptions, std::string id,
           const GURL&, const net::RedirectInfo& redirect,
           const network::mojom::URLResponseHead&, std::vector<std::string>*) {
          if (ValidURL(redirect.new_url)) {
            return;
          }
          subscriptions->loader_.reset();
          subscriptions->downloading_.clear();
          if (List* list = subscriptions->Find(id)) {
            list->status = "Unsafe redirect, kept cached rules";
          }
          base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
              FROM_HERE,
              base::BindOnce(&BlinkerFilterSubscriptions::Refresh,
                             base::Unretained(subscriptions), false));
        },
        base::Unretained(this), list.id));
    loader_->DownloadToString(
        factory_.get(),
        base::BindOnce(&BlinkerFilterSubscriptions::Downloaded,
                       base::Unretained(this), list.id),
        kMaxListBytes);
    return;
  }
}

void BlinkerFilterSubscriptions::Downloaded(std::string id,
                                            std::optional<std::string> body) {
  const auto* info = loader_->ResponseInfo();
  bool success = body && LooksLikeList(*body) && info && info->headers &&
                 info->headers->response_code() == 200 &&
                 loader_->GetFinalURL().SchemeIs("https");
  loader_.reset();
  if (!success) {
    if (List* list = Find(id)) {
      list->status = "Update failed, kept cached rules";
    }
    downloading_.clear();
    Refresh(false);
    return;
  }
  if (List* list = Find(id)) {
    list->status = "Saving...";
  }
  worker_->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&WriteCache, CachePath(id), std::move(*body)),
      base::BindOnce(&BlinkerFilterSubscriptions::Installed,
                     base::Unretained(this), id));
}
void BlinkerFilterSubscriptions::Installed(std::string id, bool success) {
  downloading_.clear();
  if (List* list = Find(id)) {
    list->status = success ? "Up to date" : "Save failed, kept cached rules";
    if (success) {
      list->updated = base::Time::Now();
    }
    Save();
    Reload();
  }
  Refresh(false);
}
}  // namespace content
