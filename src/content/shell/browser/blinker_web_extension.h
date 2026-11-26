// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_WEB_EXTENSION_H_
#define CONTENT_SHELL_BROWSER_BLINKER_WEB_EXTENSION_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/compiler_specific.h"
#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/ref_counted.h"
#include "base/memory/ref_counted_memory.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/thread_annotations.h"
#include "base/values.h"
#include "content/shell/common/blinker_extension_l10n.h"
#include "content/shell/common/blinker_match_pattern.h"
#include "url/gurl.h"

namespace url {
class Origin;
}  // namespace url

namespace content {

class BrowserContext;
class WebContents;

// Як у Chrome, бо розширення зашивають схему в себе.
inline constexpr char kBlinkerExtensionScheme[] = "chrome-extension";
// Стартова сторінка вкладки це порожній about:blank під рідним екраном. Скрипти
// розширень бачать її як сторінку на цьому зарезервованому хості, що ніколи не
// розв'язується, тож Shimeji та подібні малюють і на ній.
inline constexpr char kBlinkerStartPageUrl[] = "https://start.blinker.invalid/";

// Окремий модуль, щоб API були вже під час виконання залежностей воркера.
inline constexpr char kBlinkerWorkerShimPath[] = "__blinker_worker_api__.js";

// Світ сторінки. Для власних сторінок розширення, їх ізолювати не треба.
inline constexpr int32_t kBlinkerMainWorldId = 0;

// Окремий світ для userScripts, щоб код користувача не діставав chrome.*
// розширення.
enum class BlinkerScriptWorld {
  kIsolated,
  kMain,
  kUserScript,
};

// Розширення Chrome без платформи розширень, бо на iOS її нема. Текст
// скрипта спільний для реєстру, знімка і рендерера, без копій.
using BlinkerScriptText = scoped_refptr<const base::RefCountedString>;

struct BlinkerContentScript {
  enum class RunAt {
    kDocumentStart,
    kDocumentEnd,
    kDocumentIdle,
  };

  BlinkerContentScript();
  BlinkerContentScript(const BlinkerContentScript&);
  BlinkerContentScript& operator=(const BlinkerContentScript&);
  BlinkerContentScript(BlinkerContentScript&&);
  BlinkerContentScript& operator=(BlinkerContentScript&&);
  ~BlinkerContentScript();

  blinker_extensions::ScriptUrlFilter matches;
  // Кожен файл окремо, бо Chrome виконує кожен файл окремим скриптом.
  std::vector<BlinkerScriptText> js;
  BlinkerScriptText css;
  RunAt run_at = RunAt::kDocumentIdle;
  bool all_frames = false;
  bool match_about_blank = false;
  bool match_origin_as_fallback = false;
  BlinkerScriptWorld world = BlinkerScriptWorld::kIsolated;
};

// Фрейми about, data і blob Chrome зіставляє по адресі того, хто їх створив.
struct BlinkerFrameUrls {
  GURL document;
  // Документ це стартова сторінка. Для неї працюють лише звичайні скрипти
  // розширень, юзерскрипти і скрипти світу сторінки ні, бо це не сайт.
  bool start_page = false;
  // Найближчий предок не з about, для match_about_blank.
  GURL about_parent;
  // Походження документа або його попередника, для match_origin_as_fallback.
  GURL origin;
};

blinker_extensions::UrlParts BlinkerUrlParts(const GURL& url LIFETIME_BOUND);

struct BlinkerDynamicScript {
  BlinkerDynamicScript();
  BlinkerDynamicScript(BlinkerDynamicScript&&);
  BlinkerDynamicScript& operator=(BlinkerDynamicScript&&);
  ~BlinkerDynamicScript();

  std::string id;
  BlinkerContentScript script;
  // Через chrome.userScripts. У Chrome окремий реєстр і окремі списки.
  bool is_user_script = false;
  // Для getRegisteredContentScripts і повтору реєстрації при старті.
  base::DictValue spec;
};

// Набори вмикаються окремо через updateEnabledRulesets, тому не зливаємо.
struct BlinkerStaticRuleset {
  std::string id;
  bool enabled = true;
  // Одним текстом через перенос рядка. std::string на кожне правило коштував
  // сотні байтів RSS, а так фільтр бере текст без копії.
  std::shared_ptr<const std::string> filter_text;
  size_t filter_line_count = 0;
  // redirect і modifyHeaders, рядком фільтра їх не виразиш. Сирі, щоб
  // перебудувати при перемиканні набору.
  std::vector<base::DictValue> action_rules;
  size_t rule_count = 0;  // як оголошено, до відкидання
};

struct BlinkerPermissionChange {
  std::vector<std::string> permissions;
  std::vector<std::string> origins;
};

class BlinkerWebExtension {
 public:
  BlinkerWebExtension();
  ~BlinkerWebExtension();
  BlinkerWebExtension(const BlinkerWebExtension&) = delete;
  BlinkerWebExtension& operator=(const BlinkerWebExtension&) = delete;

