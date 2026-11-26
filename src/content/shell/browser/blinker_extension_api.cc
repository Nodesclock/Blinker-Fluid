// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extension_api.h"

#include <algorithm>
#include <map>
#include <set>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/hash/hash.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "base/uuid.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_url_parameters.h"
#include "components/download/public/common/simple_download_manager.h"
#include "content/public/browser/download_manager.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/document_user_data.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/frame_type.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/service_worker_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/common/url_constants.h"
#include "net/base/net_errors.h"
#include "content/shell/browser/blinker_extension_api_tables.h"
#include "content/shell/browser/blinker_extension_storage.h"
#include "content/shell/browser/blinker_extension_messaging.h"
#include "content/shell/browser/blinker_extensions.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/browser/blinker_web_request.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "net/cookies/cookie_change_dispatcher.h"
#include "net/cookies/cookie_util.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/service_manager/public/cpp/interface_provider.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "content/shell/common/blinker_match_pattern.h"
#include "content/shell/common/blinker_script_executor.mojom.h"
#include "url/origin.h"
#include "url/url_constants.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/geometry/rect.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "third_party/blink/public/common/messaging/string_message_codec.h"
#include "third_party/re2/src/re2/re2.h"

namespace content {

std::string BlinkCaptureVisibleTab(Shell* shell, bool png, int quality);
// Реалізовано в shell_platform_delegate_ios.mm, бо треба UIKit.
extern "C" void BlinkShellWillCloseReactivate(Shell* closing,
                                              WebContents* preferred_opener);
std::string BlinkBookmarksOp(const std::string& request_json);
void BlinkConfirmExtensionUninstall(const std::string& extension_id);

namespace {

namespace bx = blinker_extensions;

std::map<WebContents*, int>& TabIds() {
  static base::NoDestructor<std::map<WebContents*, int>> ids;
  return *ids;
}

int TabIdFor(WebContents* contents) {
  if (!contents) {
    return -1;
  }
  static int next_id = 1;
  auto [it, inserted] = TabIds().try_emplace(contents, 0);
  if (inserted) {
    it->second = next_id++;
  }
  return it->second;
}

Shell* ShellForTabId(int tab_id) {
  for (Shell* shell : Shell::windows()) {
    if (shell && shell->web_contents() &&
        TabIdFor(shell->web_contents()) == tab_id) {
      return shell;
    }
  }
  return nullptr;
}

// Вкладка, над якою відкрито сторінку розширення. Живе на WebContents попапу.
class ExtensionPageOpener : public base::SupportsUserData::Data {
 public:
  static const void* Key() {
    static const char key = 0;
    return &key;
  }
  explicit ExtensionPageOpener(base::WeakPtr<WebContents> opener)
      : opener_(std::move(opener)) {}
  WebContents* opener() const { return opener_.get(); }

 private:
  base::WeakPtr<WebContents> opener_;
};

// Вкладка під попапом, якщо вона ще є. Без цього "активною" була б перша
// вкладка в списку, і попап перезавантажував та наповнював чужу сторінку.
Shell* ShellUnderExtensionPage(WebContents* page) {
  WebContents* opener = BlinkerExtensionPageOpener(page);
  return opener ? Shell::FromWebContents(opener) : nullptr;
}

// Попап відкривається вкладкою, тому сторінка розширення поступається
// сторінці під нею
Shell* ActiveShell() {
  Shell* extension_page = nullptr;
  for (Shell* shell : Shell::windows()) {
    if (!shell || !shell->web_contents() ||
        shell->web_contents()->GetVisibility() != Visibility::VISIBLE) {
      continue;
    }
    if (shell->web_contents()->GetLastCommittedURL().SchemeIs(
            kBlinkerExtensionScheme)) {
      if (Shell* under = ShellUnderExtensionPage(shell->web_contents())) {
        return under;
      }
      extension_page = extension_page ? extension_page : shell;
      continue;
    }
    return shell;
  }
  for (Shell* shell : Shell::windows()) {
    if (shell && shell->web_contents() &&
        !shell->web_contents()->GetLastCommittedURL().SchemeIs(
            kBlinkerExtensionScheme)) {
      return shell;
    }
  }
  if (extension_page) {
    return extension_page;
  }
  return Shell::windows().empty() ? nullptr : Shell::windows().front();
}

constexpr int kWindowId = 1;

int TabIndex(Shell* shell) {
  const auto& windows = Shell::windows();
  const auto it = std::find(windows.begin(), windows.end(), shell);
  return it == windows.end() ? -1 : static_cast<int>(it - windows.begin());
}

std::map<WebContents*, GURL>& TabFavicons() {
  static base::NoDestructor<std::map<WebContents*, GURL>> favicons;
  return *favicons;
}

const char* LoadingStatus(WebContents* contents) {
  if (contents->WasDiscarded()) {
    return "unloaded";
  }
  return contents->IsLoading() ? "loading" : "complete";
}

base::DictValue TabToValue(Shell* shell) {
  base::DictValue tab;
  WebContents* contents = shell->web_contents();
  const bool active = shell == ActiveShell();
  tab.Set("id", TabIdFor(contents));
  tab.Set("index", TabIndex(shell));
  tab.Set("windowId", kWindowId);
  tab.Set("active", active);
  tab.Set("highlighted", active);
  tab.Set("selected", active);
  tab.Set("pinned", false);
  tab.Set("audible", contents->IsCurrentlyAudible());
  tab.Set("discarded", contents->WasDiscarded());
  tab.Set("autoDiscardable", true);
  tab.Set("frozen", false);
  tab.Set("groupId", -1);
  base::DictValue muted;
  muted.Set("muted", contents->IsAudioMuted());
  tab.Set("mutedInfo", std::move(muted));
  tab.Set("incognito", contents->GetBrowserContext()->IsOffTheRecord());
  // url це остання закомічена адреса, нова в pendingUrl як у Chrome
  tab.Set("url", contents->GetLastCommittedURL().spec());
  if (const NavigationEntry* pending =
          contents->GetController().GetPendingEntry()) {
    tab.Set("pendingUrl", pending->GetURL().spec());
  }
  tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
  if (const auto it = TabFavicons().find(contents);
      it != TabFavicons().end() && it->second.is_valid()) {
    tab.Set("favIconUrl", it->second.spec());
  }
  tab.Set("status", LoadingStatus(contents));
  const gfx::Rect bounds = contents->GetContainerBounds();
  tab.Set("width", bounds.width());
  tab.Set("height", bounds.height());
  return tab;
}

constexpr int kWindowIdCurrent = -2;

std::optional<int> OptionalInt(const base::DictValue& dict,
                               std::string_view key) {
  const std::optional<double> value = dict.FindDouble(key);
  if (!value) {
    return std::nullopt;
  }
  return static_cast<int>(*value);
}

std::string TabNotFound(int tab_id) {
  return base::StrCat({"No tab with id: ", base::NumberToString(tab_id), "."});
}

Shell* DefaultTab(const base::DictValue& request, std::string* error) {
  const std::optional<int> tab_id = OptionalInt(request, "tabId");
  Shell* shell = tab_id ? ShellForTabId(*tab_id) : ActiveShell();
  if (!shell || !shell->web_contents()) {
    *error = tab_id ? TabNotFound(*tab_id) : std::string("No selected tab");
    return nullptr;
  }
  return shell;
}

base::DictValue ZoomSettings() {
  base::DictValue settings;
  settings.Set("mode", "automatic");
  settings.Set("scope", "per-origin");
  return settings;
}

Shell* VisibleShell() {
  for (Shell* shell : Shell::windows()) {
    if (shell && shell->web_contents() &&
        shell->web_contents()->GetVisibility() == Visibility::VISIBLE) {
      return shell;
    }
  }
  return nullptr;
}

// Адреса що сама не розбирається береться від кореня розширення
// тому "options.html" відкриває його сторінку
bool PrepareUrlForNavigation(const std::string& url_string,
                             const std::string& extension_id,
                             GURL* out,
                             std::string* error) {
  GURL url(url_string);
  if (!url.is_valid()) {
    url = GURL(base::StrCat({kBlinkerExtensionScheme, "://", extension_id,
                             "/"}))
              .Resolve(url_string);
  }
  if (url.SchemeIs(url::kJavaScriptScheme)) {
    *error =
        "JavaScript URLs are not allowed in API based extension navigations. "
        "Use chrome.scripting.executeScript instead.";
    return false;
  }
  if (url.SchemeIsFile()) {
    *error = "Cannot navigate to a file URL without local file access.";
    return false;
  }
  if (!url.is_valid() ||
      (!url.SchemeIsHTTPOrHTTPS() && !url.SchemeIs(url::kAboutScheme) &&
       !url.SchemeIs(url::kDataScheme) &&
       !url.SchemeIs(kBlinkerExtensionScheme))) {
    *error = base::StrCat({"Invalid url: \"", url_string, "\"."});
    return false;
  }
  *out = std::move(url);
  return true;
}

// Дія користувача дає activeTab доступ поки вкладка не перейде на інше
// походження
class ActiveTabGrants {
 public:
  static ActiveTabGrants& Get() {
    static base::NoDestructor<ActiveTabGrants> grants;
    return *grants;
  }

  void Grant(const std::string& extension_id, WebContents* contents) {
    if (!contents || !BlinkerWebExtensionRegistry::GetInstance().HasPermission(
                         extension_id, "activeTab")) {
      return;
    }
    grants_[contents][extension_id] =
        contents->GetPrimaryMainFrame()->GetLastCommittedOrigin();
  }

  bool Covers(const std::string& extension_id,
              WebContents* contents,
              const GURL& url) const {
    const auto tab = grants_.find(contents);
    if (tab == grants_.end()) {
      return false;
    }
    const auto grant = tab->second.find(extension_id);
    return grant != tab->second.end() &&
           grant->second.IsSameOriginWith(url::Origin::Create(url));
  }

  void Revoke(WebContents* contents) { grants_.erase(contents); }

 private:
  friend class base::NoDestructor<ActiveTabGrants>;
  ActiveTabGrants() = default;
  ~ActiveTabGrants() = default;

  std::map<WebContents*, std::map<std::string, url::Origin>> grants_;
};

bool CanSeeTabDetails(const std::string& extension_id,
                      WebContents* contents,
                      const GURL& url) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  return registry.HasPermission(extension_id, "tabs") ||
         registry.HasHostPermission(extension_id, url) ||
         ActiveTabGrants::Get().Covers(extension_id, contents, url);
}

// pendingUrl окремо, бо вкладка може йти на сайт якого розширення не бачить
base::DictValue ScrubbedTab(Shell* shell, const std::string& extension_id) {
  base::DictValue tab = TabToValue(shell);
  WebContents* contents = shell->web_contents();
  if (!CanSeeTabDetails(extension_id, contents,
                        contents->GetLastCommittedURL())) {
    tab.Remove("url");
    tab.Remove("title");
    tab.Remove("favIconUrl");
  }
  if (const std::string* pending = tab.FindString("pendingUrl");
      pending && !CanSeeTabDetails(extension_id, contents, GURL(*pending))) {
    tab.Remove("pendingUrl");
  }
  return tab;
}

// Порожній рядок значить доступ є. Адресу в помилці бачить тільки
// розширення з "tabs"
std::string FrameAccessError(const std::string& extension_id,
                             RenderFrameHost* frame) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  const GURL& url = frame->GetLastCommittedURL();
  if (url.SchemeIs(kBlinkerExtensionScheme)) {
    return url.host() == extension_id
               ? std::string()
               : "Cannot access a chrome-extension:// URL of different "
                 "extension";
  }
  GURL effective = url;
  if (url.is_empty() || url.SchemeIs(url::kAboutScheme) ||
      url.SchemeIs(url::kDataScheme) || url.SchemeIsBlob()) {
    effective = frame->GetLastCommittedOrigin()
                    .GetTupleOrPrecursorTupleIfOpaque()
                    .GetURL();
  }
  if (effective.is_valid() &&
      (registry.HasHostPermission(extension_id, effective) ||
       ActiveTabGrants::Get().Covers(
           extension_id, WebContents::FromRenderFrameHost(frame), effective))) {
    return std::string();
  }
  if (registry.HasPermission(extension_id, "tabs")) {
    return base::StrCat({"Cannot access contents of url \"", url.spec(),
                         "\". Extension manifest must request permission to "
                         "access this host."});
  }
  return "Cannot access contents of the page. Extension manifest must request "
         "permission to access the respective host.";
}

bool IsExtensionPopupUrl(const std::string& extension_id, const GURL& url) {
  const BlinkerWebExtension* extension =
      BlinkerWebExtensionRegistry::GetInstance().FindExtension(extension_id);
  if (!extension || !url.SchemeIs(kBlinkerExtensionScheme) ||
      url.host() != extension_id) {
    return false;
  }
  for (const char* key : {"action", "browser_action", "page_action"}) {
    const base::DictValue* action = extension->manifest.FindDict(key);
    const std::string* popup =
        action ? action->FindString("default_popup") : nullptr;
    if (popup && url.path() ==
                     base::StrCat({"/", base::TrimString(*popup, "/",
                                                         base::TRIM_LEADING)})) {
      return true;
    }
  }
  return false;
}

bool IsExtensionPopup(const std::string& extension_id, Shell* shell) {
  return IsExtensionPopupUrl(extension_id,
                             shell->web_contents()->GetLastCommittedURL());
}

// Браузер сам у JS писати не може, тому контекст тримає довгий запит
// events.watch
class EventHub {
 public:
  static EventHub& Get() {
    static base::NoDestructor<EventHub> hub;
    return *hub;
  }

  using Callback = base::OnceCallback<void(std::string)>;

  void Broadcast(std::string name, base::ListValue args) {
    BroadcastEach(name, [&args](const std::string&) {
      return std::optional<base::ListValue>(args.Clone());
    });
  }

  template <typename ArgsFor>
  void BroadcastEach(std::string_view name, ArgsFor args_for) {
    for (const std::unique_ptr<BlinkerWebExtension>& extension :
         BlinkerWebExtensionRegistry::GetInstance().extensions()) {
      if (!extension->enabled) {
        continue;
      }
      std::optional<base::ListValue> args = args_for(extension->id);
      if (args) {
        Post(extension->id, std::string(name), std::move(*args));
      }
    }
  }

  // Тільки події яких розширення чекає. Часті, як tabs.onUpdated,
  // тримали б воркери живими
  static bool ShouldWakeWorkerFor(std::string_view name) {
    return name.starts_with("alarms.") || name.starts_with("contextMenus.") ||
           name.starts_with("notifications.") ||
           name.starts_with("downloads.") || name.starts_with("commands.") ||
           name.starts_with("bookmarks.");
  }

  bool HasWaiter(const std::string& extension_id) const {
    for (const auto& [id, waiter] : waiters_) {
      if (waiter.extension_id == extension_id) {
        return true;
      }
    }
    return false;
  }

  void Post(const std::string& extension_id,
            std::string name,
            base::ListValue args) {
    const bool wake = ShouldWakeWorkerFor(name) && !HasWaiter(extension_id);
    Queue& queue = queues_[extension_id];
    base::DictValue event;
    event.Set("seq", static_cast<double>(++queue.seq));
    event.Set("name", std::move(name));
    event.Set("args", std::move(args));
    event.Set("ts", base::Time::Now().InMillisecondsFSinceUnixEpoch());
    queue.events.push_back(std::move(event));
    // щоб сторінка що не читає чергу не роздувала пам'ять браузера
    while (queue.events.size() > 128) {
      queue.events.erase(queue.events.begin());
    }
    Flush(extension_id);
    if (wake) {
      BlinkerWakeExtensionWorker(extension_id);
    }
  }

  void Watch(const std::string& extension_id, uint64_t since, Callback cb) {
    const uint64_t id = next_waiter_++;
    waiters_[id] = {extension_id, since, std::move(cb)};
    Flush(extension_id);
    if (waiters_.count(id)) {
      GetUIThreadTaskRunner({})->PostDelayedTask(
          FROM_HERE,
          base::BindOnce(&EventHub::Timeout, base::Unretained(this), id),
          base::Seconds(25));
    }
  }

  uint64_t SeqFor(const std::string& extension_id) {
    return queues_[extension_id].seq;
  }

  uint64_t ReplaySeqFor(const std::string& extension_id,
                        base::TimeDelta window) {
    Queue& queue = queues_[extension_id];
    const double cutoff =
        (base::Time::Now() - window).InMillisecondsFSinceUnixEpoch();
    for (const base::DictValue& event : queue.events) {
      const std::optional<double> ts = event.FindDouble("ts");
      const std::optional<double> seq = event.FindDouble("seq");
      if (ts && seq && *ts >= cutoff) {
        return static_cast<uint64_t>(*seq) - 1;
      }
    }
    return queue.seq;
  }

 private:
  friend class base::NoDestructor<EventHub>;
  EventHub() = default;
  ~EventHub() = default;

  struct Queue {
    std::vector<base::DictValue> events;
    uint64_t seq = 0;
  };
  struct Waiter {
    std::string extension_id;
    uint64_t since = 0;
    Callback callback;
  };

  void Answer(Waiter waiter, bool with_events) {
    Queue& queue = queues_[waiter.extension_id];
    base::ListValue events;
    if (with_events) {
      for (const base::DictValue& event : queue.events) {
        if (static_cast<uint64_t>(event.FindDouble("seq").value_or(0)) >
            waiter.since) {
          events.Append(event.Clone());
        }
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("seq", static_cast<double>(queue.seq));
    reply.Set("events", std::move(events));
    std::optional<std::string> json = base::WriteJson(reply);
    std::move(waiter.callback).Run(json.value_or("{\"ok\":false}"));
  }

  void Flush(const std::string& extension_id) {
    std::vector<uint64_t> ready;
    for (const auto& [id, waiter] : waiters_) {
      if (waiter.extension_id == extension_id &&
          waiter.since < queues_[extension_id].seq) {
        ready.push_back(id);
      }
    }
    for (uint64_t id : ready) {
      auto it = waiters_.find(id);
      if (it == waiters_.end()) {
        continue;
      }
      Waiter waiter = std::move(it->second);
      waiters_.erase(it);
      Answer(std::move(waiter), /*with_events=*/true);
    }
  }

  void Timeout(uint64_t id) {
    auto it = waiters_.find(id);
    if (it == waiters_.end()) {
      return;
    }
    Waiter waiter = std::move(it->second);
    waiters_.erase(it);
    Answer(std::move(waiter), /*with_events=*/false);
  }

  std::map<std::string, Queue> queues_;
  std::map<uint64_t, Waiter> waiters_;
  uint64_t next_waiter_ = 1;
};

std::string Quoted(std::string_view value) {
  std::string out;
  base::EscapeJSONString(value, /*put_in_quotes=*/true, &out);
  return out;
}

std::string Serialize(const base::DictValue& value) {
  std::optional<std::string> json = base::WriteJson(value);
  return json.value_or("{\"ok\":false,\"error\":\"unserializable\"}");
}

std::string ErrorReply(std::string_view message) {
  return base::StrCat({"{\"ok\":false,\"error\":", Quoted(message), "}"});
}

std::vector<std::string> IdsFrom(const base::DictValue& request,
                                 const char* key) {
  std::vector<std::string> ids;
  const base::ListValue* list = request.FindList(key);
  if (!list) {
    return ids;
  }
  for (const base::Value& entry : *list) {
    if (const std::string* id = entry.GetIfString()) {
      ids.push_back(*id);
    }
  }
  return ids;
}

void ExecuteScriptingInjection(const BlinkerApiCaller& caller,
                               const base::DictValue& request,
                               base::OnceCallback<void(std::string)> callback);
void ExecuteScriptingCss(const BlinkerApiCaller& caller,
                         const base::DictValue& request,
                         bool insert,
                         base::OnceCallback<void(std::string)> callback);

void HandleScripting(const BlinkerApiCaller& caller,
                     const base::DictValue& request,
                     const std::string& op,
                     base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();

  if (op == "registerContentScripts" || op == "updateContentScripts") {
    const base::ListValue* scripts = request.FindList("scripts");
    if (!scripts) {
      std::move(callback).Run(ErrorReply("scripts is required"));
      return;
    }
    std::string error;
    const bool update = (op == "updateContentScripts");
    if (!registry.RegisterDynamicScripts(caller.extension_id, *scripts, update,
                                         &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (op == "unregisterContentScripts") {
    registry.UnregisterDynamicScripts(caller.extension_id,
                                      IdsFrom(request, "ids"));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (op == "getRegisteredContentScripts") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("scripts",
              registry.GetDynamicScripts(caller.extension_id,
                                         IdsFrom(request, "ids")));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "executeScript") {
    ExecuteScriptingInjection(caller, request, std::move(callback));
    return;
  }

  if (op == "insertCSS" || op == "removeCSS") {
    ExecuteScriptingCss(caller, request, op == "insertCSS", std::move(callback));
    return;
  }

  std::move(callback).Run(ErrorReply(base::StrCat(
      {"chrome.scripting.", op, " is not implemented in this browser"})));
}

// Повернення на chromiumapp.org браузер перехоплює, як у Chrome
// Потік завжди закінчується відповіддю
class BlinkerAuthFlow : public WebContentsObserver {
 public:
  static void Start(Shell* opener,
                    const GURL& auth_url,
                    const std::string& redirect_prefix,
                    base::OnceCallback<void(std::string)> callback) {
    // Спершу about:blank, щоб спостерігач стояв до першої навігації
    Shell* shell = Shell::CreateNewWindow(
        opener->web_contents()->GetBrowserContext(), GURL(url::kAboutBlankURL),
        nullptr, gfx::Size());
    if (!shell || !shell->web_contents()) {
      std::move(callback).Run(ErrorReply("Could not open the sign-in window"));
      return;
    }
    new BlinkerAuthFlow(shell, redirect_prefix, std::move(callback));
    shell->LoadURL(auth_url);
  }

  BlinkerAuthFlow(const BlinkerAuthFlow&) = delete;
  BlinkerAuthFlow& operator=(const BlinkerAuthFlow&) = delete;

  // Публічний, бо видаляє черга завдань. З обробника навігації себе не видалиш
  ~BlinkerAuthFlow() override = default;

 private:
  BlinkerAuthFlow(Shell* shell,
                  const std::string& redirect_prefix,
                  base::OnceCallback<void(std::string)> callback)
      : WebContentsObserver(shell->web_contents()),
        shell_(shell),
        redirect_prefix_(redirect_prefix),
        callback_(std::move(callback)) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&BlinkerAuthFlow::FinishWithError,
                       weak_factory_.GetWeakPtr(),
                       "The sign-in flow timed out"),
        base::Minutes(5));
  }

  void DidStartNavigation(NavigationHandle* navigation) override {
    if (!navigation || !navigation->IsInPrimaryMainFrame()) {
      return;
    }
    const GURL& url = navigation->GetURL();
    if (url.spec().starts_with(redirect_prefix_)) {
      Finish(url.spec(), std::string());
    }
  }

  void WebContentsDestroyed() override {
    shell_ = nullptr;
    FinishWithError("The user did not approve access");
  }

  void FinishWithError(const char* message) { Finish(std::string(), message); }

  void Finish(std::string redirect_url, std::string error) {
    if (done_) {
      return;
    }
    done_ = true;
    Observe(nullptr);
    if (Shell* shell = shell_) {
      shell_ = nullptr;
      // окремим завданням, ми всередині колбека навігації
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce([](Shell* target) {
            for (Shell* live : Shell::windows()) {
              if (live == target) {
                target->Close();
                return;
              }
            }
          }, shell));
    }
    if (callback_) {
      if (error.empty()) {
        base::DictValue reply;
        reply.Set("ok", true);
        reply.Set("redirectUrl", std::move(redirect_url));
        std::move(callback_).Run(Serialize(reply));
      } else {
        std::move(callback_).Run(ErrorReply(error));
      }
    }
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }

  raw_ptr<Shell> shell_ = nullptr;
  std::string redirect_prefix_;
  base::OnceCallback<void(std::string)> callback_;
  bool done_ = false;
  base::WeakPtrFactory<BlinkerAuthFlow> weak_factory_{this};
};

void HandleIdentity(const BlinkerApiCaller& caller,
                    const base::DictValue& request,
                    const std::string& op,
                    base::OnceCallback<void(std::string)> callback) {
  if (op != "launchWebAuthFlow") {
    std::move(callback).Run(ErrorReply(base::StrCat(
        {"chrome.identity.", op, " is not implemented in this browser"})));
    return;
  }
  const std::string* url = request.FindString("url");
  const GURL auth_url(url ? *url : std::string());
  if (!auth_url.is_valid() || !auth_url.SchemeIsHTTPOrHTTPS()) {
    std::move(callback).Run(ErrorReply("Invalid url"));
    return;
  }
  Shell* active = ActiveShell();
  if (!active || !active->web_contents()) {
    std::move(callback).Run(ErrorReply("No window to sign in from"));
    return;
  }
  BlinkerAuthFlow::Start(
      active, auth_url,
      base::StrCat({"https://", caller.extension_id, ".chromiumapp.org/"}),
      std::move(callback));
}

void HandleSearch(const base::DictValue& request,
                  const std::string& op,
                  base::OnceCallback<void(std::string)> callback) {
  if (op != "query") {
    std::move(callback).Run(ErrorReply(base::StrCat(
        {"chrome.search.", op, " is not implemented in this browser"})));
    return;
  }
  const std::string* text = request.FindString("text");
  if (!text || text->empty()) {
    std::move(callback).Run(ErrorReply("Missing search text"));
    return;
  }
  const GURL url(BlinkerSearchURLForQuery(*text));
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    std::move(callback).Run(ErrorReply("No search engine is configured"));
    return;
  }
  const std::string* disposition = request.FindString("disposition");
  const int tab_id = static_cast<int>(request.FindDouble("tabId").value_or(-1));
  const bool new_tab = disposition && (*disposition == "NEW_TAB" ||
                                       *disposition == "NEW_WINDOW");
  Shell* shell = tab_id >= 0 ? ShellForTabId(tab_id) : ActiveShell();
  if (!shell || !shell->web_contents()) {
    std::move(callback).Run(ErrorReply("No window to search in"));
    return;
  }
  if (new_tab || tab_id < 0) {
    if (!Shell::CreateNewWindow(shell->web_contents()->GetBrowserContext(), url,
                                nullptr, gfx::Size())) {
      std::move(callback).Run(ErrorReply("Could not open a tab"));
      return;
    }
  } else {
    shell->LoadURL(url);
  }
  std::move(callback).Run("{\"ok\":true}");
}

