// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_web_request.h"

#include <algorithm>
#include <atomic>
#include <map>
#include <utility>

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/synchronization/lock.h"
#include "base/time/time.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/shell/browser/blinker_extension_api.h"

extern "C" void BlinkBootLog(const char* stage);
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/common/blinker_match_pattern.h"
#include "net/http/http_response_headers.h"
#include "services/network/public/cpp/resource_request.h"

namespace content {

namespace {

namespace bx = blinker_extensions;

// Щоб throttle перевіряв одне relaxed читання, а не лок.
std::atomic<bool> g_any_listener{false};

const char* TypeName(BlinkerResourceType type) {
  switch (type) {
    case BlinkerResourceType::kScript:
      return "script";
    case BlinkerResourceType::kImage:
      return "image";
    case BlinkerResourceType::kStylesheet:
      return "stylesheet";
    case BlinkerResourceType::kObject:
      return "object";
    case BlinkerResourceType::kXmlHttpRequest:
      return "xmlhttprequest";
    case BlinkerResourceType::kSubdocument:
      return "sub_frame";
    case BlinkerResourceType::kPing:
      return "ping";
    case BlinkerResourceType::kMedia:
      return "media";
    case BlinkerResourceType::kFont:
      return "font";
    case BlinkerResourceType::kWebSocket:
      return "websocket";
    case BlinkerResourceType::kDocument:
    case BlinkerResourceType::kPopup:
      return "main_frame";
    case BlinkerResourceType::kOther:
      break;
  }
  return "other";
}

class Registry {
 public:
  static Registry& Get() {
    static base::NoDestructor<Registry> registry;
    return *registry;
  }

  // Воркер після перезапуску реєструє ті самі фільтри знову, тому дублі
  // пропускаємо. Кому з слухачів віддати подію вирішує шім.
  void Add(const BlinkerWebRequestFilter& filter) {
    base::AutoLock lock(lock_);
    std::vector<CompiledFilter>& list =
        filters_[Key(filter.extension_id, filter.event)];
    for (const CompiledFilter& existing : list) {
      if (existing.urls == filter.urls && existing.types == filter.types) {
        return;
      }
    }
    CompiledFilter& compiled = list.emplace_back();
    compiled.extension_id = filter.extension_id;
    compiled.event = filter.event;
    compiled.urls = filter.urls;
    compiled.types = filter.types;
    for (const std::string& pattern : filter.urls) {
      compiled.patterns.AddInclude(pattern);
    }
    g_any_listener.store(true, std::memory_order_relaxed);
  }

  void Remove(std::string_view extension_id, std::string_view event) {
    base::AutoLock lock(lock_);
    if (event.empty()) {
      const std::string prefix = Key(extension_id, "");
      std::erase_if(filters_, [&](const auto& entry) {
        return entry.first.starts_with(prefix);
      });
    } else {
      filters_.erase(Key(extension_id, event));
    }
    g_any_listener.store(!filters_.empty(), std::memory_order_relaxed);
  }

  std::vector<std::string> Matching(const std::string& event,
                                    const GURL& url,
                                    const char* type_name) {
    std::vector<std::string> out;
    const bx::UrlParts parts = BlinkerUrlParts(url);
    base::AutoLock lock(lock_);
    for (const auto& [key, list] : filters_) {
      for (const CompiledFilter& filter : list) {
        if (filter.event == event && Matches(filter, parts, type_name)) {
          out.push_back(filter.extension_id);
          break;
        }
      }
    }
    return out;
  }

 private:
  friend class base::NoDestructor<Registry>;
  Registry() = default;
  ~Registry() = default;

  static std::string Key(std::string_view extension_id,
                         std::string_view event) {
    return base::StrCat({extension_id, "\n", event});
  }

  struct CompiledFilter {
    std::string extension_id;
    std::string event;
    std::vector<std::string> urls;
    std::vector<std::string> types;
    bx::MatchPatternSet patterns;
  };

  static bool Matches(const CompiledFilter& filter,
                      const bx::UrlParts& url,
                      const char* type_name) {
    if (!filter.types.empty() &&
        std::find(filter.types.begin(), filter.types.end(), type_name) ==
            filter.types.end()) {
      return false;
    }
    return filter.urls.empty() ||
           filter.patterns.Matches(url);
  }

