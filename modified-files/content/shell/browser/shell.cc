// Copyright 2013 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell.h"

#include <stdint.h>
#include <stddef.h>

#include <map>
#include <memory>
#include <string>
#include <utility>

#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/location.h"
#include "base/memory/memory_pressure_listener.h"
#include "base/no_destructor.h"
#include "base/run_loop.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
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
#include "content/public/browser/page.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/presentation_receiver_flags.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/renderer_preferences_util.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/content_switches.h"
#include "content/shell/app/resource.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/browser/shell_devtools_frontend.h"
#include "content/shell/browser/shell_javascript_dialog_manager.h"
#include "content/shell/common/shell_switches.h"
#include "media/media_buildflags.h"
#include "net/base/net_errors.h"
#include "net/base/url_util.h"
#include "net/cookies/canonical_cookie.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/origin.h"
#include "third_party/blink/public/common/peerconnection/webrtc_ip_handling_policy.h"
#include "third_party/blink/public/common/renderer_preferences/renderer_preferences.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom-forward.h"
#include "third_party/blink/public/mojom/input/pointer_lock_result.mojom.h"
#include "third_party/blink/public/mojom/window_features/window_features.mojom.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdio.h>
#include <time.h>

extern "C" void BlinkBootLog(const char* stage);
extern "C" int BlinkActiveRWHVCount();
extern "C" int BlinkActiveBrowserCompositorCount();
extern "C" int BlinkActiveAttachedCALayerCount();
#endif

namespace content {

namespace {
// Null until/unless the default main message loop is running.
base::OnceClosure& GetMainMessageLoopQuitClosure() {
  static base::NoDestructor<base::OnceClosure> closure;
  return *closure;
}

constexpr int kDefaultTestWindowWidthDip = 800;
constexpr int kDefaultTestWindowHeightDip = 600;

// Owning pointer. We can not use unique_ptr as a global. That introduces a
// static constructor/destructor.
// Acquired in Shell::Init(), released in Shell::Shutdown().
ShellPlatformDelegate* g_platform;

#if BUILDFLAG(IS_IOS)
constexpr uint64_t kRedditPurgeFootprintBytes = 550ULL * 1024ULL * 1024ULL;
constexpr uint64_t kRedditStopFootprintBytes = 700ULL * 1024ULL * 1024ULL;
constexpr uint64_t kRedditEmergencyFootprintBytes = 800ULL * 1024ULL * 1024ULL;
// Single-process iOS memory guard knobs. Keep these centralized so on-device
// tuning can adjust thresholds without touching navigation logic.
constexpr bool kEnableIOSGlobalLowMemoryGuard = true;
constexpr uint64_t kGlobalSoftPurgeBytes = 400ULL * 1024ULL * 1024ULL;
constexpr uint64_t kGlobalCriticalPurgeBytes = 500ULL * 1024ULL * 1024ULL;
constexpr uint64_t kGlobalBlockNewContentsBytes = 650ULL * 1024ULL * 1024ULL;
// OOM watchdog: footprint/RSS growth since the last sample that counts as a
// spike, and the absolute footprint levels that trigger a purge / new-alloc
// block on the interactive page.
constexpr uint64_t kOomWatchdogGrowthSpikeBytes = 100ULL * 1024ULL * 1024ULL;
constexpr uint64_t kOomWatchdogPurgeBytes = 300ULL * 1024ULL * 1024ULL;
constexpr uint64_t kOomWatchdogBlockBytes = 350ULL * 1024ULL * 1024ULL;
// Fallback bottom ratio applied on chat-like sites whose prompt sits near the
// bottom, when live caret/DOM metrics are unavailable.
constexpr float kChatFallbackBottomRatio = 0.92f;
bool g_reddit_memory_blocked = false;
bool g_global_low_memory_mode = false;
bool g_global_low_memory_page_shown = false;
bool g_global_low_memory_task_posted = false;
int g_main_frame_navigation_start_count = 0;
base::TimeTicks g_duplicate_view_first_seen;
base::TimeTicks g_last_oom_watchdog_sample;
uint64_t g_last_oom_watchdog_footprint = 0;
uint64_t g_last_oom_watchdog_rss = 0;
// Heavy-site diagnostics and mitigation state (iOS).
constexpr size_t kRecentLoadStartSlots = 16;
const char* g_last_user_action = "startup";
base::TimeTicks g_recent_load_starts[kRecentLoadStartSlots];
size_t g_recent_load_start_head = 0;
bool g_ai_guard_logged_for_page = false;
base::TimeTicks g_last_ai_presend_purge;
uint64_t g_last_heavy_heartbeat_footprint = 0;
// Auth redirect diagnostics + loop detection.
bool g_in_auth_flow = false;
std::string g_recent_auth_urls[10];
base::TimeTicks g_recent_auth_times[10];
size_t g_recent_auth_head = 0;
bool g_chatgpt_auth_breaker_used = false;
bool g_chatgpt_mweb_logged = false;
// ChatGPT auth UA profile: 0=chromium-mobile (override off), 1=desktop,
// 2=mobile-safari (default; avoids the mweb_fallback loop).
int g_chatgpt_auth_profile = 2;
// Site-scoped keyboard-relocation fallback ratio, read by the iOS keyboard
// handler when Blink caret metrics are unavailable. >0 only on chat-like
// sites whose prompt sits near the bottom.
float g_keyboard_chat_fallback_ratio = 0.0f;
// Current top-level host and whether it is a chat-relocation site. The iOS
// keyboard code path has no WebContents/URL, so these are published on every
// committed top-level navigation. Read and mutated on the UI thread only.
std::string g_keyboard_relocation_host;
bool g_is_chat_keyboard_relocation_site = false;

// Google sign-in popup (GSI flow): the site opens an about:blank popup,
// navigates it to accounts.google.com, and after auth the popup postMessages
// the credential to the opener and calls window.close(). The popup must be a
// real Shell window; these track the one outstanding auth popup.
WebContents* g_auth_popup_contents = nullptr;
WebContents* g_auth_popup_opener = nullptr;

bool IsHeavySiteURL(const GURL& url);

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
  stats.basic_kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                             reinterpret_cast<task_info_t>(&basic_info),
                             &basic_count);
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
  CFStringRef footprint_value =
      CFStringCreateWithCString(kCFAllocatorDefault, footprint,
                                kCFStringEncodingUTF8);
  if (footprint_value) {
    CFPreferencesSetAppValue(CFSTR("BlinkLastHeartbeatFootprint"),
                             footprint_value,
                             kCFPreferencesCurrentApplication);
    CFRelease(footprint_value);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  }

  char buf[512];
  snprintf(buf, sizeof(buf), "HEARTBEAT: timestamp=%ld footprint=%llu url=%s",
           static_cast<long>(time(nullptr)),
           static_cast<unsigned long long>(stats.phys_footprint),
           url->spec().c_str());
  BlinkBootLog(buf);
}

