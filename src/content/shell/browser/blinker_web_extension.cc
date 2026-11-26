// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_web_extension.h"

#include <algorithm>
#include <initializer_list>
#include <map>
#include <utility>

#include "base/containers/adapters.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/hash/hash.h"
#include "base/no_destructor.h"
#include "base/i18n/rtl.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/path_service.h"
#include "base/task/thread_pool.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "build/build_config.h"
#include "base/functional/bind.h"
#include "base/strings/strcat.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/console_message.h"
#include "content/public/browser/service_worker_context.h"
#include "content/public/browser/service_worker_context_observer.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/mojom/cors_origin_pattern.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "content/public/browser/shared_cors_origin_access_list.h"
#include "third_party/blink/public/common/service_worker/service_worker_status_code.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "third_party/blink/public/mojom/service_worker/service_worker_registration_options.mojom.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/blinker_crx_installer.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_extension_messaging.h"
#include "content/shell/browser/blinker_extension_net_actions.h"
#include "content/shell/browser/blinker_extension_storage.h"
#include "content/shell/common/blinker_dnr_rule.h"
#include "content/shell/common/blinker_extension_l10n.h"
#include "content/shell/common/shell_paths.h"
#include "third_party/zlib/google/zip.h"
#include "content/shell/common/blinker_match_pattern.h"
#include "url/origin.h"
#include "url/url_constants.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>

#include "base/strings/sys_string_conversions.h"

extern "C" const char* BlinkDocumentsDir();
#endif
// На відміну від BLINKER_DIAGF пише і в релізі, а на телефоні тільки реліз
// і запускається
extern "C" void BlinkBootLog(const char* stage);

namespace content {

namespace {

namespace bx = blinker_extensions;

const std::string& BrowserBuildVersion() {
  static const base::NoDestructor<std::string> version([] {
#if BUILDFLAG(IS_IOS)
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(
        CFBundleGetMainBundle(), CFSTR("CFBundleShortVersionString"));
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
      return base::SysCFStringRefToUTF8(static_cast<CFStringRef>(value));
    }
#endif
    return std::string();
  }());
  return *version;
}

// CONTENT_END + 2 і + 3 вже зайняті зумом і косметичним фільтром
constexpr int32_t kFirstExtensionWorldId = ISOLATED_WORLD_ID_CONTENT_END + 4;
// Другий світ USER_SCRIPT, щоб юзерскрипт не діставав chrome.* розширення
constexpr int32_t kWorldsPerExtension = 2;
constexpr size_t kMaxExtensions = static_cast<size_t>(
    (ISOLATED_WORLD_ID_MAX - kFirstExtensionWorldId) / kWorldsPerExtension);

constexpr int64_t kMaxScriptFileBytes = 4 * 1024 * 1024;

// Shimeji (Chrome Web Store) спавнить персонажів лише у вкладці, з якої
// натиснули Spawn, і пам'ятає їх тільки для неї. Щоб при увімкненому
// розширенні вони були на кожній вкладці, включно зі стартовою, після його
// content script у кожну сторінку йде цей маленький скрипт. Він чекає, поки
// розширення готове, і якщо у вкладці персонажів нема, шле йому ті самі
// повідомлення, що шле його попап. Нічого не чіпає, якщо розширення вимкнене,
// переключатель ON/OFF стоїть в OFF або персонажів ще не додано.
constexpr char kShimejiExtensionId[] = "gohjpllcolmccldfdggmamodembldgpc";
// Shimeji тягне і кидає персонажів мишею: mousedown на персонажі, через 200 мс
// він іде за mousemove, а швидкість кидка береться з останніх трьох mousemove.
// Палець дає touch-події і скрол, миші немає, тож персонажів не зрушити, а
// довге утримання тільки викликає меню. Цей скрипт перекладає дотик на
// персонажа в ті самі події миші. Рух далі за 8 пікселів це перетягування,
// утримання на місці 450 мс це контекстне меню (розширення відкриває його лише
// після швидкого натискання і відпускання перед contextmenu, як це робить
// довге натискання в Blink), короткий дотик це клік.
constexpr char kShimejiTouchJs[] =
    "(()=>{try{if(window.__bfTouch)return;window.__bfTouch=1;"
    "const isSprite=(el)=>!!el&&typeof el.id==='string'&&"
    "/^shimeji-[0-9]+$/.test(el.id);"
    "const fire=(type,el,x,y,button,buttons)=>(el||document).dispatchEvent("
    "new MouseEvent(type,{bubbles:true,cancelable:true,view:window,clientX:x,"
    "clientY:y,screenX:x,screenY:y,button:button,buttons:buttons}));"
    "const SLOP=8,HOLD=450,MIN_DRAG=240;let st=null;"
    "document.addEventListener('touchstart',(e)=>{"
    "if(st||e.touches.length!==1||!isSprite(e.target))return;"
    "const t=e.touches[0];e.preventDefault();"
    "st={el:e.target,x0:t.clientX,y0:t.clientY,x:t.clientX,y:t.clientY,"
    "id:t.identifier,phase:'wait',downAt:0,timer:0};"
    "const s=st;s.timer=setTimeout(()=>{if(st===s&&s.phase==='wait'){"
    "s.phase='menu';fire('mousedown',s.el,s.x,s.y,2,2);"
    "fire('mouseup',s.el,s.x,s.y,2,0);"
    "fire('contextmenu',s.el,s.x,s.y,2,2);}},HOLD);"
    "},{passive:false,capture:true});"
    "document.addEventListener('touchmove',(e)=>{"
    "if(!st)return;const t=Array.prototype.find.call(e.touches,"
    "(x)=>x.identifier===st.id);if(!t)return;e.preventDefault();"
    "st.x=t.clientX;st.y=t.clientY;"
    "if(st.phase==='wait'&&Math.hypot(st.x-st.x0,st.y-st.y0)>SLOP){"
    "clearTimeout(st.timer);st.phase='drag';st.downAt=Date.now();"
    "fire('mousedown',st.el,st.x0,st.y0,0,1);}"
    "if(st.phase==='drag')fire('mousemove',document,st.x,st.y,0,1);"
    "},{passive:false,capture:true});"
    "const finish=(e)=>{if(!st)return;const s=st;st=null;"
    "if(e.cancelable)e.preventDefault();clearTimeout(s.timer);"
    "if(s.phase==='wait'){fire('mousedown',s.el,s.x,s.y,0,1);"
    "fire('mouseup',s.el,s.x,s.y,0,0);return;}"
    "if(s.phase==='drag'){setTimeout(()=>fire('mouseup',s.el,s.x,s.y,0,0),"
    "Math.max(0,MIN_DRAG-(Date.now()-s.downAt)));}};"
    "document.addEventListener('touchend',finish,{passive:false,capture:true});"
    "document.addEventListener('touchcancel',finish,"
    "{passive:false,capture:true});"
    "}catch(e){}})();";

constexpr char kShimejiEverywhereJs[] =
    "(()=>{try{const c=globalThis.chrome;"
    "if(!c||!c.runtime||!c.runtime.__blinkerDeliverLocal||!c.storage||"
    "window.__bfSeeder)return;window.__bfSeeder=1;"
    "const L=c.runtime.__blinkerDeliverLocal;let spawned=0,was=true;"
    "c.runtime.onMessage.addListener((m)=>{"
    "if(m&&m.type==='callAnotherShimeji')spawned=Date.now();});"
    "const get=(k)=>c.storage.local.get(k).then("
    "(o)=>o&&o[k]?JSON.parse(o[k]):undefined);"
    "const ready=()=>new Promise((res)=>{const t=(i)=>L("
    "{type:'isConnected'},(r)=>{if(r&&r.noReceiver){"
    "if(i<40)setTimeout(()=>t(i+1),250);else res(false);}else res(true);});"
    "t(0);});"
    "const tab=()=>new Promise((res)=>{try{c.runtime.sendMessage("
    "{type:'getTabId'},(r)=>res(r&&r.success?r.result:null));}"
    "catch(e){res(null);}});"
    "const seed=async(again)=>{if(!await ready())return;"
    "const[st,specs,last,id]=await Promise.all("
    "[get('settings'),get('specs'),get('lastTabState'),tab()]);"
    "if((st&&st.active===false)||!specs||!specs.length)return;"
    "if(!again&&last&&last.tabId===id&&last.shimejis&&last.shimejis.length)"
    "return;"
    "if(again&&Date.now()-spawned<3000)return;"
    "specs.forEach((s,i)=>setTimeout(()=>L({type:'callAnotherShimeji',"
    "specId:s.id},()=>{}),i*400));};"
    "get('settings').then((s)=>{was=!(s&&s.active===false);});"
    "seed(false);"
    "c.storage.onChanged.addListener((ch,area)=>{"
    "if(area!=='local'||!ch.settings)return;try{"
    "const n=JSON.parse(ch.settings.newValue||'{}');"
    "const now=n.active!==false;"
    "if(now&&!was)setTimeout(()=>seed(true),1500);was=now;}catch(e){}});"
    "}catch(e){}})();";
constexpr size_t kMaxScriptBytesPerExtension = 16 * 1024 * 1024;
constexpr int64_t kMaxRulesetFileBytes = 8 * 1024 * 1024;
// Стандартні набори uBO Lite це близько 120 тисяч рядків, ліміт з запасом
constexpr size_t kMaxRulesPerExtension = 200000;

void ExtLog(const std::string& line) {
  BlinkBootLog(line.c_str());
}

void LocalizeManifestStrings(base::Value* value,
                             const bx::L10nMessages& messages) {
  if (value->is_dict()) {
    for (auto entry : value->GetDict()) {
      LocalizeManifestStrings(&entry.second, messages);
    }
    return;
  }
  if (value->is_list()) {
    for (base::Value& entry : value->GetList()) {
      LocalizeManifestStrings(&entry, messages);
    }
    return;
  }
  if (!value->is_string() ||
      value->GetString().find(bx::kMessageBegin) == std::string::npos) {
    return;
  }
  std::string text = value->GetString();
  bx::ReplaceMessages(messages, &text);
  *value = base::Value(std::move(text));
}

std::string ReadBoundedFile(const base::FilePath& path, int64_t max_bytes) {
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents, max_bytes)) {
    return std::string();
  }
  return contents;
}

// Файлова система iOS розрізняє регістр, а розширення пишуть і "en_US",
// і "en_us", і "en-US"
std::map<std::string, base::FilePath> LocaleDirectories(
    const base::FilePath& extension_dir) {
  std::map<std::string, base::FilePath> out;
  base::FileEnumerator enumerator(extension_dir.AppendASCII("_locales"),
                                  /*recursive=*/false,
                                  base::FileEnumerator::DIRECTORIES);
  for (base::FilePath path = enumerator.Next(); !path.empty();
       path = enumerator.Next()) {
    std::string name = base::ToLowerASCII(path.BaseName().AsUTF8Unsafe());
    std::replace(name.begin(), name.end(), '-', '_');
    out.emplace(std::move(name), path);
  }
  return out;
}

bx::L10nMessages LoadMessages(const base::FilePath& extension_dir,
                              const std::string& extension_id,
                              const std::string& default_locale) {
  const std::string app_locale =
      bx::AppLocaleFromConfigured(base::i18n::GetConfiguredLocale());
  bx::L10nMessages messages;
  if (!default_locale.empty()) {
    const std::map<std::string, base::FilePath> directories =
        LocaleDirectories(extension_dir);
    const std::vector<std::string> locales =
        bx::FallbackLocales(app_locale, default_locale);
    // Від найзагальнішого каталогу, щоб точніший перекривав його ключі
    for (const std::string& locale : base::Reversed(locales)) {
      const auto directory = directories.find(base::ToLowerASCII(locale));
      if (directory == directories.end()) {
        continue;
      }
      std::optional<base::Value> catalog = base::JSONReader::Read(
          ReadBoundedFile(directory->second.AppendASCII("messages.json"),
                          kMaxScriptFileBytes),
          base::JSON_PARSE_CHROMIUM_EXTENSIONS);
      if (!catalog || !catalog->is_dict()) {
        continue;
      }
      for (const auto [name, entry] : catalog->GetDict()) {
        const base::DictValue* dict = entry.GetIfDict();
        const std::string* message =
            dict ? dict->FindString("message") : nullptr;
        if (!message || !bx::IsValidMessageName(name)) {
          continue;
        }
        bx::L10nMessages placeholders;
        if (const base::DictValue* list = dict->FindDict("placeholders")) {
          for (const auto [placeholder, value] : *list) {
            const std::string* content =
                value.is_dict() ? value.GetDict().FindString("content")
                                : nullptr;
            if (content) {
              placeholders[base::ToLowerASCII(placeholder)] = *content;
            }
          }
        }
        std::string text = *message;
        bx::ReplaceVariables(placeholders, "$", "$", &text);
        messages[base::ToLowerASCII(name)] = std::move(text);
      }
    }
  }
  const bool rtl = base::i18n::GetTextDirectionForLocale(app_locale.c_str()) ==
                   base::i18n::RIGHT_TO_LEFT;
  messages["@@extension_id"] = extension_id;
  messages["@@ui_locale"] = app_locale;
  messages["@@bidi_dir"] = rtl ? "rtl" : "ltr";
  messages["@@bidi_reversed_dir"] = rtl ? "ltr" : "rtl";
  messages["@@bidi_start_edge"] = rtl ? "right" : "left";
  messages["@@bidi_end_edge"] = rtl ? "left" : "right";
  return messages;
}

std::string MessagesJson(const bx::L10nMessages& messages) {
  base::DictValue dict;
  for (const auto& [name, message] : messages) {
    dict.Set(name, message);
  }
  return base::WriteJson(dict).value_or("{}");
}

// Маніфест це чужі дані, без перевірки можна прочитати
// "../../../../var/mobile/Library/..."
bool ResolveExtensionPath(const base::FilePath& root,
                          std::string_view relative,
                          base::FilePath* out) {
  if (!relative.empty() && relative.front() == '/') {
    relative.remove_prefix(1);
  }
  if (relative.empty() || relative.front() == '/' ||
      relative.find("..") != std::string_view::npos) {
    return false;
  }
  base::FilePath candidate = root.Append(base::FilePath(std::string(relative)));
  // Ще раз перевіряємо вкладеність, щоб дивний компонент не вивів назовні
  if (!root.IsParent(candidate)) {
    return false;
  }
  *out = std::move(candidate);
  return true;
}