  // Шматки спільні, тож публікація у фільтр нічого не копіює.
  std::vector<std::shared_ptr<const std::string>> ActiveFilterChunks() const;
  size_t ActiveFilterLineCount() const;

  std::string id;  // ім'я теки, стабільне, воно ж runtime.id
  std::string name;
  std::string version;
  std::string default_locale;
  int manifest_version = 0;
  base::FilePath root;
  base::DictValue manifest;
  // Повідомлення з _locales, злиті за правилами Chrome, разом із @@.
  blinker_extensions::L10nMessages messages;
  std::vector<BlinkerContentScript> content_scripts;
  std::vector<BlinkerStaticRuleset> static_rulesets;
  base::ListValue dynamic_rules;  // сирі правила DNR, зберігаються
  base::ListValue session_rules;  // тільки на цей сеанс
  std::shared_ptr<const std::string> dynamic_filter_text;
  size_t dynamic_filter_line_count = 0;
  std::shared_ptr<const std::string> session_filter_text;
  size_t session_filter_line_count = 0;
  std::vector<base::DictValue> dynamic_action_rules;
  std::vector<base::DictValue> session_action_rules;
  // Запиту дозволу нема, користувач вже встановив розширення яке їх оголошує.
  std::vector<std::string> permissions;
  std::vector<std::string> host_permissions;
  std::vector<std::string> optional_permissions;
  std::vector<std::string> optional_host_permissions;
  std::vector<std::string> granted_optional;
  // Доки воркер після встановлення не почув runtime.onInstalled.
  bool first_run = true;
  // Версія, про яку воркер уже знає. Інша за `version` означає оновлення.
  std::string stored_version;
  // Інша збірка браузера означає chrome_update.
  std::string stored_browser_version;
  base::DictValue api_state;
  // З малого пулу ізольованих світів, що лишає iOS. -1 якщо світу не
  // вистачило.
  int32_t isolated_world_id = -1;
  int32_t user_script_world_id = -1;
  // configureWorld({messaging:true}), без запиту вимкнено як у Chrome.
  bool user_script_messaging = false;
  bool enabled = true;
  std::vector<std::string> web_accessible_resources;
  std::string background_service_worker;
  bool background_is_module = false;
  bool unlimited_storage = false;
  // Зберігаються, бо persistAcrossSessions за замовчуванням true.
  std::vector<BlinkerDynamicScript> dynamic_scripts;
  // Секрет сеансу, щоб міст слухав лише content script свого розширення.
  // Сторінка не бачить жодної з двох сторін.
  std::string messaging_token;
  // Розмір і mtime скрипта воркера. Якщо змінились, воркер треба замінити, бо
  // інакше крутиться старий код.
  std::string worker_signature;
  // Щоб налаштування чесно показували, що підтримується не все.
  std::vector<std::string> unsupported_features;

  mutable BlinkerScriptText content_shim_cache;
  mutable BlinkerScriptText page_shim_cache;
};

// Рендерер працює в окремому потоці того ж процесу, тому читає лише
// незмінний знімок, а реєстр міняє тільки UI.
struct BlinkerInjectionSnapshot
    : public base::RefCountedThreadSafe<BlinkerInjectionSnapshot> {
  struct Extension {
    Extension();
    Extension(const Extension&);
    Extension& operator=(const Extension&);
    ~Extension();

    std::string id;
    int32_t isolated_world_id = -1;
    int32_t user_script_world_id = -1;
    // Спершу скрипти маніфесту, потім зареєстровані.
    std::vector<BlinkerContentScript> scripts;
    BlinkerScriptText content_shim;
    BlinkerScriptText page_shim;
    // Порожній, якщо розширення не вмикало messaging для user scripts.
    BlinkerScriptText user_script_shim;
  };

  BlinkerInjectionSnapshot();

  std::vector<Extension> extensions;

 private:
  friend class base::RefCountedThreadSafe<BlinkerInjectionSnapshot>;
  ~BlinkerInjectionSnapshot();
};

class BlinkerWebExtensionRegistry {
 public:
  static BlinkerWebExtensionRegistry& GetInstance();

  BlinkerWebExtensionRegistry(const BlinkerWebExtensionRegistry&) = delete;
  BlinkerWebExtensionRegistry& operator=(const BlinkerWebExtensionRegistry&) =
      delete;

  // Повторний виклик перечитує з диска.
  void LoadAll();

  bool loaded() const { return loaded_; }

  const std::vector<std::unique_ptr<BlinkerWebExtension>>& extensions() const {
    return extensions_;
  }

  // Запасний шлях з браузера, лише головний фрейм. Вимикається, щойно
  // запрацює рендерер.
  void InjectContentScripts(WebContents* contents, const GURL& url);

