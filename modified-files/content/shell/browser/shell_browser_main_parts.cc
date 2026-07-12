// Copyright 2013 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_browser_main_parts.h"

#include <cctype>
#include <iterator>
#include <string>
#include <utility>

#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted_memory.h"
#include "base/run_loop.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/current_thread.h"
#include "base/threading/thread.h"
#include "base/threading/thread_restrictions.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
extern "C" void BlinkBootLog(const char* stage);
#endif
#include "cc/base/switches.h"
#include "components/performance_manager/embedder/graph_features.h"
#include "components/performance_manager/embedder/performance_manager_lifetime.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/first_party_sets_handler.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/common/content_switches.h"
#include "content/public/common/result_codes.h"
#include "content/public/common/url_constants.h"
#include "content/shell/android/shell_descriptors.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_devtools_manager_delegate.h"
#include "content/shell/browser/shell_platform_delegate.h"
#include "content/shell/common/shell_switches.h"
#include "device/bluetooth/bluetooth_adapter_factory.h"
#include "net/base/filename_util.h"
#include "net/base/net_module.h"
#include "net/grit/net_resources.h"
#include "ui/base/buildflags.h"
#include "ui/base/resource/resource_bundle.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_ANDROID)
#include "components/crash/content/browser/child_exit_observer_android.h"
#include "components/crash/content/browser/child_process_crash_observer_android.h"
#include "net/android/network_change_notifier_factory_android.h"
#include "net/base/network_change_notifier.h"
#endif

#if BUILDFLAG(IS_LINUX) && defined(USE_AURA)
#include "ui/base/ime/init/input_method_initializer.h"
#endif

#if BUILDFLAG(IS_CHROMEOS)
#include "chromeos/ash/components/dbus/dbus_thread_manager.h"
#include "device/bluetooth/dbus/bluez_dbus_manager.h"
#include "device/bluetooth/floss/floss_dbus_manager.h"
#include "device/bluetooth/floss/floss_features.h"
#endif

#if BUILDFLAG(IS_LINUX)
#include "device/bluetooth/dbus/dbus_bluez_manager_wrapper_linux.h"
#include "ui/linux/linux_ui.h"          // nogncheck
#include "ui/linux/linux_ui_factory.h"  // nogncheck
#endif

#if BUILDFLAG(IS_FUCHSIA)
#include "content/shell/browser/fuchsia_view_presenter.h"
#endif

namespace content {


namespace {

GURL GetStartupURL() {
  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(switches::kBrowserTest))
    return GURL();

#if BUILDFLAG(IS_ANDROID)
  // Delay renderer creation on Android until surface is ready.
  return GURL();
#else
  const base::CommandLine::StringVector& args = command_line->GetArgs();
  if (args.empty()) {
#if BUILDFLAG(IS_IOS)
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    // A custom homepage set in Settings overrides the start page entirely.
    if (CFPropertyListRef hp = CFPreferencesCopyAppValue(
            CFSTR("BlinkHomepage"), kCFPreferencesCurrentApplication)) {
      std::string homepage;
      if (CFGetTypeID(hp) == CFStringGetTypeID()) {
        char buf[1024] = {0};
        if (CFStringGetCString((CFStringRef)hp, buf, sizeof(buf),
                               kCFStringEncodingUTF8)) {
          homepage = buf;
        }
      }
      CFRelease(hp);
      if (!homepage.empty()) {
        return GURL(homepage);
      }
    }
    // Otherwise load a blank page; the native start page (a UIKit view) is
    // shown on top of it by the UI layer.
    return GURL("about:blank");
#else
    return GURL("https://www.google.com/");
#endif
  }

#if BUILDFLAG(IS_WIN)
  GURL url(base::WideToUTF16(args[0]));
#else
  GURL url(args[0]);
#endif
  if (url.is_valid() && url.has_scheme())
    return url;

  return net::FilePathToFileURL(
      base::MakeAbsoluteFilePath(base::FilePath(args[0])));
#endif
}

#if BUILDFLAG(IS_IOS)
constexpr int kMaxRestoreURLLength = 300;

std::string CFStringToUTF8(CFStringRef value) {
  if (!value) {
    return std::string();
  }
  char buf[4096] = {0};
  if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
    return std::string();
  }
  return std::string(buf);
}

std::string CopyPreferenceString(CFStringRef key) {
  std::string value;
  if (CFPropertyListRef stored = CFPreferencesCopyAppValue(
          key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(stored) == CFStringGetTypeID()) {
      value = CFStringToUTF8(static_cast<CFStringRef>(stored));
    }
    CFRelease(stored);
  }
  return value;
}

