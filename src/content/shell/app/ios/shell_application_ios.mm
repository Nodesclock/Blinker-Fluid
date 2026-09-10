// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/shell/app/ios/shell_application_ios.h"

#import <Metal/Metal.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <os/proc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <exception>

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
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_memory_policy.h"
#include "ui/gfx/geometry/size.h"

extern "C" void BlinkPersistOpenTabs();

// Diagnostic file locations, resolved once in shell_main.cc (they move into the
// app container when the install is sandboxed out of /var/mobile/Documents).
extern "C" const char* BlinkBootLogPath();
extern "C" const char* BlinkBootLogPrevPath();

// The production paths are supplied by shell_main.cc, which is not linked into
// unit-test executables. Keep test-only consumers linkable without duplicating
// the container-resolution machinery; a production strong definition always
// overrides these weak fallbacks.
extern "C" __attribute__((weak)) const char* BlinkDocumentsDir() {
  return "/tmp";
}

extern "C" __attribute__((weak)) const char* BlinkBootLogPath() {
  return "/tmp/blink_boot.log";
}

extern "C" __attribute__((weak)) const char* BlinkBootLogPrevPath() {
  return "/tmp/blink_boot_prev.log";
}

extern "C" __attribute__((weak)) const char* BlinkCrashSignalPath() {
  return "/tmp/.blink_last_crash_signal";
}

extern "C" __attribute__((weak)) const char* BlinkFullLogPath() {
  return "/tmp/content_shell_full.log";
}

#if BUILDFLAG(IS_IOS_TVOS)
#include "content/shell/app/ios/shell_app_scene_delegate_tvos.h"
#endif

static int g_argc = 0;
static const char** g_argv = nullptr;
static std::unique_ptr<content::ContentMainRunner> g_main_runner;
static std::unique_ptr<content::ShellMainDelegate> g_main_delegate;

// Early startup logger. This can run before Foundation is initialized and
// therefore uses only C runtime APIs.
// shell_main.cc supplies the production implementation. Test executables link
// this app delegate without shell_main, so retain a weak no-op fallback.
extern "C" __attribute__((weak)) void BlinkArmCrashHandler(void) {}

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
    if (!in_url && (!strncmp(input + read, "https://", 8) ||
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

extern "C" const char* BlinkIOSContainerDocumentsDirectory() {
  static char documents_path[PATH_MAX];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* path = paths.firstObject;
    if (path.length) {
      strlcpy(documents_path, path.fileSystemRepresentation,
              sizeof(documents_path));
    }
  });
  return documents_path;
}

// Persistent descriptor avoids repeated file setup on the UI thread.
extern "C" void BlinkBootLog(const char* stage) {
  char sanitized[4096] = {};
  SanitizeBootLogLine(stage, sanitized, sizeof(sanitized));

  os_unfair_lock_lock(&g_boot_log_lock);
  static int log_fd = -1;
  const char* path = BlinkBootLogPath();
  if (!g_boot_log_initialized) {
    // Preserve the previous run before truncating the current log.
    rename(path, BlinkBootLogPrevPath());
    log_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    g_boot_log_initialized = true;
  }
  if (log_fd >= 0) {
    char line[4160];
    int n = snprintf(line, sizeof(line), "%ld %s\n", (long)time(nullptr),
                     sanitized);
    if (n > 0) {
      if (n >= static_cast<int>(sizeof(line))) {
        n = static_cast<int>(sizeof(line)) - 1;
      }
      ssize_t written = write(log_fd, line, static_cast<size_t>(n));
      (void)written;
    }
  }
  os_unfair_lock_unlock(&g_boot_log_lock);
}

// printf-style convenience over BlinkBootLog. Formats into a stack buffer and
// forwards. Callers reach this through BLINKER_DIAGF / BLINKER_LOGF, so in a
// release build the format string and arguments are never referenced.
extern "C" void BlinkBootLogf(const char* format, ...) {
  char message[4096];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  BlinkBootLog(message);
}

