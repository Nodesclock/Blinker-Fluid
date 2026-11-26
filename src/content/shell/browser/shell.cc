// Copyright 2013 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell.h"

#include <stddef.h>
#include <stdint.h>

#include <array>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"
#include "base/location.h"
#include "base/memory/memory_pressure_listener.h"
#include "base/memory/raw_ptr.h"
#include "base/run_loop.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "build/build_config.h"
#include "components/custom_handlers/protocol_handler.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/custom_handlers/simple_protocol_handler_registry_factory.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/color_chooser.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/document_picture_in_picture_window_controller.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/presentation_receiver_flags.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/renderer_preferences_util.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/content_switches.h"
#include "content/shell/app/resource.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_extensions.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/browser/shell_devtools_frontend.h"
#include "content/shell/browser/shell_javascript_dialog_manager.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_memory_policy.h"
#include "content/shell/common/blinker_private_logging.h"
#include "content/shell/common/blinker_site_policy.h"
#include "content/shell/common/shell_switches.h"
#include "media/media_buildflags.h"
#include "net/base/net_errors.h"
#include "net/base/url_util.h"
#include "net/cookies/canonical_cookie.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "third_party/blink/public/common/peerconnection/webrtc_ip_handling_policy.h"
#include "third_party/blink/public/common/renderer_preferences/renderer_preferences.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom-forward.h"
#include "third_party/blink/public/mojom/input/pointer_lock_result.mojom.h"
#include "third_party/blink/public/mojom/loader/resource_load_info.mojom.h"
#include "third_party/blink/public/mojom/window_features/window_features.mojom.h"
#include "ui/base/mojom/window_open_disposition.mojom-shared.h"
#include "url/origin.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdio.h>
#include <sys/utsname.h>
#include <time.h>

extern "C" int BlinkActiveRWHVCount();
extern "C" int BlinkActiveBrowserCompositorCount();
extern "C" int BlinkActiveAttachedCALayerCount();
extern "C" void BlinkDiscardBackgroundTabs(content::Shell* keep);
void BlinkApplyPrivacyRendererPrefs(blink::RendererPreferences* prefs);
extern "C" void BlinkDiscardBackgroundTabsUnderPressure();
extern "C" void BlinkTabAudioStateChanged(content::Shell* shell);
#endif

namespace content {

namespace {

constexpr int kDefaultTestWindowWidthDip = 800;
constexpr int kDefaultTestWindowHeightDip = 600;

// Owning pointer. We can not use unique_ptr as a global. That introduces a
// static constructor/destructor.
// Acquired in Shell::Init(), released in Shell::Shutdown().
ShellPlatformDelegate* g_platform;

#if BUILDFLAG(IS_IOS)
// Межі пам'яті рахуються з реального ліміту jetsam при першому зверненні
// (blinker_memory_policy.h), а не під час статичної ініціалізації.
constexpr bool kEnableIOSGlobalLowMemoryGuard = true;
bool g_global_low_memory_mode = false;
int g_main_frame_navigation_start_count = 0;
base::TimeTicks g_duplicate_view_first_seen;
base::TimeTicks g_last_oom_watchdog_sample;
uint64_t g_last_oom_watchdog_footprint = 0;
uint64_t g_last_oom_watchdog_rss = 0;
constexpr size_t kRecentLoadStartSlots = 16;
constexpr size_t kRecentAuthSlots = 10;
const char* g_last_user_action = "startup";
std::array<base::TimeTicks, kRecentLoadStartSlots> g_recent_load_starts;
size_t g_recent_load_start_head = 0;
bool g_ai_guard_logged_for_page = false;
base::TimeTicks g_last_ai_purge;
uint64_t g_last_heavy_heartbeat_footprint = 0;
bool g_in_auth_flow = false;
std::array<std::string, kRecentAuthSlots> g_recent_auth_urls;
std::array<base::TimeTicks, kRecentAuthSlots> g_recent_auth_times;
size_t g_recent_auth_head = 0;
bool g_chatgpt_auth_breaker_used = false;
bool g_chatgpt_mweb_logged = false;
// 0 звичайний, 1 desktop, 2 мобільний Safari.
int g_chatgpt_auth_profile = 2;
// Коли на сторінках з чатом нема метрик каретки і DOM.
float g_keyboard_chat_fallback_ratio = 0.0f;
constexpr float kChatInputFallbackBottomRatio = 0.92f;
// Пишеться і читається тільки на UI потоці.
bool g_is_chat_keyboard_relocation_site = false;

// Відкрите вікно OAuth і його відкривач.
WebContents* g_auth_popup_contents = nullptr;
WebContents* g_auth_popup_opener = nullptr;

bool IsHeavySiteURL(const GURL& url);

using blinker_logging::IsPrivateSession;
using blinker_logging::LoggableURLSpec;

struct BlinkMemoryStats {
  uint64_t resident_size = 0;
  uint64_t phys_footprint = 0;
  uint64_t virtual_size = 0;
  kern_return_t basic_kr = KERN_FAILURE;
  kern_return_t vm_kr = KERN_FAILURE;
};

BlinkMemoryStats GetBlinkMemoryStats() {
  BlinkMemoryStats stats;
  mach_task_basic_info_data_t basic_info;
  mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
  stats.basic_kr =
      task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&basic_info), &basic_count);
  if (stats.basic_kr == KERN_SUCCESS) {
    stats.resident_size = basic_info.resident_size;
    stats.virtual_size = basic_info.virtual_size;
  }

  task_vm_info_data_t vm_info;
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  stats.vm_kr = task_info(mach_task_self(), TASK_VM_INFO,
                          reinterpret_cast<task_info_t>(&vm_info), &vm_count);
  if (stats.vm_kr == KERN_SUCCESS) {
    stats.phys_footprint = vm_info.phys_footprint;
  }
  return stats;
}

size_t CountLivePrimaryFrames() {
  size_t live_frames = 0;
  for (Shell* shell : Shell::windows()) {
    WebContents* contents = shell->web_contents();
    if (contents && contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
      ++live_frames;
    }
  }
  return live_frames;
}

size_t CountRendererProcesses() {
  size_t renderers = 0;
  for (auto it = RenderProcessHost::AllHostsIterator(); !it.IsAtEnd();
       it.Advance()) {
    ++renderers;
  }
  return renderers;
}

void StoreHeavyPageHeartbeat(const GURL* url, const BlinkMemoryStats& stats) {
  if (!url || !url->is_valid() || !IsHeavySiteURL(*url)) {
    return;
  }
  char footprint[64];
  snprintf(footprint, sizeof(footprint), "%llu",
           static_cast<unsigned long long>(stats.phys_footprint));
  CFStringRef footprint_value = CFStringCreateWithCString(
      kCFAllocatorDefault, footprint, kCFStringEncodingUTF8);
  if (footprint_value) {
    CFPreferencesSetAppValue(CFSTR("BlinkLastHeartbeatFootprint"),
                             footprint_value, kCFPreferencesCurrentApplication);
    CFRelease(footprint_value);
  }

  BLINKER_DIAGF("HEARTBEAT: timestamp=%ld footprint=%llu url=%s",
                static_cast<long>(time(nullptr)),
                static_cast<unsigned long long>(stats.phys_footprint),
                LoggableURLSpec(*url).c_str());
}

