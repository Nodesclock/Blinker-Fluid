// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/shell/app/ios/shell_application_ios.h"

#include <mach/mach.h>
#include <os/proc.h>
#include <os/lock.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/memory/memory_pressure_listener.h"
#include "components/crash/core/app/crashpad.h"
#include "content/public/app/content_main.h"
#include "content/public/app/content_main_runner.h"
#include "content/shell/app/shell_main_delegate.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/common/blinker_memory_policy.h"
#include "ui/gfx/geometry/size.h"

extern "C" void BlinkPersistOpenTabs();

#if BUILDFLAG(IS_IOS_TVOS)
#include "content/shell/app/ios/shell_app_scene_delegate_tvos.h"
#endif

static int g_argc = 0;
static const char** g_argv = nullptr;
static std::unique_ptr<content::ContentMainRunner> g_main_runner;
static std::unique_ptr<content::ShellMainDelegate> g_main_delegate;

// Early startup logger. This can run before Foundation is initialized and
// therefore uses only C runtime APIs.
extern "C" void BlinkArmCrashHandler(void);

namespace {

os_unfair_lock g_boot_log_lock = OS_UNFAIR_LOCK_INIT;
bool g_boot_log_initialized = false;

void SanitizeBootLogLine(const char* input, char* output, size_t output_size) {
  if (!input || output_size == 0) {
    return;
  }
  size_t read = 0;
  size_t write = 0;
  bool in_url = false;
  bool redacting = false;
  while (input[read] && write + 1 < output_size) {
    if (!in_url &&
        (!strncmp(input + read, "https://", 8) ||
         !strncmp(input + read, "http://", 7))) {
      in_url = true;
    }
    const char c = input[read++];
    if (in_url && !redacting && (c == '?' || c == '#')) {
      constexpr char kRedacted[] = "[redacted]";
      constexpr size_t kRedactedLength = sizeof(kRedacted) - 1;
      if (write + kRedactedLength >= output_size) {
        break;
      }
      memcpy(output + write, kRedacted, kRedactedLength);
      write += kRedactedLength;
      redacting = true;
      continue;
    }
    if (in_url && (c == ' ' || c == '\t' || c == '\n')) {
      in_url = false;
      redacting = false;
    }
    if (!redacting || !in_url) {
      output[write++] = c;
    }
  }
  output[write] = '\0';
}

}  // namespace

extern "C" void BlinkBootLog(const char* stage) {
  char sanitized[4096] = {};
  SanitizeBootLogLine(stage, sanitized, sizeof(sanitized));

  os_unfair_lock_lock(&g_boot_log_lock);
  const char* path = "/var/mobile/Documents/blink_boot.log";
  if (!g_boot_log_initialized) {
    // Preserve the previous run before truncating the current log.
    rename(path, "/var/mobile/Documents/blink_boot_prev.log");
  }
  FILE* f = fopen(path, g_boot_log_initialized ? "a" : "w");
  g_boot_log_initialized = true;
  if (f) {
    fprintf(f, "%ld %s\n", (long)time(nullptr), sanitized);
    fclose(f);
  }
  os_unfair_lock_unlock(&g_boot_log_lock);
}

// Poll memory headroom because jetsam can terminate a foreground process
// without delivering a UIKit memory warning first.
static dispatch_source_t g_mem_watchdog_timer = nullptr;
static time_t g_last_critical_purge = 0;
static bool g_mem_watchdog_low_latched = false;

// Rate-limit critical pressure to avoid cache and GC thrashing.
static const int kCriticalPurgeMinIntervalSecs = 3;
// Remaining-memory and footprint thresholds.
static void BlinkBootLogMemory(const char* label);

