// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/shell/app/ios/shell_application_ios.h"

#include <mach/mach.h>
#include <stdio.h>
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
#include "ui/gfx/geometry/size.h"

#if BUILDFLAG(IS_IOS_TVOS)
#include "content/shell/app/ios/shell_app_scene_delegate_tvos.h"
#endif

static int g_argc = 0;
static const char** g_argv = nullptr;
static std::unique_ptr<content::ContentMainRunner> g_main_runner;
static std::unique_ptr<content::ShellMainDelegate> g_main_delegate;

// Boot tracer: appends a stage marker to a log file readable off the device,
// so the last line written shows where startup died. Pure C only: this is
// called from a dyld constructor before the ObjC runtime is initialized, so
// it must not touch Foundation. The first call of a process truncates the
// file.
extern "C" void BlinkArmCrashHandler(void);

extern "C" void BlinkBootLog(const char* stage) {
  static bool truncated = false;
  const char* path = "/var/mobile/Documents/blink_boot.log";
  if (!truncated) {
    // Keep the previous run's log as blink_boot_prev.log; when this launch
    // follows a crash, that file holds the crash trail. Pure C rename(),
    // safe pre-main.
    rename(path, "/var/mobile/Documents/blink_boot_prev.log");
  }
  FILE* f = fopen(path, truncated ? "a" : "w");
  truncated = true;
  if (f) {
    fprintf(f, "%ld %s\n", (long)time(nullptr), stage);
    fclose(f);
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

// Disarm the tab-restore crash guard. The guard is armed at launch when last
// session's tabs are restored (see GetRestoreTabURLs) and cleared only on a
// clean background. A foreground crash never reaches here, so the next launch
// skips restore, breaking a crash loop caused by a tab that dies on load.
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
  // Don't CHECK-crash if iOS reconnects an unexpected number of scene
  // sessions on relaunch; just attach the primary window, or bail if there
  // isn't one. A hard CHECK here turns that into a crash loop.
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
  // The window was created with a full-screen [UIScreen mainScreen] frame
  // before any scene existed. On iPad the scene can be a fraction of the
  // screen (Split View, Slide Over, Stage Manager), so size the window to the
  // scene's actual bounds.
  if ([scene isKindOfClass:[UIWindowScene class]]) {
    window.frame = ((UIWindowScene*)scene).coordinateSpace.bounds;
  }
  window.rootViewController = controller;
  [window makeKeyAndVisible];
  BlinkBootLog("E: makeKeyAndVisible done (window on screen)");
  // Re-arm the crash handler after Chromium installed its own during
  // startup, so post-startup crashes hit this logger.
  BlinkArmCrashHandler();
  BlinkBootLog("E2: crash handler re-armed post-startup");
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    ::crash_reporter::ProcessIntermediateDumps();
  }
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  // Scene-based clean background: disarm the tab-restore crash guard. A
  // foreground crash never reaches here.
  BlinkClearRestoreGuard();
  BlinkMarkCleanExit();
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
  // Clean background: the app did not crash this session; safe to restore
  // tabs next launch.
  BlinkClearRestoreGuard();
  BlinkMarkCleanExit();
  // Backgrounded apps are the first thing iOS jetsam-kills under memory
  // pressure. Purge now so a backgrounded tab is far less likely to be reaped
  // (which would otherwise look like a "crash" when the user returns).
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
}

// On heavy sites total RSS climbs until iOS jetsam-kills the app with an
// uncatchable SIGKILL. iOS posts memory warnings before that kill, but stock
// content_shell only listens on Android, so Blink/V8/Skia never purged.
// Forward the warning to the browser's memory system so caches free up and
// the process drops back under the jetsam limit.
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
  // Don't save UI state (see -shouldRestoreSecureApplicationState:).
  return NO;
}

- (BOOL)application:(UIApplication*)application
    shouldRestoreSecureApplicationState:(NSCoder*)coder {
  // Never restore saved UI state: restoring a scene that crashed the app
  // re-creates the same crash on every relaunch. Always start fresh.
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