void BlinkLogMemoryPressurePoint(const char* label, const GURL* url) {
  const BlinkMemoryStats stats = GetBlinkMemoryStats();

  BLINKER_DIAGF(
      "MEMSTAT: %s rss=%llu footprint=%llu vsize=%llu basic_kr=%d "
      "vm_kr=%d renderers=%zu web_contents=%zu active_frames=%zu "
      "cache_size=-1 url=%s",
      label, static_cast<unsigned long long>(stats.resident_size),
      static_cast<unsigned long long>(stats.phys_footprint),
      static_cast<unsigned long long>(stats.virtual_size), stats.basic_kr,
      stats.vm_kr, CountRendererProcesses(), Shell::windows().size(),
      CountLivePrimaryFrames(), url ? LoggableURLSpec(*url).c_str() : "(none)");
  StoreHeavyPageHeartbeat(url, stats);

  if (kEnableIOSGlobalLowMemoryGuard &&
      stats.phys_footprint >= blinker_memory::CriticalFootprint()) {
    BLINKER_DIAG(
        "GLOBAL_MEM_GUARD: footprint over critical threshold -> purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  }
}

bool IsRedditURL(const GURL& url) {
  return url.DomainIs("reddit.com");
}

bool IsYouTubeURL(const GURL& url) {
  return url.DomainIs("youtube.com");
}

bool IsGitHubURL(const GURL& url) {
  return url.DomainIs("github.com");
}

bool IsGoogleAuthURL(const GURL& url) {
  return url.DomainIs("google.com");
}

bool IsGoogleAuthPopupRequest(const GURL& requested_url) {
  if (!requested_url.IsAboutBlank()) {
    return false;
  }
  for (Shell* shell : Shell::windows()) {
    if (!shell->web_contents()) {
      continue;
    }
    GURL current = shell->web_contents()->GetVisibleURL();
    if (!current.is_valid()) {
      current = shell->web_contents()->GetLastCommittedURL();
    }
    if (IsGoogleAuthURL(current)) {
      return true;
    }
  }
  return false;
}

// Впізнає about:blank вікно OAuth ще до переходу на accounts.google.com.
bool IsClaudeGoogleAuthPopup(WebContents* source, const GURL& target_url) {
  if (!source) {
    return false;
  }
  GURL opener = source->GetLastCommittedURL();
  if (!opener.is_valid()) {
    opener = source->GetVisibleURL();
  }
  const bool opener_ok =
      opener.DomainIs("claude.ai") || opener.host() == "accounts.google.com";
  if (!opener_ok) {
    return false;
  }
  return target_url.IsAboutBlank() || IsGoogleAuthURL(target_url) ||
         target_url.host() == "accounts.google.com";
}

bool IsHeavySiteURL(const GURL& url) {
  return blinker_sites::HasTrait(url.host(), blinker_sites::kHeavy) ||
         (url.DomainIs("google.com") && url.path() == "/search");
}

bool SameHeavySite(const GURL& a, const GURL& b) {
  if (!IsHeavySiteURL(a) || !IsHeavySiteURL(b)) {
    return false;
  }
  return a.host() == b.host() || (IsRedditURL(a) && IsRedditURL(b)) ||
         (IsYouTubeURL(a) && IsYouTubeURL(b));
}

bool IsSameTopLevelSite(const GURL& a, const GURL& b) {
  if (!a.is_valid() || !b.is_valid()) {
    return false;
  }
  return a.host() == b.host();
}

// Критичне скидання чистить і bfcache, і декодовані картинки, тож без
// нестачі пам'яті воно лише робить наступну сторінку і Назад холодними.
void PurgeIfMemoryIsTight(uint64_t footprint) {
  if (footprint >= blinker_memory::CriticalFootprint()) {
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  } else if (footprint >= blinker_memory::ModerateFootprint()) {
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_MODERATE);
  }
}

void RunSiteSwitchCleanupIfNeeded(const GURL& url,
                                  const GURL& current_url,
                                  bool top_level_starting_navigation) {
  if (!top_level_starting_navigation || !url.SchemeIsHTTPOrHTTPS() ||
      IsSameTopLevelSite(url, current_url)) {
    return;
  }
  PurgeIfMemoryIsTight(GetBlinkMemoryStats().phys_footprint);
}

void ShowOOMGuardPage() {
  Shell* shell = Shell::windows().empty() ? nullptr : Shell::windows().front();
  if (!shell) {
    return;
  }
  shell->LoadDataWithBaseURL(
      GURL("about:blank"),
      "%3Chtml%3E%3Cbody%3E%3Ch2%3ELow%20memory%20protection%3C%2Fh2%3E"
      "%3Cp%3EBlinker%20Fluid%20blocked%20this%20navigation%20before%20a%20"
      "large%20allocation%20could%20crash%20the%20app.%3C%2Fp%3E%3C%2Fbody%3E"
      "%3C%2Fhtml%3E",
      GURL("about:blank"));
}

bool HasPersistentDuplicateViewOrCompositor(int active_rwhv,
                                            int active_compositors) {
  // Кожна відкрита вкладка має свій RenderWidgetHostView і компоситор. Витоком
  // вважається лише більше view, ніж живих вкладок.
  const int expected = static_cast<int>(Shell::windows().size());
  const bool duplicate =
      active_rwhv > expected || active_compositors > expected;
  if (!duplicate) {
    g_duplicate_view_first_seen = base::TimeTicks();
    return false;
  }
  const base::TimeTicks now = base::TimeTicks::Now();
  if (g_duplicate_view_first_seen.is_null()) {
    g_duplicate_view_first_seen = now;
    BLINKER_DIAG("IOS_VIEW_LIFECYCLE: transient duplicate tolerated");
    return false;
  }
  if (now - g_duplicate_view_first_seen < base::Seconds(2)) {
    BLINKER_DIAG("IOS_VIEW_LIFECYCLE: transient duplicate tolerated");
    return false;
  }
  BLINKER_DIAG("IOS_VIEW_LIFECYCLE: persistent duplicate leak suspected");
  return true;
}

void RunOOMWatchdogForHeavyLoad(const GURL& url,
                                const BlinkMemoryStats& stats) {
  if (!IsHeavySiteURL(url)) {
    return;
  }
  const base::TimeTicks now = base::TimeTicks::Now();
  if (g_last_oom_watchdog_sample.is_null()) {
    g_last_oom_watchdog_sample = now;
    g_last_oom_watchdog_footprint = stats.phys_footprint;
    g_last_oom_watchdog_rss = stats.resident_size;
    return;
  }
  const base::TimeDelta elapsed = now - g_last_oom_watchdog_sample;
  const uint64_t footprint_growth =
      stats.phys_footprint > g_last_oom_watchdog_footprint
          ? stats.phys_footprint - g_last_oom_watchdog_footprint
          : 0;
  const uint64_t rss_growth =
      stats.resident_size > g_last_oom_watchdog_rss
          ? stats.resident_size - g_last_oom_watchdog_rss
          : 0;
  if (elapsed <= base::Seconds(1) &&
      (footprint_growth > 100ULL * 1024ULL * 1024ULL ||
       rss_growth > 100ULL * 1024ULL * 1024ULL)) {
    BLINKER_LOG("OOM_WATCHDOG: rapid memory growth");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    BLINKER_LOG("OOM_WATCHDOG: critical purge sent");
    if (!Shell::windows().empty() && Shell::windows().front()->web_contents() &&
        Shell::windows().front()->web_contents()->IsLoading()) {
      Shell::windows().front()->web_contents()->Stop();
      BLINKER_LOG("OOM_WATCHDOG: heavy load paused");
    }
  }
  if (elapsed >= base::Milliseconds(250)) {
    g_last_oom_watchdog_sample = now;
    g_last_oom_watchdog_footprint = stats.phys_footprint;
    g_last_oom_watchdog_rss = stats.resident_size;
  }
}

bool ApplyDirectAllocationDangerGuard(const GURL& url,
                                      bool top_level_starting_navigation) {
  if (!top_level_starting_navigation || !IsHeavySiteURL(url)) {
    return false;
  }
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  ++g_main_frame_navigation_start_count;
  const int active_rwhv = BlinkActiveRWHVCount();
  const int active_compositors = BlinkActiveBrowserCompositorCount();
  const int active_layers = BlinkActiveAttachedCALayerCount();
  const bool persistent_duplicate =
      HasPersistentDuplicateViewOrCompositor(active_rwhv, active_compositors);
  RunOOMWatchdogForHeavyLoad(url, stats);
  BLINKER_DIAGF(
      "OOM_GUARD: direct allocation risk footprint=%llu rwhv=%d "
      "compositors=%d attached_layers=%d nav_starts=%d url=%s",
      static_cast<unsigned long long>(stats.phys_footprint), active_rwhv,
      active_compositors, active_layers, g_main_frame_navigation_start_count,
      LoggableURLSpec(url).c_str());
  PurgeIfMemoryIsTight(stats.phys_footprint);
  if (stats.phys_footprint >= blinker_memory::CriticalFootprint() &&
      persistent_duplicate) {
    BLINKER_LOG("OOM_GUARD: active compositor leak suspected");
    BLINKER_LOG("OOM_GUARD: blocked navigation before PartitionAlloc risk");
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ShowOOMGuardPage));
    return true;
  }
  return false;
}

// Хости, де слідкуєм за різким ростом пам'яті.
bool IsMonitoredHeavyHost(const GURL& url) {
  return url.is_valid() &&
         blinker_sites::HasTrait(url.host(), blinker_sites::kMonitorMemory);
}

bool IsAISiteURL(const GURL& url) {
  return url.is_valid() &&
         blinker_sites::HasTrait(url.host(), blinker_sites::kAI);
}