BlinkerContentScript::RunAt RunAtFromString(std::string_view value) {
  if (value == "document_start") {
    return BlinkerContentScript::RunAt::kDocumentStart;
  }
  if (value == "document_end") {
    return BlinkerContentScript::RunAt::kDocumentEnd;
  }
  return BlinkerContentScript::RunAt::kDocumentIdle;
}

std::vector<std::string> FilterLinesFromRuleValue(const base::DictValue& rule) {
  bx::DnrRule parsed;
  const base::DictValue* action = rule.FindDict("action");
  const base::DictValue* condition = rule.FindDict("condition");
  if (!action || !condition) {
    return {};
  }
  const std::string* type = action->FindString("type");
  if (!type) {
    return {};
  }
  if (*type == "block") {
    parsed.action = bx::DnrRule::Action::kBlock;
  } else if (*type == "allow") {
    parsed.action = bx::DnrRule::Action::kAllow;
  } else if (*type == "allowAllRequests") {
    parsed.action = bx::DnrRule::Action::kAllowAllRequests;
  } else {
    return {};
  }

  if (const std::string* regex = condition->FindString("regexFilter")) {
    parsed.is_regex = true;
    parsed.url_filter = *regex;
  }
  if (const std::string* url_filter = condition->FindString("urlFilter")) {
    parsed.url_filter = *url_filter;
  }
  parsed.case_sensitive =
      condition->FindBool("isUrlFilterCaseSensitive").value_or(false);
  if (const std::string* domain_type = condition->FindString("domainType")) {
    parsed.domain_type = *domain_type;
  }

  auto collect = [&condition](const char* key, std::vector<std::string>* out,
                              bool* bad) {
    const base::ListValue* list = condition->FindList(key);
    if (!list) {
      return;
    }
    for (const base::Value& entry : *list) {
      const std::string* s = entry.GetIfString();
      if (!s) {
        *bad = true;
        return;
      }
      out->push_back(*s);
    }
  };
  bool bad = false;
  collect("resourceTypes", &parsed.resource_types, &bad);
  collect("excludedResourceTypes", &parsed.excluded_resource_types, &bad);
  // MV3 перейменував ці поля, приймаємо обидва
  collect("initiatorDomains", &parsed.initiator_domains, &bad);
  collect("domains", &parsed.initiator_domains, &bad);
  collect("excludedInitiatorDomains", &parsed.excluded_initiator_domains, &bad);
  collect("excludedDomains", &parsed.excluded_initiator_domains, &bad);
  // Сторінка верхнього рівня. Ініціатор запиту це майже завжди вона, тож
  // беремо його. Privacy Badger цим виключає сайт трекера з його ж блокування
  collect("topDomains", &parsed.initiator_domains, &bad);
  collect("excludedTopDomains", &parsed.excluded_initiator_domains, &bad);
  collect("requestDomains", &parsed.request_domains, &bad);
  collect("excludedRequestDomains", &parsed.excluded_request_domains, &bad);
  if (bad) {
    return {};
  }
  return bx::DnrRuleToFilterLines(parsed);
}

std::string BuildChromeShim(const BlinkerWebExtension& extension,
                            bool privileged) {
  return base::StrCat({
      BlinkerExtensionBaseShim(extension),
      BlinkerExtensionStorageShim(extension.id, extension.messaging_token),
      privileged ? BlinkerExtensionPrivilegedApiShim(extension.id,
                                                     extension.messaging_token)
                 : std::string(),
      privileged ? BlinkerExtensionPageMessagingShim(extension.id)
                 : BlinkerExtensionContentMessagingShim(
                       extension.id, extension.messaging_token),
      privileged ? BlinkerExtensionApiSurfaceShim() : std::string(),
  });
}

BlinkerScriptText MakeScriptText(std::string text) {
  return base::MakeRefCounted<base::RefCountedString>(std::move(text));
}

template <typename Add>
void AddStrings(const base::ListValue* list, Add&& add) {
  if (!list) {
    return;
  }
  for (const base::Value& entry : *list) {
    if (const std::string* value = entry.GetIfString()) {
      add(*value);
    }
  }
}

const GURL& EffectiveUrlForScript(const BlinkerContentScript& script,
                                  const BlinkerFrameUrls& frame) {
  const GURL& document = frame.document;
  const bool is_about = document.SchemeIs(url::kAboutScheme);
  if (script.match_origin_as_fallback &&
      (is_about || document.SchemeIs(url::kDataScheme) ||
       document.SchemeIsBlob() || document.SchemeIsFileSystem())) {
    return frame.origin;
  }
  if (script.match_about_blank && is_about) {
    return frame.about_parent;
  }
  return document;
}

bool IsInjectableUrl(const GURL& url) {
  return url.is_valid() && (url.SchemeIsHTTPOrHTTPS() || url.SchemeIsFile());
}

bool IsHostPattern(std::string_view value) {
  return value == "<all_urls>" || value.find("://") != std::string_view::npos;
}

bool Contains(const std::vector<std::string>& list, std::string_view value) {
  return std::find(list.begin(), list.end(), value) != list.end();
}

bx::MatchPatternSet HostPermissionSet(
    std::initializer_list<const std::vector<std::string>*> lists) {
  bx::MatchPatternSet set;
  for (const std::vector<std::string>* list : lists) {
    for (const std::string& value : *list) {
      if (IsHostPattern(value)) {
        set.AddHostPermission(value);
      }
    }
  }
  return set;
}

struct UnpackedPermissions {
  std::vector<std::string> required_apis;
  std::vector<std::string> optional_apis;
  std::vector<std::string> unlisted_apis;
  std::vector<bx::MatchPattern> required_hosts;
  std::vector<bx::MatchPattern> optional_hosts;
  std::vector<bx::MatchPattern> scriptable_hosts;
  std::vector<bx::MatchPattern> unlisted_hosts;
  std::vector<std::string> optional_host_strings;
};

std::string UnpackPermissions(const BlinkerWebExtension& extension,
                              const std::vector<std::string>& apis,
                              const std::vector<std::string>& origins,
                              UnpackedPermissions* out) {
  for (const std::string& api : apis) {
    if (Contains(extension.permissions, api)) {
      out->required_apis.push_back(api);
    } else if (Contains(extension.optional_permissions, api)) {
      out->optional_apis.push_back(api);
    } else {
      out->unlisted_apis.push_back(api);
    }
  }
  const bx::MatchPatternSet required =
      HostPermissionSet({&extension.host_permissions});
  const bx::MatchPatternSet optional =
      HostPermissionSet({&extension.optional_host_permissions});
  for (const std::string& origin : origins) {
    bx::MatchPattern pattern;
    if (!pattern.Parse(origin)) {
      return base::StrCat({"Invalid value for origin pattern ", origin, ": ",
                           pattern.parse_error()});
    }
    bool listed = false;
    if (required.ContainsPattern(pattern)) {
      listed = true;
      out->required_hosts.push_back(pattern);
    } else if (optional.ContainsPattern(pattern)) {
      listed = true;
      out->optional_hosts.push_back(pattern);
      out->optional_host_strings.push_back(origin);
    }
    for (const BlinkerContentScript& script : extension.content_scripts) {
      if (script.matches.patterns().ContainsPattern(pattern)) {
        listed = true;
        out->scriptable_hosts.push_back(pattern);
        break;
      }
    }
    if (!listed) {
      out->unlisted_hosts.push_back(pattern);
    }
  }
  return std::string();
}

constexpr char kNotInManifestPermissionsError[] =
    "Only permissions specified in the manifest may be requested.";

BlinkerScriptText ExtensionPageShim(const BlinkerWebExtension& extension) {
  if (!extension.page_shim_cache) {
    extension.page_shim_cache =
        MakeScriptText(BuildChromeShim(extension, /*privileged=*/true));
  }
  return extension.page_shim_cache;
}

}  // namespace

BlinkerScriptText BlinkerExtensionContentScriptShim(
    const BlinkerWebExtension& extension) {
  if (!extension.content_shim_cache) {
    extension.content_shim_cache =
        MakeScriptText(BuildChromeShim(extension, /*privileged=*/false));
  }
  return extension.content_shim_cache;
}

std::string BlinkerExtensionBaseShim(const BlinkerWebExtension& extension) {
  std::string id_json;
  base::EscapeJSONString(extension.id, /*put_in_quotes=*/true, &id_json);
  const std::string manifest_json =
      base::WriteJson(extension.manifest).value_or("{}");
  const std::string messages_json = MessagesJson(extension.messages);
  std::string locale_json;
  base::EscapeJSONString(base::i18n::GetConfiguredLocale(), true,
                         &locale_json);
  return base::StrCat({
      "(()=>{const ID=", id_json, ";",
      "if(typeof globalThis.chrome==='undefined')globalThis.chrome={};",
      "const c=globalThis.chrome;",
      "if(c.runtime&&c.runtime.__blinkerBase)return;",
      "c.runtime=c.runtime||{};c.runtime.__blinkerBase=true;c.runtime.id=ID;",
      "c.runtime.getURL=(p)=>'", kBlinkerExtensionScheme,
      "://'+ID+'/'+String(p||'').replace(/^\\//,'');",
      "const MANIFEST=", manifest_json, ";",
      "c.runtime.getManifest=()=>JSON.parse(JSON.stringify(MANIFEST));",
      "c.runtime.lastError=undefined;",
      // У PlatformOs нема iOS. mac найближчий (та сама Cmd і шрифти), а
      // невідоме
      // значення лишило б розширення без гілки
      "c.runtime.getPlatformInfo=(cb)=>{const info={os:'mac',arch:'arm64',",
      "nacl_arch:'arm'};if(cb){cb(info);return;}return Promise.resolve(info);};",
      "c.runtime.PlatformOs={MAC:'mac',WIN:'win',ANDROID:'android',",
      "CROS:'cros',LINUX:'linux',OPENBSD:'openbsd'};",
      "c.runtime.PlatformArch={ARM:'arm',ARM64:'arm64',X86_32:'x86-32',",
      "X86_64:'x86-64',MIPS:'mips',MIPS64:'mips64',RISCV64:'riscv64'};",
      "c.runtime.PlatformNaclArch={ARM:'arm',X86_32:'x86-32',",
      "X86_64:'x86-64',MIPS:'mips',MIPS64:'mips64'};",
      "c.runtime.RequestUpdateCheckStatus={THROTTLED:'throttled',",
      "NO_UPDATE:'no_update',UPDATE_AVAILABLE:'update_available'};",
      "c.runtime.OnInstalledReason={INSTALL:'install',UPDATE:'update',",
      "CHROME_UPDATE:'chrome_update',",
      "SHARED_MODULE_UPDATE:'shared_module_update'};",
      "c.runtime.OnRestartRequiredReason={APP_UPDATE:'app_update',",
      "OS_UPDATE:'os_update',PERIODIC:'periodic'};",
      "c.runtime.ContextType={TAB:'TAB',POPUP:'POPUP',",
      "BACKGROUND:'BACKGROUND',OFFSCREEN_DOCUMENT:'OFFSCREEN_DOCUMENT',",
      "SIDE_PANEL:'SIDE_PANEL',DEVELOPER_TOOLS:'DEVELOPER_TOOLS'};",
      "c.runtime.reload=()=>{};c.runtime.setUninstallURL=(u,cb)=>{if(cb)cb();",
      "return Promise.resolve();};",
      "c.runtime.openOptionsPage=(cb)=>{const p=MANIFEST.options_page||",
      "(MANIFEST.options_ui&&MANIFEST.options_ui.page);",
      "if(p&&c.tabs&&c.tabs.create)c.tabs.create({url:c.runtime.getURL(p)});",
      "if(cb)cb();return Promise.resolve();};",

      "const MESSAGES=", messages_json, ";",
      "c.i18n={getUILanguage:()=>", locale_json, ",",
      "getAcceptLanguages:(cb)=>{const l=[", locale_json, "];if(cb){cb(l);",
      "return;}return Promise.resolve(l);},",
      "detectLanguage:(t,cb)=>{const r={isReliable:false,languages:[]};",
      "if(cb){cb(r);return;}return Promise.resolve(r);},",
      "getMessage:(name,subs,options)=>{const key=String(name).toLowerCase();",
      "let m=Object.prototype.hasOwnProperty.call(MESSAGES,key)?",
      "MESSAGES[key]:'';const list=[];",
      "if(Array.isArray(subs)){if(subs.length>9)return undefined;",
      "for(const v of subs){try{list.push(String(v));}catch(e){}}}",
      "else if(typeof subs==='string'){list.push(subs);}",
      "if(options&&typeof options==='object'&&options.escapeLt===true)",
      "m=m.replace(/</g,'&lt;');",
      "let out='';for(let i=0;i<m.length;i++){const ch=m[i];",
      "if(ch!=='$'){out+=ch;continue;}if(i+1>=m.length)break;const n=m[++i];",
      "if(n==='$'){do{out+='$';i++;}while(i<m.length&&m[i]==='$');i--;}",
      "else if(n>='1'&&n<='9'&&list[n.charCodeAt(0)-49]!==undefined)",
      "out+=list[n.charCodeAt(0)-49];}",
      "return out;}};",
      "c.extension=c.extension||{};",
      "c.extension.getURL=c.extension.getURL||c.runtime.getURL;",
      "if(c.extension.inIncognitoContext===undefined)",
      "c.extension.inIncognitoContext=false;",
      // true, бо content script тут справді працює на file://
      "c.extension.isAllowedFileSchemeAccess=",
      "c.extension.isAllowedFileSchemeAccess||((cb)=>{if(cb){cb(true);return;}",
      "return Promise.resolve(true);});",
      "c.extension.isAllowedIncognitoAccess=",
      "c.extension.isAllowedIncognitoAccess||((cb)=>{if(cb){cb(false);return;}",
      "return Promise.resolve(false);});",
      "c.extension.getBackgroundPage=c.extension.getBackgroundPage||(()=>null);",
      "c.extension.getViews=c.extension.getViews||(()=>[]);",
      // Закритий shadow root без нативного хука не дістати, тож як у сторінки
      "c.dom=c.dom||{openOrClosedShadowRoot:(el)=>(el&&el.shadowRoot)||null};",
      "if(!globalThis.browser)globalThis.browser=c;",
      "})();\n",
  });
}

std::string BlinkerLocalizeCss(const BlinkerWebExtension& extension,
                               std::string css) {
  bx::ReplaceMessages(extension.messages, &css);
  return css;
}