// Reports whether this process can obtain a Metal device. ANGLE's only iOS
// backend is Metal and it caches the answer to its very first
// MTLCreateSystemDefaultDevice() call for the life of the process, so a query
// that lands while the GPU is unreachable (a sandbox denial, or a device that
// is not yet usable this early in launch) costs us EGL, and therefore all web
// rendering, permanently. Resolved through dlsym so nothing here adds a link
// dependency on Metal, and typed void* to keep the +1 return away from ARC.
extern "C" bool BlinkIOSMetalDeviceAvailable() {
  using CreateDeviceFn = void* (*)(void);
  static CreateDeviceFn create = reinterpret_cast<CreateDeviceFn>(
      dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice"));
  if (!create) {
    return false;
  }
  void* device = create();
  if (!device) {
    return false;
  }
  CFRelease(device);
  return true;
}

// Reports whether the GPU is at least Apple3 (A9), the floor ANGLE documents
// for its Metal backend. Dawn/Graphite raises an unhandled Metal exception
// while encoding a render pass on older parts -- an A8X iPad Air 2 aborts in
// dawn::native::metal::CommandBuffer::EncodeRenderPass as soon as a page
// rasterizes (GitHub issue #10) -- so those devices need the Ganesh path.
// Unknown (no device) counts as supported: refusing Graphite over a probe that
// merely failed would penalize every device whose GPU we could not read.
extern "C" bool BlinkIOSGpuSupportsGraphite() {
  using CreateDeviceFn = void* (*)(void);
  static CreateDeviceFn create = reinterpret_cast<CreateDeviceFn>(
      dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice"));
  if (!create) {
    return true;
  }
  void* raw = create();
  if (!raw) {
    return true;
  }
  id<MTLDevice> device = (__bridge id<MTLDevice>)raw;
  bool supported = false;
  if (@available(iOS 13.0, *)) {
    supported = [device supportsFamily:MTLGPUFamilyApple3];
  } else {
    // The equivalent feature-set query is available on iOS 9.
    supported = [device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily3_v1];
  }
  CFRelease(raw);
  return supported;
}

// Records exception details before SIGABRT discards the exception object.
static void BlinkLogExceptionFrames(NSArray<NSString*>* frames) {
  NSUInteger count = MIN((NSUInteger)24, frames.count);
  for (NSUInteger i = 0; i < count; ++i) {
    BLINKER_LOGF("CRASH_EXCEPTION_FRAME: %s",
                 frames[i].UTF8String ? frames[i].UTF8String : "(unprintable)");
  }
}

static void BlinkUncaughtExceptionHandler(NSException* exception) {
  BLINKER_LOGF(
      "CRASH_EXCEPTION: name=%s reason=%s",
      exception.name.UTF8String ? exception.name.UTF8String : "(nil)",
      exception.reason.UTF8String ? exception.reason.UTF8String : "(nil)");
  BlinkLogExceptionFrames(exception.callStackSymbols);
}

static void BlinkTerminateHandler() {
  BLINKER_LOG("CRASH_TERMINATE: std::terminate called");
  BlinkLogExceptionFrames([NSThread callStackSymbols]);
  abort();
}

static void BlinkInstallExceptionHandlers() {
  static bool installed = false;
  if (installed) {
    return;
  }
  installed = true;
  NSSetUncaughtExceptionHandler(&BlinkUncaughtExceptionHandler);
  std::set_terminate(&BlinkTerminateHandler);
  BLINKER_LOG("CRASH_DIAG: ObjC/C++ exception handlers installed");
}

// Poll memory headroom because jetsam can terminate a foreground process
// without delivering a UIKit memory warning first.
static dispatch_source_t g_mem_watchdog_timer = nullptr;
static bool g_mem_watchdog_suspended = false;
static time_t g_last_critical_purge = 0;
static bool g_mem_watchdog_low_latched = false;

// Rate-limit critical pressure to avoid cache and GC thrashing.
static const int kCriticalPurgeMinIntervalSecs = 3;
// Remaining-memory and footprint thresholds.
static void BlinkBootLogMemory(const char* label);

static void BlinkMemoryWatchdogTick() {
  size_t available = 0;
  if (@available(iOS 13.0, *)) {
    available = os_proc_available_memory();
  }
  uint64_t avail = static_cast<uint64_t>(available);
  task_vm_info_data_t vm_info = {};
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  const bool have_footprint = task_info(mach_task_self(), TASK_VM_INFO,
                                        reinterpret_cast<task_info_t>(&vm_info),
                                        &vm_count) == KERN_SUCCESS;
  const uint64_t footprint =
      have_footprint ? static_cast<uint64_t>(vm_info.phys_footprint) : 0;
  const bool critical =
      (available != 0 &&
       avail < content::blinker_memory::CriticalAvailable()) ||
      (have_footprint &&
       footprint >= content::blinker_memory::CriticalFootprint());
  const bool moderate =
      (available != 0 &&
       avail < content::blinker_memory::ModerateAvailable()) ||
      (have_footprint &&
       footprint >= content::blinker_memory::ModerateFootprint());

  if (critical) {
    time_t now = time(nullptr);
    if (now - g_last_critical_purge >= kCriticalPurgeMinIntervalSecs) {
      g_last_critical_purge = now;
      BLINKER_DIAGF("MEMWATCH: available=%lluMB footprint=%lluMB -> CRITICAL",
                    avail >> 20, footprint >> 20);
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
      BLINKER_DIAGF("MEMWATCH: available=%lluMB footprint=%lluMB -> MODERATE",
                    avail >> 20, footprint >> 20);
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
    // applicationDidBecomeActive may be delivered more than once without an
    // intervening background transition (for example after Control Center or
    // a system alert). Resuming an already-active dispatch source is a fatal
    // libdispatch client error on iOS 12.
    if (g_mem_watchdog_suspended) {
      dispatch_resume(g_mem_watchdog_timer);
      g_mem_watchdog_suspended = false;
    }
    return;
  }
  g_mem_watchdog_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                                0, dispatch_get_main_queue());
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
  g_mem_watchdog_suspended = false;
  // Log the budget the policy actually derived. This runs in the foreground, so
  // os_proc_available_memory() answers here even when it did not during launch.
  BLINKER_DIAGF("MEMWATCH: watchdog started ceiling=%lluMB moderate=%lluMB "
                "critical=%lluMB block=%lluMB",
                content::blinker_memory::MemoryCeiling() >> 20,
                content::blinker_memory::ModerateFootprint() >> 20,
                content::blinker_memory::CriticalFootprint() >> 20,
                content::blinker_memory::BlockNewContentsFootprint() >> 20);
}

static void BlinkStopMemoryWatchdog() {
  if (g_mem_watchdog_timer && !g_mem_watchdog_suspended) {
    dispatch_suspend(g_mem_watchdog_timer);
    g_mem_watchdog_suspended = true;
  }
}

static void BlinkBootLogMemory(const char* label) {
  mach_task_basic_info_data_t basic_info;
  mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t basic_kr =
      task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&basic_info), &basic_count);

  task_vm_info_data_t vm_info;
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  kern_return_t vm_kr =
      task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&vm_info), &vm_count);

  BLINKER_DIAGF("MEMSTAT: %s rss=%llu footprint=%llu vsize=%llu basic_kr=%d "
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
}