static void BlinkMemoryWatchdogTick() {
  size_t available = os_proc_available_memory();
  uint64_t avail = static_cast<uint64_t>(available);
  task_vm_info_data_t vm_info = {};
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  const bool have_footprint =
      task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&vm_info), &vm_count) ==
      KERN_SUCCESS;
  const uint64_t footprint =
      have_footprint ? static_cast<uint64_t>(vm_info.phys_footprint) : 0;
  const bool critical =
      (available != 0 && avail < content::blinker_memory::kCriticalAvailable) ||
      (have_footprint &&
       footprint >= content::blinker_memory::kCriticalFootprint);
  const bool moderate =
      (available != 0 && avail < content::blinker_memory::kModerateAvailable) ||
      (have_footprint &&
       footprint >= content::blinker_memory::kModerateFootprint);

  if (critical) {
    time_t now = time(nullptr);
    if (now - g_last_critical_purge >= kCriticalPurgeMinIntervalSecs) {
      g_last_critical_purge = now;
      char buf[128];
      snprintf(buf, sizeof(buf),
               "MEMWATCH: available=%lluMB footprint=%lluMB -> CRITICAL",
               avail >> 20, footprint >> 20);
      BlinkBootLog(buf);
      BlinkBootLogMemory("watchdog critical");
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_CRITICAL);
    }
    g_mem_watchdog_low_latched = true;
  } else if (moderate) {
    // Only act on the first crossing into the moderate band, not every tick,
    // so steady-state browsing near the threshold does not GC-thrash.
    if (!g_mem_watchdog_low_latched) {
      g_mem_watchdog_low_latched = true;
      char buf[128];
      snprintf(buf, sizeof(buf),
               "MEMWATCH: available=%lluMB footprint=%lluMB -> MODERATE",
               avail >> 20, footprint >> 20);
      BlinkBootLog(buf);
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_MODERATE);
    }
  } else {
    // Recovered well above the moderate band; re-arm the moderate one-shot.
    g_mem_watchdog_low_latched = false;
  }
}

static void BlinkStartMemoryWatchdog() {
  if (g_mem_watchdog_timer) {
    dispatch_resume(g_mem_watchdog_timer);
    return;
  }
  g_mem_watchdog_timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  // Poll twice per second so a fast JS/media allocation burst cannot jump from
  // a healthy footprint to the jetsam ceiling between samples.
  dispatch_source_set_timer(
      g_mem_watchdog_timer,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
  dispatch_source_set_event_handler(g_mem_watchdog_timer, ^{
    BlinkMemoryWatchdogTick();
  });
  dispatch_resume(g_mem_watchdog_timer);
  BlinkBootLog("MEMWATCH: proactive available-memory watchdog started");
}

static void BlinkStopMemoryWatchdog() {
  if (g_mem_watchdog_timer) {
    dispatch_suspend(g_mem_watchdog_timer);
  }
}

static void BlinkBootLogMemory(const char* label) {
  mach_task_basic_info_data_t basic_info;
  mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t basic_kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                     reinterpret_cast<task_info_t>(&basic_info),
                                     &basic_count);

  task_vm_info_data_t vm_info;
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  kern_return_t vm_kr = task_info(mach_task_self(), TASK_VM_INFO,
                                  reinterpret_cast<task_info_t>(&vm_info),
                                  &vm_count);

  char buf[256];
  snprintf(buf, sizeof(buf),
           "MEMSTAT: %s rss=%llu footprint=%llu vsize=%llu basic_kr=%d "
           "vm_kr=%d",
           label,
           basic_kr == KERN_SUCCESS
               ? static_cast<unsigned long long>(basic_info.resident_size)
               : 0,
           vm_kr == KERN_SUCCESS
               ? static_cast<unsigned long long>(vm_info.phys_footprint)
               : 0,
           basic_kr == KERN_SUCCESS
               ? static_cast<unsigned long long>(basic_info.virtual_size)
               : 0,
           basic_kr, vm_kr);
  BlinkBootLog(buf);
}

// Mark clean background transitions so restoration can distinguish crashes.
static void BlinkMarkCleanExit() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setObject:@"clean_exit" forKey:@"BlinkLaunchState"];
  [d synchronize];
  BlinkBootLog("LAUNCH_STATE: clean_exit");
}

static void BlinkClearRestoreGuard() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if ([d boolForKey:@"BlinkRestoreGuard"]) {
    [d setBool:NO forKey:@"BlinkRestoreGuard"];
    [d synchronize];
  }
}

@implementation ShellAppSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  BlinkBootLog("D: scene willConnectToSession (window setup)");
  // Attach the primary browser window to the reconnecting scene.
  if (content::Shell::windows().empty()) {
    return;
  }
  UIWindow* window = content::Shell::windows()[0]->window().Get();
  if (!window) {
    return;
  }

  // The rootViewController must be added after a windowScene is set
  // so stash it in a temp variable and then reattach it. If we don't
  // do this the safe area gets screwed up on orientation changes.
  UIViewController* controller = window.rootViewController;
  window.rootViewController = nil;
  window.windowScene = (UIWindowScene*)scene;
  // Respect the scene bounds for iPad multitasking.
  if ([scene isKindOfClass:[UIWindowScene class]]) {
    window.frame = ((UIWindowScene*)scene).coordinateSpace.bounds;
  }
  window.rootViewController = controller;
  [window makeKeyAndVisible];
  BlinkBootLog("E: makeKeyAndVisible done (window on screen)");
  // Re-arm our crash handler AFTER Chromium installed its own during startup,
  // so the post-startup crash (in the render/compositing path) hits our logger.
  BlinkArmCrashHandler();
  BlinkBootLog("E2: crash handler re-armed post-startup");
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    ::crash_reporter::ProcessIntermediateDumps();
  }
  // This is a scene-based app, so the UIApplication-level active/background
  // callbacks are not delivered — start the proactive OOM watchdog here, where
  // the process is foreground (os_proc_available_memory() only reports then).
  BlinkStartMemoryWatchdog();
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  // Scene-based clean background — disarm the tab-restore crash guard (see
  // BlinkClearRestoreGuard). A crash in the foreground never reaches here.
  BlinkClearRestoreGuard();
  BlinkPersistOpenTabs();
  BlinkMarkCleanExit();
  // Backgrounded apps are jetsam-reaped first: purge now and stop polling.
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  BlinkStopMemoryWatchdog();
}