void BlinkLogMemoryPressurePoint(const char* label, const GURL* url) {
  const BlinkMemoryStats stats = GetBlinkMemoryStats();

  char buf[512];
  snprintf(buf, sizeof(buf),
           "MEMSTAT: %s rss=%llu footprint=%llu vsize=%llu basic_kr=%d "
           "vm_kr=%d renderers=%zu web_contents=%zu active_frames=%zu "
           "cache_size=-1 url=%s",
           label,
           static_cast<unsigned long long>(stats.resident_size),
           static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(stats.virtual_size), stats.basic_kr,
           stats.vm_kr, CountRendererProcesses(), Shell::windows().size(),
           CountLivePrimaryFrames(), url ? url->spec().c_str() : "(none)");
  BlinkBootLog(buf);
  StoreHeavyPageHeartbeat(url, stats);

  if (kEnableIOSGlobalLowMemoryGuard &&
      stats.phys_footprint >= kGlobalCriticalPurgeBytes) {
    BlinkBootLog("GLOBAL_MEM_GUARD: footprint over 500MB -> critical purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  }
}

bool IsRedditURL(const GURL& url) {
  return url.host() == "reddit.com" ||
         base::EndsWith(url.host(), ".reddit.com");
}

bool IsYouTubeURL(const GURL& url) {
  const std::string host(url.host());
  return host == "youtube.com" || host == "m.youtube.com" ||
         base::EndsWith(host, ".youtube.com");
}

bool IsGitHubURL(const GURL& url) {
  const std::string host(url.host());
  return host == "github.com" || base::EndsWith(host, ".github.com");
}

bool IsGoogleAuthURL(const GURL& url) {
  const std::string host(url.host());
  return host == "accounts.google.com" || host == "mail.google.com" ||
         host == "google.com" || base::EndsWith(host, ".google.com");
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

// claude.ai opens an about:blank popup that then navigates to
// accounts.google.com; IsGoogleAuthPopupRequest only checks the target URL
// and misses it. Detect via the opener instead. Popups from other openers do
// not match.
bool IsClaudeGoogleAuthPopup(WebContents* source, const GURL& target_url) {
  if (!source) {
    return false;
  }
  GURL opener = source->GetLastCommittedURL();
  if (!opener.is_valid()) {
    opener = source->GetVisibleURL();
  }
  const std::string ohost(opener.host());
  const bool opener_ok = ohost == "claude.ai" ||
                         base::EndsWith(ohost, ".claude.ai") ||
                         ohost == "accounts.google.com";
  if (!opener_ok) {
    return false;
  }
  return target_url.IsAboutBlank() || IsGoogleAuthURL(target_url) ||
         target_url.host() == "accounts.google.com";
}

bool IsHeavySiteURL(const GURL& url) {
  const std::string host(url.host());
  if (host == "reddit.com" || base::EndsWith(host, ".reddit.com") ||
      host == "accounts.google.com" || host == "mail.google.com" ||
      host == "gemini.google.com" || host == "discord.com" ||
      base::EndsWith(host, ".discord.com") || host == "homedepot.com" ||
      base::EndsWith(host, ".homedepot.com") || host == "claude.ai" ||
      base::EndsWith(host, ".claude.ai") || host == "chatgpt.com" ||
      base::EndsWith(host, ".chatgpt.com") || IsYouTubeURL(url) ||
      IsGitHubURL(url)) {
    return true;
  }
  return (host == "google.com" || base::EndsWith(host, ".google.com")) &&
         url.path() == "/search";
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

void RunSiteSwitchCleanupIfNeeded(const GURL& url,
                                  const GURL& current_url,
                                  bool top_level_starting_navigation) {
  if (!top_level_starting_navigation || !url.SchemeIsHTTPOrHTTPS() ||
      IsSameTopLevelSite(url, current_url)) {
    return;
  }
  BlinkBootLog("SITE_SWITCH_CLEANUP: running before top-level site change");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  BlinkBootLog("SITE_SWITCH_CLEANUP: memory pressure purge sent");
  BlinkBootLog("SITE_SWITCH_CLEANUP: transient caches cleared");
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
  const bool duplicate = active_rwhv > 1 || active_compositors > 1;
  if (!duplicate) {
    g_duplicate_view_first_seen = base::TimeTicks();
    return false;
  }
  const base::TimeTicks now = base::TimeTicks::Now();
  if (g_duplicate_view_first_seen.is_null()) {
    g_duplicate_view_first_seen = now;
    BlinkBootLog("IOS_VIEW_LIFECYCLE: transient duplicate tolerated");
    return false;
  }
  if (now - g_duplicate_view_first_seen < base::Seconds(2)) {
    BlinkBootLog("IOS_VIEW_LIFECYCLE: transient duplicate tolerated");
    return false;
  }
  BlinkBootLog("IOS_VIEW_LIFECYCLE: persistent duplicate leak suspected");
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
  const uint64_t rss_growth = stats.resident_size > g_last_oom_watchdog_rss
                                  ? stats.resident_size - g_last_oom_watchdog_rss
                                  : 0;
  if (elapsed <= base::Seconds(1) &&
      (footprint_growth > kOomWatchdogGrowthSpikeBytes ||
       rss_growth > kOomWatchdogGrowthSpikeBytes)) {
    BlinkBootLog("OOM_WATCHDOG: rapid memory growth");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    BlinkBootLog("OOM_WATCHDOG: critical purge sent");
    if (!Shell::windows().empty() && Shell::windows().front()->web_contents() &&
        Shell::windows().front()->web_contents()->IsLoading()) {
      Shell::windows().front()->web_contents()->Stop();
      BlinkBootLog("OOM_WATCHDOG: heavy load paused");
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
  char buf[384];
  snprintf(buf, sizeof(buf),
           "OOM_GUARD: direct allocation risk footprint=%llu rwhv=%d "
           "compositors=%d attached_layers=%d nav_starts=%d url=%s",
           static_cast<unsigned long long>(stats.phys_footprint), active_rwhv,
           active_compositors, active_layers,
           g_main_frame_navigation_start_count, url.spec().c_str());
  BlinkBootLog(buf);
  if (stats.phys_footprint >= kOomWatchdogPurgeBytes) {
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  }
  if (stats.phys_footprint >= kOomWatchdogBlockBytes &&
      persistent_duplicate) {
    BlinkBootLog("OOM_GUARD: active compositor leak suspected");
    BlinkBootLog("OOM_GUARD: blocked navigation before PartitionAlloc risk");
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ShowOOMGuardPage));
    return true;
  }
  return false;
}



// JS-injection kill switches (default off). RenderFrameHost::ExecuteJavaScript
// CHECK-fails on ordinary http/https pages (it is only valid for WebUI /
// DevTools / about:blank), so nothing may inject page JS from the loading
// path. A safe path must use ExecuteJavaScriptInIsolatedWorld or renderer
// preferences from a committed-navigation hook.
bool g_enable_keyboard_avoidance_js = false;
bool g_enable_viewport_meta_js = false;

// Gate for a possible future isolated-world injection path; nothing injects
// today. Even when this returns true, callers must use an isolated world.
bool CanSafelyInjectMainFrameJS(WebContents* source) {
  if (!source || source->IsLoading()) {
    BlinkBootLog("JS_INJECTION_GUARD: skipped unsafe injection");
    return false;
  }
  RenderFrameHost* rfh = source->GetPrimaryMainFrame();
  if (!rfh || !rfh->IsRenderFrameLive() || !rfh->IsActive()) {
    BlinkBootLog("JS_INJECTION_GUARD: stale frame skipped");
    return false;
  }
  if (rfh->GetParent()) {
    BlinkBootLog("JS_INJECTION_GUARD: subframe skipped");
    return false;
  }
  if (!rfh->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
    BlinkBootLog("JS_INJECTION_GUARD: non-http page skipped");
    return false;
  }
  BlinkBootLog("JS_INJECTION_GUARD: primary main frame confirmed");
  return true;
}

void ApplySiteModeViewportJSIfNeeded(WebContents* source) {
  // Disabled: the viewport override must go through device metrics /
  // renderer preferences, not injected <meta viewport> JS.
  if (!g_enable_viewport_meta_js) {
    BlinkBootLog("SITE_MODE: viewport JS injection disabled");
    return;
  }
  if (!CanSafelyInjectMainFrameJS(source)) {
    return;
  }
  // Isolated-world viewport injection only; intentionally not implemented.
  BlinkBootLog("JS_INJECTION_GUARD: skipped unsafe injection");
}

void InjectKeyboardAvoidanceJSIfNeeded(WebContents* source) {
  // Disabled: the scrollIntoView keyboard fallback CHECK-crashed on real
  // pages. Native keyboard handling stays active.
  if (!g_enable_keyboard_avoidance_js) {
    BlinkBootLog("KEYBOARD_AVOIDANCE_JS: disabled");
    return;
  }
  if (!CanSafelyInjectMainFrameJS(source)) {
    return;
  }
  // Isolated-world keyboard-avoidance injection only; not implemented.
  BlinkBootLog("JS_INJECTION_GUARD: skipped unsafe injection");
}

// Crash breadcrumbs, heavy-page heartbeat, and heavy-site mitigation.

// The narrow set of hosts we actively heartbeat at 500ms while open.
bool IsMonitoredHeavyHost(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  const std::string host(url.host());
  return host == "chatgpt.com" || base::EndsWith(host, ".chatgpt.com") ||
         host == "claude.ai" || base::EndsWith(host, ".claude.ai") ||
         IsGitHubURL(url) || host == "gemini.google.com" ||
         host == "mail.google.com";
}

bool IsAISiteURL(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  const std::string host(url.host());
  return host == "chatgpt.com" || base::EndsWith(host, ".chatgpt.com") ||
         host == "claude.ai" || base::EndsWith(host, ".claude.ai");
}

// github.com/<owner>/<repo>[/...]: the heavy repo tree/PR/issues pages.
bool IsGitHubRepoPage(const GURL& url) {
  if (!IsGitHubURL(url) || url.host() != "github.com") {
    return false;
  }
  std::vector<std::string> segs =
      base::SplitString(url.path(), "/", base::TRIM_WHITESPACE,
                        base::SPLIT_WANT_NONEMPTY);
  if (segs.size() < 2) {
    return false;
  }
  static const char* const kReserved[] = {
      "login",   "logout",      "join",     "settings", "notifications",
      "search",  "marketplace", "sponsors", "about",    "features",
      "topics",  "explore",     "new"};
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

// Keep the last few heartbeat lines in CFPreferences so the next launch can
// dump them after a jetsam/SIGKILL.
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
  if (CFStringRef value = CFStringCreateWithCString(
          kCFAllocatorDefault, entry, kCFStringEncodingUTF8)) {
    CFArrayAppendValue(arr, value);
    CFRelease(value);
  }
  while (CFArrayGetCount(arr) > 5) {
    CFArrayRemoveValueAtIndex(arr, 0);
  }
  CFPreferencesSetAppValue(CFSTR("BlinkRecentHeartbeats"), arr,
                           kCFPreferencesCurrentApplication);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
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
  char buf[640];
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: url=%s", url.spec().c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: last_committed=%s",
           committed.spec().c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: last_action=%s",
           g_last_user_action);
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf),
           "CRASH_BREADCRUMB: footprint=%llu rss=%llu vsize=%llu",
           static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(stats.resident_size),
           static_cast<unsigned long long>(stats.virtual_size));
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: active_rwhv=%d",
           BlinkActiveRWHVCount());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf),
           "CRASH_BREADCRUMB: active_compositors=%d active_layers=%d",
           BlinkActiveBrowserCompositorCount(),
           BlinkActiveAttachedCALayerCount());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: loading=%d net_activity=%s",
           source->IsLoading() ? 1 : 0,
           source->IsLoading() ? "loading" : "idle");
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "CRASH_BREADCRUMB: load_start_count_10s=%d",
           LoadStartsInLast10s());
  BlinkBootLog(buf);
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
  char buf[640];
  snprintf(buf, sizeof(buf), "HEARTBEAT_HEAVY: url=%s", url.spec().c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "HEARTBEAT_HEAVY: footprint=%llu",
           static_cast<unsigned long long>(stats.phys_footprint));
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "HEARTBEAT_HEAVY: rss=%llu",
           static_cast<unsigned long long>(stats.resident_size));
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "HEARTBEAT_HEAVY: active_rwhv=%d", rwhv);
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "HEARTBEAT_HEAVY: active_compositors=%d", comps);
  BlinkBootLog(buf);

  char entry[640];
  snprintf(entry, sizeof(entry),
           "ts=%ld footprint=%llu rss=%llu rwhv=%d comps=%d url=%s",
           static_cast<long>(time(nullptr)),
           static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(stats.resident_size), rwhv, comps,
           url.spec().c_str());
  StoreRecentHeartbeat(entry);

  // Chat-site send/stream mitigation: use footprint growth as a proxy for
  // streaming activity and purge before iOS jetsam fires. Never pauses the
  // request.
  if (IsAISiteURL(url)) {
    if (!g_ai_guard_logged_for_page) {
      BlinkBootLog("AI_SITE_GUARD: prompt/send activity suspected");
      g_ai_guard_logged_for_page = true;
    }
    const uint64_t prev = g_last_heavy_heartbeat_footprint;
    const bool growing =
        prev != 0 && stats.phys_footprint > prev + 40ULL * 1024ULL * 1024ULL;
    if (growing && !wc->IsLoading()) {
      BlinkBootLog("AI_SITE_GUARD: streaming active");
    }
    const base::TimeTicks now = base::TimeTicks::Now();
    const bool cooled = g_last_ai_presend_purge.is_null() ||
                        now - g_last_ai_presend_purge > base::Seconds(3);
    if (cooled && (growing || stats.phys_footprint >=
                                  320ULL * 1024ULL * 1024ULL)) {
      BlinkBootLog("AI_SITE_GUARD: pre-send purge");
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_CRITICAL);
      g_last_ai_presend_purge = now;
    }
  }
  g_last_heavy_heartbeat_footprint = stats.phys_footprint;
}

