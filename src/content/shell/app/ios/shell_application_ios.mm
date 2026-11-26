// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/shell/app/ios/shell_application_ios.h"

#import <Metal/Metal.h>
#include <algorithm>
#include <atomic>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <os/proc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <exception>

#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/memory_pressure_listener.h"
#include "components/crash/core/app/crashpad.h"
#include "content/public/app/content_main.h"
#include "content/public/app/content_main_runner.h"
#include "content/shell/app/shell_main_delegate.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_memory_policy.h"
#include "ui/gfx/geometry/size.h"

extern "C" void BlinkPersistOpenTabs();
extern "C" void BlinkSetPagesBackgrounded(bool backgrounded);
extern "C" void BlinkApplyFreshStart(void);

extern "C" const char* BlinkBootLogPath();
extern "C" const char* BlinkBootLogPrevPath();

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

extern "C" void BlinkBootLog(const char* stage) {
  char sanitized[4096] = {};
  SanitizeBootLogLine(stage, sanitized, sizeof(sanitized));

  os_unfair_lock_lock(&g_boot_log_lock);
  static int log_fd = -1;
  const char* path = BlinkBootLogPath();
  if (!g_boot_log_initialized) {
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

extern "C" void BlinkBootLogf(const char* format, ...) {
  char message[4096];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  BlinkBootLog(message);
}

// ANGLE кешує першу відповідь MTLCreateSystemDefaultDevice на весь процес
// dlsym щоб не лінкувати Metal, void* щоб ARC не чіпав +1
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

// на A8X Dawn падає в EncodeRenderPass, тому там Ganesh
// невідомий GPU вважаємо придатним
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
    supported = [device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily3_v1];
  }
  CFRelease(raw);
  return supported;
}

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

static dispatch_source_t g_mem_watchdog_timer = nullptr;
static bool g_mem_watchdog_suspended = false;
static time_t g_last_critical_purge = 0;
static bool g_mem_watchdog_low_latched = false;

static const int kCriticalPurgeMinIntervalSecs = 3;
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
    if (!g_mem_watchdog_low_latched) {
      g_mem_watchdog_low_latched = true;
      BLINKER_DIAGF("MEMWATCH: available=%lluMB footprint=%lluMB -> MODERATE",
                    avail >> 20, footprint >> 20);
      base::MemoryPressureListener::NotifyMemoryPressure(
          base::MEMORY_PRESSURE_LEVEL_MODERATE);
    }
  } else {
    g_mem_watchdog_low_latched = false;
  }
}

static void BlinkStartMemoryWatchdog() {
  if (g_mem_watchdog_timer) {
    // applicationDidBecomeActive може прийти двічі без фону, а повторний resume
    // джерела dispatch на iOS 12 фатальний
    if (g_mem_watchdog_suspended) {
      dispatch_resume(g_mem_watchdog_timer);
      g_mem_watchdog_suspended = false;
    }
    return;
  }
  g_mem_watchdog_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                                0, dispatch_get_main_queue());
  // два рази на секунду, щоб сплеск виділень JS чи медіа не проскочив до стелі
  // jetsam
  dispatch_source_set_timer(
      g_mem_watchdog_timer,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
  dispatch_source_set_event_handler(g_mem_watchdog_timer, ^{
    BlinkMemoryWatchdogTick();
  });
  dispatch_resume(g_mem_watchdog_timer);
  g_mem_watchdog_suspended = false;
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

// в звичайний лог, бо в релізі BLINKER_DIAG вимкнено, а ці числа пояснюють
// вбивства у фоні
static void BlinkLogFootprint(const char* label) {
  task_vm_info_data_t vm_info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&vm_info), &count) ==
      KERN_SUCCESS) {
    BLINKER_LOGF("%s footprint=%lluMB", label,
                 (unsigned long long)(vm_info.phys_footprint >> 20));
  } else {
    BLINKER_LOGF("%s footprint=unknown", label);
  }
}

static UIBackgroundTaskIdentifier g_bg_task = UIBackgroundTaskInvalid;
static int64_t g_bg_generation = 0;

// iOS вбиває з 0xDEAD10CC застосунок приспаний із замками на leveldb і SQLite
// закрити їх Chromium не дає, тому виходимо самі
static void BlinkMarkCleanExit();