int CopyPreferenceInt(CFStringRef key) {
  int value = 0;
  if (CFPropertyListRef stored = CFPreferencesCopyAppValue(
          key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(stored) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(stored), kCFNumberIntType,
                       &value);
    }
    CFRelease(stored);
  }
  return value;
}

void SetPreferenceInt(CFStringRef key, int value) {
  CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType,
                                      &value);
  if (number) {
    CFPreferencesSetAppValue(key, number, kCFPreferencesCurrentApplication);
    CFRelease(number);
  }
}

bool HostIsOrEndsWith(const std::string& host, const char* suffix) {
  return host == suffix || base::EndsWith(host, std::string(".") + suffix);
}

bool URLContainsTrackingParam(const std::string& spec) {
  std::string lower = spec;
  for (char& c : lower) {
    c = static_cast<char>(tolower(c));
  }
  return lower.find("gclid") != std::string::npos ||
         lower.find("gbraid") != std::string::npos ||
         lower.find("gad_source") != std::string::npos ||
         lower.find("campaign_id") != std::string::npos ||
         lower.find("utm_") != std::string::npos;
}

bool IsHeavyRestoreURL(const GURL& url) {
  const std::string host(url.host());
  if (host == "gemini.google.com" && base::StartsWith(url.path(), "/app")) {
    return true;
  }
  if (host == "mail.google.com" || host == "accounts.google.com") {
    return true;
  }
  if (HostIsOrEndsWith(host, "reddit.com")) {
    return true;
  }
  if ((host == "youtube.com" || host == "m.youtube.com" ||
       HostIsOrEndsWith(host, "youtube.com")) &&
      base::StartsWith(url.path(), "/watch")) {
    return true;
  }
  return false;
}

bool IsSafeRestoreURL(const GURL& url) {
  if (url.IsAboutBlank()) {
    return true;
  }
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const std::string spec = url.spec();
  if (spec.length() > kMaxRestoreURLLength) {
    BlinkBootLog("SESSION_RESTORE: candidate URL too long");
    return false;
  }
  if (URLContainsTrackingParam(spec)) {
    BlinkBootLog("SESSION_RESTORE: candidate contains tracking params skipped");
    return false;
  }
  if (IsHeavyRestoreURL(url)) {
    BlinkBootLog("SESSION_RESTORE: candidate heavy site skipped");
    return false;
  }
  return true;
}

void MarkLaunchRunning() {
  CFPreferencesSetAppValue(CFSTR("BlinkLaunchState"), CFSTR("running"),
                           kCFPreferencesCurrentApplication);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  BlinkBootLog("LAUNCH_STATE: running");
}

void ClearCrashLoopRestoreURL() {
  CFPreferencesSetAppValue(CFSTR("BlinkOpenTabs"), nullptr,
                           kCFPreferencesCurrentApplication);
  BlinkBootLog("SESSION_RESTORE: cleared crash-loop URL");
}