bool BlinkerReadExtensionFile(const BlinkerWebExtension& extension,
                              std::string_view relative,
                              std::string* contents) {
  std::string name(relative);
  if (!name.empty() && name.front() == '/') {
    name.erase(name.begin());
  }
  base::FilePath resolved;
  if (!ResolveExtensionPath(extension.root, name, &resolved)) {
    return false;
  }
  return base::ReadFileToStringWithMaxSize(resolved, contents,
                                           kMaxScriptFileBytes);
}

std::vector<base::FilePath> BlinkerExtensionDirectories() {
  std::vector<base::FilePath> dirs;
#if BUILDFLAG(IS_IOS)
  // Спершу свої Documents. У пісочниці спільний шлях може пройти stat на
  // старті, а потім не відкритись
  if (const char* dir = BlinkDocumentsDir()) {
    const base::FilePath sandboxed =
        base::FilePath(dir).Append("BlinkerExtensions");
    if (base::DirectoryExists(sandboxed)) {
      dirs.push_back(sandboxed);
    }
  }
  const base::FilePath shared("/var/mobile/Documents/BlinkerExtensions");
  if (base::DirectoryExists(shared) &&
      (dirs.empty() || dirs.front() != shared)) {
    dirs.push_back(shared);
  }
#endif
  return dirs;
}

base::FilePath BlinkerExtensionsDirectory() {
  const std::vector<base::FilePath> dirs = BlinkerExtensionDirectories();
  return dirs.empty() ? base::FilePath() : dirs.front();
}

base::FilePath BlinkerEnsureExtensionsDirectory() {
  base::FilePath dir = BlinkerExtensionsDirectory();
  if (!dir.empty()) {
    return dir;
  }
#if BUILDFLAG(IS_IOS)
  if (const char* documents = BlinkDocumentsDir()) {
    dir = base::FilePath(documents).Append("BlinkerExtensions");
    if (base::CreateDirectory(dir)) {
      return dir;
    }
  }
#endif
  return base::FilePath();
}

namespace {
base::FilePath StateFile(std::string_view extension_id);
}  // namespace

GURL BlinkerNewTabOverrideURL() {
  const auto& extensions =
      BlinkerWebExtensionRegistry::GetInstance().extensions();
  for (auto it = extensions.rbegin(); it != extensions.rend(); ++it) {
    const BlinkerWebExtension& extension = **it;
    const base::DictValue* overrides =
        extension.manifest.FindDict("chrome_url_overrides");
    const std::string* page =
        overrides ? overrides->FindString("newtab") : nullptr;
    if (!extension.enabled || !page || page->empty()) {
      continue;
    }
    std::string_view relative = *page;
    while (relative.starts_with('/')) {
      relative.remove_prefix(1);
    }
    GURL url(base::StrCat(
        {kBlinkerExtensionScheme, "://", extension.id, "/", relative}));
    if (url.is_valid()) {
      return url;
    }
  }
  return GURL();
}

std::string BlinkerExtensionSearchURL(std::string_view terms) {
  const auto& extensions =
      BlinkerWebExtensionRegistry::GetInstance().extensions();
  for (auto it = extensions.rbegin(); it != extensions.rend(); ++it) {
    const BlinkerWebExtension& extension = **it;
    const base::DictValue* settings =
        extension.manifest.FindDict("chrome_settings_overrides");
    const base::DictValue* provider =
        settings ? settings->FindDict("search_provider") : nullptr;
    const std::string* search_url =
        provider ? provider->FindString("search_url") : nullptr;
    if (!extension.enabled || !search_url ||
        !provider->FindBool("is_default").value_or(false)) {
      continue;
    }
    std::string url = *search_url;
    base::ReplaceSubstringsAfterOffset(
        &url, 0, "{searchTerms}",
        base::EscapeQueryParamValue(std::string(terms), /*use_plus=*/true));
    if (GURL(url).SchemeIsHTTPOrHTTPS()) {
      return url;
    }
  }
  return std::string();
}

void BlinkerRemoveExtension(std::string_view id) {
  // id це ім'я теки, все що може вийти за неї відкидаємо, а не чистимо
  const std::string name(id);
  if (name.empty() || name == "." || name == ".." ||
      name.find('/') != std::string::npos ||
      name.find('\\') != std::string::npos) {
    return;
  }
  BlinkerWebExtensionRegistry::GetInstance().SetEnabled(id, false);
  for (const base::FilePath& dir : BlinkerExtensionDirectories()) {
    const base::FilePath path = dir.Append(name);
    if (base::DirectoryExists(path)) {
      base::DeletePathRecursively(path);
    }
    // Інакше запакована копія встановиться знову при наступному скані
    base::DeleteFile(dir.Append(name + ".crx"));
    base::DeleteFile(dir.Append(name + ".crx.installed"));
  }
  // Стан теж видаляємо, щоб перевстановлення почалось з чистого і з новим
  // токеном
  const base::FilePath state = StateFile(name);
  if (!state.empty()) {
    base::DeleteFile(state);
  }
  BlinkerWebExtensionRegistry::GetInstance().LoadAll();
}

bx::UrlParts BlinkerUrlParts(const GURL& url) {
  bx::UrlParts parts;
  if (!url.is_valid()) {
    return parts;
  }
  parts.scheme = url.scheme();
  parts.host = url.host();
  parts.port = url.EffectiveIntPort();
  if (!url.path().empty()) {
    parts.path = url.PathForRequestPiece();
  }
  parts.spec = url.spec();
  return parts;
}

BlinkerContentScript::BlinkerContentScript() = default;
BlinkerContentScript::BlinkerContentScript(const BlinkerContentScript&) =
    default;
BlinkerContentScript& BlinkerContentScript::operator=(
    const BlinkerContentScript&) = default;
BlinkerContentScript::BlinkerContentScript(BlinkerContentScript&&) = default;
BlinkerContentScript& BlinkerContentScript::operator=(BlinkerContentScript&&) =
    default;
BlinkerContentScript::~BlinkerContentScript() = default;

BlinkerWebExtension::BlinkerWebExtension() = default;
BlinkerWebExtension::~BlinkerWebExtension() = default;

BlinkerInjectionSnapshot::BlinkerInjectionSnapshot() = default;
BlinkerInjectionSnapshot::~BlinkerInjectionSnapshot() = default;
BlinkerInjectionSnapshot::Extension::Extension() = default;
BlinkerInjectionSnapshot::Extension::Extension(const Extension&) = default;
BlinkerInjectionSnapshot::Extension&
BlinkerInjectionSnapshot::Extension::operator=(const Extension&) = default;
BlinkerInjectionSnapshot::Extension::~Extension() = default;

BlinkerWebExtensionRegistry::PreparedInjection::PreparedInjection() = default;
BlinkerWebExtensionRegistry::PreparedInjection::PreparedInjection(
    int32_t world_id,
    BlinkerScriptText program,
    bool is_css)
    : world_id(world_id), program(std::move(program)), is_css(is_css) {}
BlinkerWebExtensionRegistry::PreparedInjection::PreparedInjection(
    const PreparedInjection&) = default;
BlinkerWebExtensionRegistry::PreparedInjection&
BlinkerWebExtensionRegistry::PreparedInjection::operator=(
    const PreparedInjection&) = default;
BlinkerWebExtensionRegistry::PreparedInjection::~PreparedInjection() = default;

// static
BlinkerWebExtensionRegistry& BlinkerWebExtensionRegistry::GetInstance() {
  static base::NoDestructor<BlinkerWebExtensionRegistry> instance;
  return *instance;
}

BlinkerWebExtensionRegistry::BlinkerWebExtensionRegistry() = default;
BlinkerWebExtensionRegistry::~BlinkerWebExtensionRegistry() = default;

namespace {

base::FilePath BlinkerUserDataDir() {
  base::FilePath dir;
  base::PathService::Get(SHELL_DIR_USER_DATA, &dir);
  return dir;
}

base::FilePath PendingExtensionRestoreDir() {
  const base::FilePath user = BlinkerUserDataDir();
  return user.empty() ? base::FilePath()
                      : user.Append("BlinkerPendingExtensionRestore");
}

bool SafeEntryName(const std::string& name) {
  if (name.empty() || name == "." || name == ".." || name.size() > 128) {
    return false;
  }
  return std::all_of(name.begin(), name.end(), [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
  });
}

void ReplaceEntries(const base::FilePath& from, const base::FilePath& to) {
  if (!base::DirectoryExists(from) || to.empty()) {
    return;
  }
  base::CreateDirectory(to);
  base::FileEnumerator entries(from, /*recursive=*/false,
                               base::FileEnumerator::DIRECTORIES |
                                   base::FileEnumerator::FILES);
  for (base::FilePath path = entries.Next(); !path.empty();
       path = entries.Next()) {
    const std::string name = path.BaseName().AsUTF8Unsafe();
    if (!SafeEntryName(name)) {
      continue;
    }
    const base::FilePath target = to.Append(name);
    base::DeletePathRecursively(target);
    if (!base::Move(path, target)) {
      base::CopyDirectory(path, target, /*recursive=*/true);
    }
  }
}

// Відновлення з копії до запуску розширень, бо живі воркери і сховище
// тримають стан у памяті і переписали б файли
void ApplyPendingExtensionRestore() {
  const base::FilePath pending = PendingExtensionRestoreDir();
  if (pending.empty() || !base::DirectoryExists(pending)) {
    return;
  }
  const base::FilePath target = BlinkerEnsureExtensionsDirectory();
  ReplaceEntries(pending.Append("extensions"), target);
  const base::FilePath user = BlinkerUserDataDir();
  ReplaceEntries(pending.Append("state"), user.Append("BlinkerExtensionState"));
  ReplaceEntries(pending.Append("storage"),
                 user.Append("BlinkerExtensionStorage"));
  base::DeletePathRecursively(pending);
  ExtLog("EXT: restored extensions from a backup");
}

base::FilePath BackUpExtensionsBlocking() {
  const base::FilePath extensions = BlinkerExtensionsDirectory();
  base::FilePath temp;
  if (extensions.empty() || !base::DirectoryExists(extensions) ||
      !base::GetTempDir(&temp)) {
    return base::FilePath();
  }
  base::FilePath staging;
  if (!base::CreateTemporaryDirInDir(temp, "blinker-backup",
                                     &staging)) {
    return base::FilePath();
  }
  bool ok = base::CopyDirectory(extensions, staging.Append("extensions"),
                                /*recursive=*/true);
  const base::FilePath user = BlinkerUserDataDir();
  for (const auto& [from, to] :
       {std::pair{"BlinkerExtensionState", "state"},
        std::pair{"BlinkerExtensionStorage", "storage"}}) {
    const base::FilePath source = user.Append(from);
    if (ok && base::DirectoryExists(source)) {
      ok = base::CopyDirectory(source, staging.Append(to), /*recursive=*/true);
    }
  }
  base::WriteFile(staging.Append("blinker-extensions-backup.json"),
                  "{\"version\":1}");
  const base::FilePath archive = temp.Append("Blinker Fluid extensions.zip");
  base::DeleteFile(archive);
  ok = ok && zip::Zip(staging, archive, /*include_hidden_files=*/true);
  base::DeletePathRecursively(staging);
  return ok ? archive : base::FilePath();
}

int StageExtensionRestoreBlocking(const base::FilePath& archive) {
  base::FilePath temp;
  base::FilePath unpacked;
  if (!base::GetTempDir(&temp) ||
      !base::CreateTemporaryDirInDir(temp, "blinker-restore", &unpacked)) {
    return -1;
  }
  int count = 0;
  if (zip::Unzip(archive, unpacked)) {
    base::FileEnumerator dirs(unpacked.Append("extensions"),
                              /*recursive=*/false,
                              base::FileEnumerator::DIRECTORIES);
    for (base::FilePath dir = dirs.Next(); !dir.empty(); dir = dirs.Next()) {
      if (SafeEntryName(dir.BaseName().AsUTF8Unsafe()) &&
          base::PathExists(dir.Append("manifest.json"))) {
        ++count;
      }
    }
  }
  const base::FilePath pending = PendingExtensionRestoreDir();
  if (!count || pending.empty()) {
    base::DeletePathRecursively(unpacked);
    return -1;
  }
  base::DeletePathRecursively(pending);
  if (!base::Move(unpacked, pending)) {
    const bool copied = base::CopyDirectory(unpacked, pending, true);
    base::DeletePathRecursively(unpacked);
    if (!copied) {
      return -1;
    }
  }
  return count;
}

}  // namespace

void BlinkerBackUpExtensions(base::OnceCallback<void(base::FilePath)> done) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&BackUpExtensionsBlocking), std::move(done));
}

void BlinkerStageExtensionRestore(const base::FilePath& archive,
                                  base::OnceCallback<void(int)> done) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&StageExtensionRestoreBlocking, archive),
      std::move(done));
}

void BlinkerWebExtensionRegistry::LoadAll() {
  if (!loaded_) {
    ApplyPendingExtensionRestore();
  }
  loaded_ = true;
  extensions_.clear();

  int32_t next_world = kFirstExtensionWorldId;
  // Скануємо обидві теки, щоб нечитабельна не ховала іншу
  for (const base::FilePath& dir : BlinkerExtensionDirectories()) {
    if (const size_t installed = BlinkerInstallPendingCrx(dir)) {
      ExtLog(base::StrCat({"EXT: installed ",
                           base::NumberToString(installed),
                           " packed extension(s) from ", dir.AsUTF8Unsafe()}));
    }
    base::FileEnumerator enumerator(dir, /*recursive=*/false,
                                    base::FileEnumerator::DIRECTORIES);
    for (base::FilePath path = enumerator.Next(); !path.empty();
         path = enumerator.Next()) {
      if (extensions_.size() >= kMaxExtensions) {
        BLINKER_DIAGF("EXT: %zu extension limit reached, ignoring the rest",
                      kMaxExtensions);
        break;
      }
      const std::string id = path.BaseName().AsUTF8Unsafe();
      if (id == kBlinkerInstallHost) {
        continue;  // зарезервовано під сторінку встановлення
      }
      const bool already_loaded = std::any_of(
          extensions_.begin(), extensions_.end(),
          [&id](const std::unique_ptr<BlinkerWebExtension>& loaded) {
            return loaded->id == id;
          });
      if (already_loaded) {
        continue;  // перша тека виграє
      }
      if (std::unique_ptr<BlinkerWebExtension> extension =
              LoadOne(path, next_world)) {
        next_world += kWorldsPerExtension;
        LoadDynamicScripts(extension.get());
        LoadState(extension.get());
        extensions_.push_back(std::move(extension));
      }
    }
  }
  PublishFilterRules();
  PublishInjectionSnapshot();
  BlinkerRestoreExtensionApiState();
  BLINKER_DIAGF("EXT: loaded %zu extension(s)", extensions_.size());
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    size_t enabled_rulesets = 0;
    for (const BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
      enabled_rulesets += ruleset.enabled ? 1 : 0;
    }
    ExtLog(base::StrCat(
        {"EXT: ", extension->id, " v", extension->version, " rulesets=",
         base::NumberToString(enabled_rulesets), "/",
         base::NumberToString(extension->static_rulesets.size()), " lines=",
         base::NumberToString(extension->ActiveFilterLineCount()),
         " scripts=", base::NumberToString(extension->content_scripts.size()),
         "+", base::NumberToString(extension->dynamic_scripts.size()),
         " worker=", extension->background_service_worker.empty()
                         ? "none"
                         : extension->background_service_worker}));
  }
}