  base::Lock lock_;
  std::map<std::string, std::vector<CompiledFilter>> filters_ GUARDED_BY(lock_);
};

base::DictValue BaseDetails(uint64_t request_id,
                            const GURL& url,
                            const std::string& method,
                            const GURL& document_url,
                            BlinkerResourceType type,
                            int tab_id) {
  base::DictValue details;
  details.Set("requestId", base::NumberToString(request_id));
  details.Set("url", url.spec());
  details.Set("method", method.empty() ? "GET" : method);
  // Реєстру фреймів тут нема, тож підресурс належить головному фрейму.
  details.Set("frameId", type == BlinkerResourceType::kSubdocument ? 1 : 0);
  details.Set("parentFrameId", type == BlinkerResourceType::kSubdocument ? 0
                                                                        : -1);
  details.Set("tabId", tab_id);
  details.Set("type", TypeName(type));
  details.Set("timeStamp", base::Time::Now().InMillisecondsFSinceUnixEpoch());
  if (document_url.is_valid()) {
    details.Set("initiator", document_url.DeprecatedGetOriginAsURL().spec());
    details.Set("documentUrl", document_url.spec());
  }
  return details;
}

// Throttle працює на потоці завантаження, а черга подій і реєстр на UI.
void Post(const std::string& event,
          const GURL& url,
          BlinkerResourceType type,
          base::DictValue details) {
  if (!BlinkerWebRequestHasListeners()) {
    // Лог відрізняє порожній реєстр від слухачів що не підійшли.
    if (event == "onBeforeRequest" &&
        std::string_view(TypeName(type)) == "main_frame") {
      BlinkBootLog("WEBREQ: main_frame no registered listeners");
    }
    return;
  }
  const char* type_name = TypeName(type);
  auto deliver = [](std::string event, GURL url, std::string type_name,
                    base::DictValue details) {
    // Менеджери юзерскриптів ловлять .user.js в onBeforeRequest для main_frame,
    // а черга подій воркер не будить. Тому будимо тут, але лише на навігацію.
    const bool is_navigation =
        type_name == "main_frame" || type_name == "sub_frame";
    const bool wakes_worker = is_navigation && event == "onBeforeRequest";
    const std::vector<std::string> matching =
        Registry::Get().Matching(event, url, type_name.c_str());
    if (wakes_worker) {
      BlinkBootLog(base::StrCat({"WEBREQ: main_frame listeners=",
                                 base::NumberToString(matching.size()), " ",
                                 base::JoinString(matching, ",")})
                       .c_str());
    }
    for (const std::string& extension_id : matching) {
      base::ListValue args;
      args.Append(details.Clone());
      BlinkerPostExtensionEvent(extension_id,
                                base::StrCat({"webRequest.", event}),
                                std::move(args));
      if (wakes_worker) {
        BlinkerWakeExtensionWorker(extension_id);
      }
    }
  };
  if (BrowserThread::CurrentlyOn(BrowserThread::UI)) {
    deliver(event, url, type_name, std::move(details));
    return;
  }
  GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(deliver, event, url, std::string(type_name),
                                std::move(details)));
}

base::ListValue HeaderList(const net::HttpResponseHeaders* headers) {
  base::ListValue out;
  if (!headers) {
    return out;
  }
  size_t iter = 0;
  std::string name;
  std::string value;
  while (headers->EnumerateHeaderLines(&iter, &name, &value)) {
    base::DictValue header;
    header.Set("name", name);
    header.Set("value", value);
    out.Append(std::move(header));
  }
  return out;
}

}  // namespace

BlinkerWebRequestFilter::BlinkerWebRequestFilter() = default;
BlinkerWebRequestFilter::BlinkerWebRequestFilter(
    const BlinkerWebRequestFilter&) = default;
BlinkerWebRequestFilter::~BlinkerWebRequestFilter() = default;

void BlinkerWebRequestAddListener(const BlinkerWebRequestFilter& filter) {
  Registry::Get().Add(filter);
}

void BlinkerWebRequestRemoveListeners(std::string_view extension_id,
                                      std::string_view event) {
  Registry::Get().Remove(extension_id, event);
}

bool BlinkerWebRequestHasListeners() {
  return g_any_listener.load(std::memory_order_relaxed);
}