void LogLastHeartbeatForUncleanLaunch() {
  BlinkBootLog("CRASH_DIAG: previous launch unclean");
  BlinkBootLog("CRASH_DIAG: probable jetsam/SIGKILL/no crash handler stack");

  std::string footprint =
      CopyPreferenceString(CFSTR("BlinkLastHeartbeatFootprint"));
  if (footprint.empty()) {
    footprint = "unknown";
  }
  std::string line = "CRASH_DIAG: last heartbeat footprint=" + footprint;
  BlinkBootLog(line.c_str());

  // Dump the last heartbeats recorded by the heavy-page monitor
  // (StoreRecentHeartbeat in shell.cc) to show the run-up to a kill.
  if (CFPropertyListRef stored = CFPreferencesCopyAppValue(
          CFSTR("BlinkRecentHeartbeats"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(stored) == CFArrayGetTypeID()) {
      CFArrayRef arr = static_cast<CFArrayRef>(stored);
      CFIndex n = CFArrayGetCount(arr);
      for (CFIndex i = 0; i < n && i < 5; ++i) {
        CFStringRef s =
            static_cast<CFStringRef>(CFArrayGetValueAtIndex(arr, i));
        std::string hb = (s && CFGetTypeID(s) == CFStringGetTypeID())
                             ? CFStringToUTF8(s)
                             : std::string("unknown");
        std::string l = "CRASH_DIAG: last heartbeat[" + std::to_string(i) +
                        "]=" + hb;
        BlinkBootLog(l.c_str());
      }
    }
    CFRelease(stored);
  }
}

// Returns the URLs of the tabs open last session (written by
// BlinkSaveOpenTabs), but only if the last process exited cleanly and the
// saved URL is safe to load automatically.
std::vector<GURL> GetRestoreTabURLs() {
  std::vector<GURL> result;
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);

  const bool previous_unclean =
      CopyPreferenceString(CFSTR("BlinkLaunchState")) == "running";
  int unclean_count = previous_unclean
                            ? CopyPreferenceInt(CFSTR("BlinkUncleanLaunchCount")) + 1
                            : 0;
  SetPreferenceInt(CFSTR("BlinkUncleanLaunchCount"), unclean_count);
  if (previous_unclean) {
    BlinkBootLog("SESSION_RESTORE: previous launch unclean");
    LogLastHeartbeatForUncleanLaunch();
  }

  MarkLaunchRunning();

  Boolean guard_valid = false;
  Boolean guard = CFPreferencesGetAppBooleanValue(
      CFSTR("BlinkRestoreGuard"), kCFPreferencesCurrentApplication,
      &guard_valid);
  if ((guard_valid && guard) || previous_unclean) {
    CFPreferencesSetAppValue(CFSTR("BlinkRestoreGuard"), kCFBooleanFalse,
                             kCFPreferencesCurrentApplication);
    BlinkBootLog("SESSION_RESTORE: skipped unsafe restore");
    BlinkBootLog("SESSION_RESTORE: start page loaded instead");
    if (unclean_count >= 2) {
      BlinkBootLog("SAFE_MODE: enabled after repeated unclean launches");
    }
    ClearCrashLoopRestoreURL();
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    return result;
  }

  bool has_real_url = false;
  if (CFPropertyListRef saved = CFPreferencesCopyAppValue(
          CFSTR("BlinkOpenTabs"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(saved) == CFArrayGetTypeID()) {
      CFArrayRef arr = static_cast<CFArrayRef>(saved);
      const CFIndex kMaxRestore = 12;  // bound memory on a constrained device
      CFIndex n = CFArrayGetCount(arr);
      for (CFIndex i = 0; i < n && static_cast<CFIndex>(result.size()) <
                                       kMaxRestore;
           ++i) {
        CFStringRef s =
            static_cast<CFStringRef>(CFArrayGetValueAtIndex(arr, i));
        if (!s || CFGetTypeID(s) != CFStringGetTypeID()) {
          continue;
        }
        GURL u(CFStringToUTF8(s));
        if (!IsSafeRestoreURL(u)) {
          continue;
        }
        if (u.IsAboutBlank()) {
          result.push_back(GURL("about:blank"));
        } else {
          has_real_url = true;
          result.push_back(u);
          BlinkBootLog("SESSION_RESTORE: restored safe URL");
        }
      }
    }
    CFRelease(saved);
  }

  if (!has_real_url) {
    return std::vector<GURL>();
  }

  CFPreferencesSetAppValue(CFSTR("BlinkRestoreGuard"), kCFBooleanTrue,
                           kCFPreferencesCurrentApplication);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  return result;
}
#endif  // BUILDFLAG(IS_IOS)

scoped_refptr<base::RefCountedMemory> PlatformResourceProvider(int key) {
  if (key == IDR_DIR_HEADER_HTML) {
    return ui::ResourceBundle::GetSharedInstance().LoadDataResourceBytes(
        IDR_DIR_HEADER_HTML);
  }
  return nullptr;
}

}  // namespace

ShellBrowserMainParts::ShellBrowserMainParts() = default;

ShellBrowserMainParts::~ShellBrowserMainParts() = default;

void ShellBrowserMainParts::PostCreateMainMessageLoop() {
#if BUILDFLAG(IS_CHROMEOS)
  ash::DBusThreadManager::Initialize();
  if (floss::features::IsFlossEnabled()) {
    floss::FlossDBusManager::InitializeFake();
  } else {
    bluez::BluezDBusManager::InitializeFake();
  }
#elif BUILDFLAG(IS_LINUX)
  bluez::DBusBluezManagerWrapperLinux::Initialize();
#endif
}

int ShellBrowserMainParts::PreEarlyInitialization() {
#if BUILDFLAG(IS_LINUX) && defined(USE_AURA)
  ui::InitializeInputMethodForTesting();
#elif BUILDFLAG(IS_ANDROID)
  net::NetworkChangeNotifier::SetFactory(
      new net::NetworkChangeNotifierFactoryAndroid());
#endif
  return RESULT_CODE_NORMAL_EXIT;
}