static void BlinkFinishBackgroundExit(bool storage_flushed) {
  BLINKER_LOG(storage_flushed ? "BGEXIT: extension storage flushed"
                              : "BGEXIT: extension storage flush incomplete");
  BlinkPersistOpenTabs();
  BlinkMarkCleanExit();
  // exit запускає Shutdown() поки робочі потоки живі, і падає
  _exit(0);
}

static void BlinkFlushForBackgroundExit(int64_t generation) {
  if (generation != g_bg_generation) {
    return;
  }
  content::BlinkerFlushStorageForBackground(base::BindOnce(
      [](int64_t generation, bool success) {
        if (generation != g_bg_generation) {
          return;
        }
        if (success) {
          BlinkFinishBackgroundExit(true);
          return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
                         BlinkFlushForBackgroundExit(generation);
                       });
      },
      generation));
}

static void BlinkExitBeforeSuspension() {
  const int64_t generation = g_bg_generation;
  BlinkFlushForBackgroundExit(generation);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (generation == g_bg_generation) {
                     BlinkFinishBackgroundExit(false);
                   }
                 });
}

// у лог іде тільки перша помилка Dawn, після втрати пристрою їх летить тисячі
extern "C" void BlinkGpuContextLost(const char* message, unsigned long length) {
  static std::atomic_flag reported = ATOMIC_FLAG_INIT;
  if (reported.test_and_set()) {
    return;
  }
  BLINKER_LOGF("GPU_ERROR: %.*s", static_cast<int>(std::min<unsigned long>(length, 300)),
               message ? message : "");
}

static void BlinkEndBackgroundTask() {
  if (g_bg_task != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:g_bg_task];
    g_bg_task = UIBackgroundTaskInvalid;
  }
}

extern "C" void BlinkCancelBackgroundExit() {
  ++g_bg_generation;
  BlinkEndBackgroundTask();
}

static void BlinkPurgeWithBackgroundTime() {
  UIApplication* app = [UIApplication sharedApplication];
  const int64_t generation = ++g_bg_generation;
  BlinkEndBackgroundTask();
  void (^finish)(void) = ^{
    BlinkEndBackgroundTask();
  };
  g_bg_task = [app beginBackgroundTaskWithName:@"BlinkerBackgroundPurge"
                             expirationHandler:^{
                               BLINKER_LOG("BGPURGE: expired");
                               if (generation == g_bg_generation) {
                                 BlinkFinishBackgroundExit(false);
                               }
                               finish();
                             }];
  BlinkLogFootprint("BGPURGE: entering background");
  // спершу віддаємо замки, з відкритою транзакцією SQLite чи leveldb
  // система вбиває застосунок з кодом 0xDEAD10CC
  content::BlinkerFlushStorageForBackground(base::BindOnce([](bool success) {
    if (!success) {
      BLINKER_LOG("BGPURGE: extension storage flush failed");
    }
  }));
  BLINKER_LOG("BGPURGE: purging with background time");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (generation == g_bg_generation) {
                     BlinkLogFootprint("BGPURGE: after purge");
                   }
                 });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (generation == g_bg_generation) {
                     BlinkExitBeforeSuspension();
                   }
                 });
}

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

// проба взведена всю сесію, бо збій JIT буває і за хвилину після старту
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

// без extended virtual addressing (безкоштовний підпис SideStore, AltStore,
// ESign)
// iOS не дає 4 ГБ адрес і V8 з pointer compression падає на старті
static BOOL g_blink_no_address_space = NO;
static UIWindow* g_blink_notice_window = nil;

static bool BlinkCanReserveV8Cage() {
#if defined(BLINKER_V8_POINTER_CAGE)
  constexpr size_t kCageSize = size_t{4} << 30;
  void* probe = mmap(nullptr, kCageSize, PROT_NONE, MAP_PRIVATE | MAP_ANON,
                     -1, 0);
  if (probe == MAP_FAILED) {
    return false;
  }
  munmap(probe, kCageSize);
#endif
  return true;
}

@interface BlinkerAddressSpaceNotice : UIViewController
@end