void BlinkerWebRequestNotifyStart(uint64_t request_id,
                                  const network::ResourceRequest& request,
                                  const GURL& document_url,
                                  BlinkerResourceType type,
                                  int tab_id) {
  if (!BlinkerWebRequestHasListeners()) {
    return;
  }
  base::DictValue details = BaseDetails(request_id, request.url,
                                        request.method, document_url, type,
                                        tab_id);
  // Chrome шле заголовки тільки тим хто просив, шім відкидає зайве, а в нас
  // вони і так під рукою.
  base::ListValue headers;
  for (const auto& header : request.headers.GetHeaderVector()) {
    base::DictValue entry;
    entry.Set("name", header.key);
    entry.Set("value", header.value);
    headers.Append(std::move(entry));
  }

  Post("onBeforeRequest", request.url, type, details.Clone());

  base::DictValue with_headers = details.Clone();
  with_headers.Set("requestHeaders", headers.Clone());
  Post("onBeforeSendHeaders", request.url, type, with_headers.Clone());
  Post("onSendHeaders", request.url, type, std::move(with_headers));
}

void BlinkerWebRequestNotifyRedirect(uint64_t request_id,
                                     const GURL& from_url,
                                     const GURL& to_url,
                                     int status_code,
                                     const GURL& document_url,
                                     BlinkerResourceType type,
                                     int tab_id) {
  if (!BlinkerWebRequestHasListeners()) {
    return;
  }
  base::DictValue details =
      BaseDetails(request_id, from_url, "GET", document_url, type, tab_id);
  details.Set("redirectUrl", to_url.spec());
  details.Set("statusCode", status_code);
  details.Set("statusLine",
              base::StrCat({"HTTP/1.1 ", base::NumberToString(status_code)}));
  details.Set("fromCache", false);
  Post("onBeforeRedirect", from_url, type, std::move(details));
}

void BlinkerWebRequestNotifyResponse(uint64_t request_id,
                                     const GURL& url,
                                     const net::HttpResponseHeaders* headers,
                                     const GURL& document_url,
                                     BlinkerResourceType type,
                                     int tab_id,
                                     bool from_cache) {
  if (!BlinkerWebRequestHasListeners()) {
    return;
  }
  base::DictValue details =
      BaseDetails(request_id, url, "GET", document_url, type, tab_id);
  details.Set("statusCode", headers ? headers->response_code() : 0);
  details.Set("statusLine", headers ? headers->GetStatusLine() : std::string());
  details.Set("fromCache", from_cache);
  details.Set("responseHeaders", HeaderList(headers));

  Post("onHeadersReceived", url, type, details.Clone());
  Post("onResponseStarted", url, type, details.Clone());
  // Throttle бачить тільки заголовки відповіді, тож onCompleted приходить
  // раніше тіла. Слухачу важливий результат, а не момент.
  Post("onCompleted", url, type, std::move(details));
}

void BlinkerWebRequestNotifyError(uint64_t request_id,
                                  const GURL& url,
                                  const std::string& error,
                                  const GURL& document_url,
                                  BlinkerResourceType type,
                                  int tab_id) {
  if (!BlinkerWebRequestHasListeners()) {
    return;
  }
  base::DictValue details =
      BaseDetails(request_id, url, "GET", document_url, type, tab_id);
  details.Set("error", error);
  details.Set("fromCache", false);
  Post("onErrorOccurred", url, type, std::move(details));
}