  // Кличеться з потоку рендерера і читає тільки знімок.
  struct PreparedInjection {
    PreparedInjection();
    PreparedInjection(int32_t world_id, BlinkerScriptText program, bool is_css);
    PreparedInjection(const PreparedInjection&);
    PreparedInjection& operator=(const PreparedInjection&);
    ~PreparedInjection();

    int32_t world_id = -1;
    BlinkerScriptText program;
    // Як в Chrome, таблицею стилів документа, тож сторінка її не прибере і CSP
    // не заблокує.
    bool is_css = false;
  };
  std::vector<PreparedInjection> PrepareInjections(
      const BlinkerFrameUrls& frame,
      BlinkerContentScript::RunAt run_at,
      bool is_main_frame);

  // Чи вставить хоч одне розширення скрипт на стартову сторінку. Тоді вона
  // стає прозорою, щоб те, що малює скрипт, було видно під її елементами.
  bool StartPageHasContentScripts();

  // Безпечно з кожного потоку.
  scoped_refptr<const BlinkerInjectionSnapshot> injection_snapshot() const;

  // Після цього запасний шлях браузера мовчить, щоб не було подвійної
  // ін'єкції.
  bool renderer_injection_active() const {
    return renderer_injection_active_.load(std::memory_order_relaxed);
  }
  void MarkRendererInjectionActive() {
    renderer_injection_active_.store(true, std::memory_order_relaxed);
  }

  void PublishCorsAccess(BrowserContext* browser_context);

  void EnsureServiceWorkersRegistered(BrowserContext* browser_context);
  // Знімає засувку після остаточного збою реєстрації. Повторна реєстрація
  // вже зареєстрованого воркера нічого не міняє.
  void AllowServiceWorkerReregistration() {
    service_workers_registered_ = false;
  }

  struct ResolvedResource {
    base::FilePath path;
    std::string extension_id;
    bool is_background_script = false;
    // Містить приватний токен, тому доступний лише самому розширенню.
    bool is_worker_shim = false;
    // Документ мосту, генерується а не читається з диска.
    bool synthesized = false;
    std::string messaging_token;
    bool is_api_endpoint = false;
    bool initiator_is_extension = false;
    bool unlimited_storage = false;
    bool is_install_page = false;
  };

  // false якщо розширення нема, шлях виходить за його теку або initiator
  // не має доступу.
  bool ResolveResource(const GURL& url,
                       const std::optional<url::Origin>& initiator,
                       ResolvedResource* out);

  bool UpdateRules(std::string_view extension_id,
                   bool session,
                   const std::vector<int>& remove_ids,
                   const base::ListValue* add_rules,
                   std::string* error);
  base::ListValue GetRules(std::string_view extension_id,
                           bool session,
                           const std::vector<int>& only_ids);
  bool UpdateEnabledRulesets(std::string_view extension_id,
                             const std::vector<std::string>& disable,
                             const std::vector<std::string>& enable,
                             std::string* error);

  // Повертають текст помилки Chrome або порожньо. Походження зіставляються
  // як шаблони, "https://a.test/x/*" входить в "https://*/*".
  std::string ContainsPermissions(std::string_view extension_id,
                                  const std::vector<std::string>& permissions,
                                  const std::vector<std::string>& origins,
                                  bool* result);
  std::string RequestPermissions(std::string_view extension_id,
                                 const std::vector<std::string>& permissions,
                                 const std::vector<std::string>& origins,
                                 BlinkerPermissionChange* added);
  std::string RemovePermissions(std::string_view extension_id,
                                const std::vector<std::string>& permissions,
                                const std::vector<std::string>& origins,
                                BlinkerPermissionChange* removed);
  base::DictValue GetAllPermissions(std::string_view extension_id);

  // onInstalled приходить при встановленні й оновленні, onStartup раз за
  // запуск застосунку.
  struct Lifecycle {
    std::string install_reason;
    std::string previous_version;
    bool startup = false;
  };
  Lifecycle ConsumeLifecycle(std::string_view extension_id);

  // Будильники і пункти меню, які Chrome зберігає між запусками.
  void SetApiState(std::string_view extension_id, base::DictValue state);

  // Як Chrome для чутливих API, дозвіл плюс доступ до сайту `url`.
  bool HasApiAccess(std::string_view extension_id,
                    std::string_view permission,
                    const GURL& url);
  bool HasPermission(std::string_view extension_id,
                     std::string_view permission);
  // Шлях не має значення, як у Chrome.
  bool HasHostPermission(std::string_view extension_id, const GURL& url);