// github.com/<owner>/<repo>[/...], важкі сторінки репозиторію.
bool IsGitHubRepoPage(const GURL& url) {
  if (!IsGitHubURL(url) || url.host() != "github.com") {
    return false;
  }
  std::vector<std::string> segs = base::SplitString(
      url.path(), "/", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (segs.size() < 2) {
    return false;
  }
  static const char* const kReserved[] = {
      "login",  "logout",      "join",     "settings", "notifications",
      "search", "marketplace", "sponsors", "about",    "features",
      "topics", "explore",     "new"};
  for (const char* r : kReserved) {
    if (segs[0] == r) {
      return false;
    }
  }
  return true;
}

void RecordLoadStart() {
  g_recent_load_starts[g_recent_load_start_head] = base::TimeTicks::Now();
  g_recent_load_start_head =
      (g_recent_load_start_head + 1) % kRecentLoadStartSlots;
}

int LoadStartsInLast10s() {
  const base::TimeTicks now = base::TimeTicks::Now();
  int count = 0;
  for (const base::TimeTicks& t : g_recent_load_starts) {
    if (!t.is_null() && now - t <= base::Seconds(10)) {
      ++count;
    }
  }
  return count;
}

// Коротка історія для розбору виходів без crash report.
void StoreRecentHeartbeat(const char* entry) {
  CFMutableArrayRef arr = nullptr;
  if (CFPropertyListRef existing = CFPreferencesCopyAppValue(
          CFSTR("BlinkRecentHeartbeats"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(existing) == CFArrayGetTypeID()) {
      arr = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0,
                                     static_cast<CFArrayRef>(existing));
    }
    CFRelease(existing);
  }
  if (!arr) {
    arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
  }
  if (CFStringRef value = CFStringCreateWithCString(kCFAllocatorDefault, entry,
                                                    kCFStringEncodingUTF8)) {
    CFArrayAppendValue(arr, value);
    CFRelease(value);
  }
  while (CFArrayGetCount(arr) > 5) {
    CFArrayRemoveValueAtIndex(arr, 0);
  }
  // Без synchronize. Запис одразу йде в cfprefsd і переживає аварію процесу,
  // а синхронний скид на диск гальмував кожну зміну завантаження.
  CFPreferencesSetAppValue(CFSTR("BlinkRecentHeartbeats"), arr,
                           kCFPreferencesCurrentApplication);
  CFRelease(arr);
}

void LogCrashBreadcrumb(WebContents* source, const char* action) {
  if (action) {
    g_last_user_action = action;
  }
  if (!source) {
    return;
  }
  const GURL url = source->GetVisibleURL();
  const GURL committed = source->GetLastCommittedURL();
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  BLINKER_DIAGF(
      "CRASH_BREADCRUMB: action=%s loading=%d loads10s=%d "
      "footprint=%llu rss=%llu vsize=%llu rwhv=%d compositors=%d "
      "layers=%d url=%s committed=%s",
      g_last_user_action, source->IsLoading() ? 1 : 0, LoadStartsInLast10s(),
      static_cast<unsigned long long>(stats.phys_footprint),
      static_cast<unsigned long long>(stats.resident_size),
      static_cast<unsigned long long>(stats.virtual_size),
      BlinkActiveRWHVCount(), BlinkActiveBrowserCompositorCount(),
      BlinkActiveAttachedCALayerCount(), LoggableURLSpec(url).c_str(),
      LoggableURLSpec(committed).c_str());
}

base::RepeatingTimer& HeavyHeartbeatTimer() {
  static base::NoDestructor<base::RepeatingTimer> timer;
  return *timer;
}

void HeavyHeartbeatTick() {
  Shell* shell = Shell::windows().empty() ? nullptr : Shell::windows().front();
  WebContents* wc = shell ? shell->web_contents() : nullptr;
  const GURL url =
      wc ? (wc->GetLastCommittedURL().is_empty() ? wc->GetVisibleURL()
                                                 : wc->GetLastCommittedURL())
         : GURL();
  if (!wc || !IsMonitoredHeavyHost(url)) {
    HeavyHeartbeatTimer().Stop();
    return;
  }
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  const int rwhv = BlinkActiveRWHVCount();
  const int comps = BlinkActiveBrowserCompositorCount();
  BLINKER_DIAGF(
      "HEARTBEAT_HEAVY: footprint=%llu rss=%llu rwhv=%d "
      "compositors=%d url=%s",
      static_cast<unsigned long long>(stats.phys_footprint),
      static_cast<unsigned long long>(stats.resident_size), rwhv, comps,
      LoggableURLSpec(url).c_str());

  char entry[640];
  snprintf(entry, sizeof(entry),
           "ts=%ld footprint=%llu rss=%llu rwhv=%d comps=%d url=%s",
           static_cast<long>(time(nullptr)),
           static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(stats.resident_size), rwhv, comps,
           LoggableURLSpec(url).c_str());
  StoreRecentHeartbeat(entry);

  // Різкий ріст footprint означає, що час звільнити кеші. У лог іде лише
  // виміряне, без здогадок про дії користувача.
  if (IsAISiteURL(url)) {
    if (!g_ai_guard_logged_for_page) {
      BLINKER_DIAG("AI_SITE_GUARD: on AI site, heartbeat monitoring");
      g_ai_guard_logged_for_page = true;
    }
    const uint64_t prev = g_last_heavy_heartbeat_footprint;
    const bool growing =
        prev != 0 && stats.phys_footprint > prev + 40ULL * 1024ULL * 1024ULL;
    if (growing && !wc->IsLoading()) {
      BLINKER_DIAG(
          "AI_SITE_GUARD: footprint +40MB since last tick, not loading");
    }
    const base::TimeTicks now = base::TimeTicks::Now();
    const bool cooled =
        g_last_ai_purge.is_null() || now - g_last_ai_purge > base::Seconds(3);
    if (cooled && (growing || stats.phys_footprint >=
                                  blinker_memory::ModerateFootprint())) {
      BLINKER_DIAG("AI_SITE_GUARD: purge");
      base::MemoryPressureListener::NotifyMemoryPressure(
          stats.phys_footprint >= blinker_memory::CriticalFootprint()
              ? base::MEMORY_PRESSURE_LEVEL_CRITICAL
              : base::MEMORY_PRESSURE_LEVEL_MODERATE);
      g_last_ai_purge = now;
    }
  }
  g_last_heavy_heartbeat_footprint = stats.phys_footprint;
}

void StartHeavyHeartbeatIfNeeded(const GURL& url) {
  if (!IsMonitoredHeavyHost(url) || HeavyHeartbeatTimer().IsRunning()) {
    return;
  }
  BLINKER_DIAG("HEARTBEAT_HEAVY: monitor started");
  HeavyHeartbeatTimer().Start(FROM_HERE, base::Seconds(2),
                              base::BindRepeating(&HeavyHeartbeatTick));
}

bool IsAuthFlowURL(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  const std::string host(url.host());
  const std::string path(url.path());
  if (host == "auth.openai.com" || host == "accounts.google.com") {
    return true;
  }
  const bool openai_family =
      host == "chatgpt.com" || base::EndsWith(host, ".chatgpt.com") ||
      host == "openai.com" || base::EndsWith(host, ".openai.com");
  if (openai_family &&
      (base::StartsWith(path, "/auth", base::CompareCase::SENSITIVE) ||
       path.find("/oauth") != std::string::npos ||
       path.find("login_with") != std::string::npos)) {
    return true;
  }
  return path.find("/auth/callback") != std::string::npos ||
         path.find("/oauth/callback") != std::string::npos ||
         path.find("/login/callback") != std::string::npos;
}

void RecordAuthUrlAndDetectLoop(const GURL& url) {
  const base::TimeTicks now = base::TimeTicks::Now();
  const std::string spec = url.spec();
  g_recent_auth_urls[g_recent_auth_head] = spec;
  g_recent_auth_times[g_recent_auth_head] = now;
  g_recent_auth_head = (g_recent_auth_head + 1) % kRecentAuthSlots;
  int repeats = 0;
  for (size_t i = 0; i < kRecentAuthSlots; ++i) {
    if (!g_recent_auth_times[i].is_null() &&
        now - g_recent_auth_times[i] <= base::Seconds(5) &&
        g_recent_auth_urls[i] == spec) {
      ++repeats;
    }
  }
  if (repeats >= 3) {
    BLINKER_DIAG("AUTH_FLOW: redirect loop suspected");
    BLINKER_DIAGF("AUTH_FLOW: repeated url=%s", spec.c_str());
    BLINKER_DIAG("AUTH_FLOW: last 10 redirects=");
    for (size_t i = 0; i < kRecentAuthSlots; ++i) {
      size_t idx = (g_recent_auth_head + i) % kRecentAuthSlots;
      if (!g_recent_auth_urls[idx].empty()) {
        BLINKER_DIAGF("AUTH_FLOW:   [%zu]=%s", i,
                      g_recent_auth_urls[idx].c_str());
      }
    }
  }
}

// Лише кількість cookies доменів входу і ознака partitioned, без значень.
void LogAuthCookieCounts(const std::vector<net::CanonicalCookie>& cookies) {
  struct Bucket {
    const char* domain;
    int count;
  } buckets[] = {{"chatgpt.com", 0},
                 {"auth.openai.com", 0},
                 {"openai.com", 0},
                 {"accounts.google.com", 0}};
  bool partitioned_seen = false;
  for (const net::CanonicalCookie& c : cookies) {
    std::string d = c.Domain();
    if (!d.empty() && d[0] == '.') {
      d = d.substr(1);
    }
    for (Bucket& b : buckets) {
      if (d == b.domain || base::EndsWith(d, std::string(".") + b.domain)) {
        ++b.count;
      }
    }
    if (c.IsPartitioned()) {
      partitioned_seen = true;
    }
  }
  for (const Bucket& b : buckets) {
    BLINKER_DIAGF("AUTH_COOKIES: domain=%s count=%d",
                  IsPrivateSession() ? "[private]" : b.domain, b.count);
  }
  if (partitioned_seen) {
    BLINKER_DIAG("AUTH_COOKIES: partitioned cookie seen");
  }
}

void FlushAndDiagnoseAuthCookies(WebContents* wc) {
  if (!wc) {
    return;
  }
  StoragePartition* sp = wc->GetBrowserContext()->GetDefaultStoragePartition();
  if (!sp) {
    return;
  }
  network::mojom::CookieManager* cm = sp->GetCookieManagerForBrowserProcess();
  if (!cm) {
    return;
  }
  BLINKER_DIAG("AUTH_COOKIES: flushing after auth navigation");
  cm->FlushCookieStore(
      base::BindOnce([] { BLINKER_DIAG("AUTH_COOKIES: flush complete"); }));
  cm->GetAllCookies(base::BindOnce(&LogAuthCookieCounts));
}

// Запасний шлях входу для мобільного вебу ChatGPT.

constexpr char kChatGPTDesktopUA[] =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/" CONTENT_SHELL_MAJOR_VERSION
    ".0.0.0 Safari/537.36";
constexpr char kChatGPTIPhoneSafariUA[] =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 "
    "Safari/604.1";

// На iOS 11 і 12 Google відхиляє ідентичність Android/Chromium після введення
// пароля, тому сторінки Google Account там отримують UA мобільного Safari.
constexpr char kGoogleLegacySafariUA[] =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 "
    "Safari/604.1";

bool IsLegacyIOS11Or12Runtime() {
  struct utsname info = {};
  if (uname(&info) != 0) {
    return false;
  }
  int darwin_major = 0;
  return base::StringToInt(std::string(info.release)
                               .substr(0, std::string(info.release).find('.')),
                           &darwin_major) &&
         darwin_major <= 18;
}

void ApplyLegacyGoogleAuthIdentity(WebContents* contents, const GURL& url) {
  if (!contents || url.host() != "accounts.google.com" ||
      !IsLegacyIOS11Or12Runtime()) {
    return;
  }
  if (contents->GetUserAgentOverride().ua_string_override ==
      kGoogleLegacySafariUA) {
    return;
  }
  blink::UserAgentOverride ua;
  ua.ua_string_override = kGoogleLegacySafariUA;
  contents->SetUserAgentOverride(ua, true);
  BLINKER_DIAG("AUTH_FLOW: legacy Google Safari identity enabled");
}

bool IsChatGPTMwebFallback(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  const std::string host(url.host());
  if (host != "chatgpt.com" && !base::EndsWith(host, ".chatgpt.com")) {
    return false;
  }
  if (url.path().find("/auth/login_with") == std::string::npos) {
    return false;
  }
  const std::string q(url.query());
  return q.find("mweb_fallback=1") != std::string::npos &&
         q.find("connection=google-oauth2") != std::string::npos;
}

void StopFrontShellLoad() {
  Shell* shell = Shell::windows().empty() ? nullptr : Shell::windows().front();
  if (shell && shell->web_contents()) {
    shell->web_contents()->Stop();
  }
}

// Обережний запасний варіант для полів чату внизу, коли метрик рендерера нема.
void UpdateKeyboardChatFallback(const GURL& url) {
  const std::string host(url.host());
  // Порожній чи about:blank URL посеред навігації не має збивати хост чату,
  // поки клавіатура відкрита.
  if (host.empty()) {
    BLINKER_DIAG(
        "KEYBOARD_RELOCATE: chat fallback disabled reason=empty host (kept "
        "previous)");
    return;
  }
  const std::string path(url.path());
  const bool auth_page = path.find("/auth") != std::string::npos ||
                         path.find("/login") != std::string::npos ||
                         path.find("/signin") != std::string::npos ||
                         path.find("/sign-in") != std::string::npos;
  const bool chat =
      !auth_page && blinker_sites::HasTrait(host, blinker_sites::kChatKeyboard);
  g_is_chat_keyboard_relocation_site = chat;
  g_keyboard_chat_fallback_ratio = chat ? kChatInputFallbackBottomRatio : 0.0f;
  BLINKER_DIAGF("KEYBOARD_RELOCATE: current host=%s",
                IsPrivateSession() ? "[private]" : host.c_str());
  BLINKER_DIAGF("KEYBOARD_RELOCATE: chat fallback enabled=%d", chat ? 1 : 0);
  if (!chat) {
    BLINKER_DIAG(
        "KEYBOARD_RELOCATE: chat fallback disabled reason=non-chat host");
  }
}

// Поза колбеком навігації. Ставить UA для входу в ChatGPT, зупиняє цикл і раз
// повторює без mweb_fallback, щоб ChatGPT пішов звичайним редиректом.
void BreakChatGPTMwebLoop(GURL stripped_url) {
  Shell* shell = Shell::windows().empty() ? nullptr : Shell::windows().front();
  if (!shell || !shell->web_contents()) {
    return;
  }
  const char* profile = "chromium-mobile";
  blink::UserAgentOverride ua;
  if (g_chatgpt_auth_profile == 1) {
    ua.ua_string_override = kChatGPTDesktopUA;
    profile = "desktop";
  } else if (g_chatgpt_auth_profile == 2) {
    ua.ua_string_override = kChatGPTIPhoneSafariUA;
    profile = "mobile-safari";
  }
  BLINKER_DIAGF("AUTH_FLOW: chatgpt auth profile=%s", profile);
  if (!ua.ua_string_override.empty()) {
    shell->web_contents()->SetUserAgentOverride(ua, true);
  }
  BLINKER_DIAG("AUTH_FLOW: mweb loop stopped safely");
  shell->web_contents()->Stop();
  if (stripped_url.is_valid()) {
    BLINKER_DIAG("AUTH_FLOW: attempting direct provider fallback");
    BLINKER_DIAGF("AUTH_FLOW: direct provider url=%s",
                  LoggableURLSpec(stripped_url).c_str());
    BLINKER_DIAG("AUTH_FLOW: retrying without mweb_fallback");
    BLINKER_DIAG("AUTH_FLOW: stripped mweb_fallback");
    shell->LoadURL(stripped_url);
  } else {
    BLINKER_DIAG("AUTH_FLOW: no provider url found");
  }
}

// Звільняє пам'ять перед важкою сторінкою репозиторію GitHub. Клік не
// блокується, крайні випадки обробляє ApplyGlobalMemoryGuard.
void ApplyGitHubRepoGuard(const GURL& url) {
  if (!IsGitHubRepoPage(url)) {
    return;
  }
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  BLINKER_DIAG("GITHUB_REPO_GUARD: repo page detected");
  BLINKER_DIAGF("GITHUB_REPO_GUARD: footprint=%llu",
                static_cast<unsigned long long>(stats.phys_footprint));
  BLINKER_DIAG("GITHUB_REPO_GUARD: pre-repo purge");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
}

bool ApplyGlobalMemoryGuard(const GURL& url,
                            const GURL& current_url,
                            const char* label,
                            bool top_level_starting_navigation) {
  if (!kEnableIOSGlobalLowMemoryGuard) {
    return false;
  }
  if (!IsHeavySiteURL(url)) {
    return false;
  }
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  BLINKER_DIAGF(
      "GLOBAL_MEM_GUARD: %s footprint=%llu soft_at=%llu critical_at=%llu "
      "block_at=%llu url=%s",
      label, static_cast<unsigned long long>(stats.phys_footprint),
      static_cast<unsigned long long>(blinker_memory::ModerateFootprint()),
      static_cast<unsigned long long>(blinker_memory::CriticalFootprint()),
      static_cast<unsigned long long>(
          blinker_memory::BlockNewContentsFootprint()),
      LoggableURLSpec(url).c_str());

  if (stats.phys_footprint >= blinker_memory::ModerateFootprint()) {
    BLINKER_DIAG("GLOBAL_MEM_GUARD: footprint over soft threshold -> purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_MODERATE);
  }
  if (stats.phys_footprint >= blinker_memory::CriticalFootprint()) {
    BLINKER_DIAG(
        "GLOBAL_MEM_GUARD: footprint over critical threshold -> purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    // Purge лиш скидає кеші, а більшу частину footprint тримають фонові
    // рендерери. Тому їх теж скидаєм, а не чекаєм поки jetsam вб'є все.
    BlinkDiscardBackgroundTabsUnderPressure();
  }
  if (stats.phys_footprint >= blinker_memory::ModerateFootprint()) {
    BLINKER_DIAG("V8_OOM_CONTEXT near heavy URL before fatal OOM risk");
  }
  if (IsYouTubeURL(url)) {
    BLINKER_DIAG("GLOBAL_MEM_GUARD: youtube purge-only mode");
    return false;
  }
  if (IsGitHubURL(url)) {
    BLINKER_DIAG("GITHUB_MEM_GUARD: purge-only mode");
    if (stats.phys_footprint >= blinker_memory::ModerateFootprint()) {
      BLINKER_DIAG("GITHUB_MEM_GUARD: footprint over soft threshold");
    }
    if (stats.phys_footprint >= blinker_memory::CriticalFootprint()) {
      BLINKER_DIAG("GITHUB_MEM_GUARD: footprint over critical threshold");
    }
    return false;
  }
  if (url.host() == "discord.com" ||
      base::EndsWith(url.host(), ".discord.com") ||
      url.host() == "homedepot.com" ||
      base::EndsWith(url.host(), ".homedepot.com") ||
      url.host() == "claude.ai" || base::EndsWith(url.host(), ".claude.ai") ||
      url.host() == "chatgpt.com" ||
      base::EndsWith(url.host(), ".chatgpt.com") ||
      url.host() == "gemini.google.com") {
    BLINKER_DIAG("GLOBAL_MEM_GUARD: common heavy site purge-only mode");
    return false;
  }
  if (url.host() == "accounts.google.com" && IsGoogleAuthURL(current_url)) {
    BLINKER_DIAG("AUTH_POPUP_GUARD: allowed accounts.google.com navigation");
    return false;
  }
  if (top_level_starting_navigation &&
      stats.phys_footprint >= blinker_memory::BlockNewContentsFootprint() &&
      !SameHeavySite(current_url, url) && !IsRedditURL(url)) {
    g_global_low_memory_mode = true;
    BLINKER_DIAG("GLOBAL_MEM_GUARD: low-memory mode active");
    BLINKER_DIAG("GLOBAL_MEM_GUARD: blocked heavy navigation");
    return true;
  }
  return false;
}

bool ShouldBlockNewWebContents(const char* path, const GURL& url) {
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  const bool already_have_web_contents = !Shell::windows().empty();
  if (!already_have_web_contents) {
    return false;
  }
  if (stats.phys_footprint < blinker_memory::BlockNewContentsFootprint()) {
    BLINKER_DIAGF(
        "WEB_CONTENTS_GUARD: allowed path=%s existing=%zu footprint=%llu", path,
        Shell::windows().size(),
        static_cast<unsigned long long>(stats.phys_footprint));
    return false;
  }

  BLINKER_DIAGF(
      "WEB_CONTENTS_GUARD: blocked new window path=%s existing=%zu "
      "footprint=%llu block_at=%llu url=%s",
      path, Shell::windows().size(),
      static_cast<unsigned long long>(stats.phys_footprint),
      static_cast<unsigned long long>(
          blinker_memory::BlockNewContentsFootprint()),
      LoggableURLSpec(url).c_str());
  return true;
}

#endif

// Owning pointers, held as raw pointers so they need no exit-time destructor.
// Null until/unless the default main message loop is running.
base::OnceClosure* g_main_message_loop_quit_closure = nullptr;
// Set by SetShellCreatedCallback(), consumed by the next Shell or Shutdown().
base::OnceCallback<void(Shell*)>* g_shell_created_callback = nullptr;
// Created with the first Shell and deleted when the last one closes. Ordered
// so windows() reflects creation order.
std::vector<raw_ptr<Shell>>* g_windows = nullptr;

// Runs and deletes the quit closure, if any.
void RunMainMessageLoopQuitClosure() {
  if (!g_main_message_loop_quit_closure) {
    return;
  }
  base::OnceClosure quit_closure = std::move(*g_main_message_loop_quit_closure);
  delete g_main_message_loop_quit_closure;
  g_main_message_loop_quit_closure = nullptr;
  std::move(quit_closure).Run();
}

}  // namespace

Shell::Shell(std::unique_ptr<WebContents> web_contents,
             bool should_set_delegate)
    : WebContentsObserver(web_contents.get()),
      web_contents_(std::move(web_contents)) {
  if (should_set_delegate) {
    web_contents_->SetDelegate(this);
  }

  if (!switches::IsRunWebTestsSwitchPresent()) {
    UpdateFontRendererPreferencesFromSystemSettings(
        web_contents_->GetMutableRendererPrefs());
  }
  web_contents_->GetMutableRendererPrefs()->accept_languages =
      GetShellLanguage();
#if BUILDFLAG(IS_IOS)
  BlinkApplyPrivacyRendererPrefs(web_contents_->GetMutableRendererPrefs());
#endif

  if (!g_windows) {
    g_windows = new std::vector<raw_ptr<Shell>>();
  }
  g_windows->push_back(this);

  if (g_shell_created_callback) {
    base::OnceCallback<void(Shell*)> callback =
        std::move(*g_shell_created_callback);
    delete g_shell_created_callback;
    g_shell_created_callback = nullptr;
    std::move(callback).Run(this);
  }
}

Shell::~Shell() {
  g_platform->CleanUp(this);

  CHECK(g_windows);
  std::erase(*g_windows, this);
  if (g_windows->empty()) {
    delete g_windows;
    g_windows = nullptr;
  }

#if BUILDFLAG(IS_IOS)
  // Трекери вікна входу не мають лишатись висячими, якщо котрась сторона
  // вмирає не через CloseContents.
  if (web_contents_.get() == g_auth_popup_contents) {
    g_auth_popup_contents = nullptr;
    g_auth_popup_opener = nullptr;
  }
  if (web_contents_.get() == g_auth_popup_opener) {
    g_auth_popup_opener = nullptr;
  }
#endif

  web_contents_->SetDelegate(nullptr);
  web_contents_.reset();

  if (windows().empty()) {
    g_platform->DidCloseLastWindow();
  }
}

Shell* Shell::CreateShell(std::unique_ptr<WebContents> web_contents,
                          const gfx::Size& initial_size,
                          bool should_set_delegate) {
  WebContents* raw_web_contents = web_contents.get();
  Shell* shell = new Shell(std::move(web_contents), should_set_delegate);
  g_platform->CreatePlatformWindow(shell, initial_size);

  // Note: Do not make RenderFrameHost or RenderViewHost specific state changes
  // here, because they will be forgotten after a cross-process navigation. Use
  // RenderFrameCreated or RenderViewCreated instead.
  if (switches::IsRunWebTestsSwitchPresent()) {
    raw_web_contents->GetMutableRendererPrefs()->use_custom_colors = false;
    raw_web_contents->SyncRendererPrefs();
  }

  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(switches::kForceWebRtcIPHandlingPolicy)) {
    raw_web_contents->GetMutableRendererPrefs()->webrtc_ip_handling_policy =
        blink::ToWebRTCIPHandlingPolicy(command_line->GetSwitchValueASCII(
            switches::kForceWebRtcIPHandlingPolicy));
    raw_web_contents->SyncRendererPrefs();
  }

  g_platform->SetContents(shell);
  g_platform->DidCreateOrAttachWebContents(shell, raw_web_contents);
  // If the RenderFrame was created during WebContents construction (as happens
  // for windows opened from the renderer) then the Shell won't hear about the
  // main frame being created as a WebContentsObservers. This gives the delegate
  // a chance to act on the main frame accordingly.
  if (raw_web_contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
    g_platform->MainFrameCreated(shell,
                                 raw_web_contents->GetPrimaryMainFrame());
  }
  BlinkerNoteTabShellCreated(raw_web_contents);

  return shell;
}

// static
base::span<const raw_ptr<Shell>> Shell::windows() {
  if (!g_windows) {
    return {};
  }
  return *g_windows;
}

#if BUILDFLAG(IS_IOS)
// Upstream віддає список лише для читання, а порядок вкладок міняється.
extern "C" void BlinkMoveShellWindow(size_t from, size_t to) {
  if (!g_windows || from >= g_windows->size() || to >= g_windows->size() ||
      from == to) {
    return;
  }
  raw_ptr<Shell> moved = (*g_windows)[from];
  g_windows->erase(g_windows->begin() + from);
  g_windows->insert(g_windows->begin() + to, moved);
}
#endif

// static
void Shell::SetMainMessageLoopQuitClosure(base::OnceClosure quit_closure) {
  delete g_main_message_loop_quit_closure;
  g_main_message_loop_quit_closure =
      quit_closure ? new base::OnceClosure(std::move(quit_closure)) : nullptr;
}

// static
void Shell::QuitMainMessageLoopForTesting() {
  RunMainMessageLoopQuitClosure();
}

// static
void Shell::SetShellCreatedCallback(
    base::OnceCallback<void(Shell*)> shell_created_callback) {
  DCHECK(!g_shell_created_callback);
  if (shell_created_callback) {
    g_shell_created_callback =
        new base::OnceCallback<void(Shell*)>(std::move(shell_created_callback));
  }
}

// static
bool Shell::ShouldHideToolbar() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(
      switches::kContentShellHideToolbar);
}