@implementation BlinkerAddressSpaceNotice
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
  UILabel* title = [[UILabel alloc] init];
  title.text = @"Blinker Fluid can't start here";
  title.font = [UIFont boldSystemFontOfSize:22];
  title.textColor = UIColor.whiteColor;
  title.numberOfLines = 0;
  UILabel* body = [[UILabel alloc] init];
  body.text =
      @"This copy was signed without the \"extended virtual addressing\" "
      @"entitlement, which free Apple ID signing (SideStore, AltStore, ESign "
      @"and similar) cannot add. The JavaScript engine needs that address "
      @"space and would crash at launch.\n\nTo run Blinker Fluid, install it "
      @"with TrollStore or on a jailbroken device, sign it with a paid "
      @"developer certificate, or use the LiveContainer build from the "
      @"releases page.";
  body.font = [UIFont systemFontOfSize:16];
  body.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
  body.numberOfLines = 0;
  UIButton* open = [UIButton buttonWithType:UIButtonTypeSystem];
  [open setTitle:@"Open releases page" forState:UIControlStateNormal];
  open.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  [open addTarget:self
                action:@selector(openReleases)
      forControlEvents:UIControlEventTouchUpInside];
  UIStackView* stack =
      [[UIStackView alloc] initWithArrangedSubviews:@[ title, body, open ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 18;
  stack.alignment = UIStackViewAlignmentLeading;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:stack];
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                        constant:24],
    [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                         constant:-24],
    [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
  ]];
}

- (void)openReleases {
  NSURL* url = [NSURL
      URLWithString:@"https://github.com/Nodesclock/Blinker-Fluid/releases"];
  [UIApplication.sharedApplication openURL:url
                                   options:@{}
                         completionHandler:nil];
}
@end

static void BlinkShowAddressSpaceNotice(UIScene* scene) {
  UIWindow* window = nil;
  if (@available(iOS 13.0, *)) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    }
  }
  if (!window) {
    window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  }
  window.rootViewController = [[BlinkerAddressSpaceNotice alloc] init];
  [window makeKeyAndVisible];
  g_blink_notice_window = window;
}

@implementation ShellAppSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  if (g_blink_no_address_space) {
    BlinkShowAddressSpaceNotice(scene);
    return;
  }
  BLINKER_DIAG("D: scene willConnectToSession (window setup)");
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
  if ([scene isKindOfClass:[UIWindowScene class]]) {
    window.frame = ((UIWindowScene*)scene).coordinateSpace.bounds;
  }
  window.rootViewController = controller;
  [window makeKeyAndVisible];
  BLINKER_DIAG("E: makeKeyAndVisible done (window on screen)");
  if (BlinkArmCrashHandler) {
    BlinkArmCrashHandler();
  }
  BLINKER_DIAG("E2: crash handler re-armed post-startup");
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkCancelBackgroundExit();
  BlinkSetPagesBackgrounded(false);
  [[NSUserDefaults standardUserDefaults] setObject:@"running"
                                            forKey:@"BlinkLaunchState"];
  [[NSUserDefaults standardUserDefaults] synchronize];
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    ::crash_reporter::ProcessIntermediateDumps();
  }
  // застосунок на сценах не отримує колбеків UIApplication, тому сторож пам'яті
  // стартує тут
  BlinkStartMemoryWatchdog();
  BLINKER_DIAG(BlinkIOSMetalDeviceAvailable()
                   ? "GPUMETAL_FG: device available at foreground"
                   : "GPUMETAL_FG: device UNAVAILABLE at foreground");
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkClearRestoreGuard();
  BlinkClearJITTierProbe();
  BlinkPersistOpenTabs();
  BlinkMarkCleanExit();
  BlinkSetPagesBackgrounded(true);
  BlinkPurgeWithBackgroundTime();
  BlinkStopMemoryWatchdog();
}