std::unique_ptr<BlinkerWebExtension> BlinkerWebExtensionRegistry::LoadOne(
    const base::FilePath& dir,
    int32_t world_id) {
  const std::string manifest_json =
      ReadBoundedFile(dir.Append("manifest.json"), kMaxScriptFileBytes);
  if (manifest_json.empty()) {
    ExtLog(base::StrCat({"EXT: ", dir.BaseName().AsUTF8Unsafe(),
                         " has no readable manifest.json"}));
    return nullptr;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(manifest_json, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    ExtLog(base::StrCat({"EXT: ", dir.BaseName().AsUTF8Unsafe(),
                         " has a manifest.json that is not valid JSON"}));
    return nullptr;
  }
  const base::DictValue& manifest = parsed->GetDict();

  auto extension = std::make_unique<BlinkerWebExtension>();
  extension->root = dir;
  extension->id = dir.BaseName().AsUTF8Unsafe();
  extension->isolated_world_id = world_id;
  extension->user_script_world_id = world_id + 1;
  extension->manifest_version = manifest.FindInt("manifest_version").value_or(0);
  if (const std::string* name = manifest.FindString("name")) {
    extension->name = *name;
  }
  if (extension->name.empty()) {
    extension->name = extension->id;
  }
  if (const std::string* version = manifest.FindString("version")) {
    extension->version = *version;
  }
  if (const std::string* locale = manifest.FindString("default_locale")) {
    extension->default_locale = *locale;
  }
  extension->manifest = manifest.Clone();

  extension->messages =
      LoadMessages(dir, extension->id, extension->default_locale);
  for (auto entry : extension->manifest) {
    LocalizeManifestStrings(&entry.second, extension->messages);
  }
  if (extension->name.find(bx::kMessageBegin) != std::string::npos) {
    bx::ReplaceMessages(extension->messages, &extension->name);
    if (extension->name.find(bx::kMessageBegin) != std::string::npos) {
      extension->name = extension->id;
    }
  }

  const auto collect_strings = [&manifest](const char* key,
                                           std::vector<std::string>* out) {
    if (const base::ListValue* list = manifest.FindList(key)) {
      for (const base::Value& entry : *list) {
        if (const std::string* value = entry.GetIfString()) {
          out->push_back(*value);
        }
      }
    }
  };
  collect_strings("permissions", &extension->permissions);
  collect_strings("host_permissions", &extension->host_permissions);
  collect_strings("optional_permissions", &extension->optional_permissions);
  collect_strings("optional_host_permissions",
                  &extension->optional_host_permissions);
  // У MV2 шаблони хостів пишуть у permissions, у MV3 Chrome їх там ігнорує
  const auto split_hosts = [&](std::vector<std::string>* apis,
                               std::vector<std::string>* hosts) {
    for (const std::string& value : *apis) {
      if (IsHostPattern(value) && extension->manifest_version < 3) {
        hosts->push_back(value);
      }
    }
    std::erase_if(*apis, IsHostPattern);
  };
  split_hosts(&extension->permissions, &extension->host_permissions);
  split_hosts(&extension->optional_permissions,
              &extension->optional_host_permissions);

  for (const char* key : {"action", "browser_action", "page_action"}) {
    const base::DictValue* section = manifest.FindDict(key);
    if (!section) {
      continue;
    }
    extension->unsupported_features.push_back(
        section->FindString("default_popup")
            ? base::StrCat({key, " (popup opens from the menu, no toolbar "
                                 "button or badge)"})
            : base::StrCat({key, " (no toolbar button)"}));
  }
  // options_page і options_ui тут навмисно нема, їх відкриває екран розширень
  for (const char* key : {"devtools_page", "side_panel", "omnibox",
                          "chrome_url_overrides"}) {
    if (manifest.contains(key)) {
      extension->unsupported_features.emplace_back(key);
    }
  }
  if (const base::ListValue* permissions = manifest.FindList("permissions")) {
    for (const base::Value& entry : *permissions) {
      const std::string* p = entry.GetIfString();
      if (p && (*p == "webRequest" || *p == "webRequestBlocking" ||
                *p == "notifications" || *p == "downloads")) {
        extension->unsupported_features.push_back(*p);
      }
      if (p && *p == "unlimitedStorage") {
        extension->unlimited_storage = true;
      }
    }
  }

  if (const base::DictValue* background = manifest.FindDict("background")) {
    if (const std::string* worker = background->FindString("service_worker")) {
      // Усі три форми шляху до воркера означають один файл. Зберігаємо форму
      // шляху запиту, інакше скрипт воркера не пройде перевірку доступу
      std::string path = *worker;
      while (path.starts_with("./")) {
        path.erase(0, 2);
      }
      while (path.starts_with("/")) {
        path.erase(0, 1);
      }
      extension->background_service_worker = path;
    }
    if (const std::string* type = background->FindString("type")) {
      extension->background_is_module = (*type == "module");
    }
  }

  // Токен сталий поки розширення встановлене, інакше байти скрипта воркера
  // мінялись би і він перевстановлювався
  extension->messaging_token = base::UnguessableToken::Create().ToString();

  if (const base::ListValue* war =
          manifest.FindList("web_accessible_resources")) {
    for (const base::Value& entry : *war) {
      const auto strip_root = [](const std::string& resource) {
        return resource.starts_with("/") ? resource.substr(1) : resource;
      };
      if (const std::string* resource = entry.GetIfString()) {
        extension->web_accessible_resources.push_back(
            strip_root(*resource));
        continue;
      }
      if (const base::DictValue* group = entry.GetIfDict()) {
        if (const base::ListValue* resources = group->FindList("resources")) {
          for (const base::Value& r : *resources) {
            if (const std::string* resource = r.GetIfString()) {
              extension->web_accessible_resources.push_back(
                  strip_root(*resource));
            }
          }
        }
      }
    }
  }

  size_t script_bytes = 0;
  if (const base::ListValue* scripts = manifest.FindList("content_scripts")) {
    for (const base::Value& entry : *scripts) {
      const base::DictValue* script = entry.GetIfDict();
      if (!script) {
        continue;
      }
      BlinkerContentScript content_script;
      bx::ScriptUrlFilter& filter = content_script.matches;
      AddStrings(script->FindList("matches"), [&](const std::string& pattern) {
        filter.patterns().AddInclude(pattern);
      });
      if (filter.patterns().empty()) {
        continue;
      }
      AddStrings(script->FindList("exclude_matches"),
                 [&](const std::string& pattern) {
                   filter.patterns().AddExclude(pattern);
                 });
      AddStrings(script->FindList("include_globs"),
                 [&](const std::string& glob) { filter.AddIncludeGlob(glob); });
      AddStrings(script->FindList("exclude_globs"),
                 [&](const std::string& glob) { filter.AddExcludeGlob(glob); });
      if (const std::string* run_at = script->FindString("run_at")) {
        content_script.run_at = RunAtFromString(*run_at);
      }
      content_script.all_frames =
          script->FindBool("all_frames").value_or(false);
      content_script.match_about_blank =
          script->FindBool("match_about_blank").value_or(false);
      content_script.match_origin_as_fallback =
          script->FindBool("match_origin_as_fallback").value_or(false);
      if (content_script.match_origin_as_fallback &&
          !filter.patterns().AllPathsAreWildcard()) {
        continue;
      }
      if (const std::string* world = script->FindString("world");
          world && *world == "MAIN") {
        content_script.world = BlinkerScriptWorld::kMain;
      }

      auto read_files = [&](const char* key, auto&& take) {
        const base::ListValue* files = script->FindList(key);
        if (!files) {
          return;
        }
        for (const base::Value& f : *files) {
          const std::string* relative = f.GetIfString();
          base::FilePath file;
          if (!relative || !ResolveExtensionPath(dir, *relative, &file)) {
            continue;
          }
          std::string body = ReadBoundedFile(file, kMaxScriptFileBytes);
          if (body.empty() ||
              script_bytes + body.size() > kMaxScriptBytesPerExtension) {
            continue;
          }
          script_bytes += body.size();
          take(std::move(body));
        }
      };
      read_files("js", [&](std::string body) {
        content_script.js.push_back(MakeScriptText(std::move(body)));
      });
      std::string css;
      read_files("css", [&](std::string body) {
        css.append(BlinkerLocalizeCss(*extension, std::move(body)));
        css.append("\n");
      });
      if (!css.empty()) {
        content_script.css = MakeScriptText(std::move(css));
      }
      if (content_script.js.empty() && !content_script.css) {
        continue;
      }
      extension->content_scripts.push_back(std::move(content_script));
    }
  }

  // Сторінки з externally_connectable пишуть розширенню через
  // chrome.runtime.sendMessage(id, ...), для цього ставимо два службові скрипти
  if (const base::DictValue* external =
          manifest.FindDict("externally_connectable")) {
    BlinkerContentScript page;
    BlinkerContentScript bridge;
    AddStrings(external->FindList("matches"), [&](const std::string& pattern) {
      page.matches.patterns().AddInclude(pattern);
      bridge.matches.patterns().AddInclude(pattern);
    });
    if (!page.matches.patterns().empty()) {
      page.run_at = BlinkerContentScript::RunAt::kDocumentStart;
      bridge.run_at = BlinkerContentScript::RunAt::kDocumentStart;
      page.world = BlinkerScriptWorld::kMain;
      page.js.push_back(MakeScriptText(BlinkerExtensionExternalPageShim()));
      bridge.js.push_back(
          MakeScriptText(BlinkerExtensionExternalBridge(extension->id)));
      extension->content_scripts.push_back(std::move(page));
      extension->content_scripts.push_back(std::move(bridge));
    }
  }

  if (const base::DictValue* dnr =
          manifest.FindDict("declarative_net_request")) {
    if (const base::ListValue* resources =
            dnr->FindList("rule_resources")) {
      for (const base::Value& entry : *resources) {
        const base::DictValue* resource = entry.GetIfDict();
        if (!resource) {
          continue;
        }
        const std::string* relative = resource->FindString("path");
        base::FilePath ruleset;
        if (!relative || !ResolveExtensionPath(dir, *relative, &ruleset)) {
          continue;
        }
        BlinkerStaticRuleset parsed_ruleset;
        if (const std::string* ruleset_id = resource->FindString("id")) {
          parsed_ruleset.id = *ruleset_id;
        } else {
          parsed_ruleset.id = *relative;
        }
        parsed_ruleset.enabled = resource->FindBool("enabled").value_or(true);
        const std::string body =
            ReadBoundedFile(ruleset, kMaxRulesetFileBytes);
        if (body.empty()) {
          continue;
        }
        std::optional<base::Value> rules =
            base::JSONReader::Read(body, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
        if (!rules || !rules->is_list()) {
          continue;
        }
        size_t dropped = 0;
        size_t total_lines = 0;
        for (const BlinkerStaticRuleset& earlier : extension->static_rulesets) {
          total_lines += earlier.filter_line_count;
        }
        std::string ruleset_text;
        for (const base::Value& rule_value : rules->GetList()) {
          if (total_lines + parsed_ruleset.filter_line_count >=
              kMaxRulesPerExtension) {
            break;
          }
          const base::DictValue* rule = rule_value.GetIfDict();
          if (!rule) {
            continue;
          }
          ++parsed_ruleset.rule_count;
          std::vector<std::string> lines = FilterLinesFromRuleValue(*rule);
          if (lines.empty()) {
            BlinkerNetActionRule action;
            if (BlinkerNetActionRuleFromDnr(*rule, extension->id, &action)) {
              parsed_ruleset.action_rules.push_back(rule->Clone());
            } else {
              ++dropped;
            }
            continue;
          }
          for (const std::string& line : lines) {
            ruleset_text += line;
            ruleset_text += '\n';
            ++parsed_ruleset.filter_line_count;
          }
        }
        ruleset_text.shrink_to_fit();
        parsed_ruleset.filter_text =
            std::make_shared<const std::string>(std::move(ruleset_text));
        if (dropped) {
          BLINKER_DIAGF("EXT: %s/%s dropped %zu unsupported DNR rule(s)",
                        extension->id.c_str(), parsed_ruleset.id.c_str(),
                        dropped);
        }
        extension->static_rulesets.push_back(std::move(parsed_ruleset));
      }
    }
  }

  if (extension->content_scripts.empty() &&
      extension->static_rulesets.empty() &&
      extension->background_service_worker.empty()) {
    ExtLog(base::StrCat({"EXT: ", extension->id,
                         " has no content scripts, rulesets or background "
                         "worker -- nothing this port can run"}));
    return nullptr;
  }
  return extension;
}

std::vector<std::shared_ptr<const std::string>>
BlinkerWebExtension::ActiveFilterChunks() const {
  std::vector<std::shared_ptr<const std::string>> chunks;
  const auto add = [&chunks](const std::shared_ptr<const std::string>& text) {
    if (text && !text->empty()) {
      chunks.push_back(text);
    }
  };
  for (const BlinkerStaticRuleset& ruleset : static_rulesets) {
    if (ruleset.enabled) {
      add(ruleset.filter_text);
    }
  }
  add(dynamic_filter_text);
  add(session_filter_text);
  return chunks;
}

size_t BlinkerWebExtension::ActiveFilterLineCount() const {
  size_t count = 0;
  for (const BlinkerStaticRuleset& ruleset : static_rulesets) {
    if (ruleset.enabled) {
      count += ruleset.filter_line_count;
    }
  }
  return count + dynamic_filter_line_count + session_filter_line_count;
}

void BlinkerWebExtensionRegistry::PublishFilterRules() {
  // Групи по розширеннях, щоб виняток одного не скасовував блоки іншого
  std::vector<BlinkerContentFilter::ExtensionRules> sources;
  std::vector<BlinkerNetActionRule> actions;
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (!extension->enabled) {
      continue;
    }
    std::vector<std::shared_ptr<const std::string>> chunks =
        extension->ActiveFilterChunks();
    if (!chunks.empty()) {
      sources.push_back({extension->id, std::move(chunks)});
    }

    const auto add_actions = [&](const std::vector<base::DictValue>& raw) {
      for (const base::DictValue& rule : raw) {
        BlinkerNetActionRule parsed;
        if (BlinkerNetActionRuleFromDnr(rule, extension->id, &parsed)) {
          actions.push_back(std::move(parsed));
        }
      }
    };
    for (const BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
      if (ruleset.enabled) {
        add_actions(ruleset.action_rules);
      }
    }
    add_actions(extension->dynamic_action_rules);
    add_actions(extension->session_action_rules);
  }
  BlinkerContentFilter::GetInstance().SetExtensionRules(std::move(sources));
  BlinkerExtensionNetActions::GetInstance().SetRules(std::move(actions));
}

std::vector<BlinkerWebExtensionRegistry::PreparedInjection>
BlinkerWebExtensionRegistry::BuildPrograms(
    const BlinkerInjectionSnapshot::Extension& extension,
    const BlinkerFrameUrls& frame,
    BlinkerContentScript::RunAt run_at,
    bool is_main_frame,
    bool match_all_timings,
    BlinkerScriptWorld world) {
  std::vector<BlinkerScriptText> css;
  std::vector<BlinkerScriptText> js;
  const bool css_now = match_all_timings ||
                       run_at == BlinkerContentScript::RunAt::kDocumentStart;
  for (const BlinkerContentScript& script : extension.scripts) {
    if (script.world != world || (!is_main_frame && !script.all_frames)) {
      continue;
    }
    const bool js_now = match_all_timings || script.run_at == run_at;
    if ((!js_now || script.js.empty()) && (!css_now || !script.css)) {
      continue;
    }
    const GURL& target = EffectiveUrlForScript(script, frame);
    if (!IsInjectableUrl(target) ||
        !script.matches.Matches(BlinkerUrlParts(target))) {
      continue;
    }
    if (css_now && script.css) {
      css.push_back(script.css);
    }
    if (js_now) {
      js.insert(js.end(), script.js.begin(), script.js.end());
    }
  }
  std::vector<PreparedInjection> programs;
  if (css.empty() && js.empty()) {
    return programs;
  }

  // У світі сторінки шіма немає, інакше сторінка отримала б API розширення
  BlinkerScriptText shim;
  switch (world) {
    case BlinkerScriptWorld::kIsolated:
      shim = extension.content_shim;
      break;
    case BlinkerScriptWorld::kMain:
      break;
    case BlinkerScriptWorld::kUserScript:
      shim = extension.user_script_shim;
      break;
  }
  if (shim && !js.empty()) {
    programs.emplace_back(-1, std::move(shim), /*is_css=*/false);
  }
  if (css.size() == 1) {
    programs.emplace_back(-1, std::move(css.front()), /*is_css=*/true);
  } else if (!css.empty()) {
    std::string joined;
    for (const BlinkerScriptText& part : css) {
      joined += part->as_string();
    }
    programs.emplace_back(-1, MakeScriptText(std::move(joined)),
                          /*is_css=*/true);
  }
  const bool shimeji_everywhere =
      world == BlinkerScriptWorld::kIsolated && is_main_frame && !js.empty() &&
      extension.id == kShimejiExtensionId;
  for (BlinkerScriptText& source : js) {
    programs.emplace_back(-1, std::move(source), /*is_css=*/false);
  }
  if (shimeji_everywhere) {
    programs.emplace_back(-1, MakeScriptText(kShimejiEverywhereJs),
                          /*is_css=*/false);
    programs.emplace_back(-1, MakeScriptText(kShimejiTouchJs),
                          /*is_css=*/false);
  }
  return programs;
}

scoped_refptr<const BlinkerInjectionSnapshot>
BlinkerWebExtensionRegistry::injection_snapshot() const {
  base::AutoLock lock(snapshot_lock_);
  return snapshot_;
}

void BlinkerWebExtensionRegistry::PublishInjectionSnapshot() {
  auto snapshot = base::MakeRefCounted<BlinkerInjectionSnapshot>();
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (!extension->enabled) {
      continue;
    }
    BlinkerInjectionSnapshot::Extension& entry =
        snapshot->extensions.emplace_back();
    entry.id = extension->id;
    entry.isolated_world_id = extension->isolated_world_id;
    entry.user_script_world_id = extension->user_script_world_id;
    entry.scripts = extension->content_scripts;
    for (const BlinkerDynamicScript& dynamic : extension->dynamic_scripts) {
      entry.scripts.push_back(dynamic.script);
    }
    entry.content_shim = BlinkerExtensionContentScriptShim(*extension);
    entry.page_shim = ExtensionPageShim(*extension);
    if (extension->user_script_messaging) {
      entry.user_script_shim =
          MakeScriptText(BlinkerExtensionUserScriptMessagingShim(
              extension->id, extension->messaging_token));
    }
  }
  base::AutoLock lock(snapshot_lock_);
  snapshot_ = std::move(snapshot);
}