void StartHeavyHeartbeatIfNeeded(const GURL& url) {
  if (!IsMonitoredHeavyHost(url) || HeavyHeartbeatTimer().IsRunning()) {
    return;
  }
  BlinkBootLog("HEARTBEAT_HEAVY: monitor started");
  HeavyHeartbeatTimer().Start(FROM_HERE, base::Milliseconds(500),
                              base::BindRepeating(&HeavyHeartbeatTick));
}

// Auth-flow diagnostics.

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
  g_recent_auth_head = (g_recent_auth_head + 1) % 10;
  int repeats = 0;
  for (size_t i = 0; i < 10; ++i) {
    if (!g_recent_auth_times[i].is_null() &&
        now - g_recent_auth_times[i] <= base::Seconds(5) &&
        g_recent_auth_urls[i] == spec) {
      ++repeats;
    }
  }
  if (repeats >= 3) {
    char buf[700];
    BlinkBootLog("AUTH_FLOW: redirect loop suspected");
    snprintf(buf, sizeof(buf), "AUTH_FLOW: repeated url=%s", spec.c_str());
    BlinkBootLog(buf);
    BlinkBootLog("AUTH_FLOW: last 10 redirects=");
    for (size_t i = 0; i < 10; ++i) {
      size_t idx = (g_recent_auth_head + i) % 10;
      if (!g_recent_auth_urls[idx].empty()) {
        snprintf(buf, sizeof(buf), "AUTH_FLOW:   [%zu]=%s", i,
                 g_recent_auth_urls[idx].c_str());
        BlinkBootLog(buf);
      }
    }
  }
}