  bool RegisterUserScripts(std::string_view extension_id,
                           const base::ListValue& scripts,
                           bool update,
                           std::string* error);
  void UnregisterUserScripts(std::string_view extension_id,
                             const std::vector<std::string>& ids);
  base::ListValue GetUserScripts(std::string_view extension_id,
                                 const std::vector<std::string>& ids);
  void ConfigureUserScriptWorld(std::string_view extension_id, bool messaging);

  // Для register помилка це повторний id, для update відсутній.
  bool RegisterDynamicScripts(std::string_view extension_id,
                              const base::ListValue& scripts,
                              bool update,
                              std::string* error);
  // Порожній `ids` значить усі скрипти, як фільтр без значення в Chrome.
  void UnregisterDynamicScripts(std::string_view extension_id,
                                const std::vector<std::string>& ids);
  base::ListValue GetDynamicScripts(std::string_view extension_id,
                                    const std::vector<std::string>& ids);

  // Завантажує реєстр при першому виклику.
  BlinkerWebExtension* FindExtension(std::string_view id);

  bool RegisterScriptsImpl(std::string_view extension_id,
                           const base::ListValue& scripts,
                           bool update,
                           bool user_scripts,
                           std::string* error);
  void UnregisterScriptsImpl(std::string_view extension_id,
                             const std::vector<std::string>& ids,
                             bool user_scripts);
  base::ListValue GetScriptsImpl(std::string_view extension_id,
                                 const std::vector<std::string>& ids,
                                 bool user_scripts);

  size_t enabled_count() const;
  void SetEnabled(std::string_view id, bool enabled);

 private:
  friend class base::NoDestructor<BlinkerWebExtensionRegistry>;
  BlinkerWebExtensionRegistry();
  ~BlinkerWebExtensionRegistry();

  std::unique_ptr<BlinkerWebExtension> LoadOne(const base::FilePath& dir,
                                               int32_t world_id);
  void PublishFilterRules();

  // CSS іде на document_start при любому run_at. Світ MAIN без шіма, а у
  // userScripts лише sendMessage, якщо ввімкнено. world_id ставить виклик.
  static std::vector<PreparedInjection> BuildPrograms(
      const BlinkerInjectionSnapshot::Extension& extension,
      const BlinkerFrameUrls& frame,
      BlinkerContentScript::RunAt run_at,
      bool is_main_frame,
      bool match_all_timings,
      BlinkerScriptWorld world);

  // Кликати після кожної зміни, що впливає на ін'єкцію.
  void PublishInjectionSnapshot();

  void LoadDynamicScripts(BlinkerWebExtension* extension);
  void SaveDynamicScripts(const BlinkerWebExtension& extension);
  void LoadState(BlinkerWebExtension* extension);
  void SaveState(const BlinkerWebExtension& extension);

  std::vector<std::unique_ptr<BlinkerWebExtension>> extensions_;
  bool loaded_ = false;
  std::set<std::string> started_this_launch_;
  std::atomic<bool> renderer_injection_active_{false};
  bool service_workers_registered_ = false;

  mutable base::Lock snapshot_lock_;
  scoped_refptr<const BlinkerInjectionSnapshot> snapshot_
      GUARDED_BY(snapshot_lock_);
};

// Ідемпотентний, тому годиться і для воркера, і для сторінки.
std::string BlinkerExtensionBaseShim(const BlinkerWebExtension& extension);

// Той самий шім і для chrome.scripting.executeScript у світі ISOLATED.
BlinkerScriptText BlinkerExtensionContentScriptShim(
    const BlinkerWebExtension& extension);

bool BlinkerReadExtensionFile(const BlinkerWebExtension& extension,
                              std::string_view relative,
                              std::string* contents);

std::string BlinkerLocalizeCss(const BlinkerWebExtension& extension,
                               std::string css);

// Своя Documents і спільна /var/mobile/Documents, бо яка читається залежить
// від способу встановлення.
std::vector<base::FilePath> BlinkerExtensionDirectories();

base::FilePath BlinkerExtensionsDirectory();

// Як теки ще нема (нова установка), створює Documents/BlinkerExtensions.
base::FilePath BlinkerEnsureExtensionsDirectory();

void BlinkerRemoveExtension(std::string_view id);

// Архів розширень разом з їх станом і сховищем, порожній шлях значить збій.
void BlinkerBackUpExtensions(base::OnceCallback<void(base::FilePath)> done);

// Готує архів до відновлення при наступному запуску. Кількість розширень в
// ньому або -1.
void BlinkerStageExtensionRestore(const base::FilePath& archive,
                                  base::OnceCallback<void(int)> done);

// chrome_url_overrides.newtab останнього ввімкненого розширення, яке його
// оголосило, або порожній GURL.
GURL BlinkerNewTabOverrideURL();

// Пошук з chrome_settings_overrides.search_provider з is_default, або
// порожній рядок, коли такого розширення нема.
std::string BlinkerExtensionSearchURL(std::string_view terms);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_WEB_EXTENSION_H_
