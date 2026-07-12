// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/app/shell_main_delegate.h"

#include <cerrno>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <memory>
#include <tuple>
#include <utility>
#include <variant>

#include "base/base_paths.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/cpu.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/logging.h"
#include "base/logging/logging_settings.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/process/current_process.h"
#include "base/strings/string_number_conversions.h"
#include "base/trace_event/trace_log.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif
#include "components/crash/core/common/crash_key.h"
#include "components/memory_system/initializer.h"
#include "components/memory_system/parameters.h"
#include "content/common/content_constants_internal.h"
#include "content/public/app/initialize_mojo_core.h"
#include "content/public/browser/browser_main_runner.h"
#include "content/public/common/content_switches.h"
#include "content/public/common/main_function_params.h"
#include "content/public/common/url_constants.h"
#include "content/shell/app/shell_crash_reporter_client.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/common/shell_content_client.h"
#include "content/shell/common/shell_paths.h"
#include "content/shell/common/shell_switches.h"
#include "content/shell/gpu/shell_content_gpu_client.h"
#include "content/shell/renderer/shell_content_renderer_client.h"
#include "content/shell/utility/shell_content_utility_client.h"
#include "net/cookies/cookie_monster.h"
#include "ui/base/resource/resource_bundle.h"

#if !BUILDFLAG(IS_ANDROID)
#include "content/web_test/browser/web_test_browser_main_runner.h"  // nogncheck
#include "content/web_test/browser/web_test_content_browser_client.h"  // nogncheck
#include "content/web_test/renderer/web_test_content_renderer_client.h"  // nogncheck
#include "ui/native_theme/mock_os_settings_provider.h"  // nogncheck
#endif

#if BUILDFLAG(IS_ANDROID)
#include "base/android/apk_assets.h"
#include "base/posix/global_descriptors.h"
#include "content/public/browser/android/compositor.h"
#include "content/shell/android/shell_descriptors.h"
#endif

#if !BUILDFLAG(IS_FUCHSIA)
#include "components/crash/core/app/crashpad.h"  // nogncheck
#endif

#if BUILDFLAG(IS_APPLE)
#include "content/shell/app/paths_apple.h"
#endif

#if BUILDFLAG(IS_MAC)
#include "content/shell/app/shell_main_delegate_mac.h"
#endif  // BUILDFLAG(IS_MAC)

#if BUILDFLAG(IS_WIN)
#include <initguid.h>
#include <windows.h>

#include "base/logging_win.h"
#include "base/win/scoped_handle.h"
#include "base/win/win_util.h"
#include "content/shell/common/v8_crashpad_support_win.h"
#endif

#if BUILDFLAG(IS_POSIX) && !BUILDFLAG(IS_MAC) && !BUILDFLAG(IS_ANDROID)
#include "v8/include/v8-wasm-trap-handler-posix.h"
#endif

#if BUILDFLAG(IS_IOS)
#include "content/shell/app/ios/shell_application_ios.h"
#endif

#if BUILDFLAG(IS_IOS_TVOS)
#include "base/files/file_path.h"
#include "base/path_service.h"
#include "content/shell/common/shell_switches.h"
#endif