void ShellBrowserMainParts::InitializeBrowserContexts() {
  set_browser_context(new ShellBrowserContext(false));
  set_off_the_record_browser_context(new ShellBrowserContext(true));
  // Persistent Origin Trials needs to be instantiated as soon as possible
  // during browser startup, to ensure data is available prior to the first
  // request.
  browser_context_->GetOriginTrialsControllerDelegate();
  off_the_record_browser_context_->GetOriginTrialsControllerDelegate();
}

void ShellBrowserMainParts::InitializeMessageLoopContext() {
#if BUILDFLAG(IS_IOS)
  // Restore the tabs from last session if there are any (crash-guarded). The
  // first window created becomes windows()[0], which the scene attaches and
  // shows; the rest are background tabs reachable from the tab switcher.
  std::vector<GURL> restore = GetRestoreTabURLs();
  if (!restore.empty()) {
    for (const GURL& url : restore) {
      Shell::CreateNewWindow(browser_context_.get(), url, nullptr,
                             gfx::Size());
    }
    return;
  }
#endif
  Shell::CreateNewWindow(browser_context_.get(), GetStartupURL(), nullptr,
                         gfx::Size());
}

void ShellBrowserMainParts::ToolkitInitialized() {
  if (switches::IsRunWebTestsSwitchPresent())
    return;

#if BUILDFLAG(IS_LINUX)
  ui::LinuxUi::SetInstance(ui::GetDefaultLinuxUi());
#endif
}

int ShellBrowserMainParts::PreCreateThreads() {
#if BUILDFLAG(IS_ANDROID)
  const base::CommandLine* command_line =
      base::CommandLine::ForCurrentProcess();
  child_exit_observer_ = std::make_unique<crash_reporter::ChildExitObserver>();
  if (command_line->HasSwitch(switches::kEnableCrashReporter)) {
    child_exit_observer_->RegisterClient(
        std::make_unique<crash_reporter::ChildProcessCrashObserver>());
  }
#endif
  return 0;
}

void ShellBrowserMainParts::PostCreateThreads() {
  performance_manager_lifetime_ =
      std::make_unique<performance_manager::PerformanceManagerLifetime>(
          performance_manager::GraphFeatures::WithMinimal(), base::DoNothing());
}

int ShellBrowserMainParts::PreMainMessageLoopRun() {
#if BUILDFLAG(IS_FUCHSIA)
  fuchsia_view_presenter_ = std::make_unique<FuchsiaViewPresenter>();
#endif

  InitializeBrowserContexts();
  Shell::Initialize(CreateShellPlatformDelegate());
  net::NetModule::SetResourceProvider(PlatformResourceProvider);
  ShellDevToolsManagerDelegate::StartHttpHandler(browser_context_.get());
  InitializeMessageLoopContext();
  return 0;
}

void ShellBrowserMainParts::WillRunMainMessageLoop(
    std::unique_ptr<base::RunLoop>& run_loop) {
  Shell::SetMainMessageLoopQuitClosure(run_loop->QuitClosure());
}

void ShellBrowserMainParts::PostMainMessageLoopRun() {
  DCHECK_EQ(Shell::windows().size(), 0u);
  ShellDevToolsManagerDelegate::StopHttpHandler();
  browser_context_.reset();
  off_the_record_browser_context_.reset();
#if BUILDFLAG(IS_LINUX)
  ui::LinuxUi::SetInstance(nullptr);
#endif
  performance_manager_lifetime_.reset();
#if BUILDFLAG(IS_FUCHSIA)
  fuchsia_view_presenter_.reset();
#endif
}

void ShellBrowserMainParts::PostDestroyThreads() {
#if BUILDFLAG(IS_CHROMEOS)
  device::BluetoothAdapterFactory::Shutdown();
  if (floss::features::IsFlossEnabled()) {
    floss::FlossDBusManager::Shutdown();
  } else {
    bluez::BluezDBusManager::Shutdown();
  }
  ash::DBusThreadManager::Shutdown();
#elif BUILDFLAG(IS_LINUX)
  device::BluetoothAdapterFactory::Shutdown();
  bluez::DBusBluezManagerWrapperLinux::Shutdown();
#endif
}

std::unique_ptr<ShellPlatformDelegate>
ShellBrowserMainParts::CreateShellPlatformDelegate() {
  return std::make_unique<ShellPlatformDelegate>();
}

}  // namespace content