// static
Shell* Shell::FromWebContents(WebContents* web_contents) {
  for (Shell* window : windows()) {
    if (window->web_contents() && window->web_contents() == web_contents) {
      return window;
    }
  }
  return nullptr;
}

// static
void Shell::Initialize(std::unique_ptr<ShellPlatformDelegate> platform) {
  DCHECK(!g_platform);
  g_platform = platform.release();
  g_platform->Initialize(GetShellDefaultSize());
}

// static
void Shell::Shutdown() {
  if (!g_platform) {
    return;
  }

  DevToolsAgentHost::DetachAllClients();

  while (!Shell::windows().empty()) {
    Shell::windows().back()->Close();
  }

  delete g_platform;
  g_platform = nullptr;

  delete g_shell_created_callback;
  g_shell_created_callback = nullptr;

  for (auto it = RenderProcessHost::AllHostsIterator(); !it.IsAtEnd();
       it.Advance()) {
    it.GetCurrentValue()->DisableRefCounts();
  }
  RunMainMessageLoopQuitClosure();

  // Pump the message loop to allow window teardown tasks to run. On iOS the
  // run loop is controlled differently and cannot be pumped.
#if !BUILDFLAG(IS_IOS)
  base::RunLoop().RunUntilIdle();
#endif  // !BUILDFLAG(IS_IOS)
}