namespace {

enum class LoggingDest {
  kFile,
  kStderr,
#if BUILDFLAG(IS_WIN)
  kHandle,
#endif
};

#if !BUILDFLAG(IS_FUCHSIA)
content::ShellCrashReporterClient& GetShellCrashReporterClient() {
  static base::NoDestructor<content::ShellCrashReporterClient>
      shell_crash_client;
  return *shell_crash_client;
}
#endif

#if BUILDFLAG(IS_IOS)
sigjmp_buf g_jit_probe_jmp;
volatile sig_atomic_t g_jit_probe_signal = 0;

void JitProbeSignalHandler(int signal) {
  g_jit_probe_signal = signal;
  siglongjmp(g_jit_probe_jmp, 1);
}

void AppendBlinkBootLog(const char* message) {
  int fd = open("/var/mobile/Documents/blink_boot.log",
                O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    return;
  }
  const size_t len = strlen(message);
  ssize_t ignored = write(fd, message, len);
  (void)ignored;
  close(fd);
}

bool ProbeIOSBasicExecutableMemory() {
#if defined(__aarch64__) || defined(__arm64__)
  AppendBlinkBootLog("JITPROBE0: starting basic executable-memory probe\n");

  const size_t page_size = static_cast<size_t>(getpagesize());
  int last_mmap_errno = 0;
  auto try_executable_page = [&](const char* label, int mmap_flags) {
    char start_buf[160];
    snprintf(start_buf, sizeof(start_buf), "JITPROBE1: %s mmap RW\n", label);
    AppendBlinkBootLog(start_buf);

    void* code = mmap(nullptr, page_size, PROT_READ | PROT_WRITE, mmap_flags,
                      -1, 0);
    if (code == MAP_FAILED) {
      const int saved_errno = errno;
      last_mmap_errno = saved_errno;
      char buf[224];
      snprintf(buf, sizeof(buf), "JITPROBE_FAIL: %s mmap errno=%d (%s)\n",
               label, saved_errno, strerror(saved_errno));
      AppendBlinkBootLog(buf);
      return false;
    }

    // ARM64: mov w0, #42; ret
    const uint32_t tiny_function[] = {0x52800540, 0xd65f03c0};
    memcpy(code, tiny_function, sizeof(tiny_function));
    __builtin___clear_cache(static_cast<char*>(code),
                            static_cast<char*>(code) + sizeof(tiny_function));

    if (mprotect(code, page_size, PROT_READ | PROT_EXEC) != 0) {
      const int saved_errno = errno;
      char buf[224];
      snprintf(buf, sizeof(buf),
               "JITPROBE_FAIL: %s mprotect RX errno=%d (%s)\n", label,
               saved_errno, strerror(saved_errno));
      AppendBlinkBootLog(buf);
      munmap(code, page_size);
      return false;
    }

    struct sigaction old_bus;
    struct sigaction old_ill;
    struct sigaction old_segv;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = JitProbeSignalHandler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS, &action, &old_bus);
    sigaction(SIGILL, &action, &old_ill);
    sigaction(SIGSEGV, &action, &old_segv);

    bool ok = false;
    g_jit_probe_signal = 0;
    if (sigsetjmp(g_jit_probe_jmp, 1) == 0) {
      using JitFn = int (*)();
      int result = reinterpret_cast<JitFn>(code)();
      ok = (result == 42);
      if (!ok) {
        char buf[160];
        snprintf(buf, sizeof(buf),
                 "JITPROBE_FAIL: %s executable code returned %d, expected 42\n",
                 label, result);
        AppendBlinkBootLog(buf);
      }
    } else {
      char buf[160];
      snprintf(buf, sizeof(buf), "JITPROBE_FAIL: %s execution signal=%d\n",
               label, g_jit_probe_signal);
      AppendBlinkBootLog(buf);
    }

    sigaction(SIGBUS, &old_bus, nullptr);
    sigaction(SIGILL, &old_ill, nullptr);
    sigaction(SIGSEGV, &old_segv, nullptr);
    munmap(code, page_size);

    if (ok) {
      char buf[128];
      snprintf(buf, sizeof(buf),
               "JITPROBE_BASIC_EXEC_OK: %s executable memory works\n", label);
      AppendBlinkBootLog(buf);
    }
    return ok;
  };

  bool ok = false;
#if defined(MAP_JIT)
  ok = try_executable_page("MAP_JIT", MAP_PRIVATE | MAP_ANON | MAP_JIT);
  if (!ok && last_mmap_errno == EINVAL) {
    AppendBlinkBootLog(
        "JITPROBE_INFO: MAP_JIT mmap returned EINVAL; unsupported/invalid in "
        "this environment\n");
  }
  if (!ok) {
    AppendBlinkBootLog("JITPROBE2: trying plain mmap RW -> mprotect RX\n");
    ok = try_executable_page("plain", MAP_PRIVATE | MAP_ANON);
  }
#else
  AppendBlinkBootLog("JITPROBE1: MAP_JIT unavailable at build time\n");
  ok = try_executable_page("plain", MAP_PRIVATE | MAP_ANON);
#endif