BlinkerDynamicScript::BlinkerDynamicScript() = default;
BlinkerDynamicScript::BlinkerDynamicScript(BlinkerDynamicScript&&) = default;
BlinkerDynamicScript& BlinkerDynamicScript::operator=(BlinkerDynamicScript&&) =
    default;
BlinkerDynamicScript::~BlinkerDynamicScript() = default;

BlinkerWebExtension* BlinkerWebExtensionRegistry::FindExtension(
    std::string_view id) {
  if (!loaded_) {
    LoadAll();
  }
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (extension->id == id) {
      return extension.get();
    }
  }
  return nullptr;
}

namespace {

base::FilePath DynamicScriptsFile(std::string_view extension_id) {
  base::FilePath dir;
  if (!base::PathService::Get(SHELL_DIR_USER_DATA, &dir)) {
    return base::FilePath();
  }
  for (char c : extension_id) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    if (!ok) {
      return base::FilePath();
    }
  }
  if (extension_id.empty() || extension_id == "." || extension_id == "..") {
    return base::FilePath();
  }
  return dir.Append("BlinkerExtensionScripts")
      .AppendASCII(base::StrCat({extension_id, ".json"}));
}

bool BuildDynamicScript(const BlinkerWebExtension& extension,
                        const base::DictValue& spec,
                        bool user_script,
                        BlinkerDynamicScript* out,
                        std::string* error) {
  out->is_user_script = user_script;
  const std::string* id = spec.FindString("id");
  if (!id || id->empty()) {
    *error = "Script's ID must not be empty";
    return false;
  }
  if ((*id)[0] == '_') {
    *error = "Script's ID must not start with '_'";
    return false;
  }
  out->id = *id;
  out->spec = spec.Clone();

  const base::ListValue* matches = spec.FindList("matches");
  if (!matches || matches->empty()) {
    *error = base::StrCat({out->is_user_script ? "User script" : "Script",
                           " with ID '", *id, "' must specify 'matches'"});
    return false;
  }
  BlinkerContentScript& script = out->script;
  bx::ScriptUrlFilter& filter = script.matches;
  filter.set_globs_extend_patterns(out->is_user_script);
  AddStrings(matches, [&](const std::string& pattern) {
    filter.patterns().AddInclude(pattern);
  });
  AddStrings(spec.FindList("excludeMatches"), [&](const std::string& pattern) {
    filter.patterns().AddExclude(pattern);
  });
  AddStrings(spec.FindList("includeGlobs"),
             [&](const std::string& glob) { filter.AddIncludeGlob(glob); });
  AddStrings(spec.FindList("excludeGlobs"),
             [&](const std::string& glob) { filter.AddExcludeGlob(glob); });
  script.match_origin_as_fallback =
      spec.FindBool("matchOriginAsFallback").value_or(false);
  if (script.match_origin_as_fallback &&
      !filter.patterns().AllPathsAreWildcard()) {
    *error =
        "The path component for scripts with 'match_origin_as_fallback' must "
        "be '*'.";
    return false;
  }

  script.all_frames = spec.FindBool("allFrames").value_or(false);
  if (const std::string* run_at = spec.FindString("runAt")) {
    if (*run_at == "document_start") {
      script.run_at = BlinkerContentScript::RunAt::kDocumentStart;
    } else if (*run_at == "document_end") {
      script.run_at = BlinkerContentScript::RunAt::kDocumentEnd;
    }
  }
  if (const std::string* world = spec.FindString("world")) {
    if (*world == "MAIN") {
      script.world = BlinkerScriptWorld::kMain;
    } else if (*world == "USER_SCRIPT") {
      script.world = BlinkerScriptWorld::kUserScript;
    }
  }
  if (out->is_user_script && !spec.FindString("world")) {
    script.world = BlinkerScriptWorld::kUserScript;
  }

  // userScripts приймає ще й код, бо скриптлети блокувальників
  // генеруються зі списків на льоту
  const auto read_files = [&](const char* key, auto&& take) -> bool {
    const base::ListValue* files = spec.FindList(key);
    if (!files) {
      return true;
    }
    for (const base::Value& entry : *files) {
      if (const base::DictValue* source = entry.GetIfDict()) {
        if (const std::string* code = source->FindString("code")) {
          if (!out->is_user_script) {
            *error = "Only chrome.userScripts may register inline code";
            return false;
          }
          take(*code);
          continue;
        }
        if (const std::string* file = source->FindString("file")) {
          std::string contents;
          if (!BlinkerReadExtensionFile(extension, *file, &contents)) {
            *error = base::StrCat({"Could not load file: '", *file, "'."});
            return false;
          }
          take(std::move(contents));
        }
        continue;
      }
      const std::string* name = entry.GetIfString();
      if (!name) {
        continue;
      }
      std::string relative = *name;
      if (!relative.empty() && relative.front() == '/') {
        relative.erase(relative.begin());
      }
      base::FilePath resolved;
      if (!ResolveExtensionPath(extension.root, relative, &resolved)) {
        *error = base::StrCat({"Could not load file: '", *name, "'."});
        return false;
      }
      std::string contents;
      if (!base::ReadFileToStringWithMaxSize(resolved, &contents,
                                             8 * 1024 * 1024)) {
        *error = base::StrCat({"Could not load file: '", *name, "'."});
        return false;
      }
      take(std::move(contents));
    }
    return true;
  };
  std::string css;
  const auto take_js = [&](std::string source) {
    script.js.push_back(MakeScriptText(std::move(source)));
  };
  const auto take_css = [&](std::string source) {
    css.append(BlinkerLocalizeCss(extension, std::move(source)));
    css.append("\n");
  };
  if (!read_files("js", take_js) || !read_files("css", take_css)) {
    return false;
  }
  if (!css.empty()) {
    script.css = MakeScriptText(std::move(css));
  }
  if (script.js.empty() && !script.css) {
    *error =
        base::StrCat({"Script with ID '", *id, "' must specify at least one ",
                      "js or css file"});
    return false;
  }
  return true;
}

}  // namespace

void BlinkerWebExtensionRegistry::LoadDynamicScripts(
    BlinkerWebExtension* extension) {
  const base::FilePath path = DynamicScriptsFile(extension->id);
  if (path.empty()) {
    return;
  }
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents, 4 * 1024 * 1024)) {
    return;
  }
  std::optional<base::ListValue> stored =
      base::JSONReader::ReadList(contents, base::JSON_PARSE_RFC);
  if (!stored) {
    return;
  }
  for (const base::Value& entry : *stored) {
    const base::DictValue* wrapper = entry.GetIfDict();
    if (!wrapper) {
      continue;
    }
    const base::DictValue* spec = wrapper->FindDict("spec");
    const bool user_script =
        spec ? wrapper->FindBool("userScript").value_or(false) : false;
    if (!spec) {
      spec = wrapper;
    }
    BlinkerDynamicScript script;
    std::string error;
    if (BuildDynamicScript(*extension, *spec, user_script, &script, &error)) {
      extension->dynamic_scripts.push_back(std::move(script));
    }
  }
}

void BlinkerWebExtensionRegistry::SaveDynamicScripts(
    const BlinkerWebExtension& extension) {
  const base::FilePath path = DynamicScriptsFile(extension.id);
  if (path.empty()) {
    return;
  }
  base::ListValue stored;
  for (const BlinkerDynamicScript& script : extension.dynamic_scripts) {
    if (script.spec.FindBool("persistAcrossSessions").value_or(true)) {
      base::DictValue entry;
      entry.Set("userScript", script.is_user_script);
      entry.Set("spec", script.spec.Clone());
      stored.Append(std::move(entry));
    }
  }
  std::optional<std::string> json = base::WriteJson(stored);
  if (!json) {
    return;
  }
  base::ThreadPool::PostTask(
      FROM_HERE,
      {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      base::BindOnce(
          [](base::FilePath path, std::string json) {
            if (base::CreateDirectory(path.DirName())) {
              base::WriteFile(path, json);
            }
          },
          path, std::move(*json)));
}

bool BlinkerWebExtensionRegistry::RegisterScriptsImpl(
    std::string_view extension_id,
    const base::ListValue& scripts,
    bool update,
    bool user_scripts,
    std::string* error) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    *error = "No such extension";
    return false;
  }
  // Спочатку будуємо, потім застосовуємо, бо у Chrome виклик або весь,
  // або ніякий
  std::vector<BlinkerDynamicScript> built;
  for (const base::Value& entry : scripts) {
    const base::DictValue* spec = entry.GetIfDict();
    if (!spec) {
      *error = "Invalid script";
      return false;
    }
    BlinkerDynamicScript script;
    if (!BuildDynamicScript(*extension, *spec, user_scripts, &script, error)) {
      return false;
    }
    const auto existing =
        std::find_if(extension->dynamic_scripts.begin(),
                     extension->dynamic_scripts.end(),
                     [&](const BlinkerDynamicScript& s) {
                       return s.id == script.id &&
                              s.is_user_script == user_scripts;
                     });
    const bool present = existing != extension->dynamic_scripts.end();
    if (present && !update) {
      *error = base::StrCat(
          {"Duplicate script ID '", script.id, "'"});
      return false;
    }
    if (!present && update) {
      *error = base::StrCat({"Script with ID '", script.id, "' does not exist"});
      return false;
    }
    built.push_back(std::move(script));
  }

  for (BlinkerDynamicScript& script : built) {
    auto existing = std::find_if(
        extension->dynamic_scripts.begin(), extension->dynamic_scripts.end(),
        [&](const BlinkerDynamicScript& s) {
          return s.id == script.id && s.is_user_script == user_scripts;
        });
    if (existing != extension->dynamic_scripts.end()) {
      *existing = std::move(script);
    } else {
      extension->dynamic_scripts.push_back(std::move(script));
    }
  }
  SaveDynamicScripts(*extension);
  PublishInjectionSnapshot();
  return true;
}