gfx::Size Shell::AdjustWindowSize(const gfx::Size& initial_size) {
  if (!initial_size.IsEmpty()) {
    return initial_size;
  }
  return GetShellDefaultSize();
}

// static
Shell* Shell::CreateNewWindow(BrowserContext* browser_context,
                              const GURL& url,
                              const scoped_refptr<SiteInstance>& site_instance,
                              const gfx::Size& initial_size) {
#if BUILDFLAG(IS_IOS)
  // Однопроцесний браузер не тягне скільки завгодно фреймів у пам'яті. Перед
  // новою вкладкою скидаєм неактивні, історія і мініатюри лишаються.
  if (!Shell::windows().empty()) {
    BlinkDiscardBackgroundTabs(nullptr);
  }
  // На iOS сюди веде лиш кнопка нової вкладки, window.open і вікна входу
  // обробляють AddNewContents і OpenURLFromTab.
  BLINKER_DIAG("TAB_MANAGER: new tab created via CreateNewWindow");
  if (ShouldBlockNewWebContents("CreateNewWindow", url)) {
    BLINKER_DIAG("TAB_MANAGER: new tab blocked (extreme memory)");
    // Це явний запит New Tab. Якщо вернути наявний Shell, викликач вважатиме
    // вкладку 0 новою і перемкне екран зі стартової сторінки.
    return nullptr;
  }
#endif
  WebContents::CreateParams create_params(browser_context, site_instance);
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kForcePresentationReceiverForTesting)) {
    create_params.starting_sandbox_flags = kPresentationReceiverSandboxFlags;
  }
  std::unique_ptr<WebContents> web_contents =
      WebContents::Create(create_params);
  Shell* shell =
      CreateShell(std::move(web_contents), AdjustWindowSize(initial_size),
                  true /* should_set_delegate */);

  if (!url.is_empty()) {
    shell->LoadURL(url);
  }
  return shell;
}

// static
Shell* Shell::CreateDuplicate(Shell* source) {
  if (!source || !source->web_contents()) {
    return nullptr;
  }
#if BUILDFLAG(IS_IOS)
  BlinkDiscardBackgroundTabs(source);
  if (ShouldBlockNewWebContents("CreateDuplicate",
                                source->web_contents()->GetVisibleURL())) {
    return nullptr;
  }
#endif
  Shell* shell = CreateShell(source->web_contents()->Clone(),
                             AdjustWindowSize(gfx::Size()),
                             true /* should_set_delegate */);
  // Clone копіює лише записи навігації, а сторінку треба завантажити.
  shell->web_contents()->GetController().LoadIfNecessary();
  return shell;
}

void Shell::RenderFrameCreated(RenderFrameHost* frame_host) {
  if (frame_host == frame_host->GetOutermostMainFrame()) {
    g_platform->MainFrameCreated(this, frame_host);
  }
}

void Shell::LoadURL(const GURL& url) {
  LoadURLForFrame(
      url, std::string(),
      ui::PageTransitionFromInt(ui::PAGE_TRANSITION_TYPED |
                                ui::PAGE_TRANSITION_FROM_ADDRESS_BAR));
}

void Shell::LoadURLForFrame(const GURL& url,
                            const std::string& frame_name,
                            ui::PageTransition transition_type) {
#if BUILDFLAG(IS_IOS)
  ApplyLegacyGoogleAuthIdentity(web_contents_.get(), url);
  const GURL current_url =
      web_contents_ ? web_contents_->GetVisibleURL() : GURL();
  const bool top_level_starting_navigation = frame_name.empty();
  BlinkLogMemoryPressurePoint(
      IsRedditURL(url) ? "before reddit.com load" : "before page load", &url);
  if (IsAuthFlowURL(url)) {
    // Редиректи входу guard не блокує, інакше ланцюжок login_with
    // oauth
    // зламається.
    BLINKER_DIAG("AUTH_FLOW: guard purge-only");
    const BlinkMemoryStats astats = GetBlinkMemoryStats();
    if (astats.phys_footprint >= blinker_memory::CriticalFootprint()) {
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    }
    BLINKER_DIAG("AUTH_FLOW: redirect allowed");
  } else {
    RunSiteSwitchCleanupIfNeeded(url, current_url,
                                 top_level_starting_navigation);
    if (ApplyDirectAllocationDangerGuard(url, top_level_starting_navigation)) {
      return;
    }
    if (ApplyGlobalMemoryGuard(url, current_url, "before load",
                               top_level_starting_navigation)) {
      return;
    }
  }
  ApplyGitHubRepoGuard(url);
  LogCrashBreadcrumb(web_contents_.get(),
                     IsGitHubRepoPage(url) ? "repo page load"
                     : IsAISiteURL(url)    ? "ai site navigation"
                                           : "navigation");
#endif
  // Нова навігація поверх незавершеної змагається з розбором RWHV в
  // однопроцесному рендерері, тому спершу зупиняємо поточне завантаження.
#if BUILDFLAG(IS_IOS)
  if (web_contents_ && web_contents_->IsLoading()) {
    // Повторний клік на те саме посилання не перезапускає навігацію, бо кожен
    // перезапуск перебудовує RWHV і компоситор. Поточну зупиняє лише інший URL.
    NavigationEntry* pending = web_contents_->GetController().GetPendingEntry();
    if (pending && pending->GetURL() == url) {
      return;
    }
    web_contents_->Stop();
  }
#endif
#if BUILDFLAG(IS_IOS)
  // Порожня сторінка вкладки це стартова. Якщо розширення малюють у ній
  // (Shimeji), документ мусить мати надійне походження, бо без нього в
  // ньому нема service worker, а значить і мосту до розширення. Адреса
  // лишається about:blank, так її бачить решта застосунку.
  if (frame_name.empty() && url.IsAboutBlank() && web_contents_ &&
      BlinkerWebExtensionRegistry::GetInstance().StartPageHasContentScripts()) {
    NavigationController::LoadURLParams data_params{GURL(
        "data:text/html;charset=utf-8," +
        base::EscapeQueryParamValue(
            "<!doctype html><meta name=viewport "
            "content=\"width=device-width,initial-scale=1\">"
            "<style>html,body{margin:0;height:100%;background:#0e0e10}"
            "</style>",
            /*use_plus=*/false))};
    data_params.load_type = NavigationController::LOAD_TYPE_DATA;
    data_params.base_url_for_data_url = GURL(kBlinkerStartPageUrl);
    data_params.virtual_url_for_special_cases = url;
    data_params.override_user_agent = NavigationController::UA_OVERRIDE_FALSE;
    // Порожня вкладка лишається однією сторінкою в історії
    data_params.should_replace_current_entry =
        web_contents_->GetVisibleURL().IsAboutBlank();
    web_contents_->GetController().LoadURLWithParams(data_params);
    return;
  }
#endif
  NavigationController::LoadURLParams params(url);
#if BUILDFLAG(IS_IOS)
  if (frame_name.empty()) {
    if (!IsAuthFlowURL(url)) {
      BlinkApplySiteMode(web_contents(), url);
    }
    params.url = BlinkURLForSiteMode(url, BlinkIsDesktopSite(web_contents()));
    // UA_OVERRIDE_INHERIT тягне mobile флаг старого запису навіть після
    // SetUserAgentOverride(), тому новий запит вмикає UA явно.
    params.override_user_agent =
        web_contents()->GetUserAgentOverride().ua_string_override.empty()
            ? NavigationController::UA_OVERRIDE_FALSE
            : NavigationController::UA_OVERRIDE_TRUE;
  }
#endif
  params.frame_name = frame_name;
  params.transition_type = transition_type;
  web_contents_->GetController().LoadURLWithParams(params);
#if BUILDFLAG(IS_IOS)
  BlinkLogMemoryPressurePoint(IsRedditURL(url) ? "after reddit.com load request"
                                               : "after page load request",
                              &url);
  ApplyGlobalMemoryGuard(url, current_url, "after load request", false);
#endif
}

void Shell::LoadDataWithBaseURL(const GURL& url,
                                const std::string& data,
                                const GURL& base_url) {
  bool load_as_string = false;
  LoadDataWithBaseURLInternal(url, data, base_url, load_as_string);
}

#if BUILDFLAG(IS_ANDROID)
void Shell::LoadDataAsStringWithBaseURL(const GURL& url,
                                        const std::string& data,
                                        const GURL& base_url) {
  bool load_as_string = true;
  LoadDataWithBaseURLInternal(url, data, base_url, load_as_string);
}
#endif

void Shell::LoadDataWithBaseURLInternal(const GURL& url,
                                        const std::string& data,
                                        const GURL& base_url,
                                        bool load_as_string) {
#if !BUILDFLAG(IS_ANDROID)
  DCHECK(!load_as_string);  // Only supported on Android.
#endif

  NavigationController::LoadURLParams params{GURL()};
  const std::string data_url_header = "data:text/html;charset=utf-8,";
  if (load_as_string) {
    params.url = GURL(data_url_header);
    std::string data_url_as_string = data_url_header + data;
#if BUILDFLAG(IS_ANDROID)
    params.data_url_as_string = base::MakeRefCounted<base::RefCountedString>(
        std::move(data_url_as_string));
#endif
  } else {
    params.url = GURL(data_url_header + data);
  }

  params.load_type = NavigationController::LOAD_TYPE_DATA;
  params.base_url_for_data_url = base_url;
  params.virtual_url_for_special_cases = url;
  params.override_user_agent = NavigationController::UA_OVERRIDE_FALSE;
  web_contents_->GetController().LoadURLWithParams(params);
}