- (void)sceneWillResignActive:(UIScene*)scene {
  // The app switcher can terminate a suspended process without delivering
  // sceneDidEnterBackground, so save as soon as the scene loses focus.
  BlinkPersistOpenTabs();
}

// iPad multitasking: keep each window sized to its scene as the user drags the
// Split View divider, resizes a Stage Manager window, or rotates the device.
- (void)windowScene:(UIWindowScene*)windowScene
    didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
        interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
             traitCollection:(UITraitCollection*)previousTraitCollection {
  for (content::Shell* shell : content::Shell::windows()) {
    UIWindow* window = shell->window().Get();
    if (window.windowScene == windowScene) {
      window.frame = windowScene.coordinateSpace.bounds;
    }
  }
}

@end

@implementation ShellAppDelegate

- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:
        (UISceneSession*)connectingSceneSession
                                   options:(UISceneConnectionOptions*)options {
  UISceneConfiguration* configuration =
      [[UISceneConfiguration alloc] initWithName:nil
                                     sessionRole:connectingSceneSession.role];
#if BUILDFLAG(IS_IOS_TVOS)
  configuration.delegateClass = ShellAppSceneDelegateTVOS.class;
#else
  configuration.delegateClass = ShellAppSceneDelegate.class;
#endif
  return configuration;
}

- (BOOL)application:(UIApplication*)application
    willFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  BlinkBootLog("B: willFinishLaunching (pre RunContentProcess)");
  g_main_delegate = std::make_unique<content::ShellMainDelegate>();
  content::ContentMainParams params(g_main_delegate.get());
  params.argc = g_argc;
  params.argv = g_argv;
  g_main_runner = content::ContentMainRunner::Create();
  BlinkBootLog("B2: ContentMainRunner created, calling RunContentProcess");
  content::RunContentProcess(std::move(params), g_main_runner.get());
  BlinkBootLog("C: RunContentProcess returned");
  BlinkArmCrashHandler();
  return YES;
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  return YES;
}

- (void)applicationWillResignActive:(UIApplication*)application {
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  // Clean background => the app did not crash this session; safe to restore
  // tabs next launch.
  BlinkClearRestoreGuard();
  BlinkMarkCleanExit();
  // Backgrounded apps are the first thing iOS jetsam-kills under memory
  // pressure. Purge now so a backgrounded tab is far less likely to be reaped
  // (which would otherwise look like a "crash" when the user returns).
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
}

// Forward UIKit warnings to Chromium's memory-pressure system.
- (void)applicationDidReceiveMemoryWarning:(UIApplication*)application {
  BlinkBootLogMemory("before UIKit memory warning purge");
  BlinkBootLog("MEMWARN: UIKit memory warning -> NotifyMemoryPressure CRITICAL");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  BlinkBootLogMemory("after UIKit memory warning purge");
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
}

- (void)applicationWillTerminate:(UIApplication*)application {
  BlinkMarkCleanExit();
}

- (BOOL)application:(UIApplication*)application
    shouldSaveSecureApplicationState:(NSCoder*)coder {
  // Tab restoration is handled by the browser's lightweight session model.
  return NO;
}

- (BOOL)application:(UIApplication*)application
    shouldRestoreSecureApplicationState:(NSCoder*)coder {
  // UIKit restoration conflicts with the browser's session model.
  return NO;
}

@end

int RunShellApplication(int argc, const char** argv) {
  g_argc = argc;
  g_argv = argv;
  BlinkBootLog("A: RunShellApplication entry (pre UIApplicationMain)");
  @autoreleasepool {
    return UIApplicationMain(argc, const_cast<char**>(argv), nil,
                             NSStringFromClass([ShellAppDelegate class]));
  }
}