// Mark clean background transitions so restoration can distinguish crashes.
static void BlinkMarkCleanExit() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setObject:@"clean_exit" forKey:@"BlinkLaunchState"];
  [d synchronize];
  BLINKER_LOG("LAUNCH_STATE: clean_exit");
}

static void BlinkClearRestoreGuard() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if ([d boolForKey:@"BlinkRestoreGuard"]) {
    [d setBool:NO forKey:@"BlinkRestoreGuard"];
    [d synchronize];
  }
}

static void BlinkClearJITTierProbe() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if ([d objectForKey:@"BlinkJITTierProbe"] &&
      [d integerForKey:@"BlinkJITTierProbe"] >= 0) {
    [d setInteger:-1 forKey:@"BlinkJITTierProbe"];
    [d synchronize];
    BLINKER_DIAG("JIT_TIER_PROBE: disarmed; tier survived this launch");
  }
}

extern "C" void BlinkPrepareForRestart() {
  BlinkClearRestoreGuard();
  BlinkClearJITTierProbe();
  BlinkMarkCleanExit();
}

// The probe used to be disarmed on a 20-second timer, on the assumption that
// generated code either works immediately or not at all. It does not: a tier-4
// SIGSEGV inside worker-thread JIT arrived ~90 seconds into a session, long
// after the timer had cleared the probe, so the ladder never demoted and the
// same crash repeated on every launch. Keep the probe armed for the whole
// session and clear it only on a clean background, so any codegen fault demotes
// once. Unrelated failures still cannot ratchet the engine down: the crash
// signal has to be SIGILL/SIGBUS/SIGSEGV/SIGTRAP, which excludes an uncaught
// ObjC exception (SIGABRT) and a jetsam SIGKILL (no handler, no signal file).