#if BUILDFLAG(IS_IOS)
// Реалізовано в shell_platform_delegate_ios.mm, бо треба UIKit.
extern "C" void BlinkPresentShellWindow(Shell* shell);
extern "C" void BlinkHideShellWindow(Shell* shell);
extern "C" void BlinkShellWillCloseReactivate(Shell* closing,
                                              WebContents* preferred_opener);
#endif

WebContents* Shell::AddNewContents(
    WebContents* source,
    std::unique_ptr<WebContents> new_contents,
    const GURL& target_url,
    ui::mojom::WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
#if BUILDFLAG(IS_IOS)
  // Вікно входу Google має реально існувати, бо після входу воно шле дані
  // відкривачу через postMessage і закривається, а CloseContents вертає екран.
  const bool is_google_auth_popup =
      IsGoogleAuthPopupRequest(target_url) ||
      target_url.host() == "accounts.google.com" ||
      IsClaudeGoogleAuthPopup(source, target_url);
  if (is_google_auth_popup) {
    BLINKER_DIAG("AUTH_POPUP_GUARD: detected google auth popup");
    BLINKER_DIAG("CLAUDE_AUTH: google button clicked");
    BLINKER_DIAG("AUTH_POPUP_GUARD: keeping popup as real window");
    WebContents* raw_popup = new_contents.get();
    g_auth_popup_contents = raw_popup;
    g_auth_popup_opener = source;
    Shell* popup_shell =
        CreateShell(std::move(new_contents),
                    AdjustWindowSize(window_features.bounds.size()),
                    true /* should_set_delegate */);
    BlinkPresentShellWindow(popup_shell);
    BLINKER_DIAG("AUTH_POPUP_GUARD: allowed accounts.google.com navigation");
    return raw_popup;
  }
  if (ShouldBlockNewWebContents("AddNewContents", target_url)) {
    if (was_blocked) {
      *was_blocked = true;
    }
    return nullptr;
  }
#endif
#if !BUILDFLAG(IS_ANDROID)
  // If the shell is opening a document picture-in-picture window, it needs to
  // inform the DocumentPictureInPictureWindowController.
  if (disposition == ui::mojom::WindowOpenDisposition::kNewPictureInPicture) {
    DocumentPictureInPictureWindowController* controller =
        PictureInPictureWindowController::
            GetOrCreateDocumentPictureInPictureController(source);
    controller->Close(/*should_pause_video=*/false);
    controller->SetChildWebContents(new_contents.get());
    controller->Show();
  }
#endif  // !BUILDFLAG(IS_ANDROID)

  WebContents* result = new_contents.get();
  Shell* created_shell = CreateShell(
      std::move(new_contents), AdjustWindowSize(window_features.bounds.size()),
      !delay_popup_contents_delegate_for_testing_ /* should_set_delegate */);
#if BUILDFLAG(IS_IOS)
  if (disposition == WindowOpenDisposition::kNewBackgroundTab) {
    BlinkHideShellWindow(created_shell);
  } else {
    BlinkPresentShellWindow(created_shell);
  }
#endif
  return result;
}

void Shell::GoBackOrForward(int offset) {
  web_contents_->GetController().GoToOffset(offset);
}

void Shell::Reload() {
  web_contents_->GetController().Reload(ReloadType::NORMAL, false);
}

void Shell::ReloadBypassingCache() {
  web_contents_->GetController().Reload(ReloadType::BYPASSING_CACHE, false);
}

void Shell::Stop() {
  web_contents_->Stop();
}

void Shell::UpdateNavigationControls(bool should_show_loading_ui) {
  int current_index = web_contents_->GetController().GetCurrentEntryIndex();
  int max_index = web_contents_->GetController().GetEntryCount() - 1;

  g_platform->EnableUIControl(this, ShellPlatformDelegate::BACK_BUTTON,
                              current_index > 0);
  g_platform->EnableUIControl(this, ShellPlatformDelegate::FORWARD_BUTTON,
                              current_index < max_index);
  g_platform->EnableUIControl(
      this, ShellPlatformDelegate::STOP_BUTTON,
      should_show_loading_ui && web_contents_->IsLoading());
}

void Shell::ShowDevTools() {
  if (!devtools_frontend_) {
    auto* devtools_frontend = ShellDevToolsFrontend::Show(web_contents());
    devtools_frontend_ = devtools_frontend->GetWeakPtr();
  }

  devtools_frontend_->Activate();
}

void Shell::CloseDevTools() {
  if (!devtools_frontend_) {
    return;
  }
  devtools_frontend_->Close();
  devtools_frontend_ = nullptr;
}

void Shell::ResizeWebContentForTests(const gfx::Size& content_size) {
  g_platform->ResizeWebContent(this, content_size);
}

gfx::NativeView Shell::GetContentView() {
  if (!web_contents_) {
    return gfx::NativeView();
  }
  return web_contents_->GetNativeView();
}

#if !BUILDFLAG(IS_ANDROID)
gfx::NativeWindow Shell::window() {
  return g_platform->GetNativeWindow(this);
}
#endif

#if BUILDFLAG(IS_MAC)
void Shell::ActionPerformed(int control) {
  switch (control) {
    case IDC_NAV_BACK:
      GoBackOrForward(-1);
      break;
    case IDC_NAV_FORWARD:
      GoBackOrForward(1);
      break;
    case IDC_NAV_RELOAD:
      Reload();
      break;
    case IDC_NAV_STOP:
      Stop();
      break;
  }
}

void Shell::URLEntered(const std::string& url_string) {
  if (!url_string.empty()) {
    GURL url(url_string);
    if (!url.has_scheme()) {
      url = GURL("http://" + url_string);
    }
    LoadURL(url);
  }
}
#endif

WebContents* Shell::OpenURLFromTab(
    WebContents* source,
    const OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>
        navigation_handle_callback) {
  WebContents* target = nullptr;
  switch (params.disposition) {
    case ui::mojom::WindowOpenDisposition::kCurrentTab:
      target = source;
      break;

    // Normally, the difference between `kNewPopup` and `kNewWindow` is that a
    // popup should have no toolbar, no status bar, no menu bar, no scrollbars
    // and be not resizable.  For simplicity and to enable new testing scenarios
    // in content shell and web tests, popups don't get special treatment below
    // (i.e. they will have a toolbar and other things described here).
    case ui::mojom::WindowOpenDisposition::kNewPopup:
    case ui::mojom::WindowOpenDisposition::kNewWindow:
    // content_shell doesn't really support tabs, but some web tests use
    // middle click (which translates into kNavigationPolicyNewBackgroundTab),
    // so we treat the cases below just like a `kNewWindow` disposition.
    case ui::mojom::WindowOpenDisposition::kNewBackgroundTab:
    case ui::mojom::WindowOpenDisposition::kNewForegroundTab: {
#if BUILDFLAG(IS_IOS)
      BLINKER_DIAG(
          "WEB_CONTENTS_GUARD: target=_blank using existing WebContents");
      target = source;
      break;
#else
      Shell* new_window =
          Shell::CreateNewWindow(source->GetBrowserContext(),
                                 GURL(),  // Don't load anything just yet.
                                 params.source_site_instance,
                                 gfx::Size());  // Use default size.
      target = new_window->web_contents();
      break;
#endif
    }

    // No tabs in content_shell:
    case ui::mojom::WindowOpenDisposition::kSingletonTab:
    // No incognito mode in content_shell:
    case ui::mojom::WindowOpenDisposition::kOffTheRecord:
    // TODO(lukasza): Investigate if some web tests might need support for
    // `kSaveToDisk` disposition.  This would probably require that
    // WebTestControlHost always sets up and cleans up a temporary directory
    // as the default downloads destinations for the duration of a test.
    case ui::mojom::WindowOpenDisposition::kSaveToDisk:
    // Ignoring requests with disposition == `kIgnoreAction`...
    case ui::mojom::WindowOpenDisposition::kIgnoreAction:
    default:
      return nullptr;
  }

#if BUILDFLAG(IS_IOS)
  // Як у LoadURLForFrame. Той самий URL не перезапускає навігацію, інший
  // зупиняє поточну.
  if (params.disposition == WindowOpenDisposition::kCurrentTab &&
      target->IsLoading()) {
    NavigationEntry* pending = target->GetController().GetPendingEntry();
    if (pending && pending->GetURL() == params.url) {
      return target;
    }
    target->Stop();
  }
#endif

  base::WeakPtr<NavigationHandle> navigation_handle =
      target->GetController().LoadURLWithParams(
          NavigationController::LoadURLParams(params));

  if (navigation_handle_callback && navigation_handle) {
    std::move(navigation_handle_callback).Run(*navigation_handle);
  }

  return target;
}

void Shell::LoadingStateChanged(WebContents* source,
                                bool should_show_loading_ui) {
#if BUILDFLAG(IS_IOS)
  const GURL url = source->GetLastCommittedURL().is_empty()
                       ? source->GetVisibleURL()
                       : source->GetLastCommittedURL();
  UpdateKeyboardChatFallback(url);
  BlinkLogMemoryPressurePoint(
      source->IsLoading() ? "page load started" : "page load stopped", &url);
  ApplyGlobalMemoryGuard(
      url, url,
      source->IsLoading() ? "loading state active" : "loading state stopped",
      false);
  if (source->IsLoading()) {
    RecordLoadStart();
    g_ai_guard_logged_for_page = false;
    g_last_heavy_heartbeat_footprint = 0;
    LogCrashBreadcrumb(source, "load started");
  } else {
    LogCrashBreadcrumb(source, "load committed");
    StartHeavyHeartbeatIfNeeded(url);
  }
  // RenderFrameHost::ExecuteJavaScript тут не можна, на http(s) він падає на
  // CHECK. Скрипти йдуть через ExecuteJavaScriptInIsolatedWorld після коміту.
#endif
  UpdateNavigationControls(should_show_loading_ui);
  g_platform->SetIsLoading(this, source->IsLoading());
}

#if BUILDFLAG(IS_IOS)
// Щоб режим сайту не мінявся під час редиректів входу.
bool BlinkShellIsInAuthFlow() {
  return g_in_auth_flow;
}

// Глобальний прапор входу лишався після входу в іншій вкладці, і кнопка
// Desktop/Mobile мовчки нічого не робила. Кнопці важить лиш ця вкладка.
bool BlinkShellTabIsInAuthFlow(WebContents* contents) {
  if (!contents) {
    return false;
  }
  NavigationEntry* pending = contents->GetController().GetPendingEntry();
  return IsAuthFlowURL(contents->GetLastCommittedURL()) ||
         (pending && IsAuthFlowURL(pending->GetURL()));
}

// Читає обробник клавіатури як запасне bottom ratio, коли метрик каретки нема.
// Більше 0 лиш на сайтах з чатом.
extern "C" float BlinkKeyboardChatFallbackRatio() {
  return g_keyboard_chat_fallback_ratio;
}

// Клавіатура читає цей стан UI потоку без свого WebContents.
extern "C" int BlinkIsChatKeyboardRelocationSite() {
  return g_is_chat_keyboard_relocation_site ? 1 : 0;
}