void BlinkerWebExtensionRegistry::UnregisterScriptsImpl(
    std::string_view extension_id,
    const std::vector<std::string>& ids,
    bool user_scripts) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return;
  }
  std::erase_if(extension->dynamic_scripts,
                [&](const BlinkerDynamicScript& script) {
                  if (script.is_user_script != user_scripts) {
                    return false;
                  }
                  return ids.empty() ||
                         std::find(ids.begin(), ids.end(), script.id) !=
                             ids.end();
                });
  SaveDynamicScripts(*extension);
  PublishInjectionSnapshot();
}

base::ListValue BlinkerWebExtensionRegistry::GetScriptsImpl(
    std::string_view extension_id,
    const std::vector<std::string>& ids,
    bool user_scripts) {
  base::ListValue out;
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return out;
  }
  for (const BlinkerDynamicScript& script : extension->dynamic_scripts) {
    if (script.is_user_script != user_scripts) {
      continue;
    }
    if (!ids.empty() &&
        std::find(ids.begin(), ids.end(), script.id) == ids.end()) {
      continue;
    }
    out.Append(script.spec.Clone());
  }
  return out;
}

bool BlinkerWebExtensionRegistry::RegisterDynamicScripts(
    std::string_view extension_id,
    const base::ListValue& scripts,
    bool update,
    std::string* error) {
  return RegisterScriptsImpl(extension_id, scripts, update,
                             /*user_scripts=*/false, error);
}

void BlinkerWebExtensionRegistry::UnregisterDynamicScripts(
    std::string_view extension_id,
    const std::vector<std::string>& ids) {
  UnregisterScriptsImpl(extension_id, ids, /*user_scripts=*/false);
}

base::ListValue BlinkerWebExtensionRegistry::GetDynamicScripts(
    std::string_view extension_id,
    const std::vector<std::string>& ids) {
  return GetScriptsImpl(extension_id, ids, /*user_scripts=*/false);
}

bool BlinkerWebExtensionRegistry::RegisterUserScripts(
    std::string_view extension_id,
    const base::ListValue& scripts,
    bool update,
    std::string* error) {
  return RegisterScriptsImpl(extension_id, scripts, update,
                             /*user_scripts=*/true, error);
}

void BlinkerWebExtensionRegistry::UnregisterUserScripts(
    std::string_view extension_id,
    const std::vector<std::string>& ids) {
  UnregisterScriptsImpl(extension_id, ids, /*user_scripts=*/true);
}

base::ListValue BlinkerWebExtensionRegistry::GetUserScripts(
    std::string_view extension_id,
    const std::vector<std::string>& ids) {
  return GetScriptsImpl(extension_id, ids, /*user_scripts=*/true);
}

void BlinkerWebExtensionRegistry::ConfigureUserScriptWorld(
    std::string_view extension_id,
    bool messaging) {
  if (BlinkerWebExtension* extension = FindExtension(extension_id)) {
    extension->user_script_messaging = messaging;
    SaveState(*extension);
    PublishInjectionSnapshot();
  }
}

namespace {

base::FilePath StateFile(std::string_view extension_id) {
  base::FilePath dir;
  if (!base::PathService::Get(SHELL_DIR_USER_DATA, &dir)) {
    return base::FilePath();
  }
  for (char c : extension_id) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    if (!ok) {
      return base::FilePath();
    }
  }
  if (extension_id.empty() || extension_id == "." || extension_id == "..") {
    return base::FilePath();
  }
  return dir.Append("BlinkerExtensionState")
      .AppendASCII(base::StrCat({extension_id, ".json"}));
}

std::shared_ptr<const std::string> FilterTextForRules(
    const base::ListValue& rules,
    size_t* line_count) {
  std::string text;
  size_t count = 0;
  for (const base::Value& entry : rules) {
    if (const base::DictValue* rule = entry.GetIfDict()) {
      for (const std::string& line : FilterLinesFromRuleValue(*rule)) {
        text += line;
        text += '\n';
        ++count;
      }
    }
  }
  text.shrink_to_fit();
  if (line_count) {
    *line_count = count;
  }
  return std::make_shared<const std::string>(std::move(text));
}

std::vector<base::DictValue> ActionRulesFor(const base::ListValue& rules,
                                            const std::string& extension_id) {
  std::vector<base::DictValue> out;
  for (const base::Value& entry : rules) {
    const base::DictValue* rule = entry.GetIfDict();
    if (!rule) {
      continue;
    }
    BlinkerNetActionRule parsed;
    if (BlinkerNetActionRuleFromDnr(*rule, extension_id, &parsed)) {
      out.push_back(rule->Clone());
    }
  }
  return out;
}

int RuleId(const base::Value& rule) {
  const base::DictValue* dict = rule.GetIfDict();
  return dict ? dict->FindInt("id").value_or(-1) : -1;
}

constexpr size_t kMaxDynamicRules = 30000;
constexpr size_t kMaxSessionRules = 5000;

}  // namespace

void BlinkerWebExtensionRegistry::LoadState(BlinkerWebExtension* extension) {
  const base::FilePath path = StateFile(extension->id);
  if (path.empty()) {
    return;
  }
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents, 8 * 1024 * 1024)) {
    return;
  }
  std::optional<base::DictValue> state =
      base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  if (!state) {
    return;
  }
  if (const base::ListValue* rules = state->FindList("dynamicRules")) {
    extension->dynamic_rules = rules->Clone();
    extension->dynamic_filter_text = FilterTextForRules(
        extension->dynamic_rules, &extension->dynamic_filter_line_count);
  }
  // Тільки набори що ще є в маніфесті, старий перемикач не воскрешає
  // видалений
  if (const base::DictValue* toggles = state->FindDict("rulesets")) {
    for (BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
      if (std::optional<bool> enabled = toggles->FindBool(ruleset.id)) {
        ruleset.enabled = *enabled;
      }
    }
  }
  if (std::optional<bool> enabled = state->FindBool("enabled")) {
    extension->enabled = *enabled;
  }
  if (const std::string* signature = state->FindString("workerSignature")) {
    extension->worker_signature = *signature;
  }
  if (const std::string* token = state->FindString("messagingToken")) {
    if (!token->empty()) {
      extension->messaging_token = *token;
    }
  }
  if (const base::ListValue* granted = state->FindList("granted")) {
    for (const base::Value& entry : *granted) {
      if (const std::string* value = entry.GetIfString()) {
        extension->granted_optional.push_back(*value);
      }
    }
  }
  extension->first_run = !state->FindBool("installed").value_or(false);
  if (const std::string* version = state->FindString("version")) {
    extension->stored_version = *version;
  } else if (!extension->first_run) {
    extension->stored_version = extension->version;
  }
  if (const std::string* build = state->FindString("browserVersion")) {
    extension->stored_browser_version = *build;
  }
  if (const base::DictValue* api_state = state->FindDict("apiState")) {
    extension->api_state = api_state->Clone();
  }
  extension->user_script_messaging =
      state->FindBool("userScriptMessaging").value_or(false);
}

void BlinkerWebExtensionRegistry::SaveState(
    const BlinkerWebExtension& extension) {
  const base::FilePath path = StateFile(extension.id);
  if (path.empty()) {
    return;
  }
  base::DictValue state;
  state.Set("dynamicRules", extension.dynamic_rules.Clone());
  base::DictValue toggles;
  for (const BlinkerStaticRuleset& ruleset : extension.static_rulesets) {
    toggles.Set(ruleset.id, ruleset.enabled);
  }
  state.Set("rulesets", std::move(toggles));
  base::ListValue granted;
  for (const std::string& value : extension.granted_optional) {
    granted.Append(value);
  }
  state.Set("granted", std::move(granted));
  state.Set("installed", !extension.first_run);
  state.Set("version", extension.stored_version);
  state.Set("browserVersion", extension.stored_browser_version);
  state.Set("apiState", extension.api_state.Clone());
  state.Set("userScriptMessaging", extension.user_script_messaging);
  state.Set("enabled", extension.enabled);
  state.Set("workerSignature", extension.worker_signature);
  state.Set("messagingToken", extension.messaging_token);
  std::optional<std::string> json = base::WriteJson(state);
  if (!json) {
    return;
  }
  base::ThreadPool::PostTask(
      FROM_HERE,
      {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      base::BindOnce(
          [](base::FilePath path, std::string json) {
            if (base::CreateDirectory(path.DirName())) {
              base::WriteFile(path, json);
            }
          },
          path, std::move(*json)));
}

bool BlinkerWebExtensionRegistry::UpdateRules(std::string_view extension_id,
                                              bool session,
                                              const std::vector<int>& remove_ids,
                                              const base::ListValue* add_rules,
                                              std::string* error) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    *error = "No such extension";
    return false;
  }
  base::ListValue& rules =
      session ? extension->session_rules : extension->dynamic_rules;
  // Спершу видалення, потім додавання, і весь виклик падає якщо новий id
  // збігся з тим що лишився
  base::ListValue next;
  for (const base::Value& rule : rules) {
    const int id = RuleId(rule);
    if (std::find(remove_ids.begin(), remove_ids.end(), id) ==
        remove_ids.end()) {
      next.Append(rule.Clone());
    }
  }
  if (add_rules) {
    for (const base::Value& rule : *add_rules) {
      const base::DictValue* dict = rule.GetIfDict();
      if (!dict || !dict->FindInt("id") || *dict->FindInt("id") < 1) {
        *error = "Rule ids must be positive integers";
        return false;
      }
      const int id = *dict->FindInt("id");
      for (const base::Value& existing : next) {
        if (RuleId(existing) == id) {
          *error = base::StrCat({"Rule with id ", base::NumberToString(id),
                                 " does not have a unique ID."});
          return false;
        }
      }
      next.Append(rule.Clone());
    }
  }
  if (next.size() > (session ? kMaxSessionRules : kMaxDynamicRules)) {
    *error = session ? "MAX_NUMBER_OF_SESSION_RULES exceeded"
                     : "MAX_NUMBER_OF_DYNAMIC_RULES exceeded";
    return false;
  }
  rules = std::move(next);
  if (session) {
    extension->session_filter_text =
        FilterTextForRules(rules, &extension->session_filter_line_count);
    extension->session_action_rules =
        ActionRulesFor(rules, extension->id);
  } else {
    extension->dynamic_filter_text =
        FilterTextForRules(rules, &extension->dynamic_filter_line_count);
    extension->dynamic_action_rules =
        ActionRulesFor(rules, extension->id);
    SaveState(*extension);
  }
  PublishFilterRules();
  return true;
}

base::ListValue BlinkerWebExtensionRegistry::GetRules(
    std::string_view extension_id,
    bool session,
    const std::vector<int>& only_ids) {
  base::ListValue out;
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return out;
  }
  const base::ListValue& rules =
      session ? extension->session_rules : extension->dynamic_rules;
  for (const base::Value& rule : rules) {
    if (!only_ids.empty() &&
        std::find(only_ids.begin(), only_ids.end(), RuleId(rule)) ==
            only_ids.end()) {
      continue;
    }
    out.Append(rule.Clone());
  }
  return out;
}

bool BlinkerWebExtensionRegistry::UpdateEnabledRulesets(
    std::string_view extension_id,
    const std::vector<std::string>& disable,
    const std::vector<std::string>& enable,
    std::string* error) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    *error = "No such extension";
    return false;
  }
  for (const std::vector<std::string>* ids : {&disable, &enable}) {
    for (const std::string& id : *ids) {
      const bool known = std::any_of(
          extension->static_rulesets.begin(), extension->static_rulesets.end(),
          [&](const BlinkerStaticRuleset& r) { return r.id == id; });
      if (!known) {
        *error = base::StrCat({"Invalid ruleset id: ", id, "."});
        return false;
      }
    }
  }
  for (BlinkerStaticRuleset& ruleset : extension->static_rulesets) {
    if (std::find(disable.begin(), disable.end(), ruleset.id) !=
        disable.end()) {
      ruleset.enabled = false;
    }
    if (std::find(enable.begin(), enable.end(), ruleset.id) != enable.end()) {
      ruleset.enabled = true;
    }
  }
  SaveState(*extension);
  PublishFilterRules();
  return true;
}

std::string BlinkerWebExtensionRegistry::ContainsPermissions(
    std::string_view extension_id,
    const std::vector<std::string>& permissions,
    const std::vector<std::string>& origins,
    bool* result) {
  *result = false;
  const BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return "No such extension";
  }
  UnpackedPermissions unpacked;
  std::string error =
      UnpackPermissions(*extension, permissions, origins, &unpacked);
  if (!error.empty()) {
    return error;
  }
  if (!unpacked.unlisted_apis.empty() || !unpacked.unlisted_hosts.empty()) {
    return std::string();
  }
  for (const std::string& api : unpacked.optional_apis) {
    if (!Contains(extension->granted_optional, api)) {
      return std::string();
    }
  }
  const bx::MatchPatternSet granted =
      HostPermissionSet({&extension->granted_optional});
  for (const bx::MatchPattern& host : unpacked.optional_hosts) {
    if (!granted.ContainsPattern(host)) {
      return std::string();
    }
  }
  *result = true;
  return std::string();
}