  if (ok) {
    AppendBlinkBootLog(
        "JITPROBE_BASIC_EXEC_OK: basic executable memory available\n");
  } else {
    AppendBlinkBootLog(
        "JITPROBE_DECISION_DETAIL: all basic executable-memory tests failed\n");
  }
  return ok;
#else
  AppendBlinkBootLog("JITPROBE_FAIL: non-ARM64 iOS build cannot probe V8 JIT\n");
  return false;
#endif
}
#endif  // BUILDFLAG(IS_IOS)

#if BUILDFLAG(IS_WIN)
// If "Content Shell" doesn't show up in your list of trace providers in
// Sawbuck, add these registry entries to your machine (NOTE the optional
// Wow6432Node key for x64 machines):
// 1. Find:  HKLM\SOFTWARE\[Wow6432Node\]Google\Sawbuck\Providers
// 2. Add a subkey with the name "{6A3E50A4-7E15-4099-8413-EC94D8C2A4B6}"
// 3. Add these values:
//    "default_flags"=dword:00000001
//    "default_level"=dword:00000004
//    @="Content Shell"

// {6A3E50A4-7E15-4099-8413-EC94D8C2A4B6}
const GUID kContentShellProviderName = {
    0x6a3e50a4, 0x7e15, 0x4099,
        { 0x84, 0x13, 0xec, 0x94, 0xd8, 0xc2, 0xa4, 0xb6 } };
#endif

void InitLogging(const base::CommandLine& command_line) {
  LoggingDest dest = LoggingDest::kFile;

  if (command_line.GetSwitchValueASCII(switches::kEnableLogging) == "stderr") {
    dest = LoggingDest::kStderr;
  }

#if BUILDFLAG(IS_WIN)
  // On Windows child process may be given a handle in the --log-file switch.
  base::win::ScopedHandle log_handle;
  if (command_line.GetSwitchValueASCII(switches::kEnableLogging) == "handle") {
    auto handle_str = command_line.GetSwitchValueNative(switches::kLogFile);
    uint32_t handle_value = 0;
    if (base::StringToUint(handle_str, &handle_value)) {
      // This handle is owned by the logging framework and is closed when the
      // process exits.
      HANDLE duplicate = nullptr;
      if (::DuplicateHandle(GetCurrentProcess(),
                            base::win::Uint32ToHandle(handle_value),
                            GetCurrentProcess(), &duplicate, 0, FALSE,
                            DUPLICATE_SAME_ACCESS)) {
        log_handle.Set(duplicate);
        dest = LoggingDest::kHandle;
      }
    }
  }
#endif  // BUILDFLAG(IS_WIN)

  base::FilePath log_filename;
  if (dest == LoggingDest::kFile) {
    log_filename = command_line.GetSwitchValuePath(switches::kLogFile);
    if (log_filename.empty()) {
#if BUILDFLAG(IS_FUCHSIA) || BUILDFLAG(IS_IOS)
      base::PathService::Get(base::DIR_TEMP, &log_filename);
#else
      base::PathService::Get(base::DIR_EXE, &log_filename);
#endif
      log_filename = log_filename.AppendASCII("content_shell.log");
    }
  }

  logging::LoggingSettings settings;
#if BUILDFLAG(IS_WIN)
  if (dest == LoggingDest::kHandle) {
    // TODO(crbug.com/328285906) Use a ScopedHandle in logging settings.
    settings.log_file = log_handle.release();
  } else {
    settings.log_file = nullptr;
  }
#endif  // BUILDFLAG(IS_WIN)

  if (dest == LoggingDest::kFile) {
    settings.log_file_path = log_filename.value();
  }

  if (dest == LoggingDest::kStderr) {
    settings.logging_dest =
        logging::LOG_TO_STDERR | logging::LOG_TO_SYSTEM_DEBUG_LOG;
  } else {
    // Includes both handle or provided filename on Windows.
    settings.logging_dest = logging::LOG_TO_ALL;
  }

  // Append so logs survive a crash+relaunch.
  settings.delete_old = logging::APPEND_TO_OLD_LOG_FILE;
  logging::InitLogging(settings);
  logging::SetLogItems(true /* Process ID */, true /* Thread ID */,
                       true /* Timestamp */, false /* Tick count */);
}

}  // namespace