void Shell::DidStartNavigation(NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame()) {
    return;
  }
  const GURL url = navigation_handle->GetURL();
  if (url.SchemeIsHTTPOrHTTPS() && !navigation_handle->IsSameDocument()) {
    // Покриває і посилання з рендерера, reload та історію. Ставиться до запиту
    // в мережу, не після коміту і не посеред редиректів входу.
    if (!IsAuthFlowURL(url) && !g_in_auth_flow) {
      BlinkApplySiteMode(web_contents(), url);
    }
    // Масштаб сайту ставиться ще до першого кадру, а не після коміту, тож
    // сторінка не стрибає з 100% на свій масштаб
    BlinkApplyPageZoom(web_contents(), url);
    navigation_handle->SetIsOverridingUserAgent(
        !web_contents()->GetUserAgentOverride().ua_string_override.empty());
  }
  if (!IsAuthFlowURL(url)) {
    return;
  }
  g_in_auth_flow = true;
  BLINKER_DIAGF("AUTH_FLOW: navigation url=%s", LoggableURLSpec(url).c_str());
  BLINKER_DIAGF("AUTH_FLOW: method=%s",
                navigation_handle->IsPost() ? "POST" : "GET");
  BLINKER_DIAGF("AUTH_FLOW: top_frame=%d",
                navigation_handle->IsInPrimaryMainFrame() ? 1 : 0);
  const std::optional<url::Origin>& initiator =
      navigation_handle->GetInitiatorOrigin();
  const std::string initiator_str =
      initiator ? initiator->Serialize() : std::string("(none)");
  BLINKER_DIAGF("AUTH_FLOW: initiator_origin=%s",
                IsPrivateSession() ? "[private]" : initiator_str.c_str());
  const bool third_party = initiator && initiator->host() != url.host();
  BLINKER_DIAGF("AUTH_FLOW: same_site=%d", third_party ? 0 : 1);
  BLINKER_DIAGF("AUTH_FLOW: third_party_context=%d", third_party ? 1 : 0);
  BLINKER_DIAG("AUTH_FLOW: site mode locked during auth");
  BLINKER_DIAG("AUTH_FLOW: user agent stable during auth");
  RecordAuthUrlAndDetectLoop(url);
}

void Shell::DidRedirectNavigation(NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame()) {
    return;
  }
  const GURL url = navigation_handle->GetURL();
  if (!IsAuthFlowURL(url) && !g_in_auth_flow) {
    return;
  }
  const std::vector<GURL>& chain = navigation_handle->GetRedirectChain();
  if (chain.size() >= 2) {
    BLINKER_DIAGF("AUTH_FLOW: redirect from=%s",
                  LoggableURLSpec(chain[chain.size() - 2]).c_str());
  }
  BLINKER_DIAGF("AUTH_FLOW: redirect to=%s", LoggableURLSpec(url).c_str());
  BLINKER_DIAGF("AUTH_FLOW: redirect_count_for_chain=%zu", chain.size());
  RecordAuthUrlAndDetectLoop(url);

  // Вихід з циклу редиректів login_with/mweb_fallback.
  if (IsChatGPTMwebFallback(url)) {
    if (!g_chatgpt_mweb_logged) {
      g_chatgpt_mweb_logged = true;
      BLINKER_DIAG("AUTH_FLOW: mweb_fallback loop detected");
      BLINKER_DIAG("AUTH_FLOW: stuck before provider redirect");
    }
    if (chain.size() >= 6) {
      if (!g_chatgpt_auth_breaker_used) {
        g_chatgpt_auth_breaker_used = true;
        GURL stripped = net::AppendOrReplaceQueryParameter(url, "mweb_fallback",
                                                           std::nullopt);
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&BreakChatGPTMwebLoop, stripped));
      } else {
        // Повтор уже був, а цикл лишився. Зупиняємось до
        // ERR_TOO_MANY_REDIRECTS.
        BLINKER_DIAG("AUTH_FLOW: retry exhausted");
        BLINKER_DIAG("AUTH_FLOW: no provider url found");
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&StopFrontShellLoad));
      }
    }
  }
}

void Shell::DidFinishNavigation(NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame()) {
    return;
  }
  const GURL url = navigation_handle->GetURL();
  // Закомічена навігація верхнього рівня вирішує, чи це сайт для клавіатури.
  if (navigation_handle->HasCommitted()) {
    if (!navigation_handle->IsSameDocument()) {
      BlinkerContentFilter::GetInstance().ResetHostCount(url.host());
    }
    UpdateKeyboardChatFallback(url);
    // Стартовий документ з розширень лишає ту саму адресу about:blank, тож
    // екран сам не дізнається, що під ним з'явився надійний документ.
    if (!navigation_handle->IsSameDocument() &&
        web_contents()->GetVisibleURL().IsAboutBlank()) {
      g_platform->SetAddressBarURL(this, web_contents()->GetVisibleURL());
    }
    if (!navigation_handle->IsErrorPage()) {
      BlinkApplyPageZoom(web_contents(), url);
      // Навігація в межах документа лишає і хост, і вже вставлені правила,
      // а повторна вставка змушувала перераховувати стилі всієї сторінки.
      if (!navigation_handle->IsSameDocument()) {
        BlinkInjectCosmeticFilters(web_contents(), url);
      }
    }
  }
  if (!IsAuthFlowURL(url) && !g_in_auth_flow) {
    return;
  }
  if (navigation_handle->GetNetErrorCode() == net::ERR_TOO_MANY_REDIRECTS) {
    BLINKER_DIAG("AUTH_FLOW: redirect loop suspected");
    const std::vector<GURL>& chain = navigation_handle->GetRedirectChain();
    BLINKER_DIAG("AUTH_FLOW: last 10 redirects=");
    size_t start = chain.size() > 10 ? chain.size() - 10 : 0;
    for (size_t i = start; i < chain.size(); ++i) {
      BLINKER_DIAGF("AUTH_FLOW:   [%zu]=%s", i,
                    LoggableURLSpec(chain[i]).c_str());
    }
  }
  FlushAndDiagnoseAuthCookies(web_contents());
  // Знімаєм блок, коли вернулись на звичайний контент (напр. chatgpt.com).
  if (!IsAuthFlowURL(url)) {
    g_in_auth_flow = false;
    g_chatgpt_auth_breaker_used = false;
    g_chatgpt_mweb_logged = false;
  }
}

void Shell::ResourceLoadComplete(
    RenderFrameHost* render_frame_host,
    const GlobalRequestID& request_id,
    const GURL& original_url,
    const blink::mojom::ResourceLoadInfo& resource_load_info) {
#if BUILDFLAG(IS_IOS)
  if (resource_load_info.net_error != net::OK ||
      resource_load_info.request_destination !=
          network::mojom::RequestDestination::kImage) {
    return;
  }
  const GURL& image_url = resource_load_info.final_url;
  const std::string host(image_url.host());
  const bool google_avatar_host =
      host == "lh3.googleusercontent.com" || base::EndsWith(host, ".ggpht.com");
  const std::string path(image_url.path());
  if (!google_avatar_host || (path.find("/a/") == std::string::npos &&
                              path.find("/a-/") == std::string::npos)) {
    return;
  }
  // З цього хоста приходять і чужі аватарки (відгуки, коментарі, пошук). Своя
  // лише у фреймах акаунта Google, тож інші ігноруєм.
  const std::string frame_host(
      render_frame_host ? render_frame_host->GetLastCommittedURL().host() : "");
  if (frame_host != "accounts.google.com" &&
      frame_host != "myaccount.google.com" && frame_host != "ogs.google.com") {
    return;
  }
  extern void BlinkObserveGoogleAvatarURL(Shell*, const char*);
  BlinkObserveGoogleAvatarURL(this, image_url.spec().c_str());
#endif
}

void Shell::DidFinishLoad(RenderFrameHost* render_frame_host,
                          const GURL& validated_url) {
#if BUILDFLAG(IS_IOS)
  const std::string host(validated_url.host());
  if (host != "accounts.google.com" && host != "myaccount.google.com" &&
      host != "ogs.google.com" && host != "www.google.com") {
    return;
  }
  extern void BlinkScanGoogleAvatars(WebContents*);
  // Віджет акаунта доточується пізніше за load, тож скануємо ще двічі.
  BlinkScanGoogleAvatars(web_contents());
  for (int seconds : {2, 5}) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<WebContents> contents) {
              extern void BlinkScanGoogleAvatars(WebContents*);
              BlinkScanGoogleAvatars(contents.get());
            },
            web_contents()->GetWeakPtr()),
        base::Seconds(seconds));
  }
#endif
}
#endif  // BUILDFLAG(IS_IOS)

#if BUILDFLAG(IS_ANDROID)
void Shell::SetOverlayMode(bool use_overlay_mode) {
  g_platform->SetOverlayMode(this, use_overlay_mode);
}
#endif

void Shell::EnterFullscreenModeForTab(
    RenderFrameHost* requesting_frame,
    const blink::mojom::FullscreenOptions& options) {
  ToggleFullscreenModeForTab(WebContents::FromRenderFrameHost(requesting_frame),
                             true);
}

void Shell::ExitFullscreenModeForTab(WebContents* web_contents) {
  ToggleFullscreenModeForTab(web_contents, false);
}

void Shell::ToggleFullscreenModeForTab(WebContents* web_contents,
                                       bool enter_fullscreen) {
#if BUILDFLAG(IS_IOS)
  const GURL url = web_contents ? web_contents->GetVisibleURL() : GURL();
  BLINKER_DIAG(enter_fullscreen ? "FULLSCREEN: request" : "FULLSCREEN: exited");
  if (IsYouTubeURL(url)) {
    BLINKER_DIAG("FULLSCREEN: youtube path");
  }
#endif
#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
  g_platform->ToggleFullscreenModeForTab(this, web_contents, enter_fullscreen);
#endif
  const bool fullscreen_changed = is_fullscreen_ != enter_fullscreen;
  if (fullscreen_changed) {
    is_fullscreen_ = enter_fullscreen;
    web_contents->GetPrimaryMainFrame()
        ->GetRenderViewHost()
        ->GetWidget()
        ->SynchronizeVisualProperties();
#if BUILDFLAG(IS_IOS)
    if (enter_fullscreen) {
      BLINKER_DIAG("FULLSCREEN: entered");
    }
#endif
  }
#if BUILDFLAG(IS_IOS)
  if (enter_fullscreen && !fullscreen_changed) {
    BLINKER_DIAG("FULLSCREEN: fallback");
  }
#endif
}

bool Shell::IsFullscreenForTabOrPending(const WebContents* web_contents) {
#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
  return g_platform->IsFullscreenForTabOrPending(this, web_contents);
#else
  return is_fullscreen_;
#endif
}

blink::mojom::DisplayMode Shell::GetDisplayMode(
    const WebContents* web_contents) {
  // TODO: should return blink::mojom::DisplayModeFullscreen wherever user puts
  // a browser window into fullscreen (not only in case of renderer-initiated
  // fullscreen mode): crbug.com/476874.
  return IsFullscreenForTabOrPending(web_contents)
             ? blink::mojom::DisplayMode::kFullscreen
             : blink::mojom::DisplayMode::kBrowser;
}