std::string BlinkerWebExtensionRegistry::RequestPermissions(
    std::string_view extension_id,
    const std::vector<std::string>& permissions,
    const std::vector<std::string>& origins,
    BlinkerPermissionChange* added) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return "No such extension";
  }
  UnpackedPermissions unpacked;
  std::string error =
      UnpackPermissions(*extension, permissions, origins, &unpacked);
  if (!error.empty()) {
    return error;
  }
  if (!unpacked.unlisted_apis.empty() || !unpacked.unlisted_hosts.empty()) {
    return kNotInManifestPermissionsError;
  }
  for (const std::string& api : unpacked.optional_apis) {
    if (!Contains(extension->granted_optional, api)) {
      extension->granted_optional.push_back(api);
      added->permissions.push_back(api);
    }
  }
  for (size_t i = 0; i < unpacked.optional_hosts.size(); ++i) {
    if (!HostPermissionSet({&extension->granted_optional})
             .ContainsPattern(unpacked.optional_hosts[i])) {
      extension->granted_optional.push_back(unpacked.optional_host_strings[i]);
      added->origins.push_back(unpacked.optional_host_strings[i]);
    }
  }
  if (!added->permissions.empty() || !added->origins.empty()) {
    SaveState(*extension);
  }
  return std::string();
}

std::string BlinkerWebExtensionRegistry::RemovePermissions(
    std::string_view extension_id,
    const std::vector<std::string>& permissions,
    const std::vector<std::string>& origins,
    BlinkerPermissionChange* removed) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return "No such extension";
  }
  UnpackedPermissions unpacked;
  std::string error =
      UnpackPermissions(*extension, permissions, origins, &unpacked);
  if (!error.empty()) {
    return error;
  }
  if (!unpacked.unlisted_apis.empty() || !unpacked.unlisted_hosts.empty()) {
    return kNotInManifestPermissionsError;
  }
  if (!unpacked.required_apis.empty() || !unpacked.required_hosts.empty() ||
      !unpacked.scriptable_hosts.empty()) {
    return "You cannot remove required permissions.";
  }
  for (const std::string& api : unpacked.optional_apis) {
    if (std::erase(extension->granted_optional, api)) {
      removed->permissions.push_back(api);
    }
  }
  std::erase_if(extension->granted_optional, [&](const std::string& value) {
    bx::MatchPattern granted;
    if (!IsHostPattern(value) || !granted.Parse(value)) {
      return false;
    }
    granted.set_path("/*");
    for (const bx::MatchPattern& host : unpacked.optional_hosts) {
      if (host.Contains(granted)) {
        removed->origins.push_back(value);
        return true;
      }
    }
    return false;
  });
  if (!removed->permissions.empty() || !removed->origins.empty()) {
    SaveState(*extension);
  }
  return std::string();
}

base::DictValue BlinkerWebExtensionRegistry::GetAllPermissions(
    std::string_view extension_id) {
  base::DictValue out;
  const BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return out;
  }
  base::ListValue apis;
  for (const std::string& api : extension->permissions) {
    apis.Append(api);
  }
  std::vector<std::string> hosts;
  for (const std::vector<std::string>* list :
       {&extension->host_permissions, &extension->granted_optional}) {
    for (const std::string& value : *list) {
      if (!IsHostPattern(value)) {
        continue;
      }
      bx::MatchPattern pattern;
      const size_t host_start = value.find("://");
      if (value == "<all_urls>" || !pattern.Parse(value) ||
          host_start == std::string::npos) {
        hosts.push_back(value);
        continue;
      }
      const size_t path_start = value.find('/', host_start + 3);
      hosts.push_back(base::StrCat(
          {std::string_view(value).substr(0, path_start), "/*"}));
    }
  }
  for (const std::string& value : extension->granted_optional) {
    if (!IsHostPattern(value) && !Contains(extension->permissions, value)) {
      apis.Append(value);
    }
  }
  if (const base::ListValue* scripts =
          extension->manifest.FindList("content_scripts")) {
    for (const base::Value& entry : *scripts) {
      if (const base::DictValue* script = entry.GetIfDict()) {
        AddStrings(script->FindList("matches"),
                   [&](const std::string& pattern) {
                     hosts.push_back(pattern);
                   });
      }
    }
  }
  std::sort(hosts.begin(), hosts.end());
  hosts.erase(std::unique(hosts.begin(), hosts.end()), hosts.end());
  base::ListValue origins;
  for (std::string& host : hosts) {
    origins.Append(std::move(host));
  }
  out.Set("permissions", std::move(apis));
  out.Set("origins", std::move(origins));
  return out;
}

bool BlinkerWebExtensionRegistry::HasPermission(std::string_view extension_id,
                                                std::string_view permission) {
  const BlinkerWebExtension* extension = FindExtension(extension_id);
  return extension && (Contains(extension->permissions, permission) ||
                       Contains(extension->granted_optional, permission));
}

bool BlinkerWebExtensionRegistry::HasHostPermission(
    std::string_view extension_id,
    const GURL& url) {
  const BlinkerWebExtension* extension = FindExtension(extension_id);
  return extension && url.is_valid() &&
         HostPermissionSet(
             {&extension->host_permissions, &extension->granted_optional})
             .Matches(BlinkerUrlParts(url));
}

bool BlinkerWebExtensionRegistry::HasApiAccess(std::string_view extension_id,
                                               std::string_view permission,
                                               const GURL& url) {
  return HasPermission(extension_id, permission) &&
         HasHostPermission(extension_id, url);
}

BlinkerWebExtensionRegistry::Lifecycle
BlinkerWebExtensionRegistry::ConsumeLifecycle(std::string_view extension_id) {
  Lifecycle out;
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return out;
  }
  // Воркер MV3 стартує багато разів за запуск, а onStartup у Chrome один
  const bool first_start = started_this_launch_.insert(extension->id).second;
  const std::string& build = BrowserBuildVersion();
  if (extension->first_run) {
    out.install_reason = "install";
  } else if (extension->stored_version != extension->version) {
    out.install_reason = "update";
    out.previous_version = extension->stored_version;
  } else if (!build.empty() && extension->stored_browser_version != build) {
    out.install_reason = "chrome_update";
  }
  out.startup = first_start && out.install_reason != "install";
  if (!out.install_reason.empty()) {
    extension->first_run = false;
    extension->stored_version = extension->version;
    extension->stored_browser_version = build;
    SaveState(*extension);
  }
  return out;
}

void BlinkerWebExtensionRegistry::SetApiState(std::string_view extension_id,
                                              base::DictValue state) {
  BlinkerWebExtension* extension = FindExtension(extension_id);
  if (!extension) {
    return;
  }
  extension->api_state = std::move(state);
  SaveState(*extension);
}

std::vector<BlinkerWebExtensionRegistry::PreparedInjection>
BlinkerWebExtensionRegistry::PrepareInjections(
    const BlinkerFrameUrls& frame,
    BlinkerContentScript::RunAt run_at,
    bool is_main_frame) {
  std::vector<PreparedInjection> out;
  const scoped_refptr<const BlinkerInjectionSnapshot> snapshot =
      injection_snapshot();
  const GURL& url = frame.document;
  if (!snapshot || snapshot->extensions.empty() || !url.is_valid()) {
    return out;
  }
  if (url.SchemeIs(kBlinkerExtensionScheme)) {
    if (run_at != BlinkerContentScript::RunAt::kDocumentStart) {
      return out;
    }
    for (const BlinkerInjectionSnapshot::Extension& extension :
         snapshot->extensions) {
      if (extension.id == url.host()) {
        out.emplace_back(kBlinkerMainWorldId, extension.page_shim,
                         /*is_css=*/false);
        break;
      }
    }
    return out;
  }

  if (!IsInjectableUrl(url) && !IsInjectableUrl(frame.about_parent) &&
      !IsInjectableUrl(frame.origin)) {
    return out;
  }
  for (const BlinkerInjectionSnapshot::Extension& extension :
       snapshot->extensions) {
    if (extension.isolated_world_id < 0) {
      continue;
    }
    const std::pair<BlinkerScriptWorld, int32_t> worlds[] = {
        {BlinkerScriptWorld::kIsolated, extension.isolated_world_id},
        {BlinkerScriptWorld::kMain, kBlinkerMainWorldId},
        {BlinkerScriptWorld::kUserScript, extension.user_script_world_id},
    };
    for (const auto& [world, world_id] : worlds) {
      if (world_id < 0) {
        continue;
      }
      // Стартова сторінка не сайт, юзерскрипти і світ сторінки там зайві
      if (frame.start_page && world != BlinkerScriptWorld::kIsolated) {
        continue;
      }
      for (PreparedInjection& injection :
           BuildPrograms(extension, frame, run_at, is_main_frame,
                         /*match_all_timings=*/false, world)) {
        injection.world_id = world_id;
        out.push_back(std::move(injection));
      }
    }
  }
  return out;
}

bool BlinkerWebExtensionRegistry::StartPageHasContentScripts() {
  const scoped_refptr<const BlinkerInjectionSnapshot> snapshot =
      injection_snapshot();
  if (!snapshot) {
    return false;
  }
  BlinkerFrameUrls frame;
  frame.document = GURL(kBlinkerStartPageUrl);
  frame.start_page = true;
  for (const BlinkerInjectionSnapshot::Extension& extension :
       snapshot->extensions) {
    if (extension.isolated_world_id >= 0 &&
        !BuildPrograms(extension, frame,
                       BlinkerContentScript::RunAt::kDocumentEnd,
                       /*is_main_frame=*/true, /*match_all_timings=*/true,
                       BlinkerScriptWorld::kIsolated)
             .empty()) {
      return true;
    }
  }
  return false;
}

void BlinkerWebExtensionRegistry::InjectContentScripts(WebContents* contents,
                                                       const GURL& url) {
  // Коли працює шлях рендерера, цей мовчить, інакше скрипти двічі
  if (renderer_injection_active() || !contents || extensions_.empty() ||
      !url.is_valid()) {
    return;
  }
  if (!IsInjectableUrl(url)) {
    return;
  }
  BlinkerFrameUrls frame_urls;
  frame_urls.document = url;
  RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    return;
  }
  const scoped_refptr<const BlinkerInjectionSnapshot> snapshot =
      injection_snapshot();
  if (!snapshot) {
    return;
  }
  for (const BlinkerInjectionSnapshot::Extension& extension :
       snapshot->extensions) {
    if (extension.isolated_world_id < 0) {
      continue;
    }
    for (const PreparedInjection& injection : BuildPrograms(
             extension, frame_urls, BlinkerContentScript::RunAt::kDocumentEnd,
             /*is_main_frame=*/true, /*match_all_timings=*/true,
             BlinkerScriptWorld::kIsolated)) {
      std::string program = injection.program->as_string();
      if (injection.is_css) {
        // Звідси таблицю стилів документа не вставити, лише елементом
        std::string escaped;
        base::EscapeJSONString(injection.program->as_string(),
                               /*put_in_quotes=*/true, &escaped);
        program = base::StrCat(
            {"(()=>{const s=document.createElement('style');s.textContent=",
             escaped, ";(document.head||document.documentElement)",
             ".appendChild(s);})();"});
      }
      frame->ExecuteJavaScriptInIsolatedWorld(base::UTF8ToUTF16(program),
                                              base::NullCallback(),
                                              extension.isolated_world_id);
    }
  }
}

namespace {

// Попередження й помилки воркерів у журнал запуску, обрізані щоб не світити
// сайти, з якими працює блокувальник
class ExtensionWorkerObserver : public ServiceWorkerContextObserver {
 public:
  void OnRegistrationCompleted(const GURL& scope) override {
    if (IsExtension(scope)) {
      ExtLog("EXTSW: registration completed " + scope.spec());
    }
  }
  void OnVersionActivated(int64_t version_id, const GURL& scope) override {
    if (IsExtension(scope)) {
      ExtLog("EXTSW: activated " + scope.spec());
    }
  }
  void OnVersionRedundant(int64_t version_id, const GURL& scope) override {
    if (IsExtension(scope)) {
      ExtLog("EXTSW: version redundant " + scope.spec());
    }
  }
  void OnErrorReported(int64_t version_id,
                       const GURL& scope,
                       const ErrorInfo& info) override {
    if (!IsExtension(scope)) {
      return;
    }
    ExtLog(base::StrCat({"EXTSW ERROR ", scope.spec(), " ",
                         Truncate(base::UTF16ToUTF8(info.error_message)), " @",
                         info.source_url.spec(), ":",
                         base::NumberToString(info.line_number), ":",
                         base::NumberToString(info.column_number)}));
  }
  void OnReportConsoleMessage(int64_t version_id,
                              const GURL& scope,
                              const ConsoleMessage& message) override {
    if (!IsExtension(scope)) {
      return;
    }
    if (message.message_level != blink::mojom::ConsoleMessageLevel::kError &&
        message.message_level != blink::mojom::ConsoleMessageLevel::kWarning) {
      return;
    }
    ExtLog(base::StrCat(
        {"EXTSW console ", scope.host(), " ",
         message.message_level == blink::mojom::ConsoleMessageLevel::kError
             ? "error: "
             : "warning: ",
         Truncate(base::UTF16ToUTF8(message.message)), " @",
         message.source_url.spec(), ":",
         base::NumberToString(message.line_number)}));
  }
  void OnDestruct(ServiceWorkerContext* context) override {
    context->RemoveObserver(this);
  }

 private:
  static bool IsExtension(const GURL& scope) {
    return scope.SchemeIs(kBlinkerExtensionScheme);
  }
  static std::string Truncate(std::string text) {
    if (text.size() > 400) {
      text.resize(400);
      text += "...";
    }
    return text;
  }
};

}  // namespace

namespace {

// Дозволи на хости в Chrome заодно знімають CORS з запитів розширення,
// без цього конфіги й API не вантажаться
std::vector<network::mojom::CorsOriginPatternPtr> CorsPatternsFor(
    const BlinkerWebExtension& extension) {
  std::vector<network::mojom::CorsOriginPatternPtr> patterns;
  const auto add = [&patterns](const std::string& scheme,
                               const std::string& host, bool subdomains) {
    patterns.push_back(network::mojom::CorsOriginPattern::New(
        scheme, host, /*port=*/0,
        subdomains ? network::mojom::CorsDomainMatchMode::kAllowSubdomains
                   : network::mojom::CorsDomainMatchMode::kDisallowSubdomains,
        network::mojom::CorsPortMatchMode::kAllowAnyPort,
        network::mojom::CorsOriginAccessMatchPriority::kDefaultPriority));
  };

  for (const std::vector<std::string>* list :
       {&extension.host_permissions, &extension.granted_optional}) {
    for (const std::string& pattern : *list) {
      if (pattern == "<all_urls>" || pattern == "*://*/*") {
        add("http", std::string(), /*subdomains=*/true);
        add("https", std::string(), /*subdomains=*/true);
        continue;
      }
      const size_t scheme_end = pattern.find("://");
      if (scheme_end == std::string::npos) {
        continue;
      }
      const std::string scheme = pattern.substr(0, scheme_end);
      std::string host = pattern.substr(scheme_end + 3);
      const size_t slash = host.find('/');
      if (slash != std::string::npos) {
        host = host.substr(0, slash);
      }
      bool subdomains = false;
      if (host.starts_with("*.")) {
        host = host.substr(2);
        subdomains = true;
      } else if (host == "*") {
        host.clear();
        subdomains = true;
      }
      if (scheme == "*") {
        add("http", host, subdomains);
        add("https", host, subdomains);
      } else {
        add(scheme, host, subdomains);
      }
    }
  }
  return patterns;
}

}  // namespace