namespace content {

ShellMainDelegate::ShellMainDelegate(bool is_content_browsertests)
    : is_content_browsertests_(is_content_browsertests) {}

ShellMainDelegate::~ShellMainDelegate() {
}

std::optional<int> ShellMainDelegate::BasicStartupComplete() {
  base::CommandLine& command_line = *base::CommandLine::ForCurrentProcess();
  if (command_line.HasSwitch("run-layout-test")) {
    std::cerr << std::string(79, '*') << "\n"
              << "* The flag --run-layout-test is obsolete. Please use --"
              << switches::kRunWebTests << " instead. *\n"
              << std::string(79, '*') << "\n";
    command_line.AppendSwitch(switches::kRunWebTests);
  }

#if BUILDFLAG(IS_IOS)
  // BrowserEngineKit (the iOS multi-process model) requires iOS 17.4+. Force
  // single-process so the renderer/GPU run in-process and never hit the BEK
  // process-spawn path.
  command_line.AppendSwitch(switches::kSingleProcess);

  // Route Chromium's internal log next to blink_boot.log and raise GPU/GL
  // verbosity for surface-creation diagnostics.
  if (!command_line.HasSwitch(switches::kLogFile)) {
    command_line.AppendSwitchASCII(
        switches::kLogFile, "/var/mobile/Documents/content_shell_full.log");
  }
  command_line.AppendSwitchASCII(
      switches::kVModule,
      "*gl*=1,*angle*=1,*gpu*=1,*command_buffer*=1,*compositor*=1,*viz*=1,"
      "*video*=1,*media*=1,*overlay*=1,*ca_renderer*=1,*decode*=1,"
      "*image_transport*=1,*shared_image*=1");

  // V8 heap caps and the JIT decision. Probe whether this process has basic
  // executable memory before deciding.
  if (!command_line.HasSwitch("js-flags")) {
    // Keep the V8 heap cap small: ArrayBuffers/crypto buffers live outside
    // the V8 heap, so a smaller cap leaves physical headroom for them, for
    // network bodies, images, and renderer caches. Heavy pages have hit
    // fatal PartitionAlloc OOM before UIKit could deliver a memory warning.
    const bool basic_exec_available = ProbeIOSBasicExecutableMemory();
    if (basic_exec_available) {
      AppendBlinkBootLog(
          "JITPROBE_BASIC_EXEC_OK: basic executable memory succeeded\n");
    }
    // Keep V8 jitless: even though basic executable memory works, V8 also
    // needs to reserve a CodeRange, which this constrained process cannot
    // reliably do, so jitless is the stable default.
    command_line.AppendSwitchASCII(
        "js-flags",
        "--jitless --max-old-space-size=384 --max-semi-space-size=16");
    AppendBlinkBootLog("JITPROBE_DECISION: keeping --jitless\n");
  }

  // The GPU watchdog kills the in-process GPU thread during slow init
  // (black web-content area, death ~5s after the window appears). Disable
  // it.
  command_line.AppendSwitch("disable-gpu-watchdog");

  // Bound the compositor's tile memory budget; the default sizes its cache
  // from a large available-GPU-memory estimate and pushes total RSS over the
  // iOS jetsam limit on heavy pages.
  if (!command_line.HasSwitch("force-gpu-mem-available-mb")) {
    command_line.AppendSwitchASCII("force-gpu-mem-available-mb", "256");
  }

  // Optional proxy for Tor / .onion (Settings -> Tor / Proxy, saved as
  // NSUserDefaults "BlinkProxy").
  if (CFPropertyListRef pv = CFPreferencesCopyAppValue(
          CFSTR("BlinkProxy"), kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(pv) == CFStringGetTypeID()) {
      char buf[256] = {0};
      if (CFStringGetCString((CFStringRef)pv, buf, sizeof(buf),
                             kCFStringEncodingUTF8) &&
          buf[0] != '\0') {
        command_line.AppendSwitchASCII("proxy-server", buf);
      }
    }
    CFRelease(pv);
  }

#endif

#if BUILDFLAG(IS_ANDROID)
  Compositor::Initialize();
#endif

#if BUILDFLAG(IS_WIN)
  // Enable trace control and transport through event tracing for Windows.
  logging::LogEventProvider::Initialize(kContentShellProviderName);

  v8_crashpad_support::SetUp();

  base::win::EnableStrictHandleCheckingForCurrentProcess();
#endif

#if BUILDFLAG(IS_MAC)
  // Needs to happen before InitializeResourceBundle().
  EnsureCorrectResolutionSettings();
#endif  // BUILDFLAG(IS_MAC)

  InitLogging(command_line);

#if !BUILDFLAG(IS_ANDROID)
  if (switches::IsRunWebTestsSwitchPresent()) {
    // Instantiating `ui::OsSettingsProvider` will both provide sane default
    // behavior and prevent `ui::OsSettingsProvider::Get()` from instantiating a
    // platform-specific subclass.
    os_settings_provider_ = std::make_unique<ui::OsSettingsProvider>(
        ui::OsSettingsProvider::PriorityLevel::kTesting);

    const bool browser_process =
        command_line.GetSwitchValueASCII(switches::kProcessType).empty();
    if (browser_process) {
      web_test_runner_ = std::make_unique<WebTestBrowserMainRunner>();
      web_test_runner_->Initialize();
    }
  }
#endif

#if BUILDFLAG(IS_IOS_TVOS)
  // On tvOS, local storage is limited and data cannot be written anywhere
  // other than the cache directory, so `base::DIR_CACHE` is used for
  // the user data directory.
  //
  // The exception is when a different user data directory has been specified
  // (for example by content's WrapperTestLauncherDelegate::GetCommandLine()
  // when running browser tests). In this case, we prefer the value has been
  // passed, otherwise multiple tests running at the same time will try to use
  // the same temporary files and fail.
  base::FilePath path;
  if (!command_line.HasSwitch(switches::kContentShellUserDataDir) &&
      base::PathService::Get(base::DIR_CACHE, &path) && !path.empty()) {
    command_line.AppendSwitchASCII(switches::kContentShellUserDataDir,
                                   path.MaybeAsASCII());
  }
#endif

  RegisterShellPathProvider();

  return std::nullopt;
}

bool ShellMainDelegate::ShouldCreateFeatureList(InvokedIn invoked_in) {
  return std::holds_alternative<InvokedInChildProcess>(invoked_in);
}

bool ShellMainDelegate::ShouldInitializeMojo(InvokedIn invoked_in) {
  return ShouldCreateFeatureList(invoked_in);
}

void ShellMainDelegate::PreSandboxStartup() {
// Disable platform crash handling and initialize the crash reporter, if
// requested.
// TODO(crbug.com/40188745): Implement crash reporter integration for Fuchsia.
#if !BUILDFLAG(IS_FUCHSIA)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    std::string process_type =
        base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
            switches::kProcessType);
    crash_reporter::SetCrashReporterClient(&GetShellCrashReporterClient());
    // Reporting for sub-processes will be initialized in ZygoteForked.
    if (process_type != switches::kZygoteProcess) {
      crash_reporter::InitializeCrashpad(process_type.empty(), process_type);
#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
      crash_reporter::SetFirstChanceExceptionHandler(
          v8::TryHandleWebAssemblyTrapPosix);
#endif
    }
  }