std::string BlinkerWebRequestShim() {
  return
      // Блокувальна відповідь ігнорується, в MV3 блокувального webRequest нема.
      // Браузер шле подію якщо підходить хоч один фільтр, тут кожен бере своє.
      "const wrPattern=(p)=>{if(p==='<all_urls>')return /^(https?|wss?|ftp|"
      "file|data):/;const m=/^(\\*|[a-z-]+):\\/\\/([^/]*)(\\/.*)?$/.exec(p);"
      "if(!m)return null;const esc=(v)=>v.replace(/[.+?^${}()|[\\]\\\\]/g,"
      "'\\\\$&');const scheme=m[1]==='*'?'(https?|wss?)':esc(m[1]);"
      "const hp=/^(.*?)(?::(\\d+|\\*))?$/.exec(m[2]);const h=hp[1];"
      "const host=h==='*'?'[^/]*':h.startsWith('*.')?'([^/]*\\\\.)?'+"
      "esc(h.slice(2)):esc(h);const dp={http:'80',https:'443',ws:'80',"
      "wss:'443',ftp:'21'}[m[1]];"
      "const port=!hp[2]||hp[2]==='*'?'(:\\\\d+)?':hp[2]===dp?"
      "'(:'+dp+')?':':'+hp[2];"
      "const path=esc(m[3]||'/').replace(/\\*/g,'.*');"
      "return new RegExp('^'+scheme+'://'+host+port+path+'$');};"
      "const wrAccepts=(entry,d)=>{const f=entry.filter;"
      "if(f.types&&f.types.length&&f.types.indexOf(d.type)<0)return false;"
      "if(typeof f.tabId==='number'&&f.tabId!==d.tabId)return false;"
      "if(!entry.urls)return true;const url=d.url||'';"
      "return entry.urls.some((r)=>r&&r.test(url));};"
      "const wrEvents={};"
      "const wrEvent=(name)=>{const fns=[];wrEvents[name]=fns;"
      "const stream=event('webRequest.'+name);"
      "let started=false;"
      "return {addListener:(fn,filter,extraInfoSpec)=>{"
      "if(typeof fn!=='function')return;filter=filter||{};"
      "fns.push({fn:fn,filter:filter,urls:Array.isArray(filter.urls)&&"
      "filter.urls.length?filter.urls.map(wrPattern):null});"
      "call({ns:'webRequest',op:'addListener',event:name,"
      "urls:filter.urls||[],types:filter.types||[],"
      "extraHeaders:!!(extraInfoSpec&&extraInfoSpec.indexOf&&"
      "extraInfoSpec.indexOf('extraHeaders')>=0)},null,()=>{});"
      "if(!started){started=true;"
      "stream.addListener((details)=>{for(const entry of fns.slice()){"
      "if(!wrAccepts(entry,details))continue;"
      "try{entry.fn(details);}catch(e){}}});}},"
      "removeListener:(fn)=>{const i=fns.findIndex((e)=>e.fn===fn);"
      "if(i>=0)fns.splice(i,1);"
      "if(!fns.length)call({ns:'webRequest',op:'removeListener',event:name},"
      "null,()=>{});},"
      "hasListener:(fn)=>fns.some((e)=>e.fn===fn),"
      "hasListeners:()=>fns.length>0};};"

      "c.webRequest={"
      "onBeforeRequest:wrEvent('onBeforeRequest'),"
      "onBeforeSendHeaders:wrEvent('onBeforeSendHeaders'),"
      "onSendHeaders:wrEvent('onSendHeaders'),"
      "onHeadersReceived:wrEvent('onHeadersReceived'),"
      "onResponseStarted:wrEvent('onResponseStarted'),"
      "onBeforeRedirect:wrEvent('onBeforeRedirect'),"
      "onCompleted:wrEvent('onCompleted'),"
      "onErrorOccurred:wrEvent('onErrorOccurred'),"
      "onAuthRequired:wrEvent('onAuthRequired'),"
      // Скрипт воркера читає їх ще під час виконання.
      "OnBeforeRequestOptions:{BLOCKING:'blocking',"
      "REQUEST_BODY:'requestBody',EXTRA_HEADERS:'extraHeaders'},"
      "OnBeforeSendHeadersOptions:{REQUEST_HEADERS:'requestHeaders',"
      "BLOCKING:'blocking',EXTRA_HEADERS:'extraHeaders'},"
      "OnSendHeadersOptions:{REQUEST_HEADERS:'requestHeaders',"
      "EXTRA_HEADERS:'extraHeaders'},"
      "OnHeadersReceivedOptions:{BLOCKING:'blocking',"
      "RESPONSE_HEADERS:'responseHeaders',EXTRA_HEADERS:'extraHeaders'},"
      "OnResponseStartedOptions:{RESPONSE_HEADERS:'responseHeaders',"
      "EXTRA_HEADERS:'extraHeaders'},"
      "OnCompletedOptions:{RESPONSE_HEADERS:'responseHeaders',"
      "EXTRA_HEADERS:'extraHeaders'},"
      "OnAuthRequiredOptions:{RESPONSE_HEADERS:'responseHeaders',"
      "BLOCKING:'blocking',ASYNC_BLOCKING:'asyncBlocking',"
      "EXTRA_HEADERS:'extraHeaders'},"
      "ResourceType:{MAIN_FRAME:'main_frame',SUB_FRAME:'sub_frame',"
      "STYLESHEET:'stylesheet',SCRIPT:'script',IMAGE:'image',FONT:'font',"
      "OBJECT:'object',XMLHTTPREQUEST:'xmlhttprequest',PING:'ping',"
      "MEDIA:'media',WEBSOCKET:'websocket',OTHER:'other'},"
      "MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES:20,"
      "handlerBehaviorChanged:(cb)=>{if(cb)cb();"
      "return Promise.resolve();}};";
}

}  // namespace content