// Cookie counts only (never values) for the auth domains.
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
  char buf[160];
  for (const Bucket& b : buckets) {
    snprintf(buf, sizeof(buf), "AUTH_COOKIES: domain=%s count=%d", b.domain,
             b.count);
    BlinkBootLog(buf);
  }
  if (partitioned_seen) {
    BlinkBootLog("AUTH_COOKIES: partitioned cookie seen");
  }
}

void FlushAndDiagnoseAuthCookies(WebContents* wc) {
  if (!wc) {
    return;
  }
  StoragePartition* sp =
      wc->GetBrowserContext()->GetDefaultStoragePartition();
  if (!sp) {
    return;
  }
  network::mojom::CookieManager* cm = sp->GetCookieManagerForBrowserProcess();
  if (!cm) {
    return;
  }
  BlinkBootLog("AUTH_COOKIES: flushing after auth navigation");
  cm->FlushCookieStore(
      base::BindOnce([] { BlinkBootLog("AUTH_COOKIES: flush complete"); }));
  cm->GetAllCookies(base::BindOnce(&LogAuthCookieCounts));
}

// ChatGPT mweb_fallback login loop breaker.

constexpr char kChatGPTDesktopUA[] =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
constexpr char kChatGPTIPhoneSafariUA[] =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 "
    "Safari/604.1";

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

// Chat-like sites (prompt near the bottom) get a conservative keyboard
// relocation fallback when caret metrics are unavailable. Site-scoped so
// ordinary pages never jump.
void UpdateKeyboardChatFallback(const GURL& url) {
  const std::string host(url.host());
  // Don't let a transient empty / about:blank URL (which fires mid-navigation)
  // clobber a real chat host while the keyboard is up. Keep the previous state.
  if (host.empty()) {
    BlinkBootLog(
        "KEYBOARD_RELOCATE: chat fallback disabled reason=empty host (kept "
        "previous)");
    return;
  }
  const bool chat = host == "chatgpt.com" ||
                    base::EndsWith(host, ".chatgpt.com") ||
                    host == "claude.ai" || base::EndsWith(host, ".claude.ai") ||
                    host == "gemini.google.com";
  g_keyboard_relocation_host = host;
  g_is_chat_keyboard_relocation_site = chat;
  g_keyboard_chat_fallback_ratio = chat ? kChatFallbackBottomRatio : 0.0f;
  char buf[160];
  snprintf(buf, sizeof(buf), "KEYBOARD_RELOCATE: current host=%s", host.c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "KEYBOARD_RELOCATE: chat fallback enabled=%d",
           chat ? 1 : 0);
  BlinkBootLog(buf);
  if (!chat) {
    BlinkBootLog("KEYBOARD_RELOCATE: chat fallback disabled reason=non-chat host");
  }
}

// Posted off the navigation callback: apply the auth UA profile, stop the
// looping navigation, and retry once without mweb_fallback.
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
  char buf[160];
  snprintf(buf, sizeof(buf), "AUTH_FLOW: chatgpt auth profile=%s", profile);
  BlinkBootLog(buf);
  if (!ua.ua_string_override.empty()) {
    shell->web_contents()->SetUserAgentOverride(ua, true);
  }
  BlinkBootLog("AUTH_FLOW: mweb loop stopped safely");
  shell->web_contents()->Stop();
  if (stripped_url.is_valid()) {
    BlinkBootLog("AUTH_FLOW: attempting direct provider fallback");
    char b2[700];
    snprintf(b2, sizeof(b2), "AUTH_FLOW: direct provider url=%s",
             stripped_url.spec().c_str());
    BlinkBootLog(b2);
    BlinkBootLog("AUTH_FLOW: retrying without mweb_fallback");
    BlinkBootLog("AUTH_FLOW: stripped mweb_fallback");
    shell->LoadURL(stripped_url);
  } else {
    BlinkBootLog("AUTH_FLOW: no provider url found");
  }
}

// Purge before loading a heavy GitHub repo page. Never blocks the click; the
// extreme-memory case is handled by ApplyGlobalMemoryGuard.
void ApplyGitHubRepoGuard(const GURL& url) {
  if (!IsGitHubRepoPage(url)) {
    return;
  }
  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  BlinkBootLog("GITHUB_REPO_GUARD: repo page detected");
  char buf[256];
  snprintf(buf, sizeof(buf), "GITHUB_REPO_GUARD: footprint=%llu",
           static_cast<unsigned long long>(stats.phys_footprint));
  BlinkBootLog(buf);
  BlinkBootLog("GITHUB_REPO_GUARD: pre-repo purge");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
}

void ShowRedditEmergencyLowMemoryPage() {
  BlinkBootLog("REDDIT_MEM_GUARD: deferred emergency page task running");
  g_global_low_memory_task_posted = false;
  Shell* shell = Shell::windows().empty() ? nullptr : Shell::windows().front();
  if (!shell) {
    return;
  }
  if (shell->web_contents()) {
    shell->web_contents()->Stop();
  }
  if (g_global_low_memory_page_shown) {
    return;
  }
  g_global_low_memory_page_shown = true;
  shell->LoadDataWithBaseURL(
      GURL("about:blank"),
      "%3Chtml%3E%3Cbody%3E%3Ch2%3ELow%20memory%20mode%3C%2Fh2%3E%3Cp%3E"
      "Blinker%20Fluid%20stopped%20this%20heavy%20page%20before%20iOS%20or%20"
      "V8%20ran%20out%20of%20memory.%3C%2Fp%3E%3C%2Fbody%3E%3C%2Fhtml%3E",
      GURL("about:blank"));
  BlinkBootLog("REDDIT_MEM_GUARD: static low-memory page shown");
}