void HandleTabs(const BlinkerApiCaller& caller,
                const base::DictValue& request,
                const std::string& op,
                base::OnceCallback<void(std::string)> callback) {
  if (op == "captureVisibleTab") {
    Shell* shell = ActiveShell();
    if (!shell || !shell->web_contents()) {
      std::move(callback).Run(ErrorReply("No active web contents to capture"));
      return;
    }
    WebContents* contents = shell->web_contents();
    const GURL url = contents->GetLastCommittedURL();
    if (!BlinkerWebExtensionRegistry::GetInstance().HasHostPermission(
            caller.extension_id, url) &&
        !ActiveTabGrants::Get().Covers(caller.extension_id, contents, url)) {
      std::move(callback).Run(ErrorReply(
          "Either the '<all_urls>' or 'activeTab' permission is required."));
      return;
    }
    const std::string* format = request.FindString("format");
    const int quality =
        std::clamp(request.FindInt("quality").value_or(92), 0, 100);
    std::string data_url = BlinkCaptureVisibleTab(
        shell, format && *format == "png", quality);
    if (data_url.empty()) {
      std::move(callback).Run(
          ErrorReply("Failed to capture tab: view is invalid"));
      return;
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("dataUrl", std::move(data_url));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "query") {
    bx::MatchPatternSet url_patterns;
    std::vector<std::string> url_strings;
    if (const std::string* url = request.FindString("url")) {
      url_strings.push_back(*url);
    } else if (const base::ListValue* urls = request.FindList("url")) {
      for (const base::Value& entry : *urls) {
        if (const std::string* value = entry.GetIfString()) {
          url_strings.push_back(*value);
        }
      }
    }
    for (const std::string& pattern : url_strings) {
      bx::MatchPattern parsed(/*any_scheme=*/true);
      if (!parsed.Parse(pattern)) {
        std::move(callback).Run(ErrorReply(
            base::StrCat({"Invalid url pattern '", pattern, "'"})));
        return;
      }
      url_patterns.AddIncludePattern(std::move(parsed));
    }
    const std::string* title = request.FindString("title");
    const bool check_title = title && !title->empty();
    const std::string* status = request.FindString("status");
    const std::optional<int> index = OptionalInt(request, "index");
    const std::optional<int> window_id = OptionalInt(request, "windowId");
    const std::optional<int> group_id = OptionalInt(request, "groupId");
    const std::string* window_type = request.FindString("windowType");
    const auto matches = [&](const char* key, bool value) {
      const std::optional<bool> wanted = request.FindBool(key);
      return !wanted || *wanted == value;
    };
    const bool window_matches =
        (!window_id || *window_id == kWindowId ||
         *window_id == kWindowIdCurrent) &&
        (!window_type || *window_type == "normal") &&
        (!group_id || *group_id == -1) && matches("currentWindow", true) &&
        matches("lastFocusedWindow", true) && matches("pinned", false) &&
        matches("autoDiscardable", true) && matches("frozen", false);

    base::ListValue tabs;
    std::vector<raw_ptr<Shell>> no_windows;
    for (Shell* shell : window_matches ? Shell::windows() : no_windows) {
      WebContents* contents = shell ? shell->web_contents() : nullptr;
      if (!contents) {
        continue;
      }
      const bool active = shell == ActiveShell();
      if (!matches("active", active) || !matches("highlighted", active) ||
          !matches("audible", contents->IsCurrentlyAudible()) ||
          !matches("muted", contents->IsAudioMuted()) ||
          !matches("discarded", contents->WasDiscarded()) ||
          (index && *index != TabIndex(shell)) ||
          (status && *status != LoadingStatus(contents))) {
        continue;
      }
      if (check_title || !url_patterns.empty()) {
        const GURL& url = contents->GetVisibleURL();
        if (!CanSeeTabDetails(caller.extension_id, contents, url)) {
          continue;
        }
        if (check_title &&
            !bx::UrlGlobMatches(*title,
                                base::UTF16ToUTF8(contents->GetTitle()))) {
          continue;
        }
        if (!url_patterns.empty() &&
            !url_patterns.Matches(BlinkerUrlParts(url))) {
          continue;
        }
      }
      tabs.Append(ScrubbedTab(shell, caller.extension_id));
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("tabs", std::move(tabs));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "get" || op == "getCurrent") {
    const int tab_id = op == "get" ? OptionalInt(request, "tabId").value_or(-1)
                                   : caller.tab_id;
    Shell* shell = ShellForTabId(tab_id);
    base::DictValue reply;
    reply.Set("ok", true);
    if (op == "getCurrent") {
      if (shell && !IsExtensionPopup(caller.extension_id, shell)) {
        reply.Set("tab", ScrubbedTab(shell, caller.extension_id));
      }
      std::move(callback).Run(Serialize(reply));
      return;
    }
    if (!shell) {
      std::move(callback).Run(ErrorReply(TabNotFound(tab_id)));
      return;
    }
    reply.Set("tab", ScrubbedTab(shell, caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "create") {
    GURL target(url::kAboutBlankURL);
    if (const std::string* url = request.FindString("url")) {
      std::string error;
      if (!PrepareUrlForNavigation(*url, caller.extension_id, &target,
                                   &error)) {
        std::move(callback).Run(ErrorReply(error));
        return;
      }
    }
    Shell* active = ActiveShell();
    if (!active || !active->web_contents()) {
      std::move(callback).Run(ErrorReply("No current window"));
      return;
    }
    Shell* visible = VisibleShell();
    Shell* created = Shell::CreateNewWindow(
        active->web_contents()->GetBrowserContext(), target, nullptr,
        gfx::Size());
    if (!created) {
      std::move(callback).Run(ErrorReply("Could not create tab"));
      return;
    }
    if (!request.FindBool("active").value_or(true) && visible) {
      BlinkActivateShell(visible);
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("tab", ScrubbedTab(created, caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "update") {
    std::string error;
    Shell* shell = DefaultTab(request, &error);
    if (!shell) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    if (const std::string* url = request.FindString("url")) {
      GURL target;
      if (!PrepareUrlForNavigation(*url, caller.extension_id, &target,
                                   &error)) {
        std::move(callback).Run(ErrorReply(error));
        return;
      }
      shell->LoadURL(target);
    }
    if (request.FindBool("active").value_or(false) ||
        request.FindBool("highlighted").value_or(false)) {
      BlinkActivateShell(shell);
    }
    if (const std::optional<bool> muted = request.FindBool("muted")) {
      shell->web_contents()->SetAudioMuted(*muted);
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("tab", ScrubbedTab(shell, caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "reload") {
    std::string error;
    Shell* shell = DefaultTab(request, &error);
    if (!shell) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    shell->Reload();
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (op == "goBack" || op == "goForward") {
    std::string error;
    Shell* shell = DefaultTab(request, &error);
    if (!shell) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    NavigationController& controller = shell->web_contents()->GetController();
    const bool back = op == "goBack";
    if (back ? !controller.CanGoBack() : !controller.CanGoForward()) {
      std::move(callback).Run(
          ErrorReply("Cannot find a next page in history."));
      return;
    }
    if (back) {
      controller.GoBack();
    } else {
      controller.GoForward();
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (op == "duplicate") {
    const int tab_id = OptionalInt(request, "tabId").value_or(-1);
    Shell* shell = ShellForTabId(tab_id);
    if (!shell) {
      std::move(callback).Run(ErrorReply(TabNotFound(tab_id)));
      return;
    }
    Shell* copy = Shell::CreateDuplicate(shell);
    if (!copy) {
      std::move(callback).Run(ErrorReply(base::StrCat(
          {"Cannot duplicate tab with id: ", base::NumberToString(tab_id),
           "."})));
      return;
    }
    BlinkActivateShell(copy);
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("tab", ScrubbedTab(copy, caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "discard") {
    const std::optional<int> tab_id = OptionalInt(request, "tabId");
    Shell* shell = nullptr;
    if (tab_id) {
      shell = ShellForTabId(*tab_id);
      if (!shell) {
        std::move(callback).Run(ErrorReply(TabNotFound(*tab_id)));
        return;
      }
    } else {
      base::TimeTicks oldest = base::TimeTicks::Max();
      for (Shell* candidate : Shell::windows()) {
        WebContents* contents = candidate ? candidate->web_contents() : nullptr;
        if (!contents || contents->GetVisibility() == Visibility::VISIBLE ||
            contents->WasDiscarded() ||
            contents->HasUncommittedNavigationInPrimaryMainFrame()) {
          continue;
        }
        if (contents->GetLastActiveTimeTicks() < oldest) {
          oldest = contents->GetLastActiveTimeTicks();
          shell = candidate;
        }
      }
    }
    WebContents* contents = shell ? shell->web_contents() : nullptr;
    if (contents && !contents->WasDiscarded() &&
        contents->GetVisibility() != Visibility::VISIBLE &&
        !contents->HasUncommittedNavigationInPrimaryMainFrame()) {
      contents->SetPageFrozen(true);
      contents->Discard(base::DoNothing());
    }
    if (!contents || !contents->WasDiscarded()) {
      std::move(callback).Run(ErrorReply(
          tab_id ? base::StrCat({"Cannot discard tab with id: ",
                                 base::NumberToString(*tab_id), "."})
                 : std::string("Cannot find a tab to discard.")));
      return;
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("tab", ScrubbedTab(shell, caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "remove") {
    std::vector<int> ids;
    if (const base::ListValue* list = request.FindList("tabIds")) {
      for (const base::Value& id : *list) {
        if (id.is_int() || id.is_double()) {
          ids.push_back(static_cast<int>(id.GetDouble()));
        }
      }
    } else if (const std::optional<int> id = OptionalInt(request, "tabIds")) {
      ids.push_back(*id);
    }
    std::vector<Shell*> shells;
    for (int id : ids) {
      Shell* shell = ShellForTabId(id);
      if (!shell) {
        std::move(callback).Run(ErrorReply(TabNotFound(id)));
        return;
      }
      shells.push_back(shell);
    }
    for (Shell* shell : shells) {
      shell->Close();
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  // Chrome рахує масштаб множником, а браузер відсотками
  if (op == "setZoom" || op == "getZoom" || op == "getZoomSettings" ||
      op == "setZoomSettings") {
    std::string error;
    Shell* shell = DefaultTab(request, &error);
    if (!shell) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    base::DictValue reply;
    reply.Set("ok", true);
    if (op == "getZoom") {
      reply.Set("zoomFactor", BlinkerPageZoomPercent(shell->web_contents()) /
                                  100.0);
    } else if (op == "getZoomSettings") {
      base::DictValue settings = ZoomSettings();
      settings.Set("defaultZoomFactor", 1.0);
      reply.Set("zoomSettings", std::move(settings));
    } else if (op == "setZoomSettings") {
      const base::DictValue* wanted = request.FindDict("zoomSettings");
      const std::string* mode = wanted ? wanted->FindString("mode") : nullptr;
      const std::string* scope = wanted ? wanted->FindString("scope") : nullptr;
      const bool automatic = !mode || *mode == "automatic";
      if (scope && *scope == "per-origin" && !automatic) {
        std::move(callback).Run(ErrorReply(
            "Can only set scope to \"per-origin\" in \"automatic\" mode."));
        return;
      }
      // Іншого режиму масштабу нема, мовчки погодитись означало б збрехати
      if (!automatic || (scope && *scope != "per-origin")) {
        std::move(callback).Run(
            ErrorReply("Cannot set zoom or zoom settings on this tab."));
        return;
      }
    } else {
      const double factor = request.FindDouble("zoomFactor").value_or(0.0);
      const double wanted = factor <= 0.0 ? 1.0 : factor;
      const int percent =
          std::clamp(static_cast<int>(wanted * 100 + 0.5), 25, 500);
      const int old_percent = BlinkerPageZoomPercent(shell->web_contents());
      BlinkerSetPageZoomPercent(shell->web_contents(), percent);
      BlinkerNotifyZoomChanged(shell->web_contents(), old_percent, percent);
    }
    std::move(callback).Run(Serialize(reply));
    return;
  }

  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.tabs.", op, " is not implemented in this browser"})));
}

base::DictValue WindowToValue(bool populate,
                              const std::string& extension_id) {
  base::DictValue window;
  window.Set("id", kWindowId);
  window.Set("focused", true);
  window.Set("incognito", false);
  window.Set("type", "normal");
  window.Set("state", "normal");
  window.Set("alwaysOnTop", false);
  window.Set("top", 0);
  window.Set("left", 0);
  if (Shell* shell = ActiveShell(); shell && shell->web_contents()) {
    const gfx::Rect bounds = shell->web_contents()->GetContainerBounds();
    window.Set("width", bounds.width());
    window.Set("height", bounds.height());
  }
  if (populate) {
    base::ListValue tabs;
    for (Shell* shell : Shell::windows()) {
      if (shell && shell->web_contents()) {
        tabs.Append(ScrubbedTab(shell, extension_id));
      }
    }
    window.Set("tabs", std::move(tabs));
  }
  return window;
}

void HandleWindows(const BlinkerApiCaller& caller,
                   const base::DictValue& request,
                   const std::string& op,
                   base::OnceCallback<void(std::string)> callback) {
  const base::DictValue* query = request.FindDict("queryOptions");
  const bool populate = query && query->FindBool("populate").value_or(false);
  base::DictValue reply;
  reply.Set("ok", true);
  if (op == "get" || op == "update" || op == "remove") {
    const int window_id = OptionalInt(request, "windowId").value_or(-1);
    if (window_id != kWindowId && window_id != kWindowIdCurrent) {
      std::move(callback).Run(ErrorReply(base::StrCat(
          {"No window with id: ", base::NumberToString(window_id), "."})));
      return;
    }
    if (op != "remove") {
      reply.Set("window", WindowToValue(populate, caller.extension_id));
    }
  } else if (op == "getCurrent" || op == "getLastFocused") {
    reply.Set("window", WindowToValue(populate, caller.extension_id));
  } else if (op == "getAll") {
    base::ListValue windows;
    windows.Append(WindowToValue(populate, caller.extension_id));
    reply.Set("windows", std::move(windows));
  } else if (op == "create") {
    std::vector<std::string> urls;
    if (const std::string* url = request.FindString("url")) {
      urls.push_back(*url);
    } else if (const base::ListValue* list = request.FindList("url")) {
      for (const base::Value& entry : *list) {
        if (const std::string* value = entry.GetIfString()) {
          urls.push_back(*value);
        }
      }
    }
    if (urls.empty()) {
      urls.emplace_back(url::kAboutBlankURL);
    }
    Shell* active = ActiveShell();
    if (!active || !active->web_contents()) {
      std::move(callback).Run(ErrorReply("No current window"));
      return;
    }
    std::vector<GURL> targets;
    for (const std::string& url : urls) {
      GURL target;
      std::string error;
      if (!PrepareUrlForNavigation(url, caller.extension_id, &target,
                                   &error)) {
        std::move(callback).Run(ErrorReply(error));
        return;
      }
      targets.push_back(std::move(target));
    }
    base::ListValue tabs;
    for (const GURL& target : targets) {
      if (Shell* created = Shell::CreateNewWindow(
              active->web_contents()->GetBrowserContext(), target, nullptr,
              gfx::Size())) {
        tabs.Append(ScrubbedTab(created, caller.extension_id));
      }
    }
    base::DictValue window =
        WindowToValue(/*populate=*/false, caller.extension_id);
    window.Set("tabs", std::move(tabs));
    reply.Set("window", std::move(window));
  } else {
    std::move(callback).Run(ErrorReply(base::StrCat(
        {"chrome.windows.", op, " is not implemented in this browser"})));
    return;
  }
  std::move(callback).Run(Serialize(reply));
}

BrowserContext* AnyBrowserContext();

// Вимкнене розширення не має прокидати воркер
bool ExtensionIsEnabled(const std::string& extension_id) {
  for (const std::unique_ptr<BlinkerWebExtension>& extension :
       BlinkerWebExtensionRegistry::GetInstance().extensions()) {
    if (extension->id == extension_id) {
      return extension->enabled;
    }
  }
  return false;
}

void PersistApiStateSoon(const std::string& extension_id);

// Будильники в браузері, бо таймер воркера вмирає разом з ним, а будильник
// має його розбудити
class AlarmStore {
 public:
  static AlarmStore& Get() {
    static base::NoDestructor<AlarmStore> store;
    return *store;
  }

  struct Alarm {
    std::string name;
    double scheduled_time_ms = 0;
    double period_minutes = 0;
    std::unique_ptr<base::OneShotTimer> timer;
  };

  void Create(const std::string& extension_id,
              const std::string& name,
              double when_ms,
              double period_minutes) {
    constexpr double kMinPeriodMinutes = 0.5;
    if (period_minutes > 0 && period_minutes < kMinPeriodMinutes) {
      period_minutes = kMinPeriodMinutes;
      const double earliest =
          base::Time::Now().InMillisecondsFSinceUnixEpoch() +
          kMinPeriodMinutes * 60000.0;
      when_ms = std::max(when_ms, earliest);
    }
    auto& alarms = alarms_[extension_id];
    auto alarm = std::make_unique<Alarm>();
    alarm->name = name;
    alarm->scheduled_time_ms = when_ms;
    alarm->period_minutes = period_minutes;
    alarm->timer = std::make_unique<base::OneShotTimer>();
    base::OneShotTimer* timer = alarm->timer.get();
    alarms[name] = std::move(alarm);
    const base::TimeDelta delay = base::Milliseconds(std::max(
        0.0, when_ms - base::Time::Now().InMillisecondsFSinceUnixEpoch()));
    timer->Start(FROM_HERE, delay,
                 base::BindOnce(&AlarmStore::Fire, base::Unretained(this),
                                extension_id, name));
  }

  bool Clear(const std::string& extension_id, const std::string& name) {
    auto it = alarms_.find(extension_id);
    return it != alarms_.end() && it->second.erase(name) != 0;
  }

  void ClearAll(const std::string& extension_id) {
    alarms_.erase(extension_id);
  }

  base::ListValue List(const std::string& extension_id) {
    base::ListValue out;
    auto it = alarms_.find(extension_id);
    if (it == alarms_.end()) {
      return out;
    }
    for (const auto& [name, alarm] : it->second) {
      out.Append(ToValue(*alarm));
    }
    return out;
  }

  base::ListValue Serialize(const std::string& extension_id) {
    return List(extension_id);
  }

  void Restore(const std::string& extension_id, const base::ListValue& list) {
    for (const base::Value& entry : list) {
      const base::DictValue* alarm = entry.GetIfDict();
      const std::string* name = alarm ? alarm->FindString("name") : nullptr;
      if (!name) {
        continue;
      }
      Create(extension_id, *name,
             alarm->FindDouble("scheduledTime").value_or(0),
             alarm->FindDouble("periodInMinutes").value_or(0));
    }
  }

  std::optional<base::DictValue> Find(const std::string& extension_id,
                                      const std::string& name) {
    auto it = alarms_.find(extension_id);
    if (it == alarms_.end()) {
      return std::nullopt;
    }
    auto alarm = it->second.find(name);
    if (alarm == it->second.end()) {
      return std::nullopt;
    }
    return ToValue(*alarm->second);
  }

 private:
  friend class base::NoDestructor<AlarmStore>;
  AlarmStore() = default;
  ~AlarmStore() = default;

  static base::DictValue ToValue(const Alarm& alarm) {
    base::DictValue value;
    value.Set("name", alarm.name);
    value.Set("scheduledTime", alarm.scheduled_time_ms);
    if (alarm.period_minutes > 0) {
      value.Set("periodInMinutes", alarm.period_minutes);
    }
    return value;
  }

  void Fire(std::string extension_id, std::string name) {
    auto it = alarms_.find(extension_id);
    if (it == alarms_.end()) {
      return;
    }
    auto alarm_it = it->second.find(name);
    if (alarm_it == it->second.end()) {
      return;
    }
    if (!ExtensionIsEnabled(extension_id)) {
      it->second.erase(alarm_it);
      return;
    }
    const double period = alarm_it->second->period_minutes;
    // Копія до змін мапи, бо Create чи erase нижче знищують *alarm_it
    const base::DictValue alarm_value = ToValue(*alarm_it->second);

    base::DictValue message;
    message.Set("__blinker", extension_id);
    message.Set("kind", "alarm");
    message.Set("alarm", alarm_value.Clone());

    if (period > 0) {
      Create(extension_id, name,
             base::Time::Now().InMillisecondsFSinceUnixEpoch() +
                 period * 60000.0,
             period);
    } else {
      it->second.erase(alarm_it);
    }
    PersistApiStateSoon(extension_id);

    // Дві доставки бо воркер може спати. Повтор з тим самим fireId шім
    // пропускає
    base::DictValue fired = alarm_value.Clone();
    fired.Set("fireId", static_cast<double>(++next_fire_id_));
    base::ListValue args;
    args.Append(fired.Clone());
    pending_[extension_id].Append(std::move(fired));
    while (pending_[extension_id].size() > 32) {
      pending_[extension_id].erase(pending_[extension_id].begin());
    }
    EventHub::Get().Post(extension_id, "alarms.onAlarm", std::move(args));

    BrowserContext* context = AnyBrowserContext();
    StoragePartition* partition =
        context ? context->GetDefaultStoragePartition() : nullptr;
    ServiceWorkerContext* sw =
        partition ? partition->GetServiceWorkerContext() : nullptr;
    if (!sw) {
      return;
    }
    // Не StartServiceWorkerAndDispatchMessage, він падає на CHECK коли воркер
    // не запущений
    const GURL scope(
        base::StrCat({kBlinkerExtensionScheme, "://", extension_id, "/"}));
    sw->StartWorkerForScope(
        scope, blink::StorageKey::CreateFirstParty(url::Origin::Create(scope)),
        base::DoNothing(), base::DoNothing());
  }

 public:
  base::ListValue TakePending(const std::string& extension_id) {
    auto it = pending_.find(extension_id);
    if (it == pending_.end()) {
      return base::ListValue();
    }
    base::ListValue out = std::move(it->second);
    pending_.erase(it);
    return out;
  }

 private:

  std::map<std::string, std::map<std::string, std::unique_ptr<Alarm>>> alarms_;
  std::map<std::string, base::ListValue> pending_;
  uint64_t next_fire_id_ = 0;
};

void HandleAlarms(const BlinkerApiCaller& caller,
                  const base::DictValue& request,
                  const std::string& op,
                  base::OnceCallback<void(std::string)> callback) {
  AlarmStore& store = AlarmStore::Get();
  std::string name;
  if (const std::string* n = request.FindString("name")) {
    name = *n;
  }

  if (op == "create") {
    const double period = request.FindDouble("periodInMinutes").value_or(0);
    double when = request.FindDouble("when").value_or(0);
    if (when <= 0) {
      const double delay =
          request.FindDouble("delayInMinutes").value_or(period);
      when = base::Time::Now().InMillisecondsFSinceUnixEpoch() + delay * 60000.0;
    }
    store.Create(caller.extension_id, name, when, period);
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "get") {
    base::DictValue reply;
    reply.Set("ok", true);
    if (std::optional<base::DictValue> alarm =
            store.Find(caller.extension_id, name)) {
      reply.Set("alarm", std::move(*alarm));
    }
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "getAll") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("alarms", store.List(caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "clear") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("result", store.Clear(caller.extension_id, name));
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "drain") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("alarms", store.TakePending(caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "clearAll") {
    store.ClearAll(caller.extension_id);
    PersistApiStateSoon(caller.extension_id);
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("result", true);
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.alarms.", op, " is not implemented"})));
}

// Приватні cookies в іншому сховищі, сюди не потрапляють
network::mojom::CookieManager* CookieManager() {
  ShellContentBrowserClient* client = ShellContentBrowserClient::Get();
  BrowserContext* context =
      client ? static_cast<BrowserContext*>(client->browser_context())
             : nullptr;
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  return partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
}

base::DictValue CookieToValue(const net::CanonicalCookie& cookie) {
  base::DictValue out;
  out.Set("name", cookie.Name());
  out.Set("value", cookie.Value());
  out.Set("domain", cookie.Domain());
  out.Set("hostOnly", !cookie.IsDomainCookie());
  out.Set("path", cookie.Path());
  out.Set("secure", cookie.SecureAttribute());
  out.Set("httpOnly", cookie.IsHttpOnly());
  switch (cookie.SameSite()) {
    case net::CookieSameSite::NO_RESTRICTION:
      out.Set("sameSite", "no_restriction");
      break;
    case net::CookieSameSite::LAX_MODE:
      out.Set("sameSite", "lax");
      break;
    case net::CookieSameSite::STRICT_MODE:
      out.Set("sameSite", "strict");
      break;
    default:
      out.Set("sameSite", "unspecified");
      break;
  }
  out.Set("session", !cookie.IsPersistent());
  if (cookie.IsPersistent()) {
    out.Set("expirationDate",
            cookie.ExpiryDate().InSecondsFSinceUnixEpoch());
  }
  out.Set("storeId", "0");
  return out;
}

net::CookieSameSite SameSiteFromString(const std::string* value) {
  if (!value || *value == "unspecified") {
    return net::CookieSameSite::UNSPECIFIED;
  }
  if (*value == "no_restriction") {
    return net::CookieSameSite::NO_RESTRICTION;
  }
  if (*value == "strict") {
    return net::CookieSameSite::STRICT_MODE;
  }
  return net::CookieSameSite::LAX_MODE;
}

bool CookieMatchesFilter(const net::CanonicalCookie& cookie,
                         const base::DictValue& request) {
  if (const std::string* name = request.FindString("name")) {
    if (cookie.Name() != *name) {
      return false;
    }
  }
  if (const std::string* domain = request.FindString("domain")) {
    std::string wanted = base::ToLowerASCII(*domain);
    if (!wanted.empty() && wanted.front() == '.') {
      wanted.erase(wanted.begin());
    }
    std::string have = base::ToLowerASCII(cookie.Domain());
    if (!have.empty() && have.front() == '.') {
      have.erase(have.begin());
    }
    if (have != wanted &&
        !(have.size() > wanted.size() &&
          have.ends_with("." + wanted))) {
      return false;
    }
  }
  if (const std::string* path = request.FindString("path")) {
    if (cookie.Path() != *path) {
      return false;
    }
  }
  if (std::optional<bool> secure = request.FindBool("secure")) {
    if (cookie.SecureAttribute() != *secure) {
      return false;
    }
  }
  if (std::optional<bool> session = request.FindBool("session")) {
    if (cookie.IsPersistent() == *session) {
      return false;
    }
  }
  return true;
}

bool CookieChangeIsRemoval(net::CookieChangeCause cause) {
  switch (cause) {
    case net::CookieChangeCause::INSERTED:
    case net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE:
    case net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE:
      return false;
    default:
      return true;
  }
}

const char* CookieChangeCauseName(net::CookieChangeCause cause) {
  switch (cause) {
    case net::CookieChangeCause::INSERTED:
    case net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE:
    case net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE:
    case net::CookieChangeCause::EXPLICIT:
      return "explicit";
    case net::CookieChangeCause::OVERWRITE:
      return "overwrite";
    case net::CookieChangeCause::EXPIRED:
      return "expired";
    case net::CookieChangeCause::EXPIRED_OVERWRITE:
      return "expired_overwrite";
    case net::CookieChangeCause::EVICTED:
    case net::CookieChangeCause::UNKNOWN_DELETION:
      return "evicted";
  }
  return "explicit";
}

class CookieChangeForwarder : public network::mojom::CookieChangeListener {
 public:
  CookieChangeForwarder() = default;
  CookieChangeForwarder(const CookieChangeForwarder&) = delete;
  CookieChangeForwarder& operator=(const CookieChangeForwarder&) = delete;
  ~CookieChangeForwarder() override = default;

  void Start() {
    if (receiver_.is_bound()) {
      return;
    }
    network::mojom::CookieManager* manager = CookieManager();
    if (!manager) {
      return;
    }
    manager->AddGlobalChangeListener(receiver_.BindNewPipeAndPassRemote());
    // Мережевий сервіс може впасти, тоді скидаємо receiver_ і підключаємось
    // знову
    receiver_.set_disconnect_handler(base::BindOnce(
        [](CookieChangeForwarder* self) { self->receiver_.reset(); },
        base::Unretained(this)));
  }

  void OnCookieChange(const net::CookieChangeInfo& info) override {
    const GURL url = net::cookie_util::CookieOriginToURL(
        info.cookie.Domain(), info.cookie.SecureAttribute());
    base::DictValue change;
    change.Set("cookie", CookieToValue(info.cookie));
    change.Set("removed", CookieChangeIsRemoval(info.cause));
    change.Set("cause", CookieChangeCauseName(info.cause));
    base::ListValue args;
    args.Append(std::move(change));

    BlinkerWebExtensionRegistry& registry =
        BlinkerWebExtensionRegistry::GetInstance();
    for (const std::unique_ptr<BlinkerWebExtension>& extension :
         registry.extensions()) {
      if (extension->enabled &&
          registry.HasApiAccess(extension->id, "cookies", url)) {
        EventHub::Get().Post(extension->id, "cookies.onChanged", args.Clone());
      }
    }
  }

 private:
  mojo::Receiver<network::mojom::CookieChangeListener> receiver_{this};
};

void EnsureCookieChangeForwarder() {
  static base::NoDestructor<CookieChangeForwarder> forwarder;
  forwarder->Start();
}

void HandleCookies(const BlinkerApiCaller& caller,
                   const base::DictValue& request,
                   const std::string& op,
                   base::OnceCallback<void(std::string)> callback) {
  EnsureCookieChangeForwarder();
  network::mojom::CookieManager* manager = CookieManager();
  if (!manager) {
    std::move(callback).Run(ErrorReply("no cookie store"));
    return;
  }
  const std::string* url_string = request.FindString("url");
  const GURL url = url_string ? GURL(*url_string) : GURL();

  if (op == "getAllCookieStores") {
    base::DictValue store;
    store.Set("id", "0");
    store.Set("tabIds", base::ListValue());
    base::ListValue stores;
    stores.Append(std::move(store));
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("stores", std::move(stores));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();

  if (op == "get" || op == "getAll") {
    if (url.is_valid()) {
      if (!registry.HasApiAccess(caller.extension_id, "cookies", url)) {
        std::move(callback).Run(
            ErrorReply("No host permission for that URL"));
        return;
      }
      manager->GetCookieList(
          url, net::CookieOptions::MakeAllInclusive(),
          net::CookiePartitionKeyCollection::ContainsAll(),
          base::BindOnce(
              [](base::OnceCallback<void(std::string)> cb,
                 base::DictValue filter, bool single,
                 const net::CookieAccessResultList& cookies,
                 const net::CookieAccessResultList&) {
                base::ListValue out;
                for (const auto& entry : cookies) {
                  if (!CookieMatchesFilter(entry.cookie, filter)) {
                    continue;
                  }
                  out.Append(CookieToValue(entry.cookie));
                  if (single) {
                    break;
                  }
                }
                base::DictValue reply;
                reply.Set("ok", true);
                reply.Set("cookies", std::move(out));
                std::move(cb).Run(Serialize(reply));
              },
              std::move(callback), request.Clone(), op == "get"));
      return;
    }
    if (op == "get") {
      std::move(callback).Run(ErrorReply("url is required"));
      return;
    }
    if (!registry.HasApiAccess(caller.extension_id, "cookies",
                               GURL("https://example.com/")) ||
        !registry.HasApiAccess(caller.extension_id, "cookies",
                               GURL("http://other.test/"))) {
      std::move(callback).Run(ErrorReply(
          "Reading every cookie needs a host permission for all sites"));
      return;
    }
    manager->GetAllCookies(base::BindOnce(
        [](base::OnceCallback<void(std::string)> cb, base::DictValue filter,
           const std::vector<net::CanonicalCookie>& cookies) {
          base::ListValue out;
          for (const net::CanonicalCookie& cookie : cookies) {
            if (CookieMatchesFilter(cookie, filter)) {
              out.Append(CookieToValue(cookie));
            }
          }
          base::DictValue reply;
          reply.Set("ok", true);
          reply.Set("cookies", std::move(out));
          std::move(cb).Run(Serialize(reply));
        },
        std::move(callback), request.Clone()));
    return;
  }

  if (op == "set" || op == "remove") {
    if (!url.is_valid() ||
        !registry.HasApiAccess(caller.extension_id, "cookies", url)) {
      std::move(callback).Run(ErrorReply("No host permission for that URL"));
      return;
    }
    const std::string* name = request.FindString("name");
    if (!name) {
      std::move(callback).Run(ErrorReply("name is required"));
      return;
    }

    if (op == "remove") {
      manager->GetCookieList(
          url, net::CookieOptions::MakeAllInclusive(),
          net::CookiePartitionKeyCollection::ContainsAll(),
          base::BindOnce(
              [](base::OnceCallback<void(std::string)> cb, GURL url,
                 std::string name,
                 const net::CookieAccessResultList& cookies,
                 const net::CookieAccessResultList&) {
                network::mojom::CookieManager* manager = CookieManager();
                if (!manager) {
                  std::move(cb).Run(ErrorReply("no cookie store"));
                  return;
                }
                for (const auto& entry : cookies) {
                  if (entry.cookie.Name() != name) {
                    continue;
                  }
                  manager->DeleteCanonicalCookie(
                      entry.cookie,
                      base::BindOnce(
                          [](base::OnceCallback<void(std::string)> cb,
                             GURL url, std::string name, bool) {
                            base::DictValue details;
                            details.Set("url", url.spec());
                            details.Set("name", name);
                            details.Set("storeId", "0");
                            base::DictValue reply;
                            reply.Set("ok", true);
                            reply.Set("details", std::move(details));
                            std::move(cb).Run(Serialize(reply));
                          },
                          std::move(cb), url, name));
                  return;
                }
                std::move(cb).Run("{\"ok\":true}");
              },
              std::move(callback), url, *name));
      return;
    }

    std::string value;
    if (const std::string* v = request.FindString("value")) {
      value = *v;
    }
    std::string domain;
    if (const std::string* d = request.FindString("domain")) {
      domain = *d;
    }
    std::string path;
    if (const std::string* p = request.FindString("path")) {
      path = *p;
    }
    base::Time expiry;
    if (std::optional<double> seconds = request.FindDouble("expirationDate")) {
      expiry = base::Time::FromSecondsSinceUnixEpoch(*seconds);
    }
    net::CookieInclusionStatus status;
    std::unique_ptr<net::CanonicalCookie> cookie =
        net::CanonicalCookie::CreateSanitizedCookie(
            url, *name, value, domain, path, base::Time::Now(), expiry,
            base::Time::Now(), request.FindBool("secure").value_or(false),
            request.FindBool("httpOnly").value_or(false),
            SameSiteFromString(request.FindString("sameSite")),
            net::COOKIE_PRIORITY_DEFAULT,
            /*partition_key=*/std::nullopt, &status);
    if (!cookie) {
      std::move(callback).Run(ErrorReply("Invalid cookie"));
      return;
    }
    const base::DictValue as_value = CookieToValue(*cookie);
    manager->SetCanonicalCookie(
        *cookie, url, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(
            [](base::OnceCallback<void(std::string)> cb, base::DictValue value,
               net::CookieAccessResult result) {
              if (!result.status.IsInclude()) {
                std::move(cb).Run(ErrorReply("The cookie was not set"));
                return;
              }
              base::DictValue reply;
              reply.Set("ok", true);
              reply.Set("cookie", std::move(value));
              std::move(cb).Run(Serialize(reply));
            },
            std::move(callback), as_value.Clone()));
    return;
  }

  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.cookies.", op, " is not implemented"})));
}

// Сховище в браузері, бо воркер MV3 створює пункти і одразу зупиняється

struct ContextMenuItem {
  std::string extension_id;
  std::string id;
  std::string title;
  std::string parent_id;
  std::string type = "normal";
  bool checked = false;
  bool enabled = true;
  bool visible = true;
  std::vector<std::string> contexts{"page"};
  std::vector<std::string> document_url_patterns;
  std::vector<std::string> target_url_patterns;
  uint64_t order = 0;
};

class ContextMenuStore {
 public:
  static ContextMenuStore& Get() {
    static base::NoDestructor<ContextMenuStore> store;
    return *store;
  }

  bool Create(const std::string& extension_id,
              const base::DictValue& properties,
              std::string* error) {
    ContextMenuItem item;
    item.extension_id = extension_id;
    if (const std::string* id = properties.FindString("id")) {
      item.id = *id;
    } else if (std::optional<double> n = properties.FindDouble("id")) {
      item.id = base::NumberToString(static_cast<int64_t>(*n));
    } else {
      item.id = base::NumberToString(++generated_id_);
    }
    if (Find(extension_id, item.id)) {
      *error = "Cannot create item with duplicate id " + item.id;
      return false;
    }
    if (!Apply(properties, &item, error)) {
      return false;
    }
    if (item.type != "separator" && item.title.empty()) {
      *error = "Type other than 'separator' requires a title";
      return false;
    }
    if (!item.parent_id.empty() && !Find(extension_id, item.parent_id)) {
      *error = "Cannot find menu item with id " + item.parent_id;
      return false;
    }
    item.order = ++next_order_;
    items_.push_back(std::move(item));
    return true;
  }

  bool Update(const std::string& extension_id,
              const std::string& id,
              const base::DictValue& properties,
              std::string* error) {
    ContextMenuItem* item = Find(extension_id, id);
    if (!item) {
      *error = "Cannot find menu item with id " + id;
      return false;
    }
    return Apply(properties, item, error);
  }

  void Remove(const std::string& extension_id, const std::string& id) {
    std::vector<std::string> doomed{id};
    for (size_t i = 0; i < doomed.size(); ++i) {
      for (const ContextMenuItem& item : items_) {
        if (item.extension_id == extension_id && item.parent_id == doomed[i]) {
          doomed.push_back(item.id);
        }
      }
    }
    std::erase_if(items_, [&](const ContextMenuItem& item) {
      return item.extension_id == extension_id &&
             std::find(doomed.begin(), doomed.end(), item.id) != doomed.end();
    });
  }

  void RemoveAll(const std::string& extension_id) {
    std::erase_if(items_, [&](const ContextMenuItem& item) {
      return item.extension_id == extension_id;
    });
  }

  base::ListValue Serialize(const std::string& extension_id) const {
    std::vector<const ContextMenuItem*> own;
    for (const ContextMenuItem& item : items_) {
      if (item.extension_id == extension_id) {
        own.push_back(&item);
      }
    }
    std::sort(own.begin(), own.end(),
              [](const ContextMenuItem* a, const ContextMenuItem* b) {
                return a->order < b->order;
              });
    const auto strings = [](const std::vector<std::string>& values) {
      base::ListValue list;
      for (const std::string& value : values) {
        list.Append(value);
      }
      return list;
    };
    base::ListValue out;
    for (const ContextMenuItem* item : own) {
      base::DictValue value;
      value.Set("id", item->id);
      value.Set("title", item->title);
      if (!item->parent_id.empty()) {
        value.Set("parentId", item->parent_id);
      }
      value.Set("type", item->type);
      value.Set("checked", item->checked);
      value.Set("enabled", item->enabled);
      value.Set("visible", item->visible);
      value.Set("contexts", strings(item->contexts));
      value.Set("documentUrlPatterns", strings(item->document_url_patterns));
      value.Set("targetUrlPatterns", strings(item->target_url_patterns));
      out.Append(std::move(value));
    }
    return out;
  }

  void Restore(const std::string& extension_id, const base::ListValue& list) {
    for (const base::Value& entry : list) {
      const base::DictValue* properties = entry.GetIfDict();
      std::string error;
      if (!properties || !Create(extension_id, *properties, &error)) {
        continue;
      }
      // Згенеровані id мають йти після відновлених
      uint64_t numeric = 0;
      if (const std::string* id = properties->FindString("id");
          id && base::StringToUint64(*id, &numeric)) {
        generated_id_ = std::max(generated_id_, numeric);
      }
    }
  }

  const ContextMenuItem* FindByKey(const std::string& key) const {
    const size_t sep = key.find('\n');
    if (sep == std::string::npos) {
      return nullptr;
    }
    const std::string extension_id = key.substr(0, sep);
    const std::string id = key.substr(sep + 1);
    for (const ContextMenuItem& item : items_) {
      if (item.extension_id == extension_id && item.id == id) {
        return &item;
      }
    }
    return nullptr;
  }

  bool Toggle(const ContextMenuItem& clicked) {
    ContextMenuItem* item = Find(clicked.extension_id, clicked.id);
    if (!item) {
      return false;
    }
    const bool was_checked = item->checked;
    if (item->type == "checkbox") {
      item->checked = !item->checked;
    } else if (item->type == "radio") {
      for (ContextMenuItem& other : items_) {
        if (other.extension_id == item->extension_id &&
            other.parent_id == item->parent_id && other.type == "radio") {
          other.checked = false;
        }
      }
      item->checked = true;
    }
    return was_checked;
  }

  std::vector<BlinkerContextMenuEntry> Matching(
      const BlinkerContextMenuTarget& target) {
    std::vector<const ContextMenuItem*> matched;
    for (const ContextMenuItem& item : items_) {
      if (!IsEnabledExtension(item.extension_id) || !item.visible ||
          item.type == "separator") {
        continue;
      }
      if (HasChildren(item)) {
        continue;
      }
      if (!MatchesContext(item, target) || !MatchesPatterns(item, target)) {
        continue;
      }
      matched.push_back(&item);
    }
    std::sort(matched.begin(), matched.end(),
              [](const ContextMenuItem* a, const ContextMenuItem* b) {
                return a->order < b->order;
              });

    std::vector<BlinkerContextMenuEntry> out;
    for (const ContextMenuItem* item : matched) {
      BlinkerContextMenuEntry entry;
      entry.key = item->extension_id + "\n" + item->id;
      entry.title = ExpandTitle(item->title, target);
      if (const ContextMenuItem* parent =
              item->parent_id.empty()
                  ? nullptr
                  : Find(item->extension_id, item->parent_id)) {
        if (parent->visible) {
          entry.parent_title = ExpandTitle(parent->title, target);
        }
      }
      entry.checked = item->checked;
      entry.checkable = item->type == "checkbox" || item->type == "radio";
      if (!item->enabled) {
        // В старому меню UIKit нема вимкнених пунктів, а пункт що нічого не
        // робить гірший за відсутній
        continue;
      }
      out.push_back(std::move(entry));
    }
    return out;
  }

 private:
  friend class base::NoDestructor<ContextMenuStore>;
  ContextMenuStore() = default;
  ~ContextMenuStore() = default;

  ContextMenuItem* Find(const std::string& extension_id,
                        const std::string& id) {
    for (ContextMenuItem& item : items_) {
      if (item.extension_id == extension_id && item.id == id) {
        return &item;
      }
    }
    return nullptr;
  }
  const ContextMenuItem* Find(const std::string& extension_id,
                              const std::string& id) const {
    return const_cast<ContextMenuStore*>(this)->Find(extension_id, id);
  }

  bool HasChildren(const ContextMenuItem& item) const {
    for (const ContextMenuItem& other : items_) {
      if (other.extension_id == item.extension_id &&
          other.parent_id == item.id) {
        return true;
      }
    }
    return false;
  }

  static bool IsEnabledExtension(const std::string& extension_id) {
    for (const std::unique_ptr<BlinkerWebExtension>& extension :
         BlinkerWebExtensionRegistry::GetInstance().extensions()) {
      if (extension->id == extension_id) {
        return extension->enabled;
      }
    }
    return false;
  }

  static bool Apply(const base::DictValue& properties,
                    ContextMenuItem* item,
                    std::string* error) {
    if (const std::string* title = properties.FindString("title")) {
      item->title = *title;
    }
    if (const std::string* type = properties.FindString("type")) {
      if (*type != "normal" && *type != "checkbox" && *type != "radio" &&
          *type != "separator") {
        *error = "Invalid menu item type " + *type;
        return false;
      }
      item->type = *type;
    }
    if (std::optional<bool> checked = properties.FindBool("checked")) {
      item->checked = *checked;
    }
    if (std::optional<bool> enabled = properties.FindBool("enabled")) {
      item->enabled = *enabled;
    }
    if (std::optional<bool> visible = properties.FindBool("visible")) {
      item->visible = *visible;
    }
    if (const std::string* parent = properties.FindString("parentId")) {
      item->parent_id = *parent;
    } else if (std::optional<double> n = properties.FindDouble("parentId")) {
      item->parent_id = base::NumberToString(static_cast<int64_t>(*n));
    }
    const auto strings = [&](const char* name, std::vector<std::string>* out) {
      const base::ListValue* list = properties.FindList(name);
      if (!list) {
        return;
      }
      out->clear();
      for (const base::Value& value : *list) {
        if (value.is_string()) {
          out->push_back(value.GetString());
        }
      }
    };
    strings("contexts", &item->contexts);
    strings("documentUrlPatterns", &item->document_url_patterns);
    strings("targetUrlPatterns", &item->target_url_patterns);
    return true;
  }

  static std::string ExpandTitle(const std::string& title,
                                 const BlinkerContextMenuTarget& target) {
    const size_t at = title.find("%s");
    if (at == std::string::npos) {
      return title;
    }
    std::string selection = target.selection_text;
    if (selection.size() > 32) {
      selection = selection.substr(0, 32) + "\xE2\x80\xA6";
    }
    std::string out = title;
    out.replace(at, 2, selection);
    return out;
  }

  static bool MatchesContext(const ContextMenuItem& item,
                             const BlinkerContextMenuTarget& target) {
    for (const std::string& context : item.contexts) {
      if (context == "all") {
        return true;
      }
      if (context == "selection" && !target.selection_text.empty()) {
        return true;
      }
      if (context == "link" && target.link_url.is_valid()) {
        return true;
      }
      if (context == "editable" && target.editable) {
        return true;
      }
      if (context == target.media_type && target.src_url.is_valid()) {
        return true;
      }
      if (context == "frame" && target.frame_url.is_valid() &&
          target.frame_url != target.page_url) {
        return true;
      }
      if (context == "page") {
        if (target.selection_text.empty() && !target.link_url.is_valid() &&
            !target.editable && target.media_type == "none") {
          return true;
        }
      }
    }
    return false;
  }

  static bool MatchesPatterns(const ContextMenuItem& item,
                              const BlinkerContextMenuTarget& target) {
    const auto matches = [](const std::vector<std::string>& patterns,
                            const GURL& url) {
      if (patterns.empty()) {
        return true;
      }
      if (!url.is_valid()) {
        return false;
      }
      bx::MatchPatternSet set;
      for (const std::string& pattern : patterns) {
        set.AddInclude(pattern);
      }
      return set.Matches(BlinkerUrlParts(url));
    };
    const GURL& document = target.frame_url.is_valid() ? target.frame_url
                                                       : target.page_url;
    if (!matches(item.document_url_patterns, document)) {
      return false;
    }
    const GURL& target_url =
        target.link_url.is_valid() ? target.link_url : target.src_url;
    return matches(item.target_url_patterns, target_url);
  }

  std::vector<ContextMenuItem> items_;
  uint64_t next_order_ = 0;
  uint64_t generated_id_ = 0;
};

void HandleContextMenus(const BlinkerApiCaller& caller,
                        const base::DictValue& request,
                        const std::string& op,
                        base::OnceCallback<void(std::string)> callback) {
  ContextMenuStore& store = ContextMenuStore::Get();
  const base::DictValue* properties = request.FindDict("properties");
  const base::DictValue empty;
  std::string id;
  if (const std::string* value = request.FindString("id")) {
    id = *value;
  } else if (std::optional<double> n = request.FindDouble("id")) {
    id = base::NumberToString(static_cast<int64_t>(*n));
  }

  if (op == "create") {
    std::string error;
    if (!store.Create(caller.extension_id, properties ? *properties : empty,
                      &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "update") {
    std::string error;
    if (!store.Update(caller.extension_id, id,
                      properties ? *properties : empty, &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "remove") {
    store.Remove(caller.extension_id, id);
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "removeAll") {
    store.RemoveAll(caller.extension_id);
    PersistApiStateSoon(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.contextMenus.", op, " is not implemented"})));
}

class ApiStatePersister {
 public:
  static ApiStatePersister& Get() {
    static base::NoDestructor<ApiStatePersister> persister;
    return *persister;
  }

  void MarkDirty(const std::string& extension_id) {
    dirty_.insert(extension_id);
    if (!timer_.IsRunning()) {
      timer_.Start(FROM_HERE, base::Seconds(1),
                   base::BindOnce(&ApiStatePersister::Flush,
                                  base::Unretained(this)));
    }
  }

 private:
  friend class base::NoDestructor<ApiStatePersister>;
  ApiStatePersister() = default;
  ~ApiStatePersister() = default;

  void Flush() {
    for (const std::string& extension_id : dirty_) {
      base::DictValue state;
      state.Set("alarms", AlarmStore::Get().Serialize(extension_id));
      state.Set("contextMenus",
                ContextMenuStore::Get().Serialize(extension_id));
      BlinkerWebExtensionRegistry::GetInstance().SetApiState(extension_id,
                                                             std::move(state));
    }
    dirty_.clear();
  }

  std::set<std::string> dirty_;
  base::OneShotTimer timer_;
};

void PersistApiStateSoon(const std::string& extension_id) {
  ApiStatePersister::Get().MarkDirty(extension_id);
}

struct NotificationRecord {
  std::string extension_id;
  std::string id;
  base::DictValue options;
};

class NotificationStore {
 public:
  static NotificationStore& Get() {
    static base::NoDestructor<NotificationStore> store;
    return *store;
  }

  NotificationRecord* Find(const std::string& extension_id,
                           const std::string& id) {
    for (NotificationRecord& record : records_) {
      if (record.extension_id == extension_id && record.id == id) {
        return &record;
      }
    }
    return nullptr;
  }

  std::string Create(const std::string& extension_id,
                     std::string id,
                     base::DictValue options) {
    if (id.empty()) {
      id = base::StrCat({"blinker-", base::NumberToString(++next_id_)});
    }
    if (NotificationRecord* existing = Find(extension_id, id)) {
      existing->options = std::move(options);
    } else {
      records_.push_back({extension_id, id, std::move(options)});
      while (records_.size() > 32) {
        records_.erase(records_.begin());
      }
    }
    return id;
  }

  bool Clear(const std::string& extension_id, const std::string& id) {
    const size_t before = records_.size();
    std::erase_if(records_, [&](const NotificationRecord& record) {
      return record.extension_id == extension_id && record.id == id;
    });
    return records_.size() != before;
  }

  base::ListValue IdsFor(const std::string& extension_id) const {
    base::ListValue ids;
    for (const NotificationRecord& record : records_) {
      if (record.extension_id == extension_id) {
        ids.Append(record.id);
      }
    }
    return ids;
  }

 private:
  friend class base::NoDestructor<NotificationStore>;
  NotificationStore() = default;
  ~NotificationStore() = default;

  std::vector<NotificationRecord> records_;
  uint64_t next_id_ = 0;
};

// З реєстру, щоб iconUrl не вийшов за межі розширення
void NotificationSourceAndIcon(const std::string& extension_id,
                               const base::DictValue& options,
                               std::string* source_name,
                               std::string* icon_path) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  for (const std::unique_ptr<BlinkerWebExtension>& extension :
       registry.extensions()) {
    if (extension->id == extension_id) {
      *source_name = extension->name.empty() ? extension->id : extension->name;
      break;
    }
  }
  const std::string* icon = options.FindString("iconUrl");
  if (!icon || icon->empty()) {
    return;
  }
  std::string relative = *icon;
  const std::string prefix =
      base::StrCat({kBlinkerExtensionScheme, "://", extension_id, "/"});
  if (relative.starts_with(prefix)) {
    relative = relative.substr(prefix.size());
  } else if (relative.find("://") != std::string::npos) {
    return;
  }
  const GURL url(base::StrCat({prefix, relative}));
  BlinkerWebExtensionRegistry::ResolvedResource resolved;
  if (registry.ResolveResource(url, std::nullopt, &resolved) &&
      !resolved.path.empty()) {
    *icon_path = resolved.path.AsUTF8Unsafe();
  }
}

void ShowNotification(const std::string& extension_id,
                      const std::string& id,
                      const base::DictValue& options) {
  std::string source_name;
  std::string icon_path;
  NotificationSourceAndIcon(extension_id, options, &source_name, &icon_path);
  std::string title;
  if (const std::string* value = options.FindString("title")) {
    title = *value;
  }
  std::string message;
  if (const std::string* value = options.FindString("message")) {
    message = *value;
  }
  std::vector<std::string> button_titles;
  if (const base::ListValue* buttons = options.FindList("buttons")) {
    for (const base::Value& entry : *buttons) {
      if (const base::DictValue* button = entry.GetIfDict()) {
        if (const std::string* value = button->FindString("title")) {
          button_titles.push_back(*value);
        }
      }
      if (button_titles.size() == 2) {
        break;
      }
    }
  }
  BlinkShowExtensionNotification(
      extension_id.c_str(), id.c_str(), source_name.c_str(), title.c_str(),
      message.c_str(), icon_path.c_str(),
      base::JoinString(button_titles, "\n").c_str());
}

void HandleNotifications(const BlinkerApiCaller& caller,
                         const base::DictValue& request,
                         const std::string& op,
                         base::OnceCallback<void(std::string)> callback) {
  NotificationStore& store = NotificationStore::Get();
  std::string id;
  if (const std::string* value = request.FindString("notificationId")) {
    id = *value;
  }
  const base::DictValue* options = request.FindDict("options");

  if (op == "getPermissionLevel") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("level", "granted");
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "getAll") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("ids", store.IdsFor(caller.extension_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "create" || op == "update") {
    if (!options) {
      std::move(callback).Run(ErrorReply("options are required"));
      return;
    }
    if (op == "update" && !store.Find(caller.extension_id, id)) {
      base::DictValue reply;
      reply.Set("ok", true);
      reply.Set("wasUpdated", false);
      std::move(callback).Run(Serialize(reply));
      return;
    }
    base::DictValue merged = options->Clone();
    if (op == "update") {
      base::DictValue combined =
          store.Find(caller.extension_id, id)->options.Clone();
      combined.Merge(std::move(merged));
      merged = std::move(combined);
    }
    const std::string assigned =
        store.Create(caller.extension_id, id, merged.Clone());
    ShowNotification(caller.extension_id, assigned, merged);
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("notificationId", assigned);
    reply.Set("wasUpdated", op == "update");
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "clear") {
    const bool cleared = store.Clear(caller.extension_id, id);
    if (cleared) {
      BlinkHideExtensionNotification(caller.extension_id.c_str(), id.c_str());
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("wasCleared", cleared);
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.notifications.", op, " is not implemented"})));
}

DownloadManager* DownloadManagerForExtensions() {
  ShellContentBrowserClient* client = ShellContentBrowserClient::Get();
  BrowserContext* context =
      client ? static_cast<BrowserContext*>(client->browser_context())
             : nullptr;
  return context ? context->GetDownloadManager() : nullptr;
}

bool HasDownloadsPermission(const std::string& extension_id) {
  for (const std::unique_ptr<BlinkerWebExtension>& extension :
       BlinkerWebExtensionRegistry::GetInstance().extensions()) {
    if (extension->id != extension_id) {
      continue;
    }
    for (const std::vector<std::string>* list :
         {&extension->permissions, &extension->granted_optional}) {
      if (std::find(list->begin(), list->end(), "downloads") != list->end()) {
        return true;
      }
    }
    return false;
  }
  return false;
}

const char* DownloadStateName(download::DownloadItem::DownloadState state) {
  switch (state) {
    case download::DownloadItem::IN_PROGRESS:
      return "in_progress";
    case download::DownloadItem::COMPLETE:
      return "complete";
    case download::DownloadItem::CANCELLED:
    case download::DownloadItem::INTERRUPTED:
      return "interrupted";
    default:
      return "in_progress";
  }
}

base::DictValue DownloadToValue(download::DownloadItem* item) {
  base::DictValue out;
  out.Set("id", static_cast<int>(item->GetId()));
  out.Set("url", item->GetURL().spec());
  out.Set("finalUrl", item->GetURL().spec());
  out.Set("referrer", item->GetReferrerUrl().spec());
  out.Set("filename", item->GetTargetFilePath().AsUTF8Unsafe());
  out.Set("mime", item->GetMimeType());
  out.Set("state", DownloadStateName(item->GetState()));
  out.Set("paused", item->IsPaused());
  out.Set("canResume", item->CanResume());
  out.Set("bytesReceived", static_cast<double>(item->GetReceivedBytes()));
  out.Set("totalBytes", static_cast<double>(item->GetTotalBytes()));
  out.Set("fileSize", static_cast<double>(item->GetReceivedBytes()));
  out.Set("exists", !item->GetFileExternallyRemoved());
  out.Set("incognito", false);
  out.Set("danger", "safe");
  out.Set("startTime", item->GetStartTime().InMillisecondsFSinceUnixEpoch());
  if (item->GetLastReason() != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
    out.Set("error", download::DownloadInterruptReasonToString(
                         item->GetLastReason()));
  }
  return out;
}

// Все що може вийти за папку завантажень відкидаємо а не чистимо
// бо файл пишеться без нагляду користувача
bool SafeDownloadRelativePath(const std::string& name, base::FilePath* out) {
  if (name.empty() || name.front() == '/' || name.front() == '\\' ||
      name.find("..") != std::string::npos ||
      name.find('\0') != std::string::npos) {
    return false;
  }
  *out = base::FilePath::FromUTF8Unsafe(name);
  return !out->IsAbsolute() && !out->ReferencesParent();
}

// Окремий спостерігач на кожен item, бо прогрес item повідомляє сам
class DownloadEventForwarder : public DownloadManager::Observer,
                               public download::DownloadItem::Observer {
 public:
  static DownloadEventForwarder& Get() {
    static base::NoDestructor<DownloadEventForwarder> forwarder;
    return *forwarder;
  }

  void Start() {
    DownloadManager* manager = DownloadManagerForExtensions();
    if (!manager || manager == observed_manager_) {
      return;
    }
    observed_manager_ = manager;
    manager->AddObserver(this);
  }

  void OnDownloadCreated(DownloadManager* manager,
                         download::DownloadItem* item) override {
    item->AddObserver(this);
    Broadcast("downloads.onCreated", DownloadToValue(item));
  }

  void ManagerGoingDown(DownloadManager* manager) override {
    if (observed_manager_ == manager) {
      manager->RemoveObserver(this);
      observed_manager_ = nullptr;
    }
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    const std::string state = DownloadStateName(item->GetState());
    const bool paused = item->IsPaused();
    auto& last = last_state_[item->GetId()];
    if (last.state == state && last.paused == paused) {
      return;
    }
    base::DictValue delta;
    delta.Set("id", static_cast<int>(item->GetId()));
    if (last.state != state) {
      base::DictValue change;
      if (!last.state.empty()) {
        change.Set("previous", last.state);
      }
      change.Set("current", state);
      delta.Set("state", std::move(change));
    }
    if (last.paused != paused) {
      base::DictValue change;
      change.Set("previous", last.paused);
      change.Set("current", paused);
      delta.Set("paused", std::move(change));
    }
    if (item->GetState() == download::DownloadItem::COMPLETE) {
      delta.Set("filename", item->GetTargetFilePath().AsUTF8Unsafe());
    }
    last.state = state;
    last.paused = paused;
    Broadcast("downloads.onChanged", std::move(delta));
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    last_state_.erase(item->GetId());
    item->RemoveObserver(this);
  }

 private:
  friend class base::NoDestructor<DownloadEventForwarder>;
  DownloadEventForwarder() = default;
  ~DownloadEventForwarder() override = default;

  struct LastState {
    std::string state;
    bool paused = false;
  };

  static void Broadcast(const std::string& name, base::DictValue payload) {
    base::ListValue args;
    args.Append(std::move(payload));
    for (const std::unique_ptr<BlinkerWebExtension>& extension :
         BlinkerWebExtensionRegistry::GetInstance().extensions()) {
      if (extension->enabled && HasDownloadsPermission(extension->id)) {
        EventHub::Get().Post(extension->id, name, args.Clone());
      }
    }
  }

  raw_ptr<DownloadManager> observed_manager_ = nullptr;
  std::map<uint32_t, LastState> last_state_;
};

void HandleDownloads(const BlinkerApiCaller& caller,
                     const base::DictValue& request,
                     const std::string& op,
                     base::OnceCallback<void(std::string)> callback) {
  if (!HasDownloadsPermission(caller.extension_id)) {
    std::move(callback).Run(
        ErrorReply("The 'downloads' permission is required"));
    return;
  }
  DownloadManager* manager = DownloadManagerForExtensions();
  if (!manager) {
    std::move(callback).Run(ErrorReply("no download manager"));
    return;
  }
  DownloadEventForwarder::Get().Start();

  if (op == "download") {
    const std::string* url_string = request.FindString("url");
    const GURL url = url_string ? GURL(*url_string) : GURL();
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
      std::move(callback).Run(ErrorReply("A http(s) url is required"));
      return;
    }
    constexpr net::NetworkTrafficAnnotationTag kAnnotation =
        net::DefineNetworkTrafficAnnotation("blinker_extension_download", R"(
        semantics {
          sender: "Blinker Fluid extension"
          description:
            "An installed browser extension asked to download a file through "
            "chrome.downloads.download()."
          trigger:
            "An extension the user installed called "
            "chrome.downloads.download()."
          data: "Whatever the extension put in the request: the URL, and any "
                "headers or method it set."
          destination: OTHER
        }
        policy {
          cookies_allowed: YES
          cookies_store: "user"
          setting:
            "Turn the extension off, or remove it, from Menu > Extensions. "
            "An extension cannot reach this without the 'downloads' "
            "permission in its manifest."
          policy_exception_justification: "Not implemented."
        })");
    auto params =
        std::make_unique<download::DownloadUrlParameters>(url, kAnnotation);
    params->set_content_initiated(false);
    if (const std::string* method = request.FindString("method")) {
      params->set_method(*method);
    }
    if (const base::ListValue* headers = request.FindList("headers")) {
      for (const base::Value& entry : *headers) {
        const base::DictValue* header = entry.GetIfDict();
        if (!header) {
          continue;
        }
        const std::string* name = header->FindString("name");
        const std::string* value = header->FindString("value");
        if (name && value) {
          params->add_request_header(*name, *value);
        }
      }
    }
    if (const std::string* filename = request.FindString("filename")) {
      base::FilePath relative;
      if (!SafeDownloadRelativePath(*filename, &relative)) {
        std::move(callback).Run(ErrorReply("Invalid filename"));
        return;
      }
      // Це тільки ім'я, файл все одно ляже в папку завантажень браузера
      params->set_suggested_name(base::UTF8ToUTF16(*filename));
    }
    params->set_callback(base::BindOnce(
        [](base::OnceCallback<void(std::string)> cb,
           download::DownloadItem* item,
           download::DownloadInterruptReason reason) {
          if (!item) {
            std::move(cb).Run(ErrorReply(
                download::DownloadInterruptReasonToString(reason)));
            return;
          }
          base::DictValue reply;
          reply.Set("ok", true);
          reply.Set("id", static_cast<int>(item->GetId()));
          std::move(cb).Run(Serialize(reply));
        },
        std::move(callback)));
    manager->DownloadUrl(std::move(params));
    return;
  }

  if (op == "search" || op == "erase") {
    download::SimpleDownloadManager::DownloadVector items;
    manager->GetAllDownloads(&items);
    const base::DictValue* query = request.FindDict("query");
    const std::optional<int> wanted_id =
        query ? query->FindInt("id") : std::nullopt;
    const std::string* wanted_state =
        query ? query->FindString("state") : nullptr;
    const std::string* wanted_url = query ? query->FindString("url") : nullptr;
    const std::optional<int> limit =
        query ? query->FindInt("limit") : std::nullopt;

    base::ListValue out;
    for (download::DownloadItem* item : items) {
      if (wanted_id && static_cast<int>(item->GetId()) != *wanted_id) {
        continue;
      }
      if (wanted_state && DownloadStateName(item->GetState()) != *wanted_state) {
        continue;
      }
      if (wanted_url && item->GetURL().spec() != *wanted_url) {
        continue;
      }
      if (op == "erase") {
        out.Append(static_cast<int>(item->GetId()));
        item->Remove();
        continue;
      }
      out.Append(DownloadToValue(item));
      if (limit && static_cast<int>(out.size()) >= *limit) {
        break;
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set(op == "erase" ? "ids" : "items", std::move(out));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "cancel" || op == "pause" || op == "resume" ||
      op == "removeFile") {
    const std::optional<int> id = request.FindInt("id");
    download::DownloadItem* item =
        id ? manager->GetDownload(static_cast<uint32_t>(*id)) : nullptr;
    if (!item) {
      std::move(callback).Run(ErrorReply("No download with that id"));
      return;
    }
    if (op == "cancel") {
      item->Cancel(/*user_cancel=*/true);
    } else if (op == "pause") {
      item->Pause();
    } else if (op == "resume") {
      item->Resume(/*user_resume=*/true);
    } else {
      item->DeleteFile(base::DoNothing());
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.downloads.", op, " is not implemented"})));
}

// Стан в браузері, бо воркер зупиняється за кілька секунд

class ActionStore {
 public:
  static ActionStore& Get() {
    static base::NoDestructor<ActionStore> store;
    return *store;
  }

  void Set(const std::string& extension_id,
           const std::string& field,
           int tab_id,
           const std::string& value) {
    values_[extension_id][field][tab_id] = value;
  }

  std::string Value(const std::string& extension_id,
                    const std::string& field,
                    int tab_id) const {
    const auto extension = values_.find(extension_id);
    if (extension == values_.end()) {
      return std::string();
    }
    const auto by_tab = extension->second.find(field);
    if (by_tab == extension->second.end()) {
      return std::string();
    }
    const auto exact = by_tab->second.find(tab_id);
    if (exact != by_tab->second.end()) {
      return exact->second;
    }
    const auto fallback = by_tab->second.find(0);
    return fallback == by_tab->second.end() ? std::string()
                                            : fallback->second;
  }

 private:
  friend class base::NoDestructor<ActionStore>;
  ActionStore() = default;
  ~ActionStore() = default;

  std::map<std::string, std::map<std::string, std::map<int, std::string>>>
      values_;
};

void HandleAction(const BlinkerApiCaller& caller,
                  const base::DictValue& request,
                  const std::string& op,
                  base::OnceCallback<void(std::string)> callback) {
  std::string field;
  if (const std::string* value = request.FindString("field")) {
    field = *value;
  }
  const int tab_id = request.FindInt("tabId").value_or(0);
  if (op == "set") {
    std::string value;
    if (const std::string* given = request.FindString("value")) {
      value = *given;
    }
    ActionStore::Get().Set(caller.extension_id, field, tab_id, value);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "get") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("value", ActionStore::Get().Value(caller.extension_id, field,
                                                tab_id));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(
      ErrorReply(base::StrCat({"chrome.action.", op, " is not implemented"})));
}

void HandleWebRequest(const BlinkerApiCaller& caller,
                      const base::DictValue& request,
                      const std::string& op,
                      base::OnceCallback<void(std::string)> callback) {
  std::string event;
  if (const std::string* value = request.FindString("event")) {
    event = *value;
  }
  if (op == "removeListener") {
    BlinkerWebRequestRemoveListeners(caller.extension_id, event);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op != "addListener") {
    std::move(callback).Run(ErrorReply(
        base::StrCat({"chrome.webRequest.", op, " is not implemented"})));
    return;
  }
  BlinkerWebRequestFilter filter;
  filter.extension_id = caller.extension_id;
  filter.event = event;
  filter.extra_headers = request.FindBool("extraHeaders").value_or(false);
  const auto collect = [&request](const char* key,
                                  std::vector<std::string>* out) {
    if (const base::ListValue* list = request.FindList(key)) {
      for (const base::Value& entry : *list) {
        if (const std::string* value = entry.GetIfString()) {
          out->push_back(*value);
        }
      }
    }
  };
  collect("urls", &filter.urls);
  collect("types", &filter.types);
  BlinkerWebRequestAddListener(filter);
  std::move(callback).Run("{\"ok\":true}");
}

class OffscreenDocument;
using OffscreenDocumentMap =
    std::map<std::string, std::unique_ptr<OffscreenDocument>>;
OffscreenDocumentMap& OffscreenDocuments();

// createDocument() відповідає після load, бо воркер може одразу слати
// повідомлення
class OffscreenDocument : public WebContentsObserver {
 public:
  OffscreenDocument(std::string extension_id,
                    std::unique_ptr<WebContents> contents,
                    base::OnceCallback<void(std::string)> callback)
      : WebContentsObserver(contents.get()),
        extension_id_(std::move(extension_id)),
        contents_(std::move(contents)),
        callback_(std::move(callback)) {}

  ~OffscreenDocument() override {
    Observe(nullptr);
    if (callback_) {
      std::move(callback_).Run(
          ErrorReply("Offscreen document closed before fully loading."));
    }
  }

  void Load(const GURL& url) {
    // Його ніколи не видно, але без WasShown таймери і рендер задушаться
    contents_->WasShown();
    contents_->GetController().LoadURLWithParams(
        NavigationController::LoadURLParams(url));
  }

 private:
  void DidFinishNavigation(NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame() || navigation->IsSameDocument()) {
      return;
    }
    if (!navigation->HasCommitted() || navigation->IsErrorPage() ||
        navigation->GetNetErrorCode() != net::OK) {
      Fail("Offscreen document failed to load.");
      return;
    }
    committed_ = true;
  }

  void DocumentOnLoadCompletedInPrimaryMainFrame() override {
    if (committed_ && !failure_pending_ && callback_) {
      std::move(callback_).Run("{\"ok\":true}");
    }
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    Fail("Offscreen document renderer exited.");
  }

  void Fail(std::string error) {
    if (failure_pending_) {
      return;
    }
    failure_pending_ = true;
    // Видалення знищує WebContents, тому чекаємо кінця поточного сповіщення
    GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&OffscreenDocument::RemoveFailedDocument,
                                  weak_factory_.GetWeakPtr(), std::move(error)));
  }

  void RemoveFailedDocument(std::string error) {
    auto callback = std::move(callback_);
    const std::string extension_id = extension_id_;
    OffscreenDocuments().erase(extension_id);
    if (callback) {
      std::move(callback).Run(ErrorReply(error));
    }
  }

  const std::string extension_id_;
  std::unique_ptr<WebContents> contents_;
  base::OnceCallback<void(std::string)> callback_;
  bool committed_ = false;
  bool failure_pending_ = false;
  base::WeakPtrFactory<OffscreenDocument> weak_factory_{this};
};

OffscreenDocumentMap& OffscreenDocuments() {
  static base::NoDestructor<OffscreenDocumentMap> docs;
  return *docs;
}

BrowserContext* AnyBrowserContext() {
  for (Shell* shell : Shell::windows()) {
    if (shell && shell->web_contents()) {
      return shell->web_contents()->GetBrowserContext();
    }
  }
  return nullptr;
}

void HandleOffscreen(const BlinkerApiCaller& caller,
                     const base::DictValue& request,
                     const std::string& op,
                     base::OnceCallback<void(std::string)> callback) {
  auto& docs = OffscreenDocuments();

  if (op == "hasDocument") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("result", docs.count(caller.extension_id) != 0);
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "closeDocument") {
    docs.erase(caller.extension_id);
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (op == "createDocument") {
    if (docs.count(caller.extension_id)) {
      std::move(callback).Run(
          ErrorReply("Only a single offscreen document may be created."));
      return;
    }
    const std::string* url_string = request.FindString("url");
    if (!url_string) {
      std::move(callback).Run(ErrorReply("url is required"));
      return;
    }
    const GURL base(base::StrCat(
        {kBlinkerExtensionScheme, "://", caller.extension_id, "/"}));
    const GURL url = base.Resolve(*url_string);
    if (!url.is_valid() || !url.SchemeIs(kBlinkerExtensionScheme) ||
        url.host() != caller.extension_id) {
      std::move(callback).Run(ErrorReply("Invalid offscreen document url"));
      return;
    }
    BrowserContext* context = AnyBrowserContext();
    if (!context) {
      std::move(callback).Run(ErrorReply("No browser context"));
      return;
    }
    std::unique_ptr<WebContents> contents =
        WebContents::Create(WebContents::CreateParams(context));
    if (!contents) {
      std::move(callback).Run(ErrorReply("Could not create the document"));
      return;
    }
    auto document = std::make_unique<OffscreenDocument>(
        caller.extension_id, std::move(contents), std::move(callback));
    auto* document_ptr = document.get();
    docs[caller.extension_id] = std::move(document);
    document_ptr->Load(url);
    return;
  }

  std::move(callback).Run(ErrorReply(base::StrCat(
      {"chrome.offscreen.", op, " is not implemented in this browser"})));
}

class UserScriptExecution {
 public:
  UserScriptExecution(RenderFrameHost* frame,
                      int frame_id,
                      int world_id,
                      const std::vector<std::string>& sources,
                      bool empty_result_is_error,
                      base::OnceCallback<void(base::DictValue)> callback)
      : frame_id_(frame_id),
        empty_result_is_error_(empty_result_is_error),
        callback_(std::move(callback)) {
    frame->GetRemoteInterfaces()->GetInterface(
        executor_.BindNewPipeAndPassReceiver());
    executor_.set_disconnect_handler(base::BindOnce(
        &UserScriptExecution::OnResult, base::Unretained(this), std::nullopt,
        std::make_optional<std::string>("The target frame was removed"), ""));
    executor_->Execute(
        world_id, frame->GetLastCommittedURL(), sources,
        base::BindOnce(&UserScriptExecution::OnResult, base::Unretained(this)));
  }

 private:
  void OnResult(std::optional<base::Value> result,
                const std::optional<std::string>& error,
                const std::string& document_id) {
    std::unique_ptr<UserScriptExecution> owned_this(this);
    base::DictValue entry;
    entry.Set("frameId", frame_id_);
    entry.Set("documentId", document_id);
    // Blink не відрізняє undefined від винятку, обидва приходять з цим текстом
    const bool no_value =
        error && *error == "Script execution failed" && !empty_result_is_error_;
    if (error && !no_value) {
      entry.Set("error", *error);
    } else if (result) {
      entry.Set("result", std::move(*result));
    }
    std::move(callback_).Run(std::move(entry));
  }

  const int frame_id_;
  const bool empty_result_is_error_;
  base::OnceCallback<void(base::DictValue)> callback_;
  mojo::Remote<mojom::BlinkerScriptExecutor> executor_;
};

RenderFrameHost* FrameByDocumentId(std::string_view document_id);

std::string CollectDocumentFrames(
    Shell* shell,
    const base::ListValue* document_ids,
    std::vector<std::pair<RenderFrameHost*, int>>* out) {
  if (document_ids->empty()) {
    return "Invalid document target";
  }
  for (const base::Value& value : *document_ids) {
    const std::string* id = value.GetIfString();
    if (!id) {
      return "Invalid document id";
    }
    const std::string wanted = base::ToUpperASCII(*id);
    if (!base::UnguessableToken::DeserializeFromString(wanted)) {
      return "Invalid documentId.";
    }
    RenderFrameHost* frame = FrameByDocumentId(wanted);
    if (!frame || WebContents::FromRenderFrameHost(frame) !=
                      shell->web_contents()) {
      return "No document with that id";
    }
    out->emplace_back(frame, BlinkerApiFrameId(frame));
  }
  return std::string();
}

std::string CollectTargetFrames(
    Shell* shell,
    const base::ListValue* frame_ids,
    bool all_frames,
    std::vector<std::pair<RenderFrameHost*, int>>* out) {
  if ((all_frames && frame_ids) || (frame_ids && frame_ids->empty())) {
    return "Invalid frame target";
  }
  std::vector<int> wanted_ids;
  if (frame_ids) {
    for (const base::Value& value : *frame_ids) {
      const std::optional<int> id = value.GetIfInt();
      if (!id || *id < 0) {
        return "Invalid frame id";
      }
      wanted_ids.push_back(*id);
    }
  } else if (!all_frames) {
    wanted_ids.push_back(0);
  }
  RenderFrameHost* main_frame = shell->web_contents()->GetPrimaryMainFrame();
  main_frame->ForEachRenderFrameHost([&](RenderFrameHost* frame) {
    const int id =
        frame == main_frame ? 0 : frame->GetFrameTreeNodeId().value();
    if (all_frames || std::ranges::find(wanted_ids, id) != wanted_ids.end()) {
      out->emplace_back(frame, id);
    }
  });
  for (int id : wanted_ids) {
    if (std::ranges::none_of(
            *out, [id](const auto& entry) { return entry.second == id; })) {
      return "No frame with that id";
    }
  }
  return std::string();
}

std::string FilterAccessibleFrames(
    const std::string& extension_id,
    Shell* shell,
    bool explicit_frames,
    std::vector<std::pair<RenderFrameHost*, int>>* frames) {
  std::string error = FrameAccessError(
      extension_id, shell->web_contents()->GetPrimaryMainFrame());
  if (!error.empty()) {
    return error;
  }
  for (auto it = frames->begin(); it != frames->end();) {
    error = it->first->IsRenderFrameLive()
                ? FrameAccessError(extension_id, it->first)
                : std::string("Cannot access contents of the tab");
    if (error.empty()) {
      ++it;
    } else if (explicit_frames) {
      return error;
    } else {
      it = frames->erase(it);
    }
  }
  return frames->empty() ? "Cannot access contents of the tab" : std::string();
}

class CssInjection {
 public:
  struct Source {
    std::string key;
    std::string css;
  };

  CssInjection(RenderFrameHost* frame,
               const std::vector<Source>& sources,
               bool insert,
               bool user_origin,
               base::OnceCallback<void(std::optional<std::string>)> callback)
      : remaining_(sources.size()), callback_(std::move(callback)) {
    frame->GetRemoteInterfaces()->GetInterface(
        executor_.BindNewPipeAndPassReceiver());
    executor_.set_disconnect_handler(
        base::BindOnce(&CssInjection::Finish, base::Unretained(this),
                       std::make_optional<std::string>(
                           "The target frame was removed")));
    const GURL& url = frame->GetLastCommittedURL();
    for (const Source& source : sources) {
      auto done =
          base::BindOnce(&CssInjection::OnDone, base::Unretained(this));
      if (insert) {
        executor_->InsertCSS(url, source.key, source.css, user_origin,
                             std::move(done));
      } else {
        executor_->RemoveCSS(url, source.key, user_origin, std::move(done));
      }
    }
  }

 private:
  void OnDone(const std::optional<std::string>& error) {
    if (error && !error_) {
      error_ = error;
    }
    if (--remaining_ == 0) {
      Finish(error_);
    }
  }

  void Finish(std::optional<std::string> error) {
    std::unique_ptr<CssInjection> owned_this(this);
    std::move(callback_).Run(std::move(error));
  }

  size_t remaining_;
  std::optional<std::string> error_;
  base::OnceCallback<void(std::optional<std::string>)> callback_;
  mojo::Remote<mojom::BlinkerScriptExecutor> executor_;
};

void ReplyWithFrameResults(base::OnceCallback<void(std::string)> callback,
                           std::vector<base::DictValue> entries) {
  std::ranges::sort(entries, {}, [](const base::DictValue& entry) {
    return entry.FindInt("frameId").value_or(-1);
  });
  base::ListValue results;
  for (auto& entry : entries) {
    results.Append(std::move(entry));
  }
  base::DictValue reply;
  reply.Set("ok", true);
  reply.Set("results", std::move(results));
  std::move(callback).Run(Serialize(reply));
}

void RunInFrames(const std::vector<std::pair<RenderFrameHost*, int>>& frames,
                 int world_id,
                 const std::vector<std::string>& sources,
                 bool empty_result_is_error,
                 base::OnceCallback<void(std::string)> callback) {
  auto collect = base::BarrierCallback<base::DictValue>(
      frames.size(),
      base::BindOnce(&ReplyWithFrameResults, std::move(callback)));
  for (const auto& [frame, frame_id] : frames) {
    new UserScriptExecution(frame, frame_id, world_id, sources,
                            empty_result_is_error, collect);
  }
}

void ExecuteUserScript(const BlinkerApiCaller& caller,
                       const base::DictValue& request,
                       base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  BlinkerWebExtension* extension = registry.FindExtension(caller.extension_id);
  const base::DictValue* target = request.FindDict("target");
  const std::optional<int> tab_id = target ? target->FindInt("tabId")
                                          : std::nullopt;
  Shell* shell = tab_id ? ShellForTabId(*tab_id) : nullptr;
  if (!extension || !shell) {
    std::move(callback).Run(ErrorReply("A valid target.tabId is required"));
    return;
  }
  const std::string* world_name = request.FindString("worldId");
  if (target->contains("documentIds") || (world_name && !world_name->empty())) {
    std::move(callback).Run(
        ErrorReply("documentIds and named user-script worlds are not supported"));
    return;
  }
  const std::string* world = request.FindString("world");
  const bool main_world = world && *world == "MAIN";
  if (world && !main_world && *world != "USER_SCRIPT") {
    std::move(callback).Run(ErrorReply("Invalid user-script execution world"));
    return;
  }
  const int world_id = main_world ? ISOLATED_WORLD_ID_GLOBAL
                                  : extension->user_script_world_id;
  if (world_id < 0) {
    std::move(callback).Run(ErrorReply("No user-script world is available"));
    return;
  }

  const base::ListValue* js = request.FindList("js");
  if (!js || js->empty()) {
    std::move(callback).Run(ErrorReply("js must contain at least one source"));
    return;
  }
  std::vector<std::string> sources;
  if (!main_world && extension->user_script_messaging) {
    sources.push_back(BlinkerExtensionUserScriptMessagingShim(
        extension->id, extension->messaging_token));
  }
  for (const base::Value& value : *js) {
    const base::DictValue* source = value.GetIfDict();
    const std::string* code = source ? source->FindString("code") : nullptr;
    const std::string* file = source ? source->FindString("file") : nullptr;
    if (!source || source->contains("code") == source->contains("file") ||
        (!code && !file)) {
      std::move(callback).Run(ErrorReply("Each source needs either code or file"));
      return;
    }
    if (code) {
      sources.push_back(*code);
    } else {
      std::string contents;
      if (!BlinkerReadExtensionFile(*extension, *file, &contents)) {
        std::move(callback).Run(ErrorReply("Could not load user-script file"));
        return;
      }
      sources.push_back(std::move(contents));
    }
  }

  std::vector<std::pair<RenderFrameHost*, int>> frames;
  const std::string frame_error = CollectTargetFrames(
      shell, target->FindList("frameIds"),
      target->FindBool("allFrames").value_or(false), &frames);
  if (!frame_error.empty()) {
    std::move(callback).Run(ErrorReply(frame_error));
    return;
  }
  for (const auto& [frame, frame_id] : frames) {
    if (!frame->IsRenderFrameLive() ||
        !registry.HasApiAccess(caller.extension_id, "userScripts",
                               frame->GetLastCommittedURL())) {
      std::move(callback).Run(ErrorReply("Cannot access the target frame"));
      return;
    }
  }
  RunInFrames(frames, world_id, sources, /*empty_result_is_error=*/true,
              std::move(callback));
}

void ExecuteScriptingInjection(const BlinkerApiCaller& caller,
                               const base::DictValue& request,
                               base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtension* extension =
      BlinkerWebExtensionRegistry::GetInstance().FindExtension(
          caller.extension_id);
  const int tab_id = static_cast<int>(request.FindDouble("tabId").value_or(-1));
  Shell* shell = tab_id >= 0 ? ShellForTabId(tab_id) : ActiveShell();
  if (!extension || !shell || !shell->web_contents()) {
    std::move(callback).Run(ErrorReply("No tab with that id"));
    return;
  }
  const std::string* world = request.FindString("world");
  const bool main_world = world && *world == "MAIN";
  if (world && !main_world && *world != "ISOLATED") {
    std::move(callback).Run(ErrorReply("Invalid execution world"));
    return;
  }
  const int world_id =
      main_world ? ISOLATED_WORLD_ID_GLOBAL : extension->isolated_world_id;
  if (world_id < 0) {
    std::move(callback).Run(ErrorReply("Cannot access contents of the tab"));
    return;
  }

  std::vector<std::string> sources;
  // В ISOLATED світі код бачить ті самі chrome.* що й content scripts
  if (!main_world) {
    sources.push_back(
        BlinkerExtensionContentScriptShim(*extension)->as_string());
  }
  const std::string* func = request.FindString("func");
  const std::string* code = request.FindString("code");
  const base::ListValue* files = request.FindList("files");
  const int kinds =
      (func ? 1 : 0) + (code ? 1 : 0) + (files && !files->empty() ? 1 : 0);
  if (kinds != 1) {
    std::move(callback).Run(
        ErrorReply("Exactly one of 'func' and 'files' must be specified"));
    return;
  }
  if (code) {
    sources.push_back(*code);
  } else if (func) {
    std::string args_json = "[]";
    if (const base::ListValue* args = request.FindList("args")) {
      args_json = base::WriteJson(*args).value_or("[]");
    }
    sources.push_back(
        base::StrCat({"(", *func, ").apply(null,", args_json, ")"}));
  } else {
    for (const base::Value& entry : *files) {
      const std::string* name = entry.GetIfString();
      std::string contents;
      if (!name || !BlinkerReadExtensionFile(*extension, *name, &contents)) {
        std::move(callback).Run(ErrorReply(base::StrCat(
            {"Could not load file: '", name ? *name : std::string(), "'."})));
        return;
      }
      sources.push_back(std::move(contents));
    }
  }

  std::vector<std::pair<RenderFrameHost*, int>> frames;
  const base::ListValue* document_ids = request.FindList("documentIds");
  const std::string frame_error =
      document_ids ? CollectDocumentFrames(shell, document_ids, &frames)
                   : CollectTargetFrames(
                         shell, request.FindList("frameIds"),
                         request.FindBool("allFrames").value_or(false),
                         &frames);
  if (!frame_error.empty()) {
    std::move(callback).Run(ErrorReply(frame_error));
    return;
  }
  const std::string access_error = FilterAccessibleFrames(
      caller.extension_id, shell,
      document_ids != nullptr || request.FindList("frameIds") != nullptr,
      &frames);
  if (!access_error.empty()) {
    std::move(callback).Run(ErrorReply(access_error));
    return;
  }
  if (frames.empty()) {
    std::move(callback).Run(ErrorReply("Cannot access contents of the tab"));
    return;
  }
  RunInFrames(frames, world_id, sources, /*empty_result_is_error=*/false,
              std::move(callback));
}

void ExecuteScriptingCss(const BlinkerApiCaller& caller,
                         const base::DictValue& request,
                         bool insert,
                         base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtension* extension =
      BlinkerWebExtensionRegistry::GetInstance().FindExtension(
          caller.extension_id);
  const base::DictValue* target = request.FindDict("target");
  const std::optional<int> tab_id =
      target ? OptionalInt(*target, "tabId") : std::nullopt;
  Shell* shell = tab_id ? ShellForTabId(*tab_id) : nullptr;
  if (!extension || !shell || !shell->web_contents()) {
    std::move(callback).Run(ErrorReply(TabNotFound(tab_id.value_or(-1))));
    return;
  }
  const std::string* css = request.FindString("css");
  const base::ListValue* files = request.FindList("files");
  if ((css != nullptr) == (files != nullptr)) {
    std::move(callback).Run(
        ErrorReply("Exactly one of 'css' and 'files' must be specified."));
    return;
  }
  // Ключі як у ScriptExecutor::GenerateInjectionKey, щоб removeCSS
  // знайшов вставлене
  std::vector<CssInjection::Source> sources;
  if (css) {
    sources.push_back(
        {base::StrCat({"C", extension->id,
                       base::NumberToString(base::FastHash(*css))}),
         *css});
  } else {
    for (const base::Value& entry : *files) {
      const std::string* name = entry.GetIfString();
      std::string contents;
      if (!name || !BlinkerReadExtensionFile(*extension, *name, &contents)) {
        std::move(callback).Run(ErrorReply(base::StrCat(
            {"Could not load file: '", name ? *name : std::string(), "'."})));
        return;
      }
      const std::string url =
          GURL(base::StrCat({kBlinkerExtensionScheme, "://", extension->id,
                             "/"}))
              .Resolve(*name)
              .spec();
      sources.push_back(
          {base::StrCat({"F", extension->id,
                         base::NumberToString(base::FastHash(url))}),
           BlinkerLocalizeCss(*extension, std::move(contents))});
    }
  }
  if (sources.empty()) {
    std::move(callback).Run(ErrorReply("No CSS to inject"));
    return;
  }

  std::vector<std::pair<RenderFrameHost*, int>> frames;
  const base::ListValue* document_ids = target->FindList("documentIds");
  std::string error =
      document_ids
          ? CollectDocumentFrames(shell, document_ids, &frames)
          : CollectTargetFrames(shell, target->FindList("frameIds"),
                                target->FindBool("allFrames").value_or(false),
                                &frames);
  if (error.empty()) {
    error = FilterAccessibleFrames(
        caller.extension_id, shell,
        document_ids != nullptr || target->FindList("frameIds") != nullptr,
        &frames);
  }
  if (!error.empty()) {
    std::move(callback).Run(ErrorReply(error));
    return;
  }
  const std::string* origin = request.FindString("origin");
  const bool user_origin = origin && *origin == "USER";
  auto collect = base::BarrierCallback<std::optional<std::string>>(
      frames.size(),
      base::BindOnce(
          [](base::OnceCallback<void(std::string)> callback,
             std::vector<std::optional<std::string>> errors) {
            for (const std::optional<std::string>& error : errors) {
              if (error) {
                std::move(callback).Run(ErrorReply(*error));
                return;
              }
            }
            std::move(callback).Run("{\"ok\":true}");
          },
          std::move(callback)));
  for (const auto& [frame, frame_id] : frames) {
    new CssInjection(frame, sources, insert, user_origin, collect);
  }
}

void HandleUserScripts(const BlinkerApiCaller& caller,
                       const base::DictValue& request,
                       const std::string& op,
                       base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();

  if (op == "execute") {
    ExecuteUserScript(caller, request, std::move(callback));
    return;
  }
  if (op == "register" || op == "update") {
    const base::ListValue* scripts = request.FindList("scripts");
    if (!scripts) {
      std::move(callback).Run(ErrorReply("scripts is required"));
      return;
    }
    std::string error;
    if (!registry.RegisterUserScripts(caller.extension_id, *scripts,
                                      op == "update", &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "unregister") {
    registry.UnregisterUserScripts(caller.extension_id,
                                   IdsFrom(request, "ids"));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "getScripts") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("scripts", registry.GetUserScripts(caller.extension_id,
                                                 IdsFrom(request, "ids")));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "configureWorld") {
    registry.ConfigureUserScriptWorld(
        caller.extension_id,
        request.FindBool("messaging").value_or(false));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  std::move(callback).Run(ErrorReply(base::StrCat(
      {"chrome.userScripts.", op, " is not implemented in this browser"})));
}

std::vector<int> IntIdsFrom(const base::DictValue& request, const char* key) {
  std::vector<int> ids;
  if (const base::ListValue* list = request.FindList(key)) {
    for (const base::Value& entry : *list) {
      if (entry.is_int()) {
        ids.push_back(entry.GetInt());
      } else if (entry.is_double()) {
        ids.push_back(static_cast<int>(entry.GetDouble()));
      }
    }
  }
  return ids;
}

void HandleDeclarativeNetRequest(
    const BlinkerApiCaller& caller,
    const base::DictValue& request,
    const std::string& op,
    base::OnceCallback<void(std::string)> callback) {
  if (op == "isRegexSupported") {
    const std::string* regex = request.FindString("regex");
    RE2::Options options;
    options.set_case_sensitive(
        request.FindBool("caseSensitive").value_or(false));
    options.set_log_errors(false);
    const bool ok = regex && !regex->empty() && RE2(*regex, options).ok();
    base::DictValue result;
    result.Set("isSupported", ok);
    if (!ok) {
      result.Set("reason", "syntaxError");
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("result", std::move(result));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();

  if (op == "updateDynamicRules" || op == "updateSessionRules") {
    std::string error;
    if (!registry.UpdateRules(caller.extension_id,
                              op == "updateSessionRules",
                              IntIdsFrom(request, "removeRuleIds"),
                              request.FindList("addRules"), &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "getDynamicRules" || op == "getSessionRules") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("rules", registry.GetRules(caller.extension_id,
                                         op == "getSessionRules",
                                         IntIdsFrom(request, "ruleIds")));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "updateEnabledRulesets") {
    std::string error;
    if (!registry.UpdateEnabledRulesets(caller.extension_id,
                                        IdsFrom(request, "disableRulesetIds"),
                                        IdsFrom(request, "enableRulesetIds"),
                                        &error)) {
      std::move(callback).Run(ErrorReply(error));
      return;
    }
    std::move(callback).Run("{\"ok\":true}");
    return;
  }
  if (op == "getEnabledRulesets") {
    base::ListValue ids;
    if (BlinkerWebExtension* extension =
            registry.FindExtension(caller.extension_id)) {
      for (const BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
        if (ruleset.enabled) {
          ids.Append(ruleset.id);
        }
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("rulesetIds", std::move(ids));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "getAvailableStaticRuleCount") {
    size_t used = 0;
    if (BlinkerWebExtension* extension =
            registry.FindExtension(caller.extension_id)) {
      for (const BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
        if (ruleset.enabled) {
          used += ruleset.filter_line_count;
        }
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("count", static_cast<double>(used < 60000 ? 60000 - used : 0));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "getMatchedRules") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("rulesMatchedInfo", base::ListValue());
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(ErrorReply(base::StrCat(
      {"chrome.declarativeNetRequest.", op,
       " is not implemented in this browser"})));
}

void HandlePermissions(const BlinkerApiCaller& caller,
                       const base::DictValue& request,
                       const std::string& op,
                       base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  BlinkerWebExtension* extension = registry.FindExtension(caller.extension_id);
  if (!extension) {
    std::move(callback).Run(ErrorReply("No such extension"));
    return;
  }
  const std::vector<std::string> permissions = IdsFrom(request, "permissions");
  const std::vector<std::string> origins = IdsFrom(request, "origins");
  const auto change_value = [](const BlinkerPermissionChange& change) {
    base::DictValue value;
    base::ListValue apis;
    for (const std::string& api : change.permissions) {
      apis.Append(api);
    }
    base::ListValue hosts;
    for (const std::string& host : change.origins) {
      hosts.Append(host);
    }
    value.Set("permissions", std::move(apis));
    value.Set("origins", std::move(hosts));
    return value;
  };

  if (op == "getAll") {
    base::DictValue reply = registry.GetAllPermissions(caller.extension_id);
    reply.Set("ok", true);
    std::move(callback).Run(Serialize(reply));
    return;
  }
  bool result = true;
  BlinkerPermissionChange change;
  std::string error;
  const char* event = nullptr;
  if (op == "contains") {
    error = registry.ContainsPermissions(caller.extension_id, permissions,
                                         origins, &result);
  } else if (op == "request") {
    error = registry.RequestPermissions(caller.extension_id, permissions,
                                        origins, &change);
    event = "permissions.onAdded";
  } else if (op == "remove") {
    error = registry.RemovePermissions(caller.extension_id, permissions,
                                       origins, &change);
    event = "permissions.onRemoved";
  } else {
    std::move(callback).Run(ErrorReply(base::StrCat(
        {"chrome.permissions.", op, " is not implemented in this browser"})));
    return;
  }
  if (!error.empty()) {
    std::move(callback).Run(ErrorReply(error));
    return;
  }
  if (event && (!change.permissions.empty() || !change.origins.empty())) {
    ShellContentBrowserClient* client = ShellContentBrowserClient::Get();
    if (!change.origins.empty() && client && client->browser_context()) {
      registry.PublishCorsAccess(client->browser_context());
    }
    base::ListValue args;
    args.Append(change_value(change));
    BlinkerPostExtensionEvent(caller.extension_id, event, std::move(args));
  }
  base::DictValue reply;
  reply.Set("ok", true);
  reply.Set("result", result);
  std::move(callback).Run(Serialize(reply));
}

class ExtensionContextIds : public DocumentUserData<ExtensionContextIds> {
 public:
  ~ExtensionContextIds() override = default;

  const std::string& context_id() const { return context_id_; }
  const std::string& document_id() const { return document_id_; }

 private:
  explicit ExtensionContextIds(RenderFrameHost* frame)
      : DocumentUserData(frame),
        context_id_(base::Uuid::GenerateRandomV4().AsLowercaseString()),
        document_id_(base::UnguessableToken::Create().ToString()) {}

  friend DocumentUserData;
  DOCUMENT_USER_DATA_KEY_DECL();

  const std::string context_id_;
  const std::string document_id_;
};

DOCUMENT_USER_DATA_KEY_IMPL(ExtensionContextIds);

base::DictValue DocumentContext(const char* type,
                                RenderFrameHost* frame,
                                int tab_id,
                                int window_id) {
  const ExtensionContextIds* ids =
      ExtensionContextIds::GetOrCreateForCurrentDocument(frame);
  base::DictValue context;
  context.Set("contextType", type);
  context.Set("contextId", ids->context_id());
  context.Set("tabId", tab_id);
  context.Set("windowId", window_id);
  context.Set("frameId", 0);
  context.Set("documentId", ids->document_id());
  context.Set("documentUrl", frame->GetLastCommittedURL().spec());
  context.Set("documentOrigin", frame->GetLastCommittedOrigin().Serialize());
  context.Set("incognito", false);
  return context;
}

bool ContextMatches(const base::DictValue& filter,
                    const base::DictValue& context) {
  static constexpr std::pair<const char*, const char*> kFields[] = {
      {"contextTypes", "contextType"}, {"contextIds", "contextId"},
      {"tabIds", "tabId"},             {"windowIds", "windowId"},
      {"documentIds", "documentId"},   {"frameIds", "frameId"},
      {"documentUrls", "documentUrl"}, {"documentOrigins", "documentOrigin"},
  };
  for (const auto& [filter_key, context_key] : kFields) {
    const base::ListValue* allowed = filter.FindList(filter_key);
    if (!allowed) {
      continue;
    }
    const base::Value* value = context.Find(context_key);
    if (!value || std::ranges::find(*allowed, *value) == allowed->end()) {
      return false;
    }
  }
  const std::optional<bool> incognito = filter.FindBool("incognito");
  return !incognito || *incognito == context.FindBool("incognito").value_or(false);
}

base::ListValue ExtensionContexts(const BlinkerWebExtension& extension,
                                  const base::DictValue& filter) {
  std::vector<base::DictValue> found;
  if (!extension.background_service_worker.empty()) {
    static base::NoDestructor<std::map<std::string, std::string>> worker_ids;
    std::string& context_id = (*worker_ids)[extension.id];
    if (context_id.empty()) {
      context_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    }
    base::DictValue worker;
    worker.Set("contextType", "BACKGROUND");
    worker.Set("contextId", context_id);
    worker.Set("tabId", -1);
    worker.Set("windowId", -1);
    worker.Set("frameId", -1);
    worker.Set("incognito", false);
    found.push_back(std::move(worker));
  }
  for (Shell* shell : Shell::windows()) {
    WebContents* contents = shell ? shell->web_contents() : nullptr;
    if (!contents) {
      continue;
    }
    const GURL& url = contents->GetLastCommittedURL();
    if (!url.SchemeIs(kBlinkerExtensionScheme) || url.host() != extension.id) {
      continue;
    }
    const bool popup = IsExtensionPopupUrl(extension.id, url);
    found.push_back(DocumentContext(popup ? "POPUP" : "TAB",
                                    contents->GetPrimaryMainFrame(),
                                    popup ? -1 : TabIdFor(contents),
                                    kWindowId));
  }
  const auto offscreen = OffscreenDocuments().find(extension.id);
  if (offscreen != OffscreenDocuments().end() &&
      offscreen->second->web_contents()) {
    found.push_back(DocumentContext(
        "OFFSCREEN_DOCUMENT",
        offscreen->second->web_contents()->GetPrimaryMainFrame(), -1, -1));
  }
  base::ListValue out;
  for (base::DictValue& context : found) {
    if (ContextMatches(filter, context)) {
      out.Append(std::move(context));
    }
  }
  return out;
}

bool IsBridgeFrame(RenderFrameHost* frame, std::string_view extension_id) {
  const GURL& url = frame->GetLastCommittedURL();
  return url.SchemeIs(kBlinkerExtensionScheme) && url.host() == extension_id &&
         url.path() == base::StrCat({"/", kBlinkerBridgePath});
}

void RestartExtensionWorker(const std::string& extension_id) {
  BlinkerWakeExtensionWorker(extension_id);
}

void ReloadExtension(const std::string& extension_id) {
  std::vector<Shell*> pages;
  for (Shell* shell : Shell::windows()) {
    const GURL& url = shell->web_contents()->GetLastCommittedURL();
    if (url.SchemeIs(kBlinkerExtensionScheme) && url.host() == extension_id) {
      pages.push_back(shell);
    }
  }
  for (Shell* shell : pages) {
    // Закрита вкладка на екрані лишила б мертве вікно, тож спершу показуємо ту,
    // над якою стояв попап
    BlinkShellWillCloseReactivate(
        shell, BlinkerExtensionPageOpener(shell->web_contents()));
    shell->Close();
  }
  BrowserContext* context = AnyBrowserContext();
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  ServiceWorkerContext* sw =
      partition ? partition->GetServiceWorkerContext() : nullptr;
  if (!sw) {
    return;
  }
  const GURL scope(
      base::StrCat({kBlinkerExtensionScheme, "://", extension_id, "/"}));
  sw->StopAllServiceWorkersForStorageKey(
      blink::StorageKey::CreateFirstParty(url::Origin::Create(scope)));
  GetUIThreadTaskRunner({})->PostDelayedTask(
      FROM_HERE, base::BindOnce(&RestartExtensionWorker, extension_id),
      base::Milliseconds(500));
}

void HandleBookmarks(const BlinkerApiCaller& caller,
                     const base::DictValue& request,
                     base::OnceCallback<void(std::string)> callback) {
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  if (!registry.HasPermission(caller.extension_id, "bookmarks")) {
    std::move(callback).Run(
        ErrorReply("The 'bookmarks' permission is required."));
    return;
  }
  std::optional<base::Value> reply =
      base::JSONReader::Read(BlinkBookmarksOp(Serialize(request)),
                             base::JSON_PARSE_RFC);
  if (!reply || !reply->is_dict()) {
    std::move(callback).Run(ErrorReply("Bookmarks store unavailable"));
    return;
  }
  base::DictValue& dict = reply->GetDict();
  if (std::optional<base::Value> events = dict.Extract("events");
      events && events->is_list()) {
    for (base::Value& event : events->GetList()) {
      const std::string* name = event.GetDict().FindString("name");
      base::ListValue* args = event.GetDict().FindList("args");
      if (!name || !args) {
        continue;
      }
      for (const std::unique_ptr<BlinkerWebExtension>& extension :
           registry.extensions()) {
        if (extension->enabled &&
            registry.HasPermission(extension->id, "bookmarks")) {
          EventHub::Get().Post(extension->id, *name, args->Clone());
        }
      }
    }
  }
  std::move(callback).Run(Serialize(dict));
}

void HandleRuntime(const BlinkerApiCaller& caller,
                   const base::DictValue& request,
                   const std::string& op,
                   base::OnceCallback<void(std::string)> callback) {
  if (op == "bridgeSender") {
    RenderFrameHost* bridge = RenderFrameHost::FromID(caller.frame_id);
    RenderFrameHost* parent = bridge ? bridge->GetParent() : nullptr;
    Shell* shell = parent ? Shell::FromWebContents(
                                WebContents::FromRenderFrameHost(parent))
                          : nullptr;
    base::DictValue reply;
    reply.Set("ok", true);
    if (caller.from_extension_origin && shell &&
        IsBridgeFrame(bridge, caller.extension_id) &&
        !parent->GetLastCommittedURL().SchemeIs(kBlinkerExtensionScheme)) {
      reply.Set("tab", TabToValue(shell));
    }
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "getContexts") {
    const BlinkerWebExtension* extension =
        BlinkerWebExtensionRegistry::GetInstance().FindExtension(
            caller.extension_id);
    const base::DictValue* filter = request.FindDict("filter");
    const base::DictValue empty;
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("contexts", extension ? ExtensionContexts(*extension,
                                                        filter ? *filter
                                                               : empty)
                                    : base::ListValue());
    std::move(callback).Run(Serialize(reply));
    return;
  }
  if (op == "reload") {
    std::move(callback).Run("{\"ok\":true}");
    // Закривати з колбека запиту не можна, тому окремою задачею
    GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&ReloadExtension, caller.extension_id));
    return;
  }
  if (op == "consumeLifecycle") {
    const BlinkerWebExtensionRegistry::Lifecycle lifecycle =
        BlinkerWebExtensionRegistry::GetInstance().ConsumeLifecycle(
            caller.extension_id);
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("startup", lifecycle.startup);
    if (!lifecycle.install_reason.empty()) {
      base::DictValue details;
      details.Set("reason", lifecycle.install_reason);
      if (!lifecycle.previous_version.empty()) {
        details.Set("previousVersion", lifecycle.previous_version);
      }
      reply.Set("installed", std::move(details));
    }
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.runtime.", op, " is not implemented"})));
}

}  // namespace

int BlinkerTabIdForWebContents(WebContents* contents) {
  return TabIdFor(contents);
}

int BlinkerApiFrameId(RenderFrameHost* frame) {
  if (!frame) {
    return -1;
  }
  return frame->IsInPrimaryMainFrame() ? 0
                                       : frame->GetFrameTreeNodeId().value();
}

std::string BlinkerApiDocumentId(RenderFrameHost* frame) {
  return frame ? ExtensionContextIds::GetOrCreateForCurrentDocument(frame)
                     ->document_id()
               : std::string();
}

void BlinkerNoteExtensionPageOpened(const GURL& page, WebContents* over) {
  if (page.SchemeIs(kBlinkerExtensionScheme) &&
      IsExtensionPopupUrl(std::string(page.host()), page)) {
    ActiveTabGrants::Get().Grant(std::string(page.host()), over);
  }
}

void BlinkerSetExtensionPageOpener(WebContents* page, WebContents* opener) {
  if (!page || !opener || page == opener) {
    return;
  }
  page->SetUserData(ExtensionPageOpener::Key(),
                    std::make_unique<ExtensionPageOpener>(opener->GetWeakPtr()));
}

WebContents* BlinkerExtensionPageOpener(WebContents* page) {
  if (!page) {
    return nullptr;
  }
  auto* data = static_cast<ExtensionPageOpener*>(
      page->GetUserData(ExtensionPageOpener::Key()));
  return data ? data->opener() : nullptr;
}

void BlinkerNoteTabNavigated(WebContents* contents,
                             NavigationHandle* navigation) {
  if (!navigation->IsInPrimaryMainFrame() || !navigation->HasCommitted() ||
      navigation->IsSameDocument()) {
    return;
  }
  TabFavicons().erase(contents);
  if (!navigation->IsSameOrigin()) {
    ActiveTabGrants::Get().Revoke(contents);
  }
}

void BlinkerNoteTabFavicon(WebContents* contents, const GURL& icon) {
  if (!contents || !icon.is_valid()) {
    return;
  }
  GURL& known = TabFavicons()[contents];
  if (known == icon) {
    return;
  }
  known = icon;
  BlinkerNotifyExtensionTabEvent(contents, "tabs.onUpdated");
}

void BlinkerRestoreExtensionApiState() {
  static base::NoDestructor<std::set<std::string>> restored;
  for (const std::unique_ptr<BlinkerWebExtension>& extension :
       BlinkerWebExtensionRegistry::GetInstance().extensions()) {
    if (!extension->enabled) {
      continue;
    }
    if (!restored->insert(extension->id).second) {
      continue;
    }
    if (const base::ListValue* alarms =
            extension->api_state.FindList("alarms")) {
      AlarmStore::Get().Restore(extension->id, *alarms);
    }
    if (const base::ListValue* menus =
            extension->api_state.FindList("contextMenus")) {
      ContextMenuStore::Get().Restore(extension->id, *menus);
    }
  }
}

namespace {

class WebNavigationFrameState
    : public DocumentUserData<WebNavigationFrameState> {
 public:
  ~WebNavigationFrameState() override = default;

  static bool IsValidUrl(const GURL& url) {
    return url.SchemeIsHTTPOrHTTPS() || url.SchemeIs(kChromeUIScheme) ||
           url.SchemeIsFile() ||
           url.SchemeIs(url::kFtpScheme) ||
           url.SchemeIs(url::kJavaScriptScheme) ||
           url.SchemeIs(url::kDataScheme) || url.SchemeIsFileSystem() ||
           url.IsAboutBlank() || url.IsAboutSrcdoc();
  }

  bool CanSendEvents() const { return !error_occurred_ && IsValidUrl(url_); }

  void StartTrackingDocumentLoad(const GURL& url,
                                 bool is_same_document,
                                 bool is_from_back_forward_cache,
                                 bool is_error_page) {
    error_occurred_ = is_error_page;
    url_ = url;
    if (!is_same_document && !is_from_back_forward_cache) {
      is_loading_ = true;
      is_parsing_ = true;
    }
  }

  const GURL& url() const { return url_; }
  bool error_occurred() const { return error_occurred_; }
  void set_error_occurred() { error_occurred_ = true; }
  bool load_completed() const { return !is_loading_; }
  void set_load_completed() { is_loading_ = false; }
  bool parsing_finished() const { return !is_parsing_; }
  void set_parsing_finished() { is_parsing_ = false; }

 private:
  explicit WebNavigationFrameState(RenderFrameHost* frame)
      : DocumentUserData(frame) {}

  friend DocumentUserData;
  DOCUMENT_USER_DATA_KEY_DECL();

  GURL url_;
  bool error_occurred_ = false;
  bool is_loading_ = false;
  bool is_parsing_ = false;
};

DOCUMENT_USER_DATA_KEY_IMPL(WebNavigationFrameState);

const char* ApiFrameType(RenderFrameHost* frame) {
  if (!frame->GetParentOrOuterDocument()) {
    return "outermost_frame";
  }
  return frame->IsFencedFrameRoot() ? "fenced_frame" : "sub_frame";
}

const char* ApiFrameType(NavigationHandle* navigation) {
  switch (navigation->GetNavigatingFrameType()) {
    case FrameType::kSubframe:
      return "sub_frame";
    case FrameType::kFencedFrameRoot:
      return "fenced_frame";
    case FrameType::kPrimaryMainFrame:
    case FrameType::kPrerenderMainFrame:
    case FrameType::kGuestMainFrame:
      return "outermost_frame";
  }
  return "outermost_frame";
}

const char* ApiDocumentLifecycle(RenderFrameHost* frame) {
  using State = RenderFrameHost::LifecycleState;
  if (frame->IsInLifecycleState(State::kActive)) {
    return "active";
  }
  if (frame->IsInLifecycleState(State::kInBackForwardCache)) {
    return "cached";
  }
  if (frame->IsInLifecycleState(State::kPrerendering)) {
    return "prerender";
  }
  if (frame->IsInLifecycleState(State::kPendingDeletion)) {
    return "pending_deletion";
  }
  return nullptr;
}

const char* ApiDocumentLifecycle(NavigationHandle* navigation) {
  if (RenderFrameHost* parent = navigation->GetParentFrameOrOuterDocument()) {
    return ApiDocumentLifecycle(parent);
  }
  if (navigation->IsInPrerenderedMainFrame()) {
    return "prerender";
  }
  return navigation->IsInPrimaryMainFrame() ? "active" : nullptr;
}

double NowForEvents() {
  return base::Time::Now().InMillisecondsFSinceUnixEpoch();
}

// Chrome теж притримує onCreatedNavigationTarget і onBeforeNavigate
// поки вкладка не стане в рядок
struct HeldTabEvents {
  bool opened_by_page = false;
  std::optional<base::DictValue> created_target;
  std::optional<base::DictValue> before_navigate;
};

std::map<WebContents*, HeldTabEvents>& HeldTabs() {
  static base::NoDestructor<std::map<WebContents*, HeldTabEvents>> tabs;
  return *tabs;
}

bool ObservesNavigation(WebContents* contents) {
  if (!contents || !BlinkerWebExtensionRegistry::GetInstance().loaded()) {
    return false;
  }
  if (Shell::FromWebContents(contents)) {
    return true;
  }
  const auto it = HeldTabs().find(contents);
  return it != HeldTabs().end() && it->second.opened_by_page;
}

void BroadcastNavigationEvent(std::string_view event,
                              const base::DictValue& details) {
  EventHub::Get().BroadcastEach(
      event,
      [&details](const std::string& extension_id)
          -> std::optional<base::ListValue> {
        if (!BlinkerWebExtensionRegistry::GetInstance().HasPermission(
                extension_id, "webNavigation")) {
          return std::nullopt;
        }
        base::ListValue args;
        args.Append(details.Clone());
        return args;
      });
}

base::DictValue DocumentEventDetails(RenderFrameHost* frame, const GURL& url) {
  base::DictValue details;
  details.Set("tabId", TabIdFor(WebContents::FromRenderFrameHost(frame)));
  details.Set("url", url.spec());
  details.Set("processId", frame->GetProcess()->GetDeprecatedID());
  details.Set("frameId", BlinkerApiFrameId(frame));
  RenderFrameHost* parent = frame->GetParentOrOuterDocument();
  details.Set("parentFrameId", BlinkerApiFrameId(parent));
  details.Set("documentId", BlinkerApiDocumentId(frame));
  if (parent) {
    details.Set("parentDocumentId", BlinkerApiDocumentId(parent));
  }
  details.Set("frameType", ApiFrameType(frame));
  if (const char* lifecycle = ApiDocumentLifecycle(frame)) {
    details.Set("documentLifecycle", lifecycle);
  }
  details.Set("timeStamp", NowForEvents());
  return details;
}

base::DictValue NavigationEventDetails(NavigationHandle* navigation) {
  base::DictValue details;
  details.Set("tabId", TabIdFor(navigation->GetWebContents()));
  details.Set("url", navigation->GetURL().spec());
  details.Set("processId", -1);
  details.Set("frameId", navigation->IsInPrimaryMainFrame()
                             ? 0
                             : navigation->GetFrameTreeNodeId().value());
  RenderFrameHost* parent = navigation->GetParentFrameOrOuterDocument();
  details.Set("parentFrameId", BlinkerApiFrameId(parent));
  if (parent) {
    details.Set("parentDocumentId", BlinkerApiDocumentId(parent));
  }
  details.Set("frameType", ApiFrameType(navigation));
  if (const char* lifecycle = ApiDocumentLifecycle(navigation)) {
    details.Set("documentLifecycle", lifecycle);
  }
  details.Set("timeStamp", NowForEvents());
  return details;
}

void DispatchFrameError(RenderFrameHost* frame,
                        const GURL& url,
                        int error_code) {
  base::DictValue details = DocumentEventDetails(frame, url);
  details.Set("error", net::ErrorToString(error_code));
  BroadcastNavigationEvent("webNavigation.onErrorOccurred", details);
}

void NoteFrameGone(RenderFrameHost* frame) {
  WebNavigationFrameState* state =
      WebNavigationFrameState::GetForCurrentDocument(frame);
  if (state && state->CanSendEvents() && !state->load_completed()) {
    DispatchFrameError(frame, state->url(), net::ERR_ABORTED);
    state->set_error_occurred();
  }
}

RenderFrameHost* FrameByDocumentId(std::string_view document_id) {
  RenderFrameHost* found = nullptr;
  for (Shell* shell : Shell::windows()) {
    if (found || !shell || !shell->web_contents()) {
      continue;
    }
    shell->web_contents()->ForEachRenderFrameHostWithAction(
        [&](RenderFrameHost* frame) {
          ExtensionContextIds* ids =
              ExtensionContextIds::GetForCurrentDocument(frame);
          if (ids && ids->document_id() == document_id) {
            found = frame;
            return RenderFrameHost::FrameIterationAction::kStop;
          }
          return RenderFrameHost::FrameIterationAction::kContinue;
        });
  }
  return found;
}

RenderFrameHost* FrameById(WebContents* contents, int frame_id) {
  if (frame_id < 0) {
    return nullptr;
  }
  if (frame_id == 0) {
    return contents->GetPrimaryMainFrame();
  }
  RenderFrameHost* frame =
      contents->UnsafeFindFrameByFrameTreeNodeId(FrameTreeNodeId(frame_id));
  if (!frame || (!frame->IsActive() &&
                 !frame->IsInLifecycleState(
                     RenderFrameHost::LifecycleState::kPrerendering))) {
    return nullptr;
  }
  return frame;
}

base::DictValue FrameDetails(RenderFrameHost* frame,
                             const WebNavigationFrameState& state) {
  base::DictValue details;
  details.Set("url", state.url().spec());
  details.Set("errorOccurred", state.error_occurred());
  details.Set("parentFrameId",
              BlinkerApiFrameId(frame->GetParentOrOuterDocument()));
  details.Set("documentId", BlinkerApiDocumentId(frame));
  if (RenderFrameHost* parent = frame->GetParentOrOuterDocument()) {
    details.Set("parentDocumentId", BlinkerApiDocumentId(parent));
  }
  details.Set("frameType", ApiFrameType(frame));
  if (const char* lifecycle = ApiDocumentLifecycle(frame)) {
    details.Set("documentLifecycle", lifecycle);
  }
  return details;
}

void HandleWebNavigation(const BlinkerApiCaller& caller,
                         const base::DictValue& request,
                         const std::string& op,
                         base::OnceCallback<void(std::string)> callback) {
  if (!BlinkerWebExtensionRegistry::GetInstance().HasPermission(
          caller.extension_id, "webNavigation")) {
    std::move(callback).Run(ErrorReply(
        "'webNavigation' permission is required to use chrome.webNavigation"));
    return;
  }
  const base::DictValue* query = request.FindDict("details");
  const std::optional<int> tab_id =
      query ? OptionalInt(*query, "tabId") : std::nullopt;
  base::DictValue reply;
  reply.Set("ok", true);

  if (op == "getFrame") {
    const std::optional<int> frame_id =
        query ? OptionalInt(*query, "frameId") : std::nullopt;
    const std::string* document_id =
        query ? query->FindString("documentId") : nullptr;
    RenderFrameHost* frame = nullptr;
    if (document_id) {
      const std::string wanted = base::ToUpperASCII(*document_id);
      if (!base::UnguessableToken::DeserializeFromString(wanted)) {
        std::move(callback).Run(ErrorReply("Invalid documentId."));
        return;
      }
      frame = FrameByDocumentId(wanted);
      if (frame &&
          ((tab_id &&
            *tab_id != TabIdFor(WebContents::FromRenderFrameHost(frame))) ||
           (frame_id && *frame_id != BlinkerApiFrameId(frame)))) {
        frame = nullptr;
      }
    } else if (!tab_id || !frame_id) {
      std::move(callback).Run(ErrorReply(
          "Either documentId or both tabId and frameId must be specified."));
      return;
    } else if (Shell* shell = ShellForTabId(*tab_id)) {
      frame = FrameById(shell->web_contents(), *frame_id);
    }
    const WebNavigationFrameState* state =
        frame ? WebNavigationFrameState::GetForCurrentDocument(frame)
              : nullptr;
    if (state && WebNavigationFrameState::IsValidUrl(state->url())) {
      reply.Set("frame", FrameDetails(frame, *state));
    }
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (op == "getAllFrames") {
    Shell* shell = tab_id ? ShellForTabId(*tab_id) : nullptr;
    if (!shell) {
      std::move(callback).Run(Serialize(reply));
      return;
    }
    WebContents* contents = shell->web_contents();
    base::ListValue frames;
    contents->ForEachRenderFrameHostWithAction([&](RenderFrameHost* frame) {
      if (WebContents::FromRenderFrameHost(frame) != contents) {
        return RenderFrameHost::FrameIterationAction::kSkipChildren;
      }
      const WebNavigationFrameState* state =
          WebNavigationFrameState::GetForCurrentDocument(frame);
      if (!state || !WebNavigationFrameState::IsValidUrl(state->url())) {
        return RenderFrameHost::FrameIterationAction::kContinue;
      }
      if (frame->IsInLifecycleState(
              RenderFrameHost::LifecycleState::kInBackForwardCache)) {
        return RenderFrameHost::FrameIterationAction::kSkipChildren;
      }
      base::DictValue details = FrameDetails(frame, *state);
      details.Set("frameId", BlinkerApiFrameId(frame));
      details.Set("processId", frame->GetProcess()->GetDeprecatedID());
      frames.Append(std::move(details));
      return RenderFrameHost::FrameIterationAction::kContinue;
    });
    reply.Set("frames", std::move(frames));
    std::move(callback).Run(Serialize(reply));
    return;
  }
  std::move(callback).Run(ErrorReply(
      base::StrCat({"chrome.webNavigation.", op, " is not implemented"})));
}

}  // namespace

void BlinkerWebNavigationStarted(NavigationHandle* navigation) {
  WebContents* contents = navigation->GetWebContents();
  if (!ObservesNavigation(contents) || navigation->IsSameDocument() ||
      !WebNavigationFrameState::IsValidUrl(navigation->GetURL())) {
    return;
  }
  base::DictValue details = NavigationEventDetails(navigation);
  if (const auto it = HeldTabs().find(contents); it != HeldTabs().end()) {
    it->second.before_navigate = std::move(details);
    return;
  }
  BroadcastNavigationEvent("webNavigation.onBeforeNavigate", details);
}

void BlinkerWebNavigationFinished(NavigationHandle* navigation) {
  WebContents* contents = navigation->GetWebContents();
  if (!ObservesNavigation(contents)) {
    return;
  }
  if (const auto it = HeldTabs().find(contents);
      it != HeldTabs().end() && it->second.before_navigate) {
    BroadcastNavigationEvent("webNavigation.onBeforeNavigate",
                             *it->second.before_navigate);
    it->second.before_navigate.reset();
  }
  const GURL& url = navigation->GetURL();
  if (!navigation->HasCommitted() || navigation->IsErrorPage()) {
    if (navigation->HasCommitted()) {
      WebNavigationFrameState::GetOrCreateForCurrentDocument(
          navigation->GetRenderFrameHost())
          ->StartTrackingDocumentLoad(url, navigation->IsSameDocument(),
                                      /*is_from_back_forward_cache=*/false,
                                      /*is_error_page=*/true);
    }
    base::DictValue details = NavigationEventDetails(navigation);
    const int error = navigation->GetNetErrorCode();
    details.Set("error", net::ErrorToString(error != net::OK ? error
                                                             : net::ERR_ABORTED));
    details.Set("documentId",
                navigation->HasCommitted()
                    ? BlinkerApiDocumentId(navigation->GetRenderFrameHost())
                    : base::UnguessableToken().ToString());
    BroadcastNavigationEvent("webNavigation.onErrorOccurred", details);
    return;
  }
  // Фрагмент визначаємо до того як стан запам'ятає нову адресу
  RenderFrameHost* frame = navigation->GetRenderFrameHost();
  WebNavigationFrameState* state =
      WebNavigationFrameState::GetOrCreateForCurrentDocument(frame);
  const bool fragment = navigation->IsSameDocument() && state->url() != url &&
                        state->url().EqualsIgnoringRef(url);
  state->StartTrackingDocumentLoad(url, navigation->IsSameDocument(),
                                   navigation->IsServedFromBackForwardCache(),
                                   /*is_error_page=*/false);
  const char* event = fragment ? "webNavigation.onReferenceFragmentUpdated"
                      : navigation->IsSameDocument()
                          ? "webNavigation.onHistoryStateUpdated"
                          : "webNavigation.onCommitted";
  base::DictValue details = DocumentEventDetails(frame, url);
  ui::PageTransition transition = navigation->GetPageTransition();
  if (navigation->WasServerRedirect()) {
    transition = ui::PageTransitionFromInt(transition |
                                           ui::PAGE_TRANSITION_SERVER_REDIRECT);
  }
  // Chrome для сумісності лишає start_page замість auto_toplevel
  details.Set("transitionType",
              ui::PageTransitionCoreTypeIs(transition,
                                           ui::PAGE_TRANSITION_AUTO_TOPLEVEL)
                  ? "start_page"
                  : ui::PageTransitionGetCoreTransitionString(transition));
  base::ListValue qualifiers;
  if (transition & ui::PAGE_TRANSITION_CLIENT_REDIRECT) {
    qualifiers.Append("client_redirect");
  }
  if (transition & ui::PAGE_TRANSITION_SERVER_REDIRECT) {
    qualifiers.Append("server_redirect");
  }
  if (transition & ui::PAGE_TRANSITION_FORWARD_BACK) {
    qualifiers.Append("forward_back");
  }
  if (transition & ui::PAGE_TRANSITION_FROM_ADDRESS_BAR) {
    qualifiers.Append("from_address_bar");
  }
  details.Set("transitionQualifiers", std::move(qualifiers));
  BroadcastNavigationEvent(event, details);
  if (navigation->IsServedFromBackForwardCache()) {
    BroadcastNavigationEvent("webNavigation.onCompleted",
                             DocumentEventDetails(frame, url));
  }
}

void BlinkerWebNavigationParsed(RenderFrameHost* frame) {
  WebNavigationFrameState* state =
      WebNavigationFrameState::GetForCurrentDocument(frame);
  if (!state || !state->CanSendEvents() ||
      !ObservesNavigation(WebContents::FromRenderFrameHost(frame))) {
    return;
  }
  state->set_parsing_finished();
  BroadcastNavigationEvent("webNavigation.onDOMContentLoaded",
                           DocumentEventDetails(frame, state->url()));
  // Load міг скінчитись раніше за розбір, а onCompleted завжди йде
  // після onDOMContentLoaded
  if (state->load_completed()) {
    BroadcastNavigationEvent("webNavigation.onCompleted",
                             DocumentEventDetails(frame, state->url()));
  }
}

void BlinkerWebNavigationLoaded(RenderFrameHost* frame, const GURL& url) {
  WebNavigationFrameState* state =
      WebNavigationFrameState::GetForCurrentDocument(frame);
  if (!state || !ObservesNavigation(WebContents::FromRenderFrameHost(frame))) {
    return;
  }
  state->set_load_completed();
  if (!state->CanSendEvents() || state->url() != url ||
      !state->parsing_finished()) {
    return;
  }
  BroadcastNavigationEvent("webNavigation.onCompleted",
                           DocumentEventDetails(frame, state->url()));
}

void BlinkerWebNavigationFailed(RenderFrameHost* frame, int error_code) {
  WebNavigationFrameState* state =
      WebNavigationFrameState::GetForCurrentDocument(frame);
  if (!state || !ObservesNavigation(WebContents::FromRenderFrameHost(frame))) {
    return;
  }
  if (state->CanSendEvents()) {
    DispatchFrameError(frame, state->url(), error_code);
  }
  state->set_error_occurred();
}

void BlinkerWebNavigationFrameDeleted(RenderFrameHost* frame) {
  if (ObservesNavigation(WebContents::FromRenderFrameHost(frame))) {
    NoteFrameGone(frame);
  }
}

void BlinkerWebNavigationFramesReplaced(RenderFrameHost* old_frame) {
  if (!ObservesNavigation(WebContents::FromRenderFrameHost(old_frame))) {
    return;
  }
  old_frame->ForEachRenderFrameHost([](RenderFrameHost* frame) {
    if (WebNavigationFrameState::GetForCurrentDocument(frame)) {
      NoteFrameGone(frame);
      WebNavigationFrameState::DeleteForCurrentDocument(frame);
    }
  });
}

void BlinkerWebNavigationTargetCreated(RenderFrameHost* source,
                                       WebContents* target,
                                       const GURL& url) {
  WebNavigationFrameState* state =
      source ? WebNavigationFrameState::GetForCurrentDocument(source)
             : nullptr;
  if (!target || !state || !state->CanSendEvents() ||
      !ObservesNavigation(WebContents::FromRenderFrameHost(source))) {
    return;
  }
  base::DictValue details;
  details.Set("sourceTabId",
              TabIdFor(WebContents::FromRenderFrameHost(source)));
  details.Set("sourceProcessId", source->GetProcess()->GetDeprecatedID());
  details.Set("sourceFrameId", BlinkerApiFrameId(source));
  details.Set("url", url.possibly_invalid_spec());
  details.Set("tabId", TabIdFor(target));
  details.Set("timeStamp", NowForEvents());
  if (const auto it = HeldTabs().find(target); it != HeldTabs().end()) {
    it->second.opened_by_page = true;
    it->second.created_target = std::move(details);
    return;
  }
  BroadcastNavigationEvent("webNavigation.onCreatedNavigationTarget",
                           details);
}

namespace {

struct ReportedTabState {
  std::string status;
  std::string url;
  std::string title;
  std::string favicon;
  bool audible = false;
  bool muted = false;
  bool discarded = false;
};

std::map<WebContents*, ReportedTabState>& ReportedTabs() {
  static base::NoDestructor<std::map<WebContents*, ReportedTabState>> tabs;
  return *tabs;
}

void AnnounceTab(base::WeakPtr<WebContents> contents) {
  Shell* shell = contents ? Shell::FromWebContents(contents.get()) : nullptr;
  const auto held = shell ? HeldTabs().find(contents.get()) : HeldTabs().end();
  if (held == HeldTabs().end()) {
    return;
  }
  HeldTabEvents events = std::move(held->second);
  HeldTabs().erase(held);
  EventHub::Get().BroadcastEach(
      "tabs.onCreated", [shell](const std::string& extension_id) {
        base::ListValue args;
        args.Append(ScrubbedTab(shell, extension_id));
        return std::optional<base::ListValue>(std::move(args));
      });
  if (events.created_target) {
    BroadcastNavigationEvent("webNavigation.onCreatedNavigationTarget",
                             *events.created_target);
  }
  if (events.before_navigate) {
    BroadcastNavigationEvent("webNavigation.onBeforeNavigate",
                             *events.before_navigate);
  }
}

}  // namespace

void BlinkerNoteTabShellCreated(WebContents* contents) {
  if (HeldTabs().contains(contents)) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&AnnounceTab, contents->GetWeakPtr()));
  }
}

void BlinkerNotifyZoomChanged(WebContents* contents,
                              int old_percent,
                              int new_percent) {
  if (!contents || old_percent == new_percent ||
      !BlinkerWebExtensionRegistry::GetInstance().loaded()) {
    return;
  }
  base::DictValue info;
  info.Set("tabId", TabIdFor(contents));
  info.Set("oldZoomFactor", old_percent / 100.0);
  info.Set("newZoomFactor", new_percent / 100.0);
  info.Set("zoomSettings", ZoomSettings());
  base::ListValue args;
  args.Append(std::move(info));
  EventHub::Get().Broadcast("tabs.onZoomChange", std::move(args));
}

void BlinkerNotifyExtensionTabEvent(WebContents* contents,
                                    std::string_view event) {
  if (!contents || !BlinkerWebExtensionRegistry::GetInstance().loaded()) {
    return;
  }
  const int tab_id = TabIdFor(contents);
  base::ListValue args;
  if (event == "tabs.onCreated") {
    HeldTabs()[contents];
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&AnnounceTab, contents->GetWeakPtr()));
    return;
  }
  if (event == "tabs.onRemoved") {
    args.Append(tab_id);
    base::DictValue info;
    info.Set("windowId", kWindowId);
    info.Set("isWindowClosing", false);
    args.Append(std::move(info));
    TabIds().erase(contents);
    ReportedTabs().erase(contents);
    TabFavicons().erase(contents);
    ActiveTabGrants::Get().Revoke(contents);
    // Без onCreated не буде і onRemoved, так зникають вікна що вкладками
    // не були
    if (HeldTabs().erase(contents)) {
      return;
    }
    EventHub::Get().Broadcast(std::string(event), std::move(args));
    return;
  }
  Shell* shell = Shell::FromWebContents(contents);
  if (!shell) {
    return;
  }
  if (event == "tabs.onActivated") {
    base::DictValue info;
    info.Set("tabId", tab_id);
    info.Set("windowId", kWindowId);
    args.Append(std::move(info));
  } else if (event == "tabs.onUpdated") {
    ReportedTabState now;
    now.status = LoadingStatus(contents);
    now.url = contents->GetLastCommittedURL().spec();
    now.title = base::UTF16ToUTF8(contents->GetTitle());
    if (const auto it = TabFavicons().find(contents);
        it != TabFavicons().end()) {
      now.favicon = it->second.spec();
    }
    now.audible = contents->IsCurrentlyAudible();
    now.muted = contents->IsAudioMuted();
    now.discarded = contents->WasDiscarded();
    ReportedTabState& last = ReportedTabs()[contents];
    std::vector<const char*> changed;
    if (now.status != last.status) {
      changed.push_back("status");
    }
    if (now.url != last.url) {
      changed.push_back("url");
    }
    if (now.title != last.title) {
      changed.push_back("title");
    }
    if (now.favicon != last.favicon) {
      changed.push_back("favIconUrl");
    }
    if (now.audible != last.audible) {
      changed.push_back("audible");
    }
    if (now.muted != last.muted) {
      changed.push_back("mutedInfo");
    }
    if (now.discarded != last.discarded) {
      changed.push_back("discarded");
    }
    last = std::move(now);
    if (changed.empty()) {
      return;
    }
    EventHub::Get().BroadcastEach(
        "tabs.onUpdated",
        [shell, tab_id, &changed](const std::string& extension_id) {
          base::DictValue tab = ScrubbedTab(shell, extension_id);
          base::DictValue change;
          for (const char* name : changed) {
            if (const base::Value* value = tab.Find(name)) {
              change.Set(name, value->Clone());
            }
          }
          base::ListValue event_args;
          event_args.Append(tab_id);
          event_args.Append(std::move(change));
          event_args.Append(std::move(tab));
          return std::optional<base::ListValue>(std::move(event_args));
        });
    return;
  } else {
    args.Append(tab_id);
  }
  EventHub::Get().Broadcast(std::string(event), std::move(args));
}

void BlinkerHandleExtensionApiCall(
    const BlinkerApiCaller& caller,
    std::string_view request_json,
    base::OnceCallback<void(std::string)> callback) {
  std::optional<base::DictValue> request =
      base::JSONReader::ReadDict(request_json, base::JSON_PARSE_RFC);
  if (!request) {
    std::move(callback).Run(ErrorReply("malformed request"));
    return;
  }
  const std::string* ns = request->FindString("ns");
  const std::string* op = request->FindString("op");
  if (!ns || !op) {
    std::move(callback).Run(ErrorReply("missing ns or op"));
    return;
  }

  if (*ns == "storage") {
    BlinkerExtensionStorage::GetInstance().HandleRequest(
        caller.extension_id, caller.unlimited_storage, request_json,
        std::move(callback));
    return;
  }

  if (!caller.from_extension_origin) {
    // Це або помилка, або сторінка дістала токен, в обох випадках відмова
    std::move(callback).Run(
        ErrorReply(base::StrCat({"chrome.", *ns,
                                 " is not available in a content script"})));
    return;
  }

  if (*ns == "scripting") {
    HandleScripting(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "userScripts") {
    HandleUserScripts(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "offscreen") {
    HandleOffscreen(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "alarms") {
    HandleAlarms(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "cookies") {
    HandleCookies(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "contextMenus") {
    HandleContextMenus(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "notifications") {
    HandleNotifications(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "downloads") {
    HandleDownloads(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "action") {
    HandleAction(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "webRequest") {
    HandleWebRequest(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "management" && *op == "uninstallSelf") {
    std::move(callback).Run("{\"ok\":true}");
    // Розширення не видаляє себе мовчки, файли і дані зникнуть назавжди
    GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE,
        base::BindOnce(&BlinkConfirmExtensionUninstall, caller.extension_id));
    return;
  }
  if (*ns == "bookmarks") {
    HandleBookmarks(caller, *request, std::move(callback));
    return;
  }
  if (*ns == "idle") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("state", BlinkerBrowserIsBackgrounded() ? "idle" : "active");
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (*ns == "tabs") {
    HandleTabs(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "windows") {
    HandleWindows(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "search") {
    HandleSearch(*request, *op, std::move(callback));
    return;
  }

  if (*ns == "identity") {
    HandleIdentity(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "declarativeNetRequest") {
    HandleDeclarativeNetRequest(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "permissions") {
    HandlePermissions(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "runtime") {
    HandleRuntime(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "webNavigation") {
    HandleWebNavigation(caller, *request, *op, std::move(callback));
    return;
  }

  if (*ns == "events") {
    for (const std::unique_ptr<BlinkerWebExtension>& extension :
         BlinkerWebExtensionRegistry::GetInstance().extensions()) {
      if (extension->id != caller.extension_id) {
        continue;
      }
      for (const std::vector<std::string>* list :
           {&extension->permissions, &extension->granted_optional}) {
        if (std::find(list->begin(), list->end(), "cookies") != list->end()) {
          EnsureCookieChangeForwarder();
        }
      }
      break;
    }
    if (*op == "seq") {
      base::DictValue reply;
      reply.Set("ok", true);
      // 10 секунд досить щоб воркер піднявся і підписався, і замало для
      // старих подій
      reply.Set("seq",
                static_cast<double>(EventHub::Get().ReplaySeqFor(
                    caller.extension_id, base::Seconds(10))));
      std::move(callback).Run(Serialize(reply));
      return;
    }
    if (*op == "watch") {
      EventHub::Get().Watch(
          caller.extension_id,
          static_cast<uint64_t>(request->FindDouble("since").value_or(0)),
          std::move(callback));
      return;
    }
  }

  std::move(callback).Run(
      ErrorReply(base::StrCat({"chrome.", *ns, " is not implemented"})));
}

BlinkerContextMenuTarget::BlinkerContextMenuTarget() = default;
BlinkerContextMenuTarget::BlinkerContextMenuTarget(
    const BlinkerContextMenuTarget&) = default;
BlinkerContextMenuTarget::~BlinkerContextMenuTarget() = default;

BlinkerContextMenuEntry::BlinkerContextMenuEntry() = default;
BlinkerContextMenuEntry::BlinkerContextMenuEntry(
    const BlinkerContextMenuEntry&) = default;
BlinkerContextMenuEntry::~BlinkerContextMenuEntry() = default;

std::vector<BlinkerContextMenuEntry> BlinkerContextMenuItemsFor(
    const BlinkerContextMenuTarget& target) {
  return ContextMenuStore::Get().Matching(target);
}

void BlinkerActivateContextMenuItem(const std::string& key,
                                    const BlinkerContextMenuTarget& target,
                                    WebContents* contents) {
  ContextMenuStore& store = ContextMenuStore::Get();
  const ContextMenuItem* item = store.FindByKey(key);
  if (!item) {
    return;
  }
  const std::string extension_id = item->extension_id;
  ActiveTabGrants::Get().Grant(extension_id, contents);
  const std::string item_id = item->id;
  const std::string parent_id = item->parent_id;
  const bool checkable = item->type == "checkbox" || item->type == "radio";
  const bool was_checked = store.Toggle(*item);
  // Після Toggle `item` може висіти, все потрібне скопійовано вище
  if (checkable) {
    PersistApiStateSoon(extension_id);
  }

  base::DictValue info;
  info.Set("menuItemId", item_id);
  if (!parent_id.empty()) {
    info.Set("parentMenuItemId", parent_id);
  }
  info.Set("mediaType", target.media_type);
  info.Set("editable", target.editable);
  if (target.page_url.is_valid()) {
    info.Set("pageUrl", target.page_url.spec());
  }
  if (target.frame_url.is_valid()) {
    info.Set("frameUrl", target.frame_url.spec());
  }
  if (target.link_url.is_valid()) {
    info.Set("linkUrl", target.link_url.spec());
  }
  if (target.src_url.is_valid()) {
    info.Set("srcUrl", target.src_url.spec());
  }
  if (!target.selection_text.empty()) {
    info.Set("selectionText", target.selection_text);
  }
  if (checkable) {
    info.Set("wasChecked", was_checked);
    info.Set("checked", !was_checked);
  }

  base::ListValue args;
  args.Append(std::move(info));
  if (Shell* shell = Shell::FromWebContents(contents)) {
    args.Append(ScrubbedTab(shell, extension_id));
  }
  EventHub::Get().Post(extension_id, "contextMenus.onClicked",
                       std::move(args));

  BrowserContext* context =
      contents ? contents->GetBrowserContext() : AnyBrowserContext();
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  ServiceWorkerContext* sw =
      partition ? partition->GetServiceWorkerContext() : nullptr;
  if (!sw) {
    return;
  }
  const GURL scope(
      base::StrCat({kBlinkerExtensionScheme, "://", extension_id, "/"}));
  sw->StartWorkerForScope(
      scope, blink::StorageKey::CreateFirstParty(url::Origin::Create(scope)),
      base::DoNothing(), base::DoNothing());
}

void BlinkerWakeExtensionWorker(const std::string& extension_id) {
  BrowserContext* context = AnyBrowserContext();
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  ServiceWorkerContext* sw =
      partition ? partition->GetServiceWorkerContext() : nullptr;
  if (!sw) {
    return;
  }
  const GURL scope(
      base::StrCat({kBlinkerExtensionScheme, "://", extension_id, "/"}));
  sw->StartWorkerForScope(
      scope, blink::StorageKey::CreateFirstParty(url::Origin::Create(scope)),
      base::DoNothing(), base::DoNothing());
}

namespace {

void WakeExtensionWorker(const std::string& extension_id) {
  BlinkerWakeExtensionWorker(extension_id);
}

}  // namespace

void BlinkerNotificationActivated(const std::string& extension_id,
                                  const std::string& notification_id,
                                  int button_index) {
  base::ListValue args;
  args.Append(notification_id);
  if (button_index >= 0) {
    args.Append(button_index);
  }
  EventHub::Get().Post(extension_id,
                       button_index >= 0 ? "notifications.onButtonClicked"
                                         : "notifications.onClicked",
                       std::move(args));
  WakeExtensionWorker(extension_id);
}

void BlinkerNotificationDismissed(const std::string& extension_id,
                                  const std::string& notification_id,
                                  bool by_user) {
  NotificationStore::Get().Clear(extension_id, notification_id);
  base::ListValue args;
  args.Append(notification_id);
  args.Append(by_user);
  EventHub::Get().Post(extension_id, "notifications.onClosed",
                       std::move(args));
  WakeExtensionWorker(extension_id);
}

namespace {
bool& BrowserBackgroundedFlag() {
  static bool backgrounded = false;
  return backgrounded;
}
}  // namespace

bool BlinkerBrowserIsBackgrounded() {
  return BrowserBackgroundedFlag();
}

void BlinkerFlushStorageForBackground(base::OnceCallback<void(bool)> callback) {
  BrowserContext* context = AnyBrowserContext();
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  if (partition) {
    partition->Flush();
    if (network::mojom::CookieManager* cookies =
            partition->GetCookieManagerForBrowserProcess()) {
      cookies->FlushCookieStore(base::DoNothing());
    }
  }
  BlinkerExtensionStorage::GetInstance().FlushPendingWrites(std::move(callback));
}

void BlinkerSetBrowserBackgrounded(bool backgrounded) {
  if (BrowserBackgroundedFlag() == backgrounded) {
    return;
  }
  BrowserBackgroundedFlag() = backgrounded;
  base::ListValue args;
  args.Append(backgrounded ? "idle" : "active");
  EventHub::Get().Broadcast("idle.onStateChanged", std::move(args));
  // Вікно одне, тож фокус губиться разом із застосунком, windowId тоді
  // WINDOW_ID_NONE
  base::ListValue focus;
  focus.Append(backgrounded ? -1 : kWindowId);
  EventHub::Get().Broadcast("windows.onFocusChanged", std::move(focus));

  // У фоні система першими вбиває найбільші апки, а кожен воркер це
  // окремий ізолят V8
  if (!backgrounded) {
    return;
  }
  BrowserContext* context = AnyBrowserContext();
  StoragePartition* partition =
      context ? context->GetDefaultStoragePartition() : nullptr;
  if (ServiceWorkerContext* sw =
          partition ? partition->GetServiceWorkerContext() : nullptr) {
    sw->StopAllServiceWorkers(base::DoNothing());
  }
}

void BlinkerPostExtensionEvent(const std::string& extension_id,
                               const std::string& name,
                               base::ListValue args) {
  EventHub::Get().Post(extension_id, name, std::move(args));
}

std::string BlinkerExtensionBadgeText(const std::string& extension_id) {
  int tab_id = 0;
  if (Shell* shell = ActiveShell()) {
    tab_id = TabIdFor(shell->web_contents());
  }
  return ActionStore::Get().Value(extension_id, "badge", tab_id);
}

std::string BlinkerExtensionActionTitle(const std::string& extension_id) {
  int tab_id = 0;
  if (Shell* shell = ActiveShell()) {
    tab_id = TabIdFor(shell->web_contents());
  }
  return ActionStore::Get().Value(extension_id, "title", tab_id);
}

void BlinkerActivateExtensionAction(const std::string& extension_id,
                                    WebContents* contents) {
  ActiveTabGrants::Get().Grant(extension_id, contents);
  base::ListValue args;
  if (Shell* shell = Shell::FromWebContents(contents)) {
    args.Append(ScrubbedTab(shell, extension_id));
  }
  EventHub::Get().Post(extension_id, "action.onClicked", std::move(args));
  WakeExtensionWorker(extension_id);
}

void BlinkerFireExtensionCommand(const std::string& extension_id,
                                 const std::string& command,
                                 WebContents* contents) {
  ActiveTabGrants::Get().Grant(extension_id, contents);
  base::ListValue args;
  args.Append(command);
  if (Shell* shell = Shell::FromWebContents(contents)) {
    args.Append(ScrubbedTab(shell, extension_id));
  }
  EventHub::Get().Post(extension_id, "commands.onCommand", std::move(args));
}

namespace {

constexpr char kUrlFilterJs[] =
    "const urlFilters=(()=>{"
    "const BU='',ED='',EP='',QD='',EU='';"
    "const PORTS={'http:':80,'https:':443,'ws:':80,'wss:':443,'ftp:':21};"
    "const MAPPED=[0,0,0,0,0,0,0,0,0,0,255,255];"
    "const suffix=(s)=>s===''?'.':(s.endsWith('.')?s:s+'.');"
    "const prefix=(s)=>s===''?'.':(s[0]==='.'?s:'.'+s);"
    "const query=(q,head,tail)=>"
    "(head?QD:'')+q.split('&').join(QD)+(tail?QD:'');"
    "const bare=(s)=>s[0]==='?'?s.slice(1):s;"
    "const forms=(href)=>{let u=null;try{u=new URL(href);}catch(e){}"
    "if(!u)return{host:'',path:'',query:'',scheme:'',port:-1,"
    "comp:BU+'.'+ED+EP+EU,full:BU+EU,regex:'',origin:''};"
    "u.username='';u.password='';u.hash='';"
    "const spec=u.href,cut=spec.indexOf('?'),q=cut<0?'':spec.slice(cut+1);"
    "return{host:u.hostname,path:u.pathname,query:q,"
    "scheme:u.protocol.slice(0,-1),"
    "port:u.port?Number(u.port):(PORTS[u.protocol]||-1),"
    "comp:BU+prefix(suffix(u.hostname))+ED+u.pathname+EP+"
    "(cut<0?'':query(q,true,true))+EU,"
    "full:BU+spec+EU,regex:spec,origin:cut<0?spec:spec.slice(0,cut)};};"
    "const C={"
    "hostContains:(s)=>(f)=>f.host.includes(s),"
    "hostEquals:(s)=>(f)=>f.comp.includes(BU+prefix(suffix(s))+ED),"
    "hostPrefix:(s)=>(f)=>f.comp.includes(BU+prefix(s)),"
    "hostSuffix:(s)=>(f)=>f.comp.includes(suffix(s)+ED),"
    "pathContains:(s)=>(f)=>f.path.includes(s),"
    "pathEquals:(s)=>(f)=>f.comp.includes(ED+s+EP),"
    "pathPrefix:(s)=>(f)=>f.comp.includes(ED+s),"
    "pathSuffix:(s)=>(f)=>f.comp.includes(s+EP),"
    "queryContains:(s)=>s[0]==='?'?C.queryPrefix(s):(f)=>f.query.includes(s),"
    "queryEquals:(s)=>(f)=>f.comp.includes(EP+query(bare(s),true,true)+EU),"
    "queryPrefix:(s)=>(f)=>f.comp.includes(EP+query(bare(s),true,false)),"
    "querySuffix:(s)=>s[0]==='?'?C.queryEquals(s):"
    "(f)=>f.comp.includes(query(s,false,true)+EU),"
    "urlContains:(s)=>(f)=>f.full.includes(s),"
    "urlEquals:(s)=>(f)=>f.full.includes(BU+s+EU),"
    "urlPrefix:(s)=>(f)=>f.full.includes(BU+s),"
    "urlSuffix:(s)=>(f)=>f.full.includes(s+EU),"
    "urlMatches:(s)=>{const r=new RegExp(s);return(f)=>r.test(f.regex);},"
    "originAndPathMatches:(s)=>{const r=new RegExp(s);"
    "return(f)=>r.test(f.origin);}};"
    "const ip=(host)=>{if(/^\\d+\\.\\d+\\.\\d+\\.\\d+$/.test(host))"
    "return host.split('.').map(Number);"
    "if(host[0]!=='['||!host.endsWith(']'))return null;"
    "const halves=host.slice(1,-1).split('::');"
    "const words=(s)=>s?s.split(':'):[];"
    "const head=words(halves[0]),tail=halves.length>1?words(halves[1]):[];"
    "return head.concat(Array(8-head.length-tail.length).fill('0'),tail)"
    ".flatMap((w)=>{const n=parseInt(w,16);return[n>>8,n&255];});};"
    "const cidr=(entry)=>{"
    "const parts=typeof entry==='string'?entry.split('/'):[];"
    "if(parts.length!==2||!/^[0-9a-fA-F:.xX]+$/.test(parts[0])||"
    "!/^\\d+$/.test(parts[1]))return null;"
    "const six=parts[0].includes(':');let host='';"
    "try{host=new URL('http://'+(six?'['+parts[0]+']':parts[0])+'/')"
    ".hostname;}"
    "catch(e){return null;}"
    "const bytes=ip(host),bits=Number(parts[1]);"
    "if(!bytes||(bytes.length===16)!==six||bits>bytes.length*8)return null;"
    "return[bytes,bits];};"
    "const inBlock=(address,block)=>{let net=block[0],bits=block[1];"
    "if(address.length!==net.length){if(address.length===4){"
    "address=MAPPED.concat(address);}else{net=MAPPED.concat(net);bits+=96;}}"
    "for(let i=0;bits>0;i++,bits-=8){"
    "const mask=bits>=8?255:(255<<(8-bits))&255;"
    "if((address[i]&mask)!==(net[i]&mask))return false;}return true;};"
    "const whole=(n)=>Number.isInteger(n)&&Math.abs(n)<2147483648;"
    "const conditionSet=(d)=>{"
    "if(d===null||typeof d!=='object'||Array.isArray(d))return null;"
    "const tests=[];"
    "for(const key of Object.keys(d)){const v=d[key];"
    "if(v===undefined||typeof v==='function')continue;"
    "if(Object.hasOwn(C,key)){"
    "if(typeof v!=='string'||(key.startsWith('host')&&/[A-Z]/.test(v)))"
    "return null;"
    "try{tests.push(C[key](v));}catch(e){return null;}"
    "}else if(key==='schemes'){"
    "if(!Array.isArray(v)||"
    "!v.every((s)=>typeof s==='string'&&!/[A-Z]/.test(s)))"
    "return null;"
    "tests.push((f)=>v.includes(f.scheme));"
    "}else if(key==='ports'){if(!Array.isArray(v))return null;"
    "const ranges=v.map((p)=>whole(p)?[p,p]:(Array.isArray(p)&&p.length===2&&"
    "whole(p[0])&&whole(p[1])?p:null));"
    "if(ranges.includes(null))return null;"
    "tests.push((f)=>ranges.some((r)=>r[0]<=f.port&&f.port<=r[1]));"
    "}else if(key==='cidrBlocks'){if(!Array.isArray(v))return null;"
    "const blocks=v.map(cidr);if(blocks.includes(null))return null;"
    "tests.push((f)=>{const a=ip(f.host);"
    "return!!a&&blocks.some((b)=>inBlock(a,b));});"
    "}else{return null;}}"
    "return(url)=>{const f=forms(url);return tests.every((t)=>t(f));};};"
    "return(rest)=>{if(!rest.length)return null;const filter=rest[0];"
    "if(filter===null||(typeof filter!=='object'&&typeof filter!=='function'))"
    "throw new TypeError('Invalid invocation');"
    "if(filter.url!==undefined&&!Array.isArray(filter.url))"
    "throw new TypeError('filters.url should be an array.');"
    "if(filter.serviceType!==undefined&&typeof filter.serviceType!=='string')"
    "throw new TypeError('filters.serviceType should be a string.');"
    "if(!filter.url||!filter.url.length)return null;"
    "const sets=filter.url.map(conditionSet);"
    "if(sets.includes(null))throw new TypeError('Could not add listener');"
    "return sets;};})();";

}  // namespace

std::string BlinkerExtensionPrivilegedApiShim(std::string_view extension_id,
                                              std::string_view token) {
  return base::StrCat({
      // Збій шіма лишив би розширення без chrome.* і без пояснень
      "(()=>{try{const ID=", Quoted(extension_id), ",TOK=", Quoted(token),
      ",EP='", kBlinkerExtensionScheme, "://'+ID+'/", kBlinkerApiPath, "';",
      "const c=globalThis.chrome=globalThis.chrome||{};",
      "if(c.scripting)return;",
      "c.runtime=c.runtime||{};",
      // Тіло рядком, щоб запит лишався простим для CORS
      "const rpc=(payload)=>fetch(EP,{method:'POST',",
      "body:JSON.stringify(Object.assign({tok:TOK},payload))})",
      ".then((r)=>r.json());",
      "const call=(payload,extract,cb)=>{",
      "const p=Promise.resolve().then(()=>rpc(payload)).then((r)=>{",
      "if(!r||!r.ok)throw new Error((r&&r.error)||",
      "'extension API unavailable');",
      "return extract?extract(r):undefined;});",
      "if(typeof cb!=='function')return p;",
      "const invoke=(value,err)=>{",
      "if(err)c.runtime.lastError={message:String((err&&err.message)||err)};",
      "else delete c.runtime.lastError;",
      "try{cb(value);}finally{delete c.runtime.lastError;}};",
      "p.then((value)=>invoke(value),(err)=>invoke(undefined,err));",
      "return undefined;};",

      "c.scripting={",
      "registerContentScripts:(scripts,cb)=>call(",
      "{ns:'scripting',op:'registerContentScripts',scripts:scripts||[]},",
      "null,cb),",
      "updateContentScripts:(scripts,cb)=>call(",
      "{ns:'scripting',op:'updateContentScripts',scripts:scripts||[]},",
      "null,cb),",
      "unregisterContentScripts:(filter,cb)=>{",
      "if(typeof filter==='function'){cb=filter;filter=null;}",
      "return call({ns:'scripting',op:'unregisterContentScripts',",
      "ids:(filter&&filter.ids)||null},null,cb);},",
      "getRegisteredContentScripts:(filter,cb)=>{",
      "if(typeof filter==='function'){cb=filter;filter=null;}",
      "return call({ns:'scripting',op:'getRegisteredContentScripts',",
      "ids:(filter&&filter.ids)||null},(r)=>(r&&r.scripts)||[],cb);},",
      "executeScript:(inj,cb)=>call({ns:'scripting',op:'executeScript',",
      "tabId:(inj&&inj.target&&inj.target.tabId),",
      "allFrames:!!(inj&&inj.target&&inj.target.allFrames),",
      "frameIds:(inj&&inj.target&&inj.target.frameIds)||null,",
      "documentIds:(inj&&inj.target&&inj.target.documentIds)||null,",
      "files:(inj&&inj.files)||null,",
      "func:(inj&&inj.func)?String(inj.func):null,",
      "code:(inj&&typeof inj.code==='string')?inj.code:null,",
      "args:(inj&&inj.args)||null,world:(inj&&inj.world)||null},",
      "(r)=>(r&&r.results)||[],cb),",
      "insertCSS:(inj,cb)=>call(Object.assign({},inj,{ns:'scripting',",
      "op:'insertCSS'}),null,cb),",
      "removeCSS:(inj,cb)=>call(Object.assign({},inj,{ns:'scripting',",
      "op:'removeCSS'}),null,cb)};",

      "const evl={},pend={};let watching=false,seq=0;",
      // Подія може прийти раніше підписки, бо воркер будять саме події
      "const hold=(name,args)=>{const list=pend[name]=pend[name]||[];",
      "list.push(args||[]);while(list.length>16)list.shift();};",
      "let parked=false;",
      "const hidden=()=>typeof document!=='undefined'&&document.hidden;",
      "if(typeof document!=='undefined')document.addEventListener(",
      "'visibilitychange',()=>{if(parked&&!document.hidden){parked=false;",
      "pump();}});",
      "const pump=()=>{if(hidden()){parked=true;return;}",
      "rpc({ns:'events',op:'watch',since:seq}).then((r)=>{",
      "if(r&&r.ok){seq=r.seq||seq;",
      "for(const ev of (r.events||[])){",
      "const fns=(evl[ev.name]||[]).slice();",
      "if(!fns.length){hold(ev.name,ev.args);continue;}",
      "for(const fn of fns){",
      "try{fn.apply(null,ev.args||[]);}catch(e){}}}",
      "setTimeout(pump,0);}else{setTimeout(pump,2000);}})",
      ".catch(()=>setTimeout(pump,2000));};",
      "const startWatch=()=>{if(watching)return;watching=true;",
      "rpc({ns:'events',op:'seq'}).then((r)=>{if(r&&r.ok)seq=r.seq||0;pump();})",
      ".catch(()=>pump());};",
      "const event=(name)=>({addListener:(fn)=>{if(typeof fn!=='function')",
      "return;const l=evl[name]=evl[name]||[];if(l.indexOf(fn)>=0)return;",
      "l.push(fn);startWatch();",
      "const waiting=pend[name];if(waiting&&waiting.length){delete pend[name];",
      "for(const args of waiting){try{fn.apply(null,args);}catch(e){}}}},",
      "removeListener:(fn)=>{const l=evl[name]||[];const i=l.indexOf(fn);",
      "if(i>=0)l.splice(i,1);},",
      "hasListener:(fn)=>(evl[name]||[]).indexOf(fn)>=0,",
      "hasListeners:()=>(evl[name]||[]).length>0});",

      "const css=(op,tabId,details,cb)=>{if(typeof tabId==='object'){",
      "cb=details;details=tabId;tabId=undefined;}details=details||{};",
      "const run=(id)=>c.scripting[op]({target:{tabId:id,",
      "allFrames:!!details.allFrames,frameIds:!details.allFrames&&",
      "typeof details.frameId==='number'?[details.frameId]:undefined},",
      "css:typeof details.code==='string'?details.code:undefined,",
      "files:details.file?[details.file]:undefined,",
      "origin:details.cssOrigin==='user'?'USER':'AUTHOR'});",
      "const p=typeof tabId==='number'?run(tabId):c.tabs.query({active:true,",
      "currentWindow:true}).then((t)=>run(t[0]&&t[0].id));",
      "if(typeof cb!=='function')return p;",
      "p.then(()=>cb(),(e)=>{c.runtime.lastError={message:String(e&&e.message",
      "||e)};try{cb();}finally{delete c.runtime.lastError;}});};",
      "const tabArg=(op,key)=>(tabId,cb)=>{if(typeof tabId==='function'){",
      "cb=tabId;tabId=undefined;}",
      "return call({ns:'tabs',op:op,tabId:typeof tabId==='number'?tabId:null},",
      "key?(r)=>(r&&r[key])||undefined:null,cb);};",
      "c.tabs={",
      "query:(q,cb)=>{if(typeof q==='function'){cb=q;q={};}",
      "return call(Object.assign({},q,{ns:'tabs',op:'query'}),",
      "(r)=>(r&&r.tabs)||[],cb);},",
      "get:(tabId,cb)=>call({ns:'tabs',op:'get',tabId:tabId},",
      "(r)=>(r&&r.tab)||undefined,cb),",
      "create:(props,cb)=>call(Object.assign({},props,{ns:'tabs',",
      "op:'create'}),(r)=>(r&&r.tab)||undefined,cb),",
      "update:(tabId,props,cb)=>{if(typeof tabId==='object'&&tabId!==null){",
      "cb=props;props=tabId;tabId=undefined;}",
      "return call(Object.assign({},props,{ns:'tabs',op:'update',",
      "tabId:(tabId===undefined?null:tabId)}),",
      "(r)=>(r&&r.tab)||undefined,cb);},",
      "remove:(tabIds,cb)=>call({ns:'tabs',op:'remove',tabIds:tabIds},",
      "null,cb),",
      "reload:(tabId,props,cb)=>{if(typeof tabId==='function'){cb=tabId;",
      "tabId=undefined;}else if(typeof props==='function'){cb=props;}",
      "return call({ns:'tabs',op:'reload',tabId:(typeof tabId==='number'?",
      "tabId:null)},null,cb);},",
      "getCurrent:(cb)=>call({ns:'tabs',op:'getCurrent'},",
      "(r)=>(r&&r.tab)||undefined,cb),",
      "highlight:(info,cb)=>{const t=info&&info.tabs;",
      "const id=Array.isArray(t)?t[0]:t;",
      "return call({ns:'tabs',op:'update',",
      "tabId:(typeof id==='number'?id:null),active:true},",
      "(r)=>({id:1,tabs:(r&&r.tab)?[r.tab]:[]}),cb);},",
      "captureVisibleTab:(a,b,cb)=>{let o=null;",
      "if(typeof a==='function'){cb=a;}else if(a&&typeof a==='object'){",
      "o=a;cb=b;}else if(typeof b==='function'){cb=b;}else{o=b;}",
      "return call({ns:'tabs',op:'captureVisibleTab',",
      "format:(o&&o.format)||'jpeg',",
      "quality:(o&&typeof o.quality==='number')?o.quality:92},",
      "(r)=>r&&r.dataUrl,cb);},",
      "detectLanguage:(tabId,cb)=>{const done=typeof tabId==='function'?tabId:",
      "cb;if(done){done('und');return;}return Promise.resolve('und');},",
      "setZoom:(tabId,factor,cb)=>{if(typeof tabId!=='number'){cb=factor;",
      "factor=tabId;tabId=undefined;}",
      "return call({ns:'tabs',op:'setZoom',",
      "tabId:(tabId===undefined?null:tabId),",
      "zoomFactor:(typeof factor==='number'?factor:1)},null,cb);},",
      "getZoom:(tabId,cb)=>{if(typeof tabId!=='number'){cb=tabId;",
      "tabId=undefined;}",
      "return call({ns:'tabs',op:'getZoom',",
      "tabId:(tabId===undefined?null:tabId)},",
      "(r)=>(r&&typeof r.zoomFactor==='number')?r.zoomFactor:1,cb);},",
      "getZoomSettings:tabArg('getZoomSettings','zoomSettings'),",
      "setZoomSettings:(tabId,settings,cb)=>{if(typeof tabId!=='number'){",
      "cb=settings;settings=tabId;tabId=undefined;}",
      "return call({ns:'tabs',op:'setZoomSettings',",
      "tabId:(tabId===undefined?null:tabId),zoomSettings:settings||{}},",
      "null,cb);},",
      "goBack:tabArg('goBack'),goForward:tabArg('goForward'),",
      "duplicate:tabArg('duplicate','tab'),discard:tabArg('discard','tab'),",
      // MV2 назви тих самих дій. Розширення MV3 тримають гілку для старого
      // API і без цих вона кидає
      "insertCSS:(tabId,details,cb)=>css('insertCSS',tabId,details,cb),",
      "removeCSS:(tabId,details,cb)=>css('removeCSS',tabId,details,cb),",
      "executeScript:(tabId,details,cb)=>{if(typeof tabId==='object'){",
      "cb=details;details=tabId;tabId=undefined;}details=details||{};",
      // allFrames з frameId значить всі фрейми, бо scripting таке поєднання
      // відхиляє
      "const p=c.scripting.executeScript({target:{tabId:tabId,",
      "allFrames:!!details.allFrames,frameIds:!details.allFrames&&",
      "typeof details.frameId==='number'?[details.frameId]:undefined},",
      "files:details.file?[details.file]:null,",
      "code:typeof details.code==='string'?details.code:undefined});",
      "if(typeof cb==='function'){p.then((r)=>cb((r||[]).map(",
      "(e)=>e&&e.result)));return;}",
      "return p.then((r)=>(r||[]).map((e)=>e&&e.result));},",
      "onUpdated:event('tabs.onUpdated'),",
      "onRemoved:event('tabs.onRemoved'),",
      "onActivated:event('tabs.onActivated'),",
      "onReplaced:event('tabs.onReplaced'),",
      "onZoomChange:event('tabs.onZoomChange'),",
      "onCreated:event('tabs.onCreated')};",

      "c.search={query:(o,cb)=>call({ns:'search',op:'query',",
      "text:(o&&o.text)||'',disposition:(o&&o.disposition)||null,",
      "tabId:(o&&typeof o.tabId==='number')?o.tabId:null},null,cb)};",

      "const us=(op,payload,extract,cb)=>call(Object.assign(",
      "{ns:'userScripts',op:op},payload||{}),extract,cb);",
      "c.userScripts={",
      "register:(scripts,cb)=>us('register',{scripts:scripts||[]},null,cb),",
      "update:(scripts,cb)=>us('update',{scripts:scripts||[]},null,cb),",
      "unregister:(filter,cb)=>{if(typeof filter==='function'){cb=filter;",
      "filter=null;}",
      "return us('unregister',{ids:(filter&&filter.ids)||null},null,cb);},",
      "getScripts:(filter,cb)=>{if(typeof filter==='function'){cb=filter;",
      "filter=null;}",
      "return us('getScripts',{ids:(filter&&filter.ids)||null},",
      "(r)=>(r&&r.scripts)||[],cb);},",
      "configureWorld:(o,cb)=>us('configureWorld',",
      "{messaging:!!(o&&o.messaging)},null,cb),",
      "resetWorldConfiguration:(id,cb)=>{if(typeof id==='function'){cb=id;}",
      "return us('configureWorld',{messaging:false},null,cb);},",
      "execute:(inj,cb)=>us('execute',{target:inj&&inj.target,",
      "js:(inj&&inj.js)||null,world:(inj&&inj.world)||'USER_SCRIPT',",
      "worldId:inj&&inj.worldId},",
      "(r)=>(r&&r.results)||[],cb)};",

      "const cm=(op,d,cb)=>call(Object.assign({ns:'contextMenus',op:op},",
      "d||{}),null,cb);",
      "c.contextMenus={",
      "create:(props,cb)=>{cm('create',{properties:props||{}},cb);",
      "return (props&&props.id)||'';},",
      "update:(id,props,cb)=>cm('update',{id:String(id),",
      "properties:props||{}},cb),",
      "remove:(id,cb)=>cm('remove',{id:String(id)},cb),",
      "removeAll:(cb)=>cm('removeAll',{},cb),",
      "onClicked:event('contextMenus.onClicked')};",
      "c.menus=c.contextMenus;",

      // Фон на телефоні значить що користувач відійшов, locked не відрізнити
      "c.idle={IdleState:{ACTIVE:'active',IDLE:'idle',LOCKED:'locked'},",
      "queryState:(seconds,cb)=>{if(typeof seconds==='function'){cb=seconds;}",
      "return call({ns:'idle',op:'queryState'},",
      "(r)=>(r&&r.state)||'active',cb);},",
      "setDetectionInterval:(n)=>undefined,",
      "getAutoLockDelay:(cb)=>{if(cb){cb(0);return;}",
      "return Promise.resolve(0);},",
      "onStateChanged:event('idle.onStateChanged')};",

      "{const mfb=c.runtime.getManifest?c.runtime.getManifest():{};",
      "if([].concat(mfb.permissions||[],mfb.optional_permissions||[])",
      ".includes('bookmarks')){",
      "const bm=(op,extra,pick,cb)=>call(Object.assign({ns:'bookmarks',op},",
      "extra),(r)=>pick?pick(r.result):r.result,cb);",
      "const ids=(v)=>Array.isArray(v)?v.map(String):[String(v)];",
      "c.bookmarks={getTree:(cb)=>bm('getTree',{},null,cb),",
      "getSubTree:(id,cb)=>bm('getSubTree',{id:String(id)},null,cb),",
      "get:(v,cb)=>bm('get',{ids:ids(v)},null,cb),",
      "getChildren:(id,cb)=>bm('getChildren',{id:String(id)},null,cb),",
      "getRecent:(n,cb)=>bm('getRecent',{count:n},null,cb),",
      "search:(q,cb)=>bm('search',{query:q},null,cb),",
      "create:(d,cb)=>bm('create',{details:d||{}},null,cb),",
      "update:(id,ch,cb)=>bm('update',{id:String(id),changes:ch||{}},null,cb),",
      "move:(id,dest,cb)=>bm('move',{id:String(id),destination:dest||{}},",
      "null,cb),",
      "remove:(id,cb)=>bm('remove',{id:String(id)},()=>undefined,cb),",
      "removeTree:(id,cb)=>bm('removeTree',{id:String(id)},()=>undefined,cb),",
      "onCreated:event('bookmarks.onCreated'),",
      "onRemoved:event('bookmarks.onRemoved'),",
      "onChanged:event('bookmarks.onChanged'),",
      "onMoved:event('bookmarks.onMoved'),",
      "onChildrenReordered:event('bookmarks.onChildrenReordered'),",
      "onImportBegan:event('bookmarks.onImportBegan'),",
      "onImportEnded:event('bookmarks.onImportEnded')};}}",

      "c.management={getSelf:(cb)=>{const m=c.runtime.getManifest();",
      "const info={id:c.runtime.id,name:m.name,version:m.version,",
      "shortName:m.short_name||m.name,description:m.description||'',",
      "enabled:true,installType:'normal',mayDisable:true,type:'extension',",
      "permissions:m.permissions||[],hostPermissions:m.host_permissions||[],",
      "offlineEnabled:!!m.offline_enabled,",
      "optionsUrl:(m.options_ui&&m.options_ui.page)?",
      "c.runtime.getURL(m.options_ui.page):''};",
      "if(cb){cb(info);return;}return Promise.resolve(info);},",
      "uninstallSelf:(o,cb)=>call({ns:'management',op:'uninstallSelf'},",
      "null,typeof o==='function'?o:cb),",
      "getPermissionWarningsByManifest:(s,cb)=>{if(cb){cb([]);return;}",
      "return Promise.resolve([]);},",
      "onInstalled:event('management.onInstalled'),",
      "onUninstalled:event('management.onUninstalled')};",

      "c.sidePanel={setOptions:(o,cb)=>{if(cb){cb();return;}",
      "return Promise.resolve();},",
      "getOptions:(o,cb)=>{const r={enabled:false};if(cb){cb(r);return;}",
      "return Promise.resolve(r);},",
      "setPanelBehavior:(o,cb)=>{if(cb){cb();return;}",
      "return Promise.resolve();},",
      "open:(o,cb)=>{c.runtime.lastError={message:",
      "'Blinker Fluid has no side panel'};",
      "if(cb){try{cb();}finally{delete c.runtime.lastError;}return;}",
      "delete c.runtime.lastError;",
      "return Promise.reject(new Error('Blinker Fluid has no side panel'));}};",

      "c.identity={",
      "getRedirectURL:(path)=>'https://'+c.runtime.id+",
      "'.chromiumapp.org/'+String(path||'').replace(/^\\//,''),",
      "launchWebAuthFlow:(d,cb)=>call({ns:'identity',op:'launchWebAuthFlow',",
      "url:(d&&d.url)||'',interactive:!!(d&&d.interactive)},",
      "(r)=>r&&r.redirectUrl,cb),",
      "getProfileUserInfo:(d,cb)=>{const r={email:'',id:''};",
      "if(typeof d==='function'){cb=d;}",
      "if(cb){cb(r);return;}return Promise.resolve(r);},",
      "onSignInChanged:event('identity.onSignInChanged')};",

      BlinkerWebRequestShim(),

      "const dl=(op,d,extract,cb)=>call(Object.assign(",
      "{ns:'downloads',op:op},d||{}),extract,cb);",
      "c.downloads={",
      "download:(opts,cb)=>dl('download',opts||{},(r)=>r&&r.id,cb),",
      "search:(query,cb)=>dl('search',{query:query||{}},",
      "(r)=>(r&&r.items)||[],cb),",
      "erase:(query,cb)=>dl('erase',{query:query||{}},",
      "(r)=>(r&&r.ids)||[],cb),",
      "cancel:(id,cb)=>dl('cancel',{id:id},null,cb),",
      "pause:(id,cb)=>dl('pause',{id:id},null,cb),",
      "resume:(id,cb)=>dl('resume',{id:id},null,cb),",
      "removeFile:(id,cb)=>dl('removeFile',{id:id},null,cb),",
      "State:{IN_PROGRESS:'in_progress',INTERRUPTED:'interrupted',",
      "COMPLETE:'complete'},",
      "onCreated:event('downloads.onCreated'),",
      "onChanged:event('downloads.onChanged')};",

      "const nf=(op,d,extract,cb)=>call(Object.assign(",
      "{ns:'notifications',op:op},d||{}),extract,cb);",
      "c.notifications={",
      "create:(id,opts,cb)=>{if(typeof id==='object'&&id!==null){",
      "cb=opts;opts=id;id='';}else if(typeof id==='function'){",
      "cb=id;id='';opts=opts||{};}",
      "return nf('create',{notificationId:id||'',options:opts||{}},",
      "(r)=>r&&r.notificationId,cb);},",
      "update:(id,opts,cb)=>nf('update',{notificationId:String(id),",
      "options:opts||{}},(r)=>!!(r&&r.wasUpdated),cb),",
      "clear:(id,cb)=>nf('clear',{notificationId:String(id)},",
      "(r)=>!!(r&&r.wasCleared),cb),",
      "getAll:(cb)=>nf('getAll',{},(r)=>{const out={};",
      "((r&&r.ids)||[]).forEach((i)=>{out[i]=true;});return out;},cb),",
      "getPermissionLevel:(cb)=>nf('getPermissionLevel',{},",
      "(r)=>(r&&r.level)||'granted',cb),",
      "onClicked:event('notifications.onClicked'),",
      "onButtonClicked:event('notifications.onButtonClicked'),",
      "onClosed:event('notifications.onClosed')};",

      "const ck=(op,d,extract,cb)=>call(Object.assign({ns:'cookies',op:op},",
      "d||{}),extract,cb);",
      "c.cookies={",
      "get:(d,cb)=>ck('get',d,(r)=>((r&&r.cookies&&r.cookies[0])||null),cb),",
      "getAll:(d,cb)=>ck('getAll',d,(r)=>(r&&r.cookies)||[],cb),",
      "set:(d,cb)=>ck('set',d,(r)=>(r&&r.cookie)||null,cb),",
      "remove:(d,cb)=>ck('remove',d,(r)=>(r&&r.details)||null,cb),",
      "getAllCookieStores:(cb)=>ck('getAllCookieStores',{},",
      "(r)=>(r&&r.stores)||[],cb),",
      "onChanged:event('cookies.onChanged')};",

      "c.offscreen={",
      "createDocument:(o,cb)=>call({ns:'offscreen',op:'createDocument',",
      "url:(o&&o.url)||null},null,cb),",
      "closeDocument:(cb)=>call({ns:'offscreen',op:'closeDocument'},null,cb),",
      "hasDocument:(cb)=>call({ns:'offscreen',op:'hasDocument'},",
      "(r)=>!!(r&&r.result),cb)};",

      "const win=(op,payload,o,cb,key)=>{if(typeof o==='function'){cb=o;",
      "o=undefined;}return call(Object.assign({ns:'windows',op:op,",
      "queryOptions:o||{}},payload),(r)=>r&&r[key||'window'],cb);};",
      "c.windows={",
      "create:(o,cb)=>{if(typeof o==='function'){cb=o;o={};}",
      "return call(Object.assign({},o,{ns:'windows',op:'create'}),",
      "(r)=>r&&r.window,cb);},",
      "update:(id,o,cb)=>win('update',{windowId:id},undefined,cb),",
      "get:(id,o,cb)=>win('get',{windowId:id},o,cb),",
      "getCurrent:(o,cb)=>win('getCurrent',{},o,cb),",
      "getLastFocused:(o,cb)=>win('getLastFocused',{},o,cb),",
      "getAll:(o,cb)=>win('getAll',{},o,cb,'windows'),",
      "remove:(id,cb)=>win('remove',{windowId:id},undefined,cb,'none'),",
      "onCreated:event('windows.onCreated'),onRemoved:event('windows.onRemoved'),",
      "onFocusChanged:event('windows.onFocusChanged')};",

      "c.commands={getAll:(cb)=>{const declared=",
      "c.runtime.getManifest().commands||{};",
      "const out=Object.keys(declared).map((name)=>({name:name,",
      "description:(declared[name]&&declared[name].description)||'',",
      "shortcut:''}));",
      "if(cb){cb(out);return;}",
      "return Promise.resolve(out);},onCommand:event('commands.onCommand')};",

      kUrlFilterJs,
      "const navEvent=(name)=>{const base=event(name),wraps=new Map();",
      "return{addListener:(fn,...rest)=>{",
      "if(typeof fn!=='function'||wraps.has(fn))return;",
      "const sets=urlFilters(rest);",
      "const w=sets?(...args)=>{const d=args[0];",
      "if(sets.some((s)=>s(d&&d.url)))fn(...args);}:fn;",
      "wraps.set(fn,w);base.addListener(w);},",
      "removeListener:(fn)=>{const w=wraps.get(fn);",
      "if(w){wraps.delete(fn);base.removeListener(w);}},",
      "hasListener:(fn)=>wraps.has(fn),hasListeners:()=>wraps.size>0};};",
      "const nav=(op,d,key,cb)=>call({ns:'webNavigation',op:op,",
      "details:d||{}},(r)=>(r&&r[key])||null,cb);",
      "c.webNavigation={",
      "onBeforeNavigate:navEvent('webNavigation.onBeforeNavigate'),",
      "onCommitted:navEvent('webNavigation.onCommitted'),",
      "onDOMContentLoaded:navEvent('webNavigation.onDOMContentLoaded'),",
      "onCompleted:navEvent('webNavigation.onCompleted'),",
      "onErrorOccurred:navEvent('webNavigation.onErrorOccurred'),",
      "onCreatedNavigationTarget:navEvent(",
      "'webNavigation.onCreatedNavigationTarget'),",
      "onReferenceFragmentUpdated:navEvent(",
      "'webNavigation.onReferenceFragmentUpdated'),",
      "onHistoryStateUpdated:navEvent('webNavigation.onHistoryStateUpdated'),",
      "onTabReplaced:event('webNavigation.onTabReplaced'),",
      "getFrame:(d,cb)=>nav('getFrame',d,'frame',cb),",
      "getAllFrames:(d,cb)=>nav('getAllFrames',d,'frames',cb)};",

      "const alarmListeners=[];",
      "c.alarms={",
      "create:(name,info,cb)=>{if(typeof name==='object'){cb=info;info=name;",
      "name='';}info=info||{};",
      "return call({ns:'alarms',op:'create',name:name||'',",
      "when:info.when||0,delayInMinutes:info.delayInMinutes||0,",
      "periodInMinutes:info.periodInMinutes||0},null,cb);},",
      "get:(name,cb)=>{if(typeof name==='function'){cb=name;name='';}",
      "return call({ns:'alarms',op:'get',name:name||''},",
      "(r)=>(r&&r.alarm)||undefined,cb);},",
      "getAll:(cb)=>call({ns:'alarms',op:'getAll'},(r)=>(r&&r.alarms)||[],cb),",
      "clear:(name,cb)=>{if(typeof name==='function'){cb=name;name='';}",
      "return call({ns:'alarms',op:'clear',name:name||''},",
      "(r)=>!!(r&&r.result),cb);},",
      "clearAll:(cb)=>call({ns:'alarms',op:'clearAll'},",
      "(r)=>!!(r&&r.result),cb),",
      "onAlarm:{addListener:(fn)=>{if(typeof fn==='function'){",
      "alarmListeners.push(fn);startWatch();drainAlarms();}},",
      "removeListener:(fn)=>{const i=",
      "alarmListeners.indexOf(fn);if(i>=0)alarmListeners.splice(i,1);},",
      "hasListener:(fn)=>alarmListeners.indexOf(fn)>=0}};",
      "const seenFires=new Set();",
      "const fireAlarm=(a)=>{if(!a)return;",
      "const id=a.fireId;",
      "if(id!==undefined){if(seenFires.has(id))return;seenFires.add(id);}",
      "for(const fn of alarmListeners.slice()){try{fn(a);}catch(err){}}};",
      "const drainAlarms=()=>rpc({ns:'alarms',op:'drain'}).then((r)=>{",
      "if(r&&r.ok)for(const a of (r.alarms||[]))fireAlarm(a);}).catch(()=>{});",
      "evl['alarms.onAlarm']=[fireAlarm];",

      "const dnr=(op,payload,extract,cb)=>call(Object.assign(",
      "{ns:'declarativeNetRequest',op:op},payload||{}),extract,cb);",
      "c.declarativeNetRequest={",
      "updateDynamicRules:(o,cb)=>dnr('updateDynamicRules',{",
      "removeRuleIds:(o&&o.removeRuleIds)||[],addRules:(o&&o.addRules)||[]},",
      "null,cb),",
      "getDynamicRules:(f,cb)=>{if(typeof f==='function'){cb=f;f=null;}",
      "return dnr('getDynamicRules',{ruleIds:(f&&f.ruleIds)||null},",
      "(r)=>(r&&r.rules)||[],cb);},",
      "updateSessionRules:(o,cb)=>dnr('updateSessionRules',{",
      "removeRuleIds:(o&&o.removeRuleIds)||[],addRules:(o&&o.addRules)||[]},",
      "null,cb),",
      "getSessionRules:(f,cb)=>{if(typeof f==='function'){cb=f;f=null;}",
      "return dnr('getSessionRules',{ruleIds:(f&&f.ruleIds)||null},",
      "(r)=>(r&&r.rules)||[],cb);},",
      "updateEnabledRulesets:(o,cb)=>dnr('updateEnabledRulesets',{",
      "disableRulesetIds:(o&&o.disableRulesetIds)||[],",
      "enableRulesetIds:(o&&o.enableRulesetIds)||[]},null,cb),",
      "getEnabledRulesets:(cb)=>dnr('getEnabledRulesets',{},",
      "(r)=>(r&&r.rulesetIds)||[],cb),",
      "getAvailableStaticRuleCount:(cb)=>dnr('getAvailableStaticRuleCount',{},",
      "(r)=>(r&&r.count)||0,cb),",
      "getMatchedRules:(f,cb)=>{if(typeof f==='function'){cb=f;f=null;}",
      "return dnr('getMatchedRules',{},(r)=>({rulesMatchedInfo:",
      "(r&&r.rulesMatchedInfo)||[]}),cb);},",
      "isRegexSupported:(o,cb)=>call({ns:'declarativeNetRequest',",
      "op:'isRegexSupported',regex:String((o&&o.regex)||''),",
      "caseSensitive:!!(o&&o.isCaseSensitive)},",
      "(r)=>r.result,cb),",
      "setExtensionActionOptions:(o,cb)=>{if(cb)cb();return Promise.resolve();},",
      "onRuleMatchedDebug:event('declarativeNetRequest.onRuleMatchedDebug')};",

      "const perm=(op,o,extract,cb)=>{if(typeof o==='function'){cb=o;o={};}",
      "return call({ns:'permissions',op:op,permissions:(o&&o.permissions)||[],",
      "origins:(o&&o.origins)||[]},extract,cb);};",
      "c.permissions={",
      "getAll:(cb)=>perm('getAll',{},(r)=>({permissions:(r&&r.permissions)||[],",
      "origins:(r&&r.origins)||[]}),cb),",
      "contains:(o,cb)=>perm('contains',o,(r)=>!!(r&&r.result),cb),",
      "request:(o,cb)=>perm('request',o,(r)=>!!(r&&r.result),cb),",
      "remove:(o,cb)=>perm('remove',o,(r)=>!!(r&&r.result),cb),",
      "onAdded:event('permissions.onAdded'),",
      "onRemoved:event('permissions.onRemoved')};",

      "const act=(op,field,d,v,extract,cb)=>call({ns:'action',op:op,",
      "field:field,tabId:(d&&d.tabId)||0,value:v===undefined?'':String(v)},",
      "extract,cb);",
      "const actGet=(field,d,cb)=>act('get',field,d,'',",
      "(r)=>(r&&r.value)||'',cb);",
      "c.action={",
      "setBadgeText:(d,cb)=>act('set','badge',d,(d&&d.text)||'',null,cb),",
      "getBadgeText:(d,cb)=>actGet('badge',d,cb),",
      "setBadgeBackgroundColor:(d,cb)=>act('set','color',d,",
      "(d&&d.color)||'',null,cb),",
      "getBadgeBackgroundColor:(d,cb)=>actGet('color',d,cb),",
      "setBadgeTextColor:(d,cb)=>{if(cb)cb();return Promise.resolve();},",
      "setTitle:(d,cb)=>act('set','title',d,(d&&d.title)||'',null,cb),",
      "getTitle:(d,cb)=>actGet('title',d,cb),",
      "setIcon:(d,cb)=>{if(cb)cb();return Promise.resolve();},",
      "setPopup:(d,cb)=>act('set','popup',d,(d&&d.popup)||'',null,cb),",
      "getPopup:(d,cb)=>actGet('popup',d,cb),",
      "enable:(t,cb)=>{if(typeof t==='function'){cb=t;t=0;}",
      "return act('set','enabled',{tabId:t},'1',null,cb);},",
      "disable:(t,cb)=>{if(typeof t==='function'){cb=t;t=0;}",
      "return act('set','enabled',{tabId:t},'',null,cb);},",
      "isEnabled:(t,cb)=>{if(typeof t==='function'){cb=t;t=0;}",
      "return act('get','enabled',{tabId:t},'',(r)=>(r&&r.value)!=='',cb);},",
      "getUserSettings:(cb)=>{const r={isOnToolbar:false};if(cb){cb(r);return;}",
      "return Promise.resolve(r);},",
      "openPopup:(o,cb)=>{const p=(c.runtime.getManifest().action||{})",
      ".default_popup;if(p&&c.tabs)c.tabs.create({url:c.runtime.getURL(p)});",
      "if(cb)cb();return Promise.resolve();},",
      "onClicked:event('action.onClicked')};",
      "c.browserAction=c.action;",

      "c.runtime.reload=()=>{rpc({ns:'runtime',op:'reload'}).catch(()=>{});};",
      "c.runtime.getContexts=(filter,cb)=>call({ns:'runtime',op:'getContexts',",
      "filter:filter||{}},(r)=>(r&&r.contexts)||[],cb);",
      "c.runtime.onStartup=c.runtime.onStartup||event('runtime.onStartup');",
      "c.runtime.onInstalled=event('runtime.onInstalled');",
      "c.runtime.onSuspend=event('runtime.onSuspend');",
      "c.runtime.onUpdateAvailable=event('runtime.onUpdateAvailable');",
      "c.runtime.onSuspendCanceled=event('runtime.onSuspendCanceled');",
      "c.runtime.onRestartRequired=event('runtime.onRestartRequired');",
      "c.runtime.onConnectExternal=event('runtime.onConnectExternal');",
      "c.runtime.onMessageExternal=event('runtime.onMessageExternal');",
      "c.runtime.onUserScriptConnect=c.runtime.onUserScriptConnect||",
      "event('runtime.onUserScriptConnect');",
      "c.runtime.getPackageDirectoryEntry=(cb)=>{const m=",
      "'getPackageDirectoryEntry is not available in Blinker Fluid';",
      "c.runtime.lastError={message:m};",
      "if(cb){try{cb(undefined);}finally{delete c.runtime.lastError;}return;}",
      "delete c.runtime.lastError;return Promise.reject(new Error(m));};",
      "c.runtime.requestUpdateCheck=(cb)=>{const r={status:'no_update'};",
      "if(cb){cb(r.status,r);return;}return Promise.resolve(r);};",
      "c.runtime.setUninstallURL=c.runtime.setUninstallURL||((u,cb)=>{",
      "if(cb){cb();return;}return Promise.resolve();});",
      "if(typeof WorkerGlobalScope!=='undefined'){",
      "setTimeout(()=>{",
      "rpc({ns:'runtime',op:'consumeLifecycle'}).then((r)=>{",
      "if(!r||!r.ok)return;",
      "if(r.startup)for(const fn of (evl['runtime.onStartup']||[]).slice()){",
      "try{fn();}catch(e){}}",
      "if(r.installed)for(const fn of (evl['runtime.onInstalled']||[]).slice()){",
      "try{fn(Object.assign({},r.installed));}catch(e){}}",
      "}).catch(()=>{});},0);}",
      "}catch(err){try{console.error('Blinker: the extension API shim failed '",
      "+'to install -- chrome.* is incomplete: '+((err&&err.stack)||err));}",
      "catch(e2){}}",
      "})();\n",
  });
}

std::string BlinkerExtensionApiSurfaceShim() {
  return base::StrCat({
      "(()=>{try{const c=globalThis.chrome;if(!c||!c.runtime)return;",
      kBlinkerApiSurfaceJs,
      kBlinkerApiEnumsJs,
      "const mf=typeof c.runtime.getManifest==='function'?",
      "c.runtime.getManifest():{};",
      "const mv=mf.manifest_version===3?3:2;",
      // Необов'язкові дозволи теж, бо після permissions.request шім вже не
      // перебудуєш
      "const granted=new Set([].concat(mf.permissions||[],",
      "mf.optional_permissions||[]));",
      "const met=(req)=>!req||req.split('|').some((alt)=>alt.split(' ').every(",
      "(d)=>d.startsWith('permission:')?granted.has(d.slice(11)):",
      "d.startsWith('manifest:')&&mf[d.slice(9)]!==undefined));",
      "const worker=typeof WorkerGlobalScope!=='undefined';",
      "const fits=(flag)=>!(flag.includes('2')&&mv!==2)&&",
      "!(flag.includes('3')&&mv!==3)&&!(flag.includes('d')&&worker);",
      "const at=(path)=>path.split('.').reduce((o,k)=>",
      "(o[k]===undefined||o[k]===null)?(o[k]={}):o[k],c);",
      "const later=(fn)=>Promise.resolve().then(fn);",
      "const fail=(m,cb)=>{if(typeof cb!=='function')",
      "return Promise.reject(new Error(m));",
      "later(()=>{c.runtime.lastError={message:m};",
      "try{cb();}finally{delete c.runtime.lastError;}});};",
      "const missing=(path)=>function(...args){",
      "return fail(path+' is not available in Blinker Fluid',",
      "args[args.length-1]);};",
      "const ok=(make)=>(...args)=>{const v=make(),cb=args[args.length-1];",
      "if(typeof cb!=='function')return Promise.resolve(v);later(()=>cb(v));};",
      "const no=(m)=>(...args)=>",
      "fail(typeof m==='function'?m(...args):m,args[args.length-1]);",
      "const noGroup=no((id)=>'No group with id: '+id+'.');",
      // Шрифти системи недоступні, але розширення чекають масив. Dark Reader
      // без нього не малює спливне вікно
      "const fonts=['Helvetica Neue','Arial','Georgia','Times New Roman',",
      "'Courier New','Menlo','Verdana','Trebuchet MS','Avenir','Gill Sans',",
      "'Palatino','Optima'].map((n)=>({fontId:n,displayName:n}));",
      "const size=(px)=>ok(()=>({pixelSize:px,",
      "levelOfControl:'not_controllable'}));",
      "const known={'fontSettings.getFontList':ok(()=>fonts.slice()),",
      "'fontSettings.getDefaultFontSize':size(16),",
      "'fontSettings.getDefaultFixedFontSize':size(13),",
      "'fontSettings.getMinimumFontSize':size(0),",
      "'fontSettings.getFont':ok(()=>({fontId:'',",
      "levelOfControl:'not_controllable'})),",
      "'tabGroups.query':ok(()=>[]),'tabGroups.get':noGroup,",
      "'tabGroups.update':noGroup,'tabGroups.move':noGroup,",
      "'tabs.group':no('Grouping is not supported by tabs in this window.'),",
      "'tabs.ungroup':no('Grouping is not supported by tabs in this window.'),",
      "'sessions.getDevices':ok(()=>[]),",
      "'sessions.getRecentlyClosed':ok(()=>[]),",
      "'sessions.restore':no((id)=>typeof id==='string'?",
      "'Invalid session id: \"'+id+'\".':",
      "'There are no recently closed sessions.'),",
      "'runtime.restart':",
      "no('Function available only for ChromeOS kiosk mode.'),",
      "'runtime.restartAfterDelay':",
      "no('API available only for ChromeOS kiosk mode.')};",
      // Цього тут бути не може, тож нема й функції. Розширення перевіряють
      // наявність і самі йдуть в обхід, а заглушка їх обдурює
      "const absent=new Set(['runtime.connectNative',",
      "'runtime.sendNativeMessage','declarativeNetRequest.updateStaticRules',",
      "'declarativeNetRequest.getDisabledRuleIds',",
      "'permissions.addHostAccessRequest','permissions.removeHostAccessRequest',",
      "'management.getAll','management.setEnabled']);",
      "const quiet=()=>{const fns=[];return{",
      "addListener:(fn)=>{if(typeof fn==='function'&&!fns.includes(fn))",
      "fns.push(fn);},",
      "removeListener:(fn)=>{const i=fns.indexOf(fn);",
      "if(i>=0)fns.splice(i,1);},",
      "hasListener:(fn)=>fns.includes(fn),hasListeners:()=>fns.length>0};};",
      "const ruled=()=>{const rules=new Map();let next=0;",
      "const reply=(cb,v,m)=>{if(typeof cb!=='function')return;",
      "later(()=>{if(m)c.runtime.lastError={message:m};",
      "try{cb(v);}finally{if(m)delete c.runtime.lastError;}});};",
      "const pick=(ids)=>ids===undefined||ids===null?[...rules.keys()]:ids;",
      "return{addRules:(list,cb)=>{",
      "const added=(list||[]).map((r)=>Object.assign({},r)),seen=new Set();",
      "for(const r of added){if(r.id===undefined)continue;",
      "if(rules.has(r.id)||seen.has(r.id)){",
      "reply(cb,undefined,'Id '+r.id+' was used multiple times.');return;}",
      "seen.add(r.id);}",
      "for(const r of added){if(r.id===undefined){",
      "while(rules.has('_'+next+'_')||seen.has('_'+next+'_'))next++;",
      "r.id='_'+next+'_';}",
      "if(r.priority===undefined)r.priority=100;rules.set(r.id,r);}",
      "reply(cb,added);},",
      "removeRules:(ids,cb)=>{if(typeof ids==='function'){cb=ids;ids=null;}",
      "for(const id of pick(ids))rules.delete(id);reply(cb);},",
      "getRules:(ids,cb)=>{if(typeof ids==='function'){cb=ids;ids=null;}",
      "reply(cb,pick(ids).filter((id)=>rules.has(id))",
      ".map((id)=>rules.get(id)));}};};",
      "const klass=(name)=>class{constructor(o){",
      "Object.assign(this,o||{},{instanceType:name});}};",
      "const setting=(dflt)=>({",
      "get:(d,cb)=>{const r={value:JSON.parse(JSON.stringify(dflt)),",
      "levelOfControl:'not_controllable'};",
      "if(typeof cb!=='function')return Promise.resolve(r);later(()=>cb(r));},",
      "set:(d,cb)=>fail('This setting is not controllable in Blinker Fluid',",
      "cb),",
      "clear:(d,cb)=>{if(typeof cb!=='function')return Promise.resolve();",
      "later(()=>cb());},",
      "onChange:quiet()});",
      // get віддає типове значення, бо розширення читають details.setting
      // без перевірки
      "const asking=['notifications','location','camera','microphone',",
      "'automaticDownloads','clipboard','autoVerify','sound'];",
      "const content=(path)=>({get:(d,cb)=>{",
      "const kind=path.split('.').pop();",
      "const r={setting:kind==='popups'?'block':",
      "asking.includes(kind)?'ask':'allow'};",
      "if(typeof cb!=='function')return Promise.resolve(r);later(()=>cb(r));},",
      "set:missing(path+'.set'),clear:missing(path+'.clear'),",
      "getResourceIdentifiers:missing(path+'.getResourceIdentifiers')});",
      "for(const [path,req,flag,fns,evs,rules,classes] of apiSurface){",
      "if(!met(req)||!fits(flag||''))continue;const o=at(path);",
      "const add=(names,make)=>{for(const n of (names||'').split(' '))",
      "if(n&&o[n]===undefined&&!absent.has(path+'.'+n))",
      "o[n]=make(path+'.'+n);};",
      "add(fns,(p)=>known[p]||missing(p));add(evs,quiet);add(rules,ruled);",
      "add(classes,klass);}",
      "for(const [path,req,kind,dflt] of apiSettings){if(!met(req))continue;",
      "const parts=path.split('.'),key=parts.pop(),o=at(parts.join('.'));",
      "if(o[key]===undefined)o[key]=kind==='chrome'?setting(dflt):",
      "content(path);}",
      "for(const ns of Object.keys(apiTypes)){",
      "const o=ns.split('.').reduce((v,k)=>v&&v[k],c);",
      "if(o)Object.assign(o,apiTypes[ns]);}",
      "}catch(err){try{console.error('Blinker: the chrome.* surface failed '",
      "+'to install: '+((err&&err.stack)||err));}catch(e2){}}",
      "})();\n",
  });
}

}  // namespace content