@implementation ShellAppSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  BLINKER_DIAG("D: scene willConnectToSession (window setup)");
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
  BLINKER_DIAG("E: makeKeyAndVisible done (window on screen)");
  // Re-arm our crash handler AFTER Chromium installed its own during startup,
  // so the post-startup crash (in the render/compositing path) hits our logger.
  if (BlinkArmCrashHandler) {
    BlinkArmCrashHandler();
  }
  BLINKER_DIAG("E2: crash handler re-armed post-startup");
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
  // Second Metal reading, now that the scene is foreground. Paired with the
  // GPUMETAL line the GPU thread writes during launch this separates the two
  // causes of a dead EGL display: still unavailable here means the process is
  // denied the GPU outright, available here means we merely asked too early.
  BLINKER_DIAG(BlinkIOSMetalDeviceAvailable()
                   ? "GPUMETAL_FG: device available at foreground"
                   : "GPUMETAL_FG: device UNAVAILABLE at foreground");
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  // Scene-based clean background — disarm the tab-restore crash guard (see
  // BlinkClearRestoreGuard). A crash in the foreground never reaches here.
  BlinkClearRestoreGuard();
  BlinkClearJITTierProbe();
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
        interfaceOrientation:
            (UIInterfaceOrientation)previousInterfaceOrientation
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
  BLINKER_DIAG("B: willFinishLaunching (pre RunContentProcess)");
  // Installed before any Chromium/UIKit work so an exception thrown during
  // startup is still named rather than surfacing as a bare SIGABRT.
  BlinkInstallExceptionHandlers();
  g_main_delegate = std::make_unique<content::ShellMainDelegate>();
  content::ContentMainParams params(g_main_delegate.get());
  params.argc = g_argc;
  params.argv = g_argv;
  g_main_runner = content::ContentMainRunner::Create();
  BLINKER_DIAG("B2: ContentMainRunner created, calling RunContentProcess");
  content::RunContentProcess(std::move(params), g_main_runner.get());
  BLINKER_DIAG("C: RunContentProcess returned");
  if (BlinkArmCrashHandler) {
    BlinkArmCrashHandler();
  }
  return YES;
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  if (!@available(iOS 13.0, *)) {
    // iOS 12 predates scenes, so attach Chromium's already-created window via
    // the classic application delegate.
    if (!content::Shell::windows().empty()) {
      UIWindow* window = content::Shell::windows()[0]->window().Get();
      if (window) {
        window.frame = UIScreen.mainScreen.bounds;
        [window makeKeyAndVisible];
        BLINKER_DIAG("E_IOS12: makeKeyAndVisible done");
      }
    }
    if (BlinkArmCrashHandler) {
      BlinkArmCrashHandler();
    }
  }
  return YES;
}

- (void)applicationWillResignActive:(UIApplication*)application {
  if (!@available(iOS 13.0, *)) {
    BlinkPersistOpenTabs();
  }
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  // Clean background => the app did not crash this session; safe to restore
  // tabs next launch.
  BlinkClearRestoreGuard();
  BlinkClearJITTierProbe();
  if (!@available(iOS 13.0, *)) {
    BlinkPersistOpenTabs();
    BlinkStopMemoryWatchdog();
  }
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
  BLINKER_LOG("MEMWARN: UIKit memory warning -> NotifyMemoryPressure CRITICAL");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  BlinkBootLogMemory("after UIKit memory warning purge");
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
  if (!@available(iOS 13.0, *)) {
    BlinkStartMemoryWatchdog();
    BLINKER_DIAG(BlinkIOSMetalDeviceAvailable()
                     ? "GPUMETAL_FG: iOS12 device available"
                     : "GPUMETAL_FG: iOS12 device UNAVAILABLE");
  }
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
  BLINKER_DIAG("A: RunShellApplication entry (pre UIApplicationMain)");
  @autoreleasepool {
    return UIApplicationMain(argc, const_cast<char**>(argv), nil,
                             NSStringFromClass([ShellAppDelegate class]));
  }
}