#endif  // !BUILDFLAG(IS_FUCHSIA)

  crash_reporter::InitializeCrashKeys();

  InitializeResourceBundle();
}

std::variant<int, MainFunctionParams> ShellMainDelegate::RunProcess(
    const std::string& process_type,
    MainFunctionParams main_function_params) {
  // For non-browser process, return and have the caller run the main loop.
  if (!process_type.empty())
    return std::move(main_function_params);

  base::CurrentProcess::GetInstance().SetProcessType(
      base::CurrentProcessType::PROCESS_BROWSER);

#if !BUILDFLAG(IS_ANDROID)
  if (switches::IsRunWebTestsSwitchPresent()) {
    // Web tests implement their own BrowserMain() replacement.
    web_test_runner_->RunBrowserMain(std::move(main_function_params));
    web_test_runner_.reset();
    // Returning 0 to indicate that we have replaced BrowserMain() and the
    // caller should not call BrowserMain() itself. Web tests do not ever
    // return an error.
    return 0;
  }
#endif

#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
  // On Android and iOS, we defer to the system message loop when the stack
  // unwinds. So here we only create (and leak) a BrowserMainRunner. The
  // shutdown of BrowserMainRunner doesn't happen in Chrome Android/iOS and
  // doesn't work properly on Android/iOS at all.
  std::unique_ptr<BrowserMainRunner> main_runner = BrowserMainRunner::Create();
  // In browser tests, the |main_function_params| contains a |ui_task| which
  // will execute the testing. The task will be executed synchronously inside
  // Initialize() so we don't depend on the BrowserMainRunner being Run().
  int initialize_exit_code =
      main_runner->Initialize(std::move(main_function_params));
  DCHECK_LT(initialize_exit_code, 0)
      << "BrowserMainRunner::Initialize failed in ShellMainDelegate";
  std::ignore = main_runner.release();
  // Return 0 as BrowserMain() should not be called after this, bounce up to
  // the system message loop for ContentShell, and we're already done thanks
  // to the |ui_task| for browser tests.
  return 0;
#else
  // On non-Android, we can return the |main_function_params| back and have the
  // caller run BrowserMain() normally.
  return std::move(main_function_params);
#endif
}