#if !BUILDFLAG(IS_ANDROID)
void Shell::RegisterProtocolHandler(RenderFrameHost* requesting_frame,
                                    const std::string& protocol,
                                    const GURL& url,
                                    bool user_gesture) {
  BrowserContext* context = requesting_frame->GetBrowserContext();
  if (context->IsOffTheRecord()) {
    return;
  }

  custom_handlers::ProtocolHandler handler =
      custom_handlers::ProtocolHandler::CreateProtocolHandler(
          protocol, url, GetProtocolHandlerSecurityLevel(requesting_frame));

  // The parameters's normalization process defined in the spec has been already
  // applied in the WebContentImpl class, so at this point it shouldn't be
  // possible to create an invalid handler.
  // https://html.spec.whatwg.org/multipage/system-state.html#normalize-protocol-handler-parameters
  DCHECK(handler.IsValid());

  custom_handlers::ProtocolHandlerRegistry* registry = custom_handlers::
      SimpleProtocolHandlerRegistryFactory::GetForBrowserContext(context, true);
  DCHECK(registry);
  if (registry->SilentlyHandleRegisterHandlerRequest(handler)) {
    return;
  }

  if (!user_gesture && !windows().empty()) {
    // TODO(jfernandez): This is not strictly needed, but we need a way to
    // inform the observers in browser tests that the request has been
    // cancelled, to avoid timeouts. Chrome just holds the handler as pending in
    // the PageContentSettingsDelegate, but we don't have such thing in the
    // Content Shell.
    registry->OnDenyRegisterProtocolHandler(handler);
    return;
  }

  // FencedFrames can not register to handle any protocols.
  if (requesting_frame->IsNestedWithinFencedFrame()) {
    registry->OnIgnoreRegisterProtocolHandler(handler);
    return;
  }

  // TODO(jfernandez): Are we interested at all on using the
  // PermissionRequestManager in the ContentShell ?
  if (registry->registration_mode() ==
      custom_handlers::RphRegistrationMode::kAutoAccept) {
    registry->OnAcceptRegisterProtocolHandler(handler);
  }
}

void Shell::UnregisterProtocolHandler(RenderFrameHost* requesting_frame,
                                      const std::string& protocol,
                                      const GURL& url,
                                      bool user_gesture) {
  BrowserContext* context = requesting_frame->GetBrowserContext();
  if (context->IsOffTheRecord()) {
    return;
  }

  custom_handlers::ProtocolHandler handler =
      custom_handlers::ProtocolHandler::CreateProtocolHandler(
          protocol, url, GetProtocolHandlerSecurityLevel(requesting_frame));
  custom_handlers::ProtocolHandlerRegistry* registry = custom_handlers::
      SimpleProtocolHandlerRegistryFactory::GetForBrowserContext(context, true);
  CHECK(registry);

  registry->RemoveHandler(handler);
}
#endif

void Shell::RequestPointerLock(WebContents* web_contents,
                               bool user_gesture,
                               bool last_unlocked_by_target) {
  // Give the platform a chance to handle the lock request, if it doesn't
  // indicate it handled it, allow the request.
  if (!g_platform->HandlePointerLockRequest(this, web_contents, user_gesture,
                                            last_unlocked_by_target)) {
    web_contents->GotResponseToPointerLockRequest(
        blink::mojom::PointerLockResult::kSuccess);
  }
}

void Shell::Close() {
  // Shell is "self-owned" and destroys itself. The ShellPlatformDelegate
  // has the chance to co-opt this and do its own destruction.
  if (!g_platform->DestroyShell(this)) {
    delete this;
  }
}

void Shell::CloseContents(WebContents* source) {
#if BUILDFLAG(IS_IOS)
  // Закриття зі скрипту, як у вікна входу Google. Якщо ця оболонка на екрані,
  // спершу активуєм іншу, краще відкривача, інакше лишиться мертвий UIWindow.
  BLINKER_DIAG("AUTH_POPUP_GUARD: script window close");
  BlinkShellWillCloseReactivate(this, g_auth_popup_opener);
  if (source == g_auth_popup_contents) {
    g_auth_popup_contents = nullptr;
    g_auth_popup_opener = nullptr;
  }
#endif
  Close();
}

bool Shell::CanOverscrollContent() {
#if defined(USE_AURA)
  return true;
#else
  return false;
#endif
}

void Shell::NavigationStateChanged(WebContents* source,
                                   InvalidateTypes changed_flags) {
  if (changed_flags & INVALIDATE_TYPE_URL) {
    g_platform->SetAddressBarURL(this, source->GetVisibleURL());
  }
#if BUILDFLAG(IS_IOS)
  if (changed_flags & INVALIDATE_TYPE_AUDIO) {
    BlinkTabAudioStateChanged(this);
  }
#endif
}

JavaScriptDialogManager* Shell::GetJavaScriptDialogManager(
    WebContents* source) {
  if (!dialog_manager_) {
    dialog_manager_ = g_platform->CreateJavaScriptDialogManager(this);
  }
  if (!dialog_manager_) {
    dialog_manager_ = std::make_unique<ShellJavaScriptDialogManager>();
  }
  return dialog_manager_.get();
}

#if BUILDFLAG(IS_MAC)
void Shell::PrimaryPageChanged(Page& page) {
  g_platform->DidNavigatePrimaryMainFramePostCommit(
      this, WebContents::FromRenderFrameHost(&page.GetMainDocument()));
}

bool Shell::HandleKeyboardEvent(WebContents* source,
                                const input::NativeWebKeyboardEvent& event) {
  return g_platform->HandleKeyboardEvent(this, source, event);
}
#endif

bool Shell::DidAddMessageToConsole(WebContents* source,
                                   blink::mojom::ConsoleMessageLevel log_level,
                                   const std::u16string& message,
                                   int32_t line_no,
                                   const std::u16string& source_id) {
  return switches::IsRunWebTestsSwitchPresent();
}

void Shell::RendererUnresponsive(
    WebContents* source,
    RenderWidgetHost* render_widget_host,
    base::RepeatingClosure hang_monitor_restarter) {
  LOG(WARNING) << "renderer unresponsive";
}

void Shell::ActivateContents(WebContents* contents) {
#if !BUILDFLAG(IS_MAC)
  // TODO(danakj): Move this to ShellPlatformDelegate.
  contents->Focus();
#else
  // Mac headless mode is quite different than other platforms. Normally
  // focusing the WebContents would cause the OS to focus the window. Because
  // headless mac doesn't actually have system windows, we can't go down the
  // normal path and have to fake it out in the browser process.
  g_platform->ActivateContents(this, contents);
#endif
}

#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
std::unique_ptr<ColorChooser> Shell::OpenColorChooser(
    WebContents* web_contents,
    SkColor color,
    const std::vector<blink::mojom::ColorSuggestionPtr>& suggestions) {
  return g_platform->OpenColorChooser(web_contents, color, suggestions);
}
#endif

void Shell::RunFileChooser(RenderFrameHost* render_frame_host,
                           scoped_refptr<FileSelectListener> listener,
                           const blink::mojom::FileChooserParams& params) {
  run_file_chooser_count_++;
  if (hold_file_chooser_) {
    held_file_chooser_listener_ = std::move(listener);
  } else {
    g_platform->RunFileChooser(render_frame_host, std::move(listener), params);
  }
}

void Shell::EnumerateDirectory(WebContents* web_contents,
                               scoped_refptr<FileSelectListener> listener,
                               const base::FilePath& path) {
  run_file_chooser_count_++;
  if (hold_file_chooser_) {
    held_file_chooser_listener_ = std::move(listener);
  } else {
    listener->FileSelectionCanceled();
  }
}

bool Shell::IsBackForwardCacheSupported(WebContents& web_contents) {
  return true;
}

PreloadingEligibility Shell::IsPrerender2Supported(
    WebContents& web_contents,
    PreloadingTriggerType trigger_type) {
  return PreloadingEligibility::kEligible;
}

namespace {
class PendingCallback : public base::RefCounted<PendingCallback> {
 public:
  explicit PendingCallback(base::OnceCallback<void()> cb)
      : callback_(std::move(cb)) {}

 private:
  friend class base::RefCounted<PendingCallback>;
  ~PendingCallback() { std::move(callback_).Run(); }
  base::OnceCallback<void()> callback_;
};
}  // namespace

bool Shell::ShouldAllowRunningInsecureContent(WebContents* web_contents,
                                              bool allowed_per_prefs,
                                              const url::Origin& origin,
                                              const GURL& resource_url) {
  if (allowed_per_prefs) {
    return true;
  }

  return g_platform->ShouldAllowRunningInsecureContent(this);
}

PictureInPictureResult Shell::EnterPictureInPicture(WebContents* web_contents) {
  // During tests, returning success to pretend the window was created and allow
  // tests to run accordingly.
  if (!switches::IsRunWebTestsSwitchPresent()) {
    return PictureInPictureResult::kNotSupported;
  }
  return PictureInPictureResult::kSuccess;
}

bool Shell::ShouldResumeRequestsForCreatedWindow() {
  return !delay_popup_contents_delegate_for_testing_;
}

void Shell::SetContentsBounds(WebContents* source, const gfx::Rect& bounds) {
  DCHECK(source == web_contents());  // There's only one WebContents per Shell.

  if (switches::IsRunWebTestsSwitchPresent()) {
    // Note that chrome drops these requests on normal windows.
    // TODO(danakj): The position is dropped here but we use the size. Web tests
    // can't move the window in headless mode anyways, but maybe we should be
    // letting them pretend?
    g_platform->ResizeWebContent(this, bounds.size());
  }
}

gfx::Size Shell::GetShellDefaultSize() {
  static gfx::Size default_shell_size;  // Only go through this method once.

  if (!default_shell_size.IsEmpty()) {
    return default_shell_size;
  }

  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(switches::kContentShellHostWindowSize)) {
    const std::string size_str = command_line->GetSwitchValueASCII(
        switches::kContentShellHostWindowSize);
    int width, height;
    if (UNSAFE_TODO(sscanf(size_str.c_str(), "%dx%d", &width, &height)) == 2) {
      default_shell_size = gfx::Size(width, height);
    } else {
      LOG(ERROR) << "Invalid size \"" << size_str << "\" given to --"
                 << switches::kContentShellHostWindowSize;
    }
  }

  if (default_shell_size.IsEmpty()) {
    default_shell_size =
        gfx::Size(kDefaultTestWindowWidthDip, kDefaultTestWindowHeightDip);
  }

  return default_shell_size;
}

#if BUILDFLAG(IS_ANDROID)
void Shell::LoadProgressChanged(double progress) {
  g_platform->LoadProgressChanged(this, progress);
}
#endif

void Shell::TitleWasSet(NavigationEntry* entry) {
  if (entry) {
    g_platform->SetTitle(this, entry->GetTitle());
  }
}

}  // namespace content