- (void)sceneWillResignActive:(UIScene*)scene {
  if (g_blink_no_address_space) {
    return;
  }
  // App switcher може вбити приспаний процес без sceneDidEnterBackground,
  // тому зберігаємо щойно сцена втратила фокус
  BlinkPersistOpenTabs();
  BlinkLogFootprint("BGPURGE: resign active");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_MODERATE);
}

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
  BlinkInstallExceptionHandlers();
  BlinkApplyFreshStart();
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* deferredHomepage = nil;
  if (![defaults boolForKey:@"BlinkPrivateBrowsing"]) {
    if (![[defaults arrayForKey:@"BlinkPendingCrashTabs"] count] &&
        ([[defaults stringForKey:@"BlinkLaunchState"]
             isEqualToString:@"running"] ||
         [defaults boolForKey:@"BlinkRestoreGuard"])) {
      NSArray* tabs = [defaults arrayForKey:@"BlinkOpenTabs"];
      if (tabs.count) {
        [defaults setObject:tabs forKey:@"BlinkPendingCrashTabs"];
      }
    }
    if ([[defaults arrayForKey:@"BlinkPendingCrashTabs"] count]) {
      [defaults removeObjectForKey:@"BlinkOpenTabs"];
      deferredHomepage = [defaults stringForKey:@"BlinkCrashHomepage"]
                             ?: [defaults stringForKey:@"BlinkHomepage"];
      if (deferredHomepage) {
        [defaults setObject:deferredHomepage forKey:@"BlinkCrashHomepage"];
      }
      [defaults removeObjectForKey:@"BlinkHomepage"];
      [defaults synchronize];
    }
  }
  if (!BlinkCanReserveV8Cage()) {
    g_blink_no_address_space = YES;
    BLINKER_LOG("ADDRESS_SPACE: no room for the V8 cage, Chromium not started");
    return YES;
  }
  g_main_delegate = std::make_unique<content::ShellMainDelegate>();
  content::ContentMainParams params(g_main_delegate.get());
  params.argc = g_argc;
  params.argv = g_argv;
  g_main_runner = content::ContentMainRunner::Create();
  BLINKER_DIAG("B2: ContentMainRunner created, calling RunContentProcess");
  content::RunContentProcess(std::move(params), g_main_runner.get());
  if (deferredHomepage) {
    [defaults setObject:deferredHomepage forKey:@"BlinkHomepage"];
    [defaults removeObjectForKey:@"BlinkCrashHomepage"];
    [defaults synchronize];
  }
  BLINKER_DIAG("C: RunContentProcess returned");
  if (BlinkArmCrashHandler) {
    BlinkArmCrashHandler();
  }
  return YES;
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  if (g_blink_no_address_space) {
    if (!@available(iOS 13.0, *)) {
      BlinkShowAddressSpaceNotice(nil);
    }
    return YES;
  }
  if (!@available(iOS 13.0, *)) {
    // на iOS 12 сцен ще нема, вікно Chromium чіпляємо через application
    // delegate
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
  if (g_blink_no_address_space) {
    return;
  }
  if (!@available(iOS 13.0, *)) {
    BlinkPersistOpenTabs();
  }
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkClearRestoreGuard();
  BlinkClearJITTierProbe();
  if (!@available(iOS 13.0, *)) {
    BlinkPersistOpenTabs();
    BlinkStopMemoryWatchdog();
  }
  BlinkMarkCleanExit();
  // для chrome.idle на телефоні відхід користувача це вихід у фон
  // від цього залежить автоблокування менеджерів паролів
  content::BlinkerSetBrowserBackgrounded(true);
  BlinkSetPagesBackgrounded(true);
  BlinkPurgeWithBackgroundTime();
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication*)application {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkBootLogMemory("before UIKit memory warning purge");
  BLINKER_LOG("MEMWARN: UIKit memory warning -> NotifyMemoryPressure CRITICAL");
  base::MemoryPressureListener::NotifyMemoryPressure(
      base::MEMORY_PRESSURE_LEVEL_CRITICAL);
  BlinkBootLogMemory("after UIKit memory warning purge");
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkCancelBackgroundExit();
  BlinkSetPagesBackgrounded(false);
  [[NSUserDefaults standardUserDefaults] setObject:@"running"
                                            forKey:@"BlinkLaunchState"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
  if (g_blink_no_address_space) {
    return;
  }
  content::BlinkerSetBrowserBackgrounded(false);
  if (!@available(iOS 13.0, *)) {
    BlinkStartMemoryWatchdog();
    BLINKER_DIAG(BlinkIOSMetalDeviceAvailable()
                     ? "GPUMETAL_FG: iOS12 device available"
                     : "GPUMETAL_FG: iOS12 device UNAVAILABLE");
  }
}

- (void)applicationWillTerminate:(UIApplication*)application {
  if (g_blink_no_address_space) {
    return;
  }
  BlinkClearRestoreGuard();
  BlinkPersistOpenTabs();
  BlinkMarkCleanExit();
}

- (BOOL)application:(UIApplication*)application
    shouldSaveSecureApplicationState:(NSCoder*)coder {
  return NO;
}

- (BOOL)application:(UIApplication*)application
    shouldRestoreSecureApplicationState:(NSCoder*)coder {
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