#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
void ShellMainDelegate::ZygoteForked() {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    std::string process_type =
        base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
            switches::kProcessType);
    crash_reporter::InitializeCrashpad(false, process_type);
    crash_reporter::SetFirstChanceExceptionHandler(
        v8::TryHandleWebAssemblyTrapPosix);
  }
}
#endif  // BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)

void ShellMainDelegate::InitializeResourceBundle() {
#if BUILDFLAG(IS_ANDROID)
  // On Android, the renderer runs with a different UID and can never access
  // the file system. Use the file descriptor passed in at launch time.
  auto* global_descriptors = base::GlobalDescriptors::GetInstance();
  int pak_fd = global_descriptors->MaybeGet(kShellPakDescriptor);
  base::MemoryMappedFile::Region pak_region;
  if (pak_fd >= 0) {
    pak_region = global_descriptors->GetRegion(kShellPakDescriptor);
  } else {
    pak_fd =
        base::android::OpenApkAsset("assets/content_shell.pak", &pak_region);
    // Loaded from disk for browsertests.
    if (pak_fd < 0) {
      base::FilePath pak_file;
      bool r = base::PathService::Get(base::DIR_ANDROID_APP_DATA, &pak_file);
      DCHECK(r);
      pak_file = pak_file.Append(FILE_PATH_LITERAL("paks"));
      pak_file = pak_file.Append(FILE_PATH_LITERAL("content_shell.pak"));
      int flags = base::File::FLAG_OPEN | base::File::FLAG_READ;
      pak_fd = base::File(pak_file, flags).TakePlatformFile();
      pak_region = base::MemoryMappedFile::Region::kWholeFile;
    }
    global_descriptors->Set(kShellPakDescriptor, pak_fd, pak_region);
  }
  DCHECK_GE(pak_fd, 0);
  // TODO(crbug.com/40346051): A better way to prevent fdsan error from a double
  // close is to refactor GlobalDescriptors.{Get,MaybeGet} to return
  // "const base::File&" rather than fd itself.
  base::File android_pak_file(pak_fd);
  ui::ResourceBundle::InitSharedInstanceWithPakFileRegion(
      android_pak_file.Duplicate(), pak_region);
  ui::ResourceBundle::GetSharedInstance().AddDataPackFromFileRegion(
      std::move(android_pak_file), pak_region, ui::k100Percent);
#elif BUILDFLAG(IS_APPLE)
  ui::ResourceBundle::InitSharedInstanceWithPakPath(GetResourcesPakFilePath());
#else
  base::FilePath pak_file;
  bool r = base::PathService::Get(base::DIR_ASSETS, &pak_file);
  DCHECK(r);
  pak_file = pak_file.Append(FILE_PATH_LITERAL("content_shell.pak"));
  ui::ResourceBundle::InitSharedInstanceWithPakPath(pak_file);
#endif
}