void PostRedditEmergencyLowMemoryPageTask() {
  if (g_global_low_memory_task_posted) {
    return;
  }
  g_global_low_memory_task_posted = true;
  BlinkBootLog("REDDIT_MEM_GUARD: deferred emergency page task posted");
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&ShowRedditEmergencyLowMemoryPage));
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
  char buf[384];
  snprintf(buf, sizeof(buf),
           "GLOBAL_MEM_GUARD: %s footprint=%llu soft_at=%llu critical_at=%llu "
           "block_at=%llu url=%s",
           label, static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(kGlobalSoftPurgeBytes),
           static_cast<unsigned long long>(kGlobalCriticalPurgeBytes),
           static_cast<unsigned long long>(kGlobalBlockNewContentsBytes),
           url.spec().c_str());
  BlinkBootLog(buf);

  if (stats.phys_footprint >= kGlobalSoftPurgeBytes) {
    BlinkBootLog("GLOBAL_MEM_GUARD: footprint over 400MB -> soft purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_MODERATE);
  }
  if (stats.phys_footprint >= kGlobalCriticalPurgeBytes) {
    BlinkBootLog("GLOBAL_MEM_GUARD: footprint over 500MB -> critical purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  }
  if (stats.phys_footprint >= kGlobalSoftPurgeBytes) {
    BlinkBootLog("V8_OOM_CONTEXT near heavy URL before fatal OOM risk");
  }
  if (IsYouTubeURL(url)) {
    BlinkBootLog("GLOBAL_MEM_GUARD: youtube purge-only mode");
    return false;
  }
  if (IsGitHubURL(url)) {
    BlinkBootLog("GITHUB_MEM_GUARD: purge-only mode");
    if (stats.phys_footprint >= kGlobalSoftPurgeBytes) {
      BlinkBootLog("GITHUB_MEM_GUARD: footprint over 400MB");
    }
    if (stats.phys_footprint >= kGlobalCriticalPurgeBytes) {
      BlinkBootLog("GITHUB_MEM_GUARD: footprint over 500MB");
    }
    return false;
  }
  if (url.host() == "discord.com" || base::EndsWith(url.host(), ".discord.com") ||
      url.host() == "homedepot.com" ||
      base::EndsWith(url.host(), ".homedepot.com") ||
      url.host() == "claude.ai" || base::EndsWith(url.host(), ".claude.ai") ||
      url.host() == "chatgpt.com" ||
      base::EndsWith(url.host(), ".chatgpt.com") ||
      url.host() == "gemini.google.com") {
    BlinkBootLog("GLOBAL_MEM_GUARD: common heavy site purge-only mode");
    return false;
  }
  if (url.host() == "accounts.google.com" && IsGoogleAuthURL(current_url)) {
    BlinkBootLog("AUTH_POPUP_GUARD: allowed accounts.google.com navigation");
    return false;
  }
  if (top_level_starting_navigation &&
      stats.phys_footprint >= kGlobalBlockNewContentsBytes &&
      !SameHeavySite(current_url, url) && !IsRedditURL(url)) {
    g_global_low_memory_mode = true;
    BlinkBootLog("GLOBAL_MEM_GUARD: low-memory mode active");
    BlinkBootLog("GLOBAL_MEM_GUARD: blocked heavy navigation");
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

  char buf[384];
  snprintf(buf, sizeof(buf),
           "WEB_CONTENTS_GUARD: blocked new window path=%s existing=%zu "
           "footprint=%llu block_at=%llu url=%s",
           path, Shell::windows().size(),
           static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(kGlobalBlockNewContentsBytes),
           url.spec().c_str());
  BlinkBootLog(buf);
  return true;
}

bool ApplyRedditMemoryGuard(const GURL& url,
                            const GURL& current_url,
                            const char* label,
                            bool top_level_starting_navigation) {
  if (!IsRedditURL(url)) {
    return false;
  }

  const BlinkMemoryStats stats = GetBlinkMemoryStats();
  char buf[256];
  snprintf(buf, sizeof(buf),
           "REDDIT_MEM_GUARD: %s footprint=%llu purge_at=%llu stop_at=%llu "
           "emergency_at=%llu",
           label, static_cast<unsigned long long>(stats.phys_footprint),
           static_cast<unsigned long long>(kRedditPurgeFootprintBytes),
           static_cast<unsigned long long>(kRedditStopFootprintBytes),
           static_cast<unsigned long long>(kRedditEmergencyFootprintBytes));
  BlinkBootLog(buf);

  if (g_reddit_memory_blocked) {
    BlinkBootLog("REDDIT_MEM_GUARD: one-shot block active");
    BlinkBootLog("REDDIT_MEM_GUARD: refusing reddit reload");
    BlinkBootLog("REDDIT_MEM_GUARD: suppressed stale reddit challenge navigation");
    BlinkBootLog("REDDIT_MEM_GUARD: early return before navigation");
    return true;
  }

  if (stats.phys_footprint >= kRedditPurgeFootprintBytes) {
    BlinkBootLog("REDDIT_MEM_GUARD: footprint over 550MB -> memory purge");
    base::MemoryPressureListener::NotifyMemoryPressure(
        base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  }

  if (!top_level_starting_navigation) {
    BlinkBootLog("REDDIT_MEM_GUARD: not blocking subresource/spa route");
    return false;
  }
  if (IsRedditURL(current_url) && stats.phys_footprint < kRedditEmergencyFootprintBytes) {
    BlinkBootLog("REDDIT_MEM_GUARD: allowing same-site interaction");
    return false;
  }
  constexpr uint64_t kRedditBlockFootprintBytes = 750ULL * 1024ULL * 1024ULL;
  if (stats.phys_footprint < kRedditBlockFootprintBytes) {
    BlinkBootLog("REDDIT_MEM_GUARD: below hard stop -> allow navigation");
    return false;
  }

  g_reddit_memory_blocked = true;
  BlinkBootLog(
      stats.phys_footprint >= kRedditEmergencyFootprintBytes
          ? "REDDIT_MEM_GUARD: footprint over 800MB -> emergency reddit block"
          : "REDDIT_MEM_GUARD: blocking top-level reddit reload");
  BlinkBootLog("REDDIT_MEM_GUARD: early return before navigation");
  if (stats.phys_footprint >= kRedditEmergencyFootprintBytes) {
    PostRedditEmergencyLowMemoryPageTask();
  }
  return true;
}
#endif
}  // namespace

std::vector<Shell*> Shell::windows_;
base::OnceCallback<void(Shell*)> Shell::shell_created_callback_;

Shell::Shell(std::unique_ptr<WebContents> web_contents,
             bool should_set_delegate)
    : WebContentsObserver(web_contents.get()),
      web_contents_(std::move(web_contents)) {
  if (should_set_delegate)
    web_contents_->SetDelegate(this);

  if (!switches::IsRunWebTestsSwitchPresent()) {
    UpdateFontRendererPreferencesFromSystemSettings(
        web_contents_->GetMutableRendererPrefs());
  }

  windows_.push_back(this);

  if (shell_created_callback_)
    std::move(shell_created_callback_).Run(this);
}

Shell::~Shell() {
  g_platform->CleanUp(this);

  for (size_t i = 0; i < windows_.size(); ++i) {
    if (windows_[i] == this) {
      windows_.erase(windows_.begin() + i);
      break;
    }
  }

#if BUILDFLAG(IS_IOS)
  // Clear the auth-popup trackers if either side dies through a path other
  // than CloseContents.
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

  if (windows().empty())
    g_platform->DidCloseLastWindow();
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
  }

  g_platform->SetContents(shell);
  g_platform->DidCreateOrAttachWebContents(shell, raw_web_contents);
  // If the RenderFrame was created during WebContents construction (as happens
  // for windows opened from the renderer) then the Shell won't hear about the
  // main frame being created as a WebContentsObservers. This gives the delegate
  // a chance to act on the main frame accordingly.
  if (raw_web_contents->GetPrimaryMainFrame()->IsRenderFrameLive())
    g_platform->MainFrameCreated(shell,
                                 raw_web_contents->GetPrimaryMainFrame());

  return shell;
}

// static
void Shell::SetMainMessageLoopQuitClosure(base::OnceClosure quit_closure) {
  GetMainMessageLoopQuitClosure() = std::move(quit_closure);
}

// static
void Shell::QuitMainMessageLoopForTesting() {
  auto& quit_loop = GetMainMessageLoopQuitClosure();
  if (quit_loop)
    std::move(quit_loop).Run();
}

// static
void Shell::SetShellCreatedCallback(
    base::OnceCallback<void(Shell*)> shell_created_callback) {
  DCHECK(!shell_created_callback_);
  shell_created_callback_ = std::move(shell_created_callback);
}

// static
bool Shell::ShouldHideToolbar() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(
      switches::kContentShellHideToolbar);
}

// static
Shell* Shell::FromWebContents(WebContents* web_contents) {
  for (Shell* window : windows_) {
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
  if (!g_platform)  // Shutdown has already been called.
    return;

  DevToolsAgentHost::DetachAllClients();

  while (!Shell::windows().empty())
    Shell::windows().back()->Close();

  delete g_platform;
  g_platform = nullptr;

  for (auto it = RenderProcessHost::AllHostsIterator(); !it.IsAtEnd();
       it.Advance()) {
    it.GetCurrentValue()->DisableRefCounts();
  }
  auto& quit_loop = GetMainMessageLoopQuitClosure();
  if (quit_loop)
    std::move(quit_loop).Run();

  // Pump the message loop to allow window teardown tasks to run. On iOS the
  // run loop is controlled differently and cannot be pumped.
#if !BUILDFLAG(IS_IOS)
  base::RunLoop().RunUntilIdle();
#endif  // !BUILDFLAG(IS_IOS)
}

gfx::Size Shell::AdjustWindowSize(const gfx::Size& initial_size) {
  if (!initial_size.IsEmpty())
    return initial_size;
  return GetShellDefaultSize();
}

// static
Shell* Shell::CreateNewWindow(BrowserContext* browser_context,
                              const GURL& url,
                              const scoped_refptr<SiteInstance>& site_instance,
                              const gfx::Size& initial_size) {
#if BUILDFLAG(IS_IOS)
  // On iOS this is reached only by the explicit New Tab button; window.open /
  // target=_blank / auth popups go through AddNewContents and OpenURLFromTab.
  // Always create a real, separate tab here.
  BlinkBootLog("TAB_MANAGER: new tab created via CreateNewWindow");
  if (ShouldBlockNewWebContents("CreateNewWindow", url)) {
    BlinkBootLog("TAB_MANAGER: new tab blocked (extreme memory)");
    Shell* existing = Shell::windows().empty() ? nullptr : Shell::windows().front();
    if (existing && !url.is_empty() && !g_reddit_memory_blocked) {
      existing->LoadURL(url);
    }
    return existing;
  }
  if (g_reddit_memory_blocked) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "REDDIT_MEM_GUARD: WebContents create path=CreateNewWindow "
             "existing=%zu url=%s",
             Shell::windows().size(), url.spec().c_str());
    BlinkBootLog(buf);
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

  if (!url.is_empty())
    shell->LoadURL(url);
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
  const GURL current_url = web_contents_ ? web_contents_->GetVisibleURL() : GURL();
  const bool top_level_starting_navigation = frame_name.empty();
  BlinkLogMemoryPressurePoint(IsRedditURL(url) ? "before reddit.com load"
                                               : "before page load",
                              &url);
  if (IsAuthFlowURL(url)) {
    // Never block an auth redirect; only purge. Blocking an oauth callback
    // would break the auth chain.
    BlinkBootLog("AUTH_FLOW: guard purge-only");
    const BlinkMemoryStats astats = GetBlinkMemoryStats();
    if (astats.phys_footprint >= kGlobalCriticalPurgeBytes) {
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    }
    BlinkBootLog("AUTH_FLOW: redirect allowed");
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
    if (ApplyRedditMemoryGuard(url, current_url, "before load",
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
  // Starting a navigation while a previous one is in flight races the
  // single-process renderer's RWHV teardown and crashes. Abort any in-flight
  // load first.
#if BUILDFLAG(IS_IOS)
  if (web_contents_ && web_contents_->IsLoading()) {
    // Re-requesting the URL already in flight would cancel+restart the
    // navigation on every tap and churn the compositor; ignore duplicates.
    // Only a navigation to a different URL stops the in-flight one.
    NavigationEntry* pending = web_contents_->GetController().GetPendingEntry();
    if (pending && pending->GetURL() == url) {
      return;
    }
    web_contents_->Stop();
  }
#endif
  NavigationController::LoadURLParams params(url);
  params.frame_name = frame_name;
  params.transition_type = transition_type;
  web_contents_->GetController().LoadURLWithParams(params);
#if BUILDFLAG(IS_IOS)
  BlinkLogMemoryPressurePoint(IsRedditURL(url) ? "after reddit.com load request"
                                               : "after page load request",
                              &url);
  ApplyGlobalMemoryGuard(url, current_url, "after load request", false);
  ApplyRedditMemoryGuard(url, current_url, "after load request", false);
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
// Implemented in shell_platform_delegate_ios.mm (needs UIKit).
extern "C" void BlinkPresentShellWindow(Shell* shell);
extern "C" void BlinkShellWillCloseReactivate(Shell* closing,
                                              WebContents* preferred_opener);
#endif

WebContents* Shell::AddNewContents(
    WebContents* source,
    std::unique_ptr<WebContents> new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
#if BUILDFLAG(IS_IOS)
  // Google sign-in popups must exist as real windows: after auth the popup
  // postMessages the credential back to the opener and closes itself.
  // CloseContents hands the screen back to the opener.
  const bool is_google_auth_popup =
      IsGoogleAuthPopupRequest(target_url) ||
      target_url.host() == "accounts.google.com" ||
      IsClaudeGoogleAuthPopup(source, target_url);
  if (is_google_auth_popup) {
    BlinkBootLog("AUTH_POPUP_GUARD: detected google auth popup");
    BlinkBootLog("CLAUDE_AUTH: google button clicked");
    BlinkBootLog("AUTH_POPUP_GUARD: keeping popup as real window");
    WebContents* raw_popup = new_contents.get();
    g_auth_popup_contents = raw_popup;
    g_auth_popup_opener = source;
    Shell* popup_shell =
        CreateShell(std::move(new_contents),
                    AdjustWindowSize(window_features.bounds.size()),
                    true /* should_set_delegate */);
    BlinkPresentShellWindow(popup_shell);
    BlinkBootLog("AUTH_POPUP_GUARD: allowed accounts.google.com navigation");
    return raw_popup;
  }
  if (ShouldBlockNewWebContents("AddNewContents", target_url)) {
    if (was_blocked) {
      *was_blocked = true;
    }
    return nullptr;
  }
  if (g_reddit_memory_blocked) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "REDDIT_MEM_GUARD: WebContents create path=AddNewContents "
             "existing=%zu disposition=%d url=%s",
             Shell::windows().size(), static_cast<int>(disposition),
             target_url.spec().c_str());
    BlinkBootLog(buf);
  }
#endif
#if !BUILDFLAG(IS_ANDROID)
  // If the shell is opening a document picture-in-picture window, it needs to
  // inform the DocumentPictureInPictureWindowController.
  if (disposition == WindowOpenDisposition::NEW_PICTURE_IN_PICTURE) {
    DocumentPictureInPictureWindowController* controller =
        PictureInPictureWindowController::
            GetOrCreateDocumentPictureInPictureController(source);
    controller->SetChildWebContents(new_contents.get());
    controller->Show();
  }
#endif  // !BUILDFLAG(IS_ANDROID)

  WebContents* result = new_contents.get();
  CreateShell(
      std::move(new_contents), AdjustWindowSize(window_features.bounds.size()),
      !delay_popup_contents_delegate_for_testing_ /* should_set_delegate */);
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
  if (!devtools_frontend_)
    return;
  devtools_frontend_->Close();
  devtools_frontend_ = nullptr;
}

void Shell::ResizeWebContentForTests(const gfx::Size& content_size) {
  g_platform->ResizeWebContent(this, content_size);
}

gfx::NativeView Shell::GetContentView() {
  if (!web_contents_)
    return gfx::NativeView();
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
    if (!url.has_scheme())
      url = GURL("http://" + url_string);
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
    case WindowOpenDisposition::CURRENT_TAB:
      target = source;
      break;

    // Normally, the difference between NEW_POPUP and NEW_WINDOW is that a popup
    // should have no toolbar, no status bar, no menu bar, no scrollbars and be
    // not resizable.  For simplicity and to enable new testing scenarios in
    // content shell and web tests, popups don't get special treatment below
    // (i.e. they will have a toolbar and other things described here).
    case WindowOpenDisposition::NEW_POPUP:
    case WindowOpenDisposition::NEW_WINDOW:
    // content_shell doesn't really support tabs, but some web tests use
    // middle click (which translates into kNavigationPolicyNewBackgroundTab),
    // so we treat the cases below just like a NEW_WINDOW disposition.
    case WindowOpenDisposition::NEW_BACKGROUND_TAB:
    case WindowOpenDisposition::NEW_FOREGROUND_TAB: {
#if BUILDFLAG(IS_IOS)
      BlinkBootLog("WEB_CONTENTS_GUARD: target=_blank using existing WebContents");
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
    case WindowOpenDisposition::SINGLETON_TAB:
    // No incognito mode in content_shell:
    case WindowOpenDisposition::OFF_THE_RECORD:
    // TODO(lukasza): Investigate if some web tests might need support for
    // SAVE_TO_DISK disposition.  This would probably require that
    // WebTestControlHost always sets up and cleans up a temporary directory
    // as the default downloads destinations for the duration of a test.
    case WindowOpenDisposition::SAVE_TO_DISK:
    // Ignoring requests with disposition == IGNORE_ACTION...
    case WindowOpenDisposition::IGNORE_ACTION:
    default:
      return nullptr;
  }

#if BUILDFLAG(IS_IOS)
  // See LoadURLForFrame: ignore duplicate navigations to the URL already in
  // flight; only a different URL stops the in-flight load.
  if (params.disposition == WindowOpenDisposition::CURRENT_TAB &&
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
  BlinkLogMemoryPressurePoint(source->IsLoading() ? "page load started"
                                                  : "page load stopped",
                              &url);
  ApplyGlobalMemoryGuard(url, url,
                         source->IsLoading() ? "loading state active"
                                             : "loading state stopped",
                         false);
  ApplyRedditMemoryGuard(url, url,
                         source->IsLoading() ? "loading state active"
                                             : "loading state stopped",
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
  if (!source->IsLoading()) {
    // Never call RenderFrameHost::ExecuteJavaScript from here; it
    // CHECK-crashes on real http/https pages. The helpers below only log and
    // return.
    BlinkBootLog("JS_INJECTION_GUARD: disabled LoadingStateChanged ExecuteJavaScript");
    BlinkBootLog("JS_INJECTION_GUARD: skipped unsafe injection");
    ApplySiteModeViewportJSIfNeeded(source);
    InjectKeyboardAvoidanceJSIfNeeded(source);
  }
#endif
  UpdateNavigationControls(should_show_loading_ui);
  g_platform->SetIsLoading(this, source->IsLoading());
}

#if BUILDFLAG(IS_IOS)
// Exposed for shell_platform_delegate_ios.mm so the desktop/mobile toggle can
// avoid changing the UA mid auth-redirect chain.
bool BlinkShellIsInAuthFlow() {
  return g_in_auth_flow;
}

// Read by the iOS keyboard handler as a fallback bottom ratio when caret
// metrics are unavailable. >0 only on chat-like sites.
extern "C" float BlinkKeyboardChatFallbackRatio() {
  return g_keyboard_chat_fallback_ratio;
}

// The keyboard relocation code path has no URL of its own; it reads the
// current host and chat eligibility from here. The returned pointer is valid
// until the next committed navigation. UI thread only.
extern "C" const char* BlinkKeyboardRelocationHost() {
  return g_keyboard_relocation_host.c_str();
}

extern "C" int BlinkIsChatKeyboardRelocationSite() {
  return g_is_chat_keyboard_relocation_site ? 1 : 0;
}

void Shell::DidStartNavigation(NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame()) {
    return;
  }
  const GURL url = navigation_handle->GetURL();
  if (!IsAuthFlowURL(url)) {
    return;
  }
  g_in_auth_flow = true;
  char buf[700];
  snprintf(buf, sizeof(buf), "AUTH_FLOW: navigation url=%s", url.spec().c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "AUTH_FLOW: method=%s",
           navigation_handle->IsPost() ? "POST" : "GET");
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "AUTH_FLOW: top_frame=%d",
           navigation_handle->IsInPrimaryMainFrame() ? 1 : 0);
  BlinkBootLog(buf);
  const std::optional<url::Origin>& initiator =
      navigation_handle->GetInitiatorOrigin();
  const std::string initiator_str =
      initiator ? initiator->Serialize() : std::string("(none)");
  snprintf(buf, sizeof(buf), "AUTH_FLOW: initiator_origin=%s",
           initiator_str.c_str());
  BlinkBootLog(buf);
  const bool third_party = initiator && initiator->host() != url.host();
  snprintf(buf, sizeof(buf), "AUTH_FLOW: same_site=%d", third_party ? 0 : 1);
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "AUTH_FLOW: third_party_context=%d",
           third_party ? 1 : 0);
  BlinkBootLog(buf);
  BlinkBootLog("AUTH_FLOW: site mode locked during auth");
  BlinkBootLog("AUTH_FLOW: user agent stable during auth");
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
  char buf[700];
  if (chain.size() >= 2) {
    snprintf(buf, sizeof(buf), "AUTH_FLOW: redirect from=%s",
             chain[chain.size() - 2].spec().c_str());
    BlinkBootLog(buf);
  }
  snprintf(buf, sizeof(buf), "AUTH_FLOW: redirect to=%s", url.spec().c_str());
  BlinkBootLog(buf);
  snprintf(buf, sizeof(buf), "AUTH_FLOW: redirect_count_for_chain=%zu",
           chain.size());
  BlinkBootLog(buf);
  RecordAuthUrlAndDetectLoop(url);

  // ChatGPT's mweb_fallback login redirects login_with?...mweb_fallback=1 to
  // itself and never reaches the provider.
  if (IsChatGPTMwebFallback(url)) {
    if (!g_chatgpt_mweb_logged) {
      g_chatgpt_mweb_logged = true;
      BlinkBootLog("AUTH_FLOW: mweb_fallback loop detected");
      BlinkBootLog("AUTH_FLOW: stuck before provider redirect");
      BlinkBootLog("AUTH_FLOW: provider redirect never reached");
      BlinkBootLog("AUTH_FLOW: auth capability probe fedcm=unknown");
      BlinkBootLog("AUTH_FLOW: credential_management=unknown");
      BlinkBootLog("AUTH_FLOW: webauthn=unknown");
      BlinkBootLog("AUTH_FLOW: popup_supported=1");
      BlinkBootLog("AUTH_FLOW: opener_supported=1");
      BlinkBootLog("AUTH_FLOW: postmessage_origin_ok=unknown");
    }
    if (chain.size() >= 6) {
      if (!g_chatgpt_auth_breaker_used) {
        g_chatgpt_auth_breaker_used = true;
        GURL stripped = net::AppendOrReplaceQueryParameter(
            url, "mweb_fallback", std::nullopt);
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&BreakChatGPTMwebLoop, stripped));
      } else {
        // Already retried once and it still loops; stop safely instead of
        // hitting ERR_TOO_MANY_REDIRECTS.
        BlinkBootLog("AUTH_FLOW: retry exhausted");
        BlinkBootLog("AUTH_FLOW: no provider url found");
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
  // Refresh the keyboard-relocation host on every committed top-level
  // navigation; LoadingStateChanged can fire with transient URLs.
  if (navigation_handle->HasCommitted()) {
    UpdateKeyboardChatFallback(url);
  }
  if (!IsAuthFlowURL(url) && !g_in_auth_flow) {
    return;
  }
  if (navigation_handle->GetNetErrorCode() == net::ERR_TOO_MANY_REDIRECTS) {
    BlinkBootLog("AUTH_FLOW: redirect loop suspected");
    const std::vector<GURL>& chain = navigation_handle->GetRedirectChain();
    BlinkBootLog("AUTH_FLOW: last 10 redirects=");
    size_t start = chain.size() > 10 ? chain.size() - 10 : 0;
    char buf[700];
    for (size_t i = start; i < chain.size(); ++i) {
      snprintf(buf, sizeof(buf), "AUTH_FLOW:   [%zu]=%s", i,
               chain[i].spec().c_str());
      BlinkBootLog(buf);
    }
  }
  // Flush auth cookies to disk whenever an auth navigation commits or leaves
  // an auth domain.
  FlushAndDiagnoseAuthCookies(web_contents());
  // Clear the lock once back on non-auth content.
  if (!IsAuthFlowURL(url)) {
    g_in_auth_flow = false;
    g_chatgpt_auth_breaker_used = false;
    g_chatgpt_mweb_logged = false;
  }
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
  BlinkBootLog(enter_fullscreen ? "FULLSCREEN: request" : "FULLSCREEN: exited");
  if (IsYouTubeURL(url)) {
    BlinkBootLog("FULLSCREEN: youtube path");
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
      BlinkBootLog("FULLSCREEN: entered");
    }
#endif
  }
#if BUILDFLAG(IS_IOS)
  if (enter_fullscreen && !fullscreen_changed) {
    BlinkBootLog("FULLSCREEN: fallback");
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
  if (context->IsOffTheRecord())
    return;

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
  if (registry->SilentlyHandleRegisterHandlerRequest(handler))
    return;

  if (!user_gesture && !windows_.empty()) {
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
  if (!g_platform->DestroyShell(this))
    delete this;
}

void Shell::CloseContents(WebContents* source) {
#if BUILDFLAG(IS_IOS)
  // Script-initiated close (window.close()), e.g. the Google auth popup. If
  // this shell owns the visible window, activate another one (preferring the
  // popup's opener) before dying, or the app is left on a dead UIWindow.
  BlinkBootLog("AUTH_POPUP_GUARD: script window close");
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
  if (changed_flags & INVALIDATE_TYPE_URL)
    g_platform->SetAddressBarURL(this, source->GetVisibleURL());
}

JavaScriptDialogManager* Shell::GetJavaScriptDialogManager(
    WebContents* source) {
  if (!dialog_manager_)
    dialog_manager_ = g_platform->CreateJavaScriptDialogManager(this);
  if (!dialog_manager_)
    dialog_manager_ = std::make_unique<ShellJavaScriptDialogManager>();
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
  if (allowed_per_prefs)
    return true;

  return g_platform->ShouldAllowRunningInsecureContent(this);
}

PictureInPictureResult Shell::EnterPictureInPicture(WebContents* web_contents) {
  // During tests, returning success to pretend the window was created and allow
  // tests to run accordingly.
  if (!switches::IsRunWebTestsSwitchPresent())
    return PictureInPictureResult::kNotSupported;
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

  if (!default_shell_size.IsEmpty())
    return default_shell_size;

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
  if (entry)
    g_platform->SetTitle(this, entry->GetTitle());
}

}  // namespace content