namespace {

// Рахується раз з заглушками замість id і токена, бо токен щоразу новий
uint32_t BlinkerShimFingerprint() {
  static const uint32_t fingerprint = base::PersistentHash(base::StrCat({
      BlinkerExtensionStorageShim("id", "token"),
      BlinkerExtensionPrivilegedApiShim("id", "token"),
      BlinkerExtensionWorkerShim("id"),
      BlinkerExtensionApiSurfaceShim(),
  }));
  return fingerprint;
}

std::string WorkerScriptSignature(const BlinkerWebExtension& extension) {
  if (extension.background_service_worker.empty()) {
    return std::string();
  }
  base::FilePath script;
  if (!ResolveExtensionPath(extension.root, extension.background_service_worker,
                            &script)) {
    return std::string();
  }
  base::File::Info info;
  if (!base::GetFileInfo(script, &info)) {
    return std::string();
  }
  return base::StrCat(
      {base::NumberToString(info.size), ":",
       base::NumberToString(info.last_modified.ToDeltaSinceWindowsEpoch()
                                .InMicroseconds()),
       ":", base::NumberToString(BlinkerShimFingerprint())});
}

// На старті сховище воркерів може ще не піднятись, Chromium відповідає
// Operation has been aborted
constexpr int kWorkerRegisterAttempts = 6;
constexpr int kWorkerRegisterRetryMs = 400;

struct WorkerRegistrationTally {
  int expected = 0;
  int ok = 0;
  int failed = 0;
};

WorkerRegistrationTally& RegistrationTally() {
  static WorkerRegistrationTally tally;
  return tally;
}

void NoteRegistrationOutcome(bool ok) {
  WorkerRegistrationTally& tally = RegistrationTally();
  if (ok) {
    ++tally.ok;
  } else {
    ++tally.failed;
  }
  if (tally.expected > 0 && tally.ok + tally.failed >= tally.expected) {
    ExtLog(base::StrCat({"EXTSW: registration summary -- ",
                         base::NumberToString(tally.ok), " ok, ",
                         base::NumberToString(tally.failed), " failed, of ",
                         base::NumberToString(tally.expected)}));
    tally = WorkerRegistrationTally();
  }
}

bool WorkerRegistrationMayRecover(blink::ServiceWorkerStatusCode status) {
  switch (status) {
    case blink::ServiceWorkerStatusCode::kErrorAbort:
    case blink::ServiceWorkerStatusCode::kErrorFailed:
    case blink::ServiceWorkerStatusCode::kErrorTimeout:
    case blink::ServiceWorkerStatusCode::kErrorIpcFailed:
    case blink::ServiceWorkerStatusCode::kErrorState:
      return true;
    default:
      return false;
  }
}

void RegisterExtensionWorker(
    ServiceWorkerContext* context,
    GURL script,
    blink::StorageKey key,
    blink::mojom::ServiceWorkerRegistrationOptions options,
    std::string id,
    int attempt = 0) {
  const GURL scope = options.scope;
  context->RegisterServiceWorker(
      script, key, options, GlobalRenderFrameHostId(),
      base::BindOnce(
          [](ServiceWorkerContext* context, GURL script, GURL scope,
             blink::StorageKey key,
             blink::mojom::ServiceWorkerRegistrationOptions options,
             std::string id, int attempt,
             blink::ServiceWorkerStatusCode status) {
            if (status != blink::ServiceWorkerStatusCode::kOk &&
                WorkerRegistrationMayRecover(status) &&
                attempt + 1 < kWorkerRegisterAttempts) {
              ExtLog(base::StrCat(
                  {"EXTSW: ", id, " register -> ",
                   blink::ServiceWorkerStatusToString(status), ", retrying (",
                   base::NumberToString(attempt + 2), "/",
                   base::NumberToString(kWorkerRegisterAttempts), ")"}));
              base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
                  FROM_HERE,
                  base::BindOnce(&RegisterExtensionWorker, context,
                                 std::move(script), std::move(key),
                                 std::move(options), std::move(id),
                                 attempt + 1),
                  base::Milliseconds(kWorkerRegisterRetryMs * (attempt + 1)));
              return;
            }
            NoteRegistrationOutcome(status ==
                                    blink::ServiceWorkerStatusCode::kOk);
            if (status != blink::ServiceWorkerStatusCode::kOk) {
              // Спроби вичерпано, знімаємо засувку, щоб наступна навігація
              // спробувала ще раз
              BlinkerWebExtensionRegistry::GetInstance()
                  .AllowServiceWorkerReregistration();
            }
            ExtLog(base::StrCat({"EXTSW: ", id, " register -> ",
                                 blink::ServiceWorkerStatusToString(status)}));
            if (status == blink::ServiceWorkerStatusCode::kOk) {
              context->StartWorkerForScope(
                  scope, key, base::DoNothing(),
                  base::BindOnce(
                      [](std::string id, StatusCodeResponse response) {
                        if (response.status_code !=
                            blink::ServiceWorkerStatusCode::kOk) {
                          ExtLog(base::StrCat(
                              {"EXTSW: ", id, " start -> ",
                               blink::ServiceWorkerStatusToString(
                                   response.status_code)}));
                        }
                      },
                      id));
            }
          },
          context, script, scope, key, options, std::move(id), attempt));
}

void RegisterWorkerAfterUnregister(
    ServiceWorkerContext* context,
    GURL script,
    blink::StorageKey key,
    blink::mojom::ServiceWorkerRegistrationOptions options,
    std::string id,
    blink::ServiceWorkerStatusCode status) {
  ExtLog(base::StrCat({"EXTSW: ", id, " unregister -> ",
                       blink::ServiceWorkerStatusToString(status)}));
  RegisterExtensionWorker(context, std::move(script), std::move(key),
                          std::move(options), std::move(id));
}

}  // namespace

void BlinkerWebExtensionRegistry::PublishCorsAccess(
    BrowserContext* browser_context) {
  if (!browser_context) {
    return;
  }
  StoragePartition* partition = browser_context->GetDefaultStoragePartition();
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (!extension->enabled) {
      continue;
    }
    const url::Origin origin = url::Origin::Create(GURL(
        base::StrCat({kBlinkerExtensionScheme, "://", extension->id, "/"})));
    std::vector<network::mojom::CorsOriginPatternPtr> allow =
        CorsPatternsFor(*extension);
    if (allow.empty()) {
      continue;
    }
    if (partition && partition->GetNetworkContext()) {
      std::vector<network::mojom::CorsOriginPatternPtr> copy;
      for (const auto& pattern : allow) {
        copy.push_back(pattern.Clone());
      }
      partition->GetNetworkContext()->SetCorsOriginAccessListsForOrigin(
          origin, std::move(copy), {}, base::DoNothing());
    }
    browser_context->GetSharedCorsOriginAccessList()->SetForOrigin(
        origin, std::move(allow), {}, base::DoNothing());
  }
}

void BlinkerWebExtensionRegistry::EnsureServiceWorkersRegistered(
    BrowserContext* browser_context) {
  if (service_workers_registered_ || !browser_context) {
    return;
  }
  StoragePartition* partition = browser_context->GetDefaultStoragePartition();
  ServiceWorkerContext* service_worker_context =
      partition ? partition->GetServiceWorkerContext() : nullptr;
  if (!service_worker_context) {
    return;
  }
  service_workers_registered_ = true;
  PublishCorsAccess(browser_context);
  static bool observer_added = false;
  if (!observer_added) {
    observer_added = true;
    static base::NoDestructor<ExtensionWorkerObserver> observer;
    service_worker_context->AddObserver(observer.get());
  }

  {
    WorkerRegistrationTally& tally = RegistrationTally();
    tally = WorkerRegistrationTally();
    for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
      if (extension->enabled &&
          !extension->background_service_worker.empty()) {
        ++tally.expected;
      }
    }
  }

  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (!extension->enabled || extension->background_service_worker.empty()) {
      continue;
    }
    const GURL scope(base::StrCat(
        {kBlinkerExtensionScheme, "://", extension->id, "/"}));
    const GURL script = scope.Resolve(extension->background_service_worker);
    if (!scope.is_valid() || !script.is_valid()) {
      continue;
    }
    blink::mojom::ServiceWorkerRegistrationOptions options(
        scope,
        extension->background_is_module ? blink::mojom::ScriptType::kModule
                                        : blink::mojom::ScriptType::kClassic,
        blink::mojom::ServiceWorkerUpdateViaCache::kImports);
    const std::string id = extension->id;
    const blink::StorageKey key =
        blink::StorageKey::CreateFirstParty(url::Origin::Create(scope));

    // Новий воркер без skipWaiting тільки чекав би, а працював старий код
    const std::string signature = WorkerScriptSignature(*extension);
    if (!signature.empty() && signature != extension->worker_signature) {
      if (!extension->worker_signature.empty()) {
        ExtLog(base::StrCat({"EXTSW: ", id,
                             " background script changed, replacing worker"}));
      }
      extension->worker_signature = signature;
      SaveState(*extension);
      service_worker_context->UnregisterServiceWorkerImmediately(
          scope, key,
          base::BindOnce(&RegisterWorkerAfterUnregister, service_worker_context,
                         script, key, options, id));
      continue;
    }
    RegisterExtensionWorker(service_worker_context, script, key, options, id);
  }
}

bool BlinkerWebExtensionRegistry::ResolveResource(
    const GURL& url,
    const std::optional<url::Origin>& initiator,
    ResolvedResource* out) {
  if (!loaded_) {
    LoadAll();
  }
  if (!url.SchemeIs(kBlinkerExtensionScheme) || !url.has_host()) {
    return false;
  }
  const std::string id(url.host());
  // Окремий хост, бо розширення про яке звіт могло не встановитись взагалі
  if (id == kBlinkerInstallHost) {
    out->is_install_page = true;
    return true;
  }
  const BlinkerWebExtension* found = nullptr;
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (extension->enabled && extension->id == id) {
      found = extension.get();
      break;
    }
  }
  if (!found) {
    return false;
  }
  std::string relative(url.path());
  if (!relative.empty() && relative.front() == '/') {
    relative.erase(relative.begin());
  }
  if (relative.empty()) {
    return false;
  }
  out->extension_id = id;
  out->initiator_is_extension =
      initiator.has_value() && initiator->scheme() == kBlinkerExtensionScheme &&
      initiator->host() == id;

  // Текст містить токен, тому web_accessible_resources його не відкривають
  if (relative == kBlinkerWorkerShimPath) {
    if (!found->background_is_module ||
        found->background_service_worker.empty() ||
        (initiator.has_value() && !out->initiator_is_extension)) {
      return false;
    }
    out->is_worker_shim = true;
    return true;
  }

  // Міст генерується. Це єдиний документ розширення, до якого дістає content
  // script
  if (relative == kBlinkerBridgePath) {
    out->synthesized = true;
    out->messaging_token = found->messaging_token;
    return true;
  }

  // Відповідає браузер, тож перевірки файлів нижче її не стосуються
  if (relative == kBlinkerApiPath) {
    out->is_api_endpoint = true;
    out->messaging_token = found->messaging_token;
    out->unlimited_storage = found->unlimited_storage;
    return true;
  }

  base::FilePath resolved;
  if (!ResolveExtensionPath(found->root, relative, &resolved)) {
    return false;
  }

  // Скрипт воркера браузер вантажить без ініціатора, і маніфест не оголошує
  // його доступним, тому пускаємо завжди
  if (!found->background_service_worker.empty() &&
      relative == found->background_service_worker) {
    // Класична відповідь воркера містить токен API, тож її отримує тільки
    // браузер або саме розширення
    if (initiator.has_value() && !out->initiator_is_extension) {
      return false;
    }
    out->path = std::move(resolved);
    out->is_background_script = true;
    return true;
  }

  const bool from_self =
      initiator.has_value() && initiator->scheme() == kBlinkerExtensionScheme &&
      initiator->host() == id;
  const bool from_browser = !initiator.has_value();
  if (!from_self && !from_browser) {
    bool allowed = false;
    for (const std::string& pattern : found->web_accessible_resources) {
      if (blinker_extensions::GlobMatches(pattern, relative)) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      return false;
    }
  }
  out->path = std::move(resolved);
  return true;
}

size_t BlinkerWebExtensionRegistry::enabled_count() const {
  return static_cast<size_t>(std::count_if(
      extensions_.begin(), extensions_.end(),
      [](const std::unique_ptr<BlinkerWebExtension>& extension) {
        return extension->enabled;
      }));
}

void BlinkerWebExtensionRegistry::SetEnabled(std::string_view id,
                                             bool enabled) {
  for (const std::unique_ptr<BlinkerWebExtension>& extension : extensions_) {
    if (extension->id == id) {
      extension->enabled = enabled;
      SaveState(*extension);
      break;
    }
  }
  PublishFilterRules();
  PublishInjectionSnapshot();
}

}  // namespace content

extern "C" unsigned long BlinkExtensionCount() {
  return static_cast<unsigned long>(
      content::BlinkerWebExtensionRegistry::GetInstance().extensions().size());
}

extern "C" unsigned long BlinkExtensionEnabledCount() {
  return static_cast<unsigned long>(
      content::BlinkerWebExtensionRegistry::GetInstance().enabled_count());
}

extern "C" void BlinkExtensionReload() {
  content::BlinkerWebExtensionRegistry::GetInstance().LoadAll();
}

extern "C" void BlinkExtensionSetEnabled(const char* id, bool enabled) {
  if (id) {
    content::BlinkerWebExtensionRegistry::GetInstance().SetEnabled(id, enabled);
  }
}