std::optional<int> ShellMainDelegate::PreBrowserMain() {
  std::optional<int> exit_code = content::ContentMainDelegate::PreBrowserMain();
  if (exit_code.has_value())
    return exit_code;

#if BUILDFLAG(IS_MAC)
  RegisterShellCrApp();
#endif
  return std::nullopt;
}

std::optional<int> ShellMainDelegate::PostEarlyInitialization(
    InvokedIn invoked_in) {
  if (!ShouldCreateFeatureList(invoked_in)) {
    // Apply field trial testing configuration since content did not.
    browser_client_->CreateFeatureListAndFieldTrials();
  }
  if (!ShouldInitializeMojo(invoked_in)) {
    InitializeMojoCore();
  }

  const std::string process_type =
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kProcessType);

  // ShellMainDelegate has GWP-ASan as well as Profiling Client disabled.
  // Consequently, we provide no parameters for these two. The memory_system
  // includes the PoissonAllocationSampler dynamically only if the Profiling
  // Client is enabled. However, we are not sure if this is the only user of
  // PoissonAllocationSampler in the ContentShell. Therefore, enforce inclusion
  // at the moment.
  //
  // TODO(crbug.com/40062835): Clarify which users of
  // PoissonAllocationSampler we have in the ContentShell. Do we really need to
  // enforce it?
  memory_system::Initializer()
      .SetDispatcherParameters(memory_system::DispatcherParameters::
                                   PoissonAllocationSamplerInclusion::kEnforce,
                               memory_system::DispatcherParameters::
                                   AllocationTraceRecorderInclusion::kIgnore,
                               process_type)
      .Initialize(memory_system_);

  return std::nullopt;
}

ContentClient* ShellMainDelegate::CreateContentClient() {
  content_client_ = std::make_unique<ShellContentClient>();
  return content_client_.get();
}

ContentBrowserClient* ShellMainDelegate::CreateContentBrowserClient() {
#if !BUILDFLAG(IS_ANDROID)
  if (switches::IsRunWebTestsSwitchPresent()) {
    browser_client_ = std::make_unique<WebTestContentBrowserClient>();
    return browser_client_.get();
  }
#endif
  browser_client_ = std::make_unique<ShellContentBrowserClient>();
  return browser_client_.get();
}

ContentGpuClient* ShellMainDelegate::CreateContentGpuClient() {
  gpu_client_ = std::make_unique<ShellContentGpuClient>();
  return gpu_client_.get();
}

ContentRendererClient* ShellMainDelegate::CreateContentRendererClient() {
#if !BUILDFLAG(IS_ANDROID)
  if (switches::IsRunWebTestsSwitchPresent()) {
    renderer_client_ = std::make_unique<WebTestContentRendererClient>();
    return renderer_client_.get();
  }
#endif
  renderer_client_ = std::make_unique<ShellContentRendererClient>();
  return renderer_client_.get();
}

ContentUtilityClient* ShellMainDelegate::CreateContentUtilityClient() {
  utility_client_ =
      std::make_unique<ShellContentUtilityClient>(is_content_browsertests_);
  return utility_client_.get();
}

}  // namespace content
