// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/app/shell_main_delegate.h"

#include <algorithm>
#include <cerrno>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <tuple>
#include <utility>
#include <variant>

#include "base/base_paths.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/cpu.h"
#include "base/dcheck_is_on.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/logging.h"
#include "base/logging/logging_settings.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/process/current_process.h"
#include "base/strings/string_number_conversions.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "base/mac/code_signature_spi.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_memory_policy.h"
#include "content/shell/common/blinker_proxy_config.h"
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
#include "gpu/config/gpu_switches.h"
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
extern "C" __attribute__((weak)) bool BlinkIOSGpuSupportsGraphite();
extern "C" const char* BlinkBootLogPath();
extern "C" const char* BlinkCrashSignalPath();
extern "C" const char* BlinkFullLogPath();
extern "C" const char* BlinkDocumentsDir();
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
  kSystem,
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

// на iOS 17+ з монітором підпису mprotect може дати успіх, а сторінка без
// execute
// тоді SIGKILL з CODESIGNING Invalid Page, обробник його не ловить
bool IOSPageIsExecutable(const void* page) {
  vm_address_t address = reinterpret_cast<vm_address_t>(page);
  vm_size_t size = 0;
  vm_region_basic_info_data_64_t info = {};
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object_name = MACH_PORT_NULL;
  const kern_return_t kr = vm_region_64(
      mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
      reinterpret_cast<vm_region_info_t>(&info), &count, &object_name);
  if (object_name != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), object_name);
  }
  return kr == KERN_SUCCESS &&
         address <= reinterpret_cast<vm_address_t>(page) &&
         (info.protection & VM_PROT_EXECUTE) != 0;
}


bool ProbeIOSCodeRangePatternExecutableMemory() {
#if defined(__aarch64__) || defined(__arm64__)
  const size_t page_size = static_cast<size_t>(getpagesize());
  const size_t reservation_size = 2 * 1024 * 1024;

  void* reservation = mmap(nullptr, reservation_size, PROT_NONE,
                           MAP_PRIVATE | MAP_ANON, -1, 0);
  if (reservation == MAP_FAILED) {
    BLINKER_DIAGF("JITPROBE_RANGE_FAIL: PROT_NONE reservation errno=%d (%s)\n", errno, strerror(errno));
    return false;
  }

  void* code = static_cast<char*>(reservation) + page_size;
  if (mprotect(code, page_size, PROT_READ | PROT_WRITE) != 0) {
    BLINKER_DIAGF("JITPROBE_RANGE_FAIL: commit RW errno=%d (%s)\n", errno, strerror(errno));
    munmap(reservation, reservation_size);
    return false;
  }

  const uint32_t tiny_function[] = {0x52800540, 0xd65f03c0};
  memcpy(code, tiny_function, sizeof(tiny_function));
  __builtin___clear_cache(static_cast<char*>(code),
                          static_cast<char*>(code) + sizeof(tiny_function));

  if (mprotect(code, page_size, PROT_READ | PROT_EXEC) != 0) {
    BLINKER_DIAGF("JITPROBE_RANGE_FAIL: RW->RX errno=%d (%s)\n", errno, strerror(errno));
    munmap(reservation, reservation_size);
    return false;
  }
  if (!IOSPageIsExecutable(code)) {
    BLINKER_DIAG("JITPROBE_RANGE_FAIL: RX page is not executable\n");
    munmap(reservation, reservation_size);
    return false;
  }

  struct sigaction sa = {}, old_bus = {}, old_ill = {}, old_segv = {};
  sa.sa_handler = JitProbeSignalHandler;
  sa.sa_flags = 0;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old_bus);
  sigaction(SIGILL, &sa, &old_ill);
  sigaction(SIGSEGV, &sa, &old_segv);

  bool ok = false;
  g_jit_probe_signal = 0;
  if (sigsetjmp(g_jit_probe_jmp, 1) == 0) {
    using JitFn = int (*)();
    ok = reinterpret_cast<JitFn>(code)() == 42;
  }

  sigaction(SIGBUS, &old_bus, nullptr);
  sigaction(SIGILL, &old_ill, nullptr);
  sigaction(SIGSEGV, &old_segv, nullptr);
  munmap(reservation, reservation_size);

  if (ok) {
    BLINKER_DIAG(
        "JITPROBE_RANGE_OK: CodeRange-pattern executable memory works\n");
  } else {
    BLINKER_DIAGF("JITPROBE_RANGE_FAIL: execute from reservation raised signal %d\n", g_jit_probe_signal);
  }
  return ok;
#else
  return false;
#endif
}

bool ProbeIOSRwxExecutableMemory() {
#if defined(__aarch64__) || defined(__arm64__)
  const size_t page_size = static_cast<size_t>(getpagesize());
  void* code = mmap(nullptr, page_size, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON, -1, 0);
  if (code == MAP_FAILED) {
    BLINKER_DIAG("JITPROBE_RWX_FAIL: mmap failed\n");
    return false;
  }

  if (mprotect(code, page_size, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
    BLINKER_DIAGF("JITPROBE_RWX_FAIL: mprotect RWX errno=%d (%s)\n", errno, strerror(errno));
    munmap(code, page_size);
    return false;
  }

  const uint32_t tiny_function[] = {0x52800540, 0xd65f03c0};
  memcpy(code, tiny_function, sizeof(tiny_function));
  __builtin___clear_cache(static_cast<char*>(code),
                          static_cast<char*>(code) + sizeof(tiny_function));

  struct sigaction sa = {}, old_bus = {}, old_ill = {}, old_segv = {};
  sa.sa_handler = JitProbeSignalHandler;
  sa.sa_flags = 0;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old_bus);
  sigaction(SIGILL, &sa, &old_ill);
  sigaction(SIGSEGV, &sa, &old_segv);

  bool ok = false;
  g_jit_probe_signal = 0;
  if (sigsetjmp(g_jit_probe_jmp, 1) == 0) {
    using JitFn = int (*)();
    ok = reinterpret_cast<JitFn>(code)() == 42;
  }

  sigaction(SIGBUS, &old_bus, nullptr);
  sigaction(SIGILL, &old_ill, nullptr);
  sigaction(SIGSEGV, &old_segv, nullptr);
  munmap(code, page_size);

  if (ok) {
    BLINKER_DIAG(
        "JITPROBE_RWX_OK: write+execute pages work; V8's RWX model is fine "
        "here\n");
  } else {
    BLINKER_DIAGF("JITPROBE_RWX_FAIL: RWX page raised signal %d on execute\n", g_jit_probe_signal);
  }
  return ok;
#else
  return false;
#endif
}

bool ProbeIOSDualMappingExecutableMemory() {
#if defined(__aarch64__) || defined(__arm64__)
  BLINKER_DIAG("JITPROBE_DUAL0: entry\n");
  const size_t page_size = static_cast<size_t>(getpagesize());

  void* rx = mmap(nullptr, page_size, PROT_READ | PROT_EXEC,
                  MAP_PRIVATE | MAP_ANON, -1, 0);
  if (rx == MAP_FAILED) {
    BLINKER_DIAGF("JITPROBE_DUAL_FAIL: rx mmap errno=%d (%s)\n", errno, strerror(errno));
    return false;
  }

  vm_address_t mirror = 0;
  vm_prot_t cur_prot = VM_PROT_READ | VM_PROT_WRITE;
  vm_prot_t max_prot = VM_PROT_READ | VM_PROT_WRITE;
  kern_return_t kr = vm_remap(
      mach_task_self(), &mirror, page_size, 0, VM_FLAGS_ANYWHERE,
      mach_task_self(), reinterpret_cast<vm_address_t>(rx),
      /*copy=*/FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) {
    BLINKER_DIAGF("JITPROBE_DUAL_FAIL: vm_remap kr=%d (%s)\n", kr, mach_error_string(kr));
    munmap(rx, page_size);
    return false;
  }

  if (mprotect(reinterpret_cast<void*>(mirror), page_size,
               PROT_READ | PROT_WRITE) != 0) {
    BLINKER_DIAGF("JITPROBE_DUAL_FAIL: mirror mprotect RW errno=%d (%s)\n", errno, strerror(errno));
    vm_deallocate(mach_task_self(), mirror, page_size);
    munmap(rx, page_size);
    return false;
  }

  {
    BLINKER_DIAGF("JITPROBE_DUAL1: remap ok rx=%p mirror=%llx cur_prot=%d\n", rx, static_cast<unsigned long long>(mirror), cur_prot);
  }

  auto* mirror_code = reinterpret_cast<uint32_t*>(mirror);
  auto rx_fn = reinterpret_cast<int (*)()>(rx);

  struct sigaction sa = {}, old_bus = {}, old_ill = {}, old_segv = {};
  sa.sa_handler = JitProbeSignalHandler;
  sa.sa_flags = 0;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old_bus);
  sigaction(SIGILL, &sa, &old_ill);
  sigaction(SIGSEGV, &sa, &old_segv);

  bool ok_first = false, ok_second = false;

  mirror_code[0] = 0x52800540;
  mirror_code[1] = 0xd65f03c0;
  __builtin___clear_cache(static_cast<char*>(rx),
                          static_cast<char*>(rx) + 8);
  BLINKER_DIAG(
      "JITPROBE_DUAL2: wrote via mirror, about to execute RX view\n");
  g_jit_probe_signal = 0;
  if (sigsetjmp(g_jit_probe_jmp, 1) == 0) {
    ok_first = (rx_fn() == 42);
  }
  BLINKER_DIAG("JITPROBE_DUAL3: first execute returned\n");

  // перезапис через дзеркало, поки RX лишається виконуваним
  // на цьому ламався варіант з перемиканням прав
  mirror_code[0] = 0x52800560;
  mirror_code[1] = 0xd65f03c0;
  __builtin___clear_cache(static_cast<char*>(rx),
                          static_cast<char*>(rx) + 8);
  if (sigsetjmp(g_jit_probe_jmp, 1) == 0) {
    ok_second = (rx_fn() == 43);
  }

  sigaction(SIGBUS, &old_bus, nullptr);
  sigaction(SIGILL, &old_ill, nullptr);
  sigaction(SIGSEGV, &old_segv, nullptr);
  vm_deallocate(mach_task_self(), mirror, page_size);
  munmap(rx, page_size);

  if (ok_first && ok_second) {
    BLINKER_DIAG(
        "JITPROBE_DUAL_OK: RW mirror and RX execution verified\n");
    return true;
  }
  BLINKER_DIAGF("JITPROBE_DUAL_FAIL: first=%d second=%d signal=%d\n", ok_first, ok_second, g_jit_probe_signal);
  return false;
#else
  return false;
#endif
}

bool ProbeIOSBasicExecutableMemory() {
#if defined(__aarch64__) || defined(__arm64__)
  BLINKER_DIAG("JITPROBE0: starting basic executable-memory probe\n");

  const size_t page_size = static_cast<size_t>(getpagesize());
  auto try_executable_page = [&](const char* label, int mmap_flags) {
    BLINKER_DIAGF("JITPROBE1: %s mmap RW\n", label);

    void* code = mmap(nullptr, page_size, PROT_READ | PROT_WRITE, mmap_flags,
                      -1, 0);
    if (code == MAP_FAILED) {
      const int saved_errno = errno;
      BLINKER_DIAGF("JITPROBE_FAIL: %s mmap errno=%d (%s)\n", label, saved_errno, strerror(saved_errno));
      return false;
    }

    const uint32_t tiny_function[] = {0x52800540, 0xd65f03c0};
    memcpy(code, tiny_function, sizeof(tiny_function));
    __builtin___clear_cache(static_cast<char*>(code),
                            static_cast<char*>(code) + sizeof(tiny_function));

    if (mprotect(code, page_size, PROT_READ | PROT_EXEC) != 0) {
      const int saved_errno = errno;
      BLINKER_DIAGF("JITPROBE_FAIL: %s mprotect RX errno=%d (%s)\n", label, saved_errno, strerror(saved_errno));
      munmap(code, page_size);
      return false;
    }
    if (!IOSPageIsExecutable(code)) {
      BLINKER_DIAGF("JITPROBE_FAIL: %s RX page is not executable\n", label);
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
        BLINKER_DIAGF("JITPROBE_FAIL: %s executable code returned %d, expected 42\n", label, result);
      }
    } else {
      BLINKER_DIAGF("JITPROBE_FAIL: %s execution signal=%d\n", label, g_jit_probe_signal);
    }

    sigaction(SIGBUS, &old_bus, nullptr);
    sigaction(SIGILL, &old_ill, nullptr);
    sigaction(SIGSEGV, &old_segv, nullptr);
    munmap(code, page_size);

    if (ok) {
      BLINKER_DIAGF("JITPROBE_BASIC_EXEC_OK: %s executable memory works\n", label);
    }
    return ok;
  };

  // MAP_JIT не перевіряємо, на TrollStore з Dopamine 3 такий mmap може вбити
  // процес у ядрі
  BLINKER_DIAG(
      "JITPROBE_INFO: skipping fatal-prone MAP_JIT probe; testing plain W^X\n");
  bool ok = try_executable_page("plain", MAP_PRIVATE | MAP_ANON);

  if (ok) {
    BLINKER_DIAG(
        "JITPROBE_BASIC_EXEC_OK: basic executable memory available\n");
  } else {
    BLINKER_DIAG(
        "JITPROBE_DECISION_DETAIL: all basic executable-memory tests failed\n");
  }
  return ok;
#else
  BLINKER_DIAG("JITPROBE_FAIL: non-ARM64 iOS build cannot probe V8 JIT\n");
  return false;
#endif
}

bool IsIOSProcessCSDebugged() {
  constexpr uint32_t kCSDebugged = 0x10000000;
  uint32_t status = 0;
  if (csops(getpid(), CS_OPS_STATUS, &status, sizeof(status)) != 0) {
    return false;
  }
  return (status & kCSDebugged) != 0;
}

void TryEnableJITViaJailbreak() {
  void* handle =
      dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    handle = dlopen("libjailbreak.dylib", RTLD_NOW | RTLD_LOCAL);
  }
  if (!handle) {
    BLINKER_DIAG(
        "JIT_AUTH: no jailbreak library found; cannot self-enable JIT\n");
    return;
  }
  using SetProcessDebuggedFn = int (*)(uint64_t /*pid*/, bool /*fully*/);
  auto set_process_debugged = reinterpret_cast<SetProcessDebuggedFn>(
      dlsym(handle, "jbclient_platform_set_process_debugged"));
  if (!set_process_debugged) {
    BLINKER_DIAG(
        "JIT_AUTH: jailbreak library has no set_process_debugged\n");
    return;
  }
  const int rv = set_process_debugged(static_cast<uint64_t>(getpid()), true);
  BLINKER_DIAGF("JIT_AUTH: jailbreak self-JIT request returned %d\n", rv);
}

bool IsIOSJITBundle() {
  CFStringRef bundle_id = CFBundleGetIdentifier(CFBundleGetMainBundle());
  if (!bundle_id) {
    return false;
  }
  // інструменти безкоштовного підпису дописують компонент команди до bundle id,
  // тому `jit` шукаємо як окремий компонент
  CFArrayRef components =
      CFStringCreateArrayBySeparatingStrings(kCFAllocatorDefault, bundle_id,
                                             CFSTR("."));
  bool is_jit = false;
  if (components) {
    const CFIndex count = CFArrayGetCount(components);
    for (CFIndex i = 0; i < count; ++i) {
      CFStringRef component = static_cast<CFStringRef>(
          const_cast<void*>(CFArrayGetValueAtIndex(components, i)));
      if (component && CFStringCompare(component, CFSTR("jit"), 0) ==
                           kCFCompareEqualTo) {
        is_jit = true;
        break;
      }
    }
    CFRelease(components);
  }
  return is_jit;
}

bool IsIOSRuntimeJITAuthorized() {
  if (!IsIOSJITBundle()) {
    BLINKER_DIAG(
        "JIT_AUTH: stable bundle selected; using jitless engine\n");
    return false;
  }
  const bool debugged_at_launch = IsIOSProcessCSDebugged();
  BLINKER_DIAG(debugged_at_launch
                         ? "JIT_AUTH: CS_DEBUGGED already set at launch\n"
                         : "JIT_AUTH: CS_DEBUGGED not set at launch\n");

  // Dopamine знімає і ті обмеження яких нема в CS_DEBUGGED, тому просимо навіть
  // коли біт стоїть
  TryEnableJITViaJailbreak();

  if (IsIOSProcessCSDebugged()) {
    BLINKER_DIAG(
        "JIT_AUTH: process is debugged; JIT authorized without Open with "
        "JIT\n");
    return true;
  }
  BLINKER_DIAG(
      "JIT_AUTH: CS_DEBUGGED absent; using safe jitless fallback\n");
  return false;
}

enum IOSJitTier {
  kTierJitless = 0,
  kTierInterpreter = 1,
  kTierBaseline = 2,
  kTierMidTier = 3,
  kTierFull = 4,
  kTierFullWasm = 5,
  kTierMax = kTierFullWasm,
};

constexpr int kDefaultIOSJitTier = kTierFull;

const char* IOSJitTierName(int tier) {
  switch (tier) {
    case kTierJitless:     return "jitless";
    case kTierInterpreter: return "interpreter";
    case kTierBaseline:    return "baseline (Sparkplug)";
    case kTierMidTier:     return "mid-tier (Maglev)";
    case kTierFull:        return "full (TurboFan)";
    case kTierFullWasm:    return "full + Wasm JIT";
    default:               return "unknown";
  }
}

const char* IOSJitTierV8Flags(int tier) {
  switch (tier) {
    case kTierJitless:
      // без кодогенерації байткод і є виконуваною формою, компілювати його
      // знову дорого
      // тому тримаємо довше ніж шість GC, але обмежено
      return "--jitless --wasm-jitless --bytecode-old-age=24";
    case kTierInterpreter:
      return "--no-sparkplug --regexp-interpret-all --wasm-jitless "
             "--disable-optimizing-compilers";
    case kTierBaseline:
      return "--sparkplug --regexp-interpret-all --wasm-jitless "
             "--disable-optimizing-compilers";
    case kTierMidTier:
      return "--maglev-as-top-tier --wasm-jitless";
    case kTierFull:
      return "--wasm-jitless";
    case kTierFullWasm:
      return "";
    default:
      return "--jitless --wasm-jitless";
  }
}

int ReadIOSPrefInt(CFStringRef key, int fallback) {
  int value = fallback;
  if (CFPropertyListRef pv =
          CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(pv) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(pv), kCFNumberIntType, &value);
    }
    CFRelease(pv);
  }
  return value;
}

void WriteIOSPrefInt(CFStringRef key, int value) {
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
  CFPreferencesSetAppValue(key, number, kCFPreferencesCurrentApplication);
  CFRelease(number);
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

int TakeLastCrashSignal() {
  const char* kPath = BlinkCrashSignalPath();
  int fd = open(kPath, O_RDONLY);
  if (fd < 0) {
    return 0;
  }
  char buf[16] = {0};
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  unlink(kPath);
  if (n <= 0) {
    return 0;
  }
  return atoi(buf);
}

std::string IOSBundleVersion() {
  CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(),
                                                         kCFBundleVersionKey);
  char buf[64] = {0};
  if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
    CFStringGetCString(static_cast<CFStringRef>(value), buf, sizeof(buf),
                       kCFStringEncodingUTF8);
  }
  return buf;
}

std::string ReadIOSPrefString(CFStringRef key) {
  std::string out;
  if (CFPropertyListRef pv =
          CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)) {
    char buf[64] = {0};
    if (CFGetTypeID(pv) == CFStringGetTypeID() &&
        CFStringGetCString(static_cast<CFStringRef>(pv), buf, sizeof(buf),
                           kCFStringEncodingUTF8)) {
      out = buf;
    }
    CFRelease(pv);
  }
  return out;
}

void WriteIOSPrefString(CFStringRef key, const std::string& value) {
  CFStringRef str = CFStringCreateWithCString(kCFAllocatorDefault,
                                              value.c_str(),
                                              kCFStringEncodingUTF8);
  CFPreferencesSetAppValue(key, str, kCFPreferencesCurrentApplication);
  CFRelease(str);
}

int ResolveIOSJitTier(bool coderange_execution_available) {
  int tier = ReadIOSPrefInt(CFSTR("BlinkJITTier"), kDefaultIOSJitTier);
  tier = std::clamp(tier, static_cast<int>(kTierJitless),
                    static_cast<int>(kTierMax));

  const std::string build = IOSBundleVersion();
  const std::string guard_build =
      ReadIOSPrefString(CFSTR("BlinkJITTierGuardBuild"));
  bool restored_now = false;
  if ((!guard_build.empty() && guard_build != build) ||
      (guard_build.empty() && tier == kTierJitless)) {
    restored_now = true;
    const int restored = std::clamp(
        ReadIOSPrefInt(CFSTR("BlinkJITTierBeforeGuard"), kDefaultIOSJitTier),
        static_cast<int>(kTierInterpreter), static_cast<int>(kTierMax));
    BLINKER_DIAGF("JIT_TIER_RESTORED: tier %d came from the crash guard on "
                  "build '%s'; this is '%s', back to tier %d (%s)\n",
                  tier, guard_build.c_str(), build.c_str(), restored,
                  IOSJitTierName(restored));
    tier = restored;
    WriteIOSPrefInt(CFSTR("BlinkJITTier"), tier);
    CFPreferencesSetAppValue(CFSTR("BlinkJITTierGuardBuild"), nullptr,
                             kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("BlinkJITTierBeforeGuard"), nullptr,
                             kCFPreferencesCurrentApplication);
  }
  const int stored_tier = tier;

  if (!coderange_execution_available && tier > kTierInterpreter) {
    BLINKER_DIAGF("JIT_TIER_CAPPED: tier %d (%s) needs executable code-range pages, "
             "which this OS refuses; running tier %d (%s)\n", tier, IOSJitTierName(tier), static_cast<int>(kTierInterpreter), IOSJitTierName(kTierInterpreter));
    tier = kTierInterpreter;
  }

  const int pending = ReadIOSPrefInt(CFSTR("BlinkJITTierProbe"), -1);
  if (restored_now) {
    TakeLastCrashSignal();
  } else if (pending >= 0) {
    const int sig = TakeLastCrashSignal();
    const bool codegen_fault = sig == SIGILL || sig == SIGBUS ||
                               sig == SIGSEGV || sig == SIGTRAP;
    if (codegen_fault) {
      if (guard_build.empty()) {
        WriteIOSPrefInt(CFSTR("BlinkJITTierBeforeGuard"), stored_tier);
      }
      WriteIOSPrefString(CFSTR("BlinkJITTierGuardBuild"), build);
      const int downgraded = std::max(0, std::min(pending, tier) - 1);
      BLINKER_DIAGF("JIT_TIER_DOWNGRADE: tier %d (%s) died with signal %d; falling "
               "back to tier %d (%s)\n", pending, IOSJitTierName(pending), sig, downgraded, IOSJitTierName(downgraded));
      tier = downgraded;
      WriteIOSPrefInt(CFSTR("BlinkJITTier"), tier);
    } else {
      BLINKER_DIAGF("JIT_TIER_KEPT: last launch ended with signal %d, which is not "
               "a codegen fault; staying on tier %d (%s)\n", sig, tier, IOSJitTierName(tier));
    }
  }

  WriteIOSPrefInt(CFSTR("BlinkJITTierProbe"),
                  tier >= kTierInterpreter ? tier : -1);
  return tier;
}

// V8 фіксує прапорці купи на старті, тому розмір беремо від встановленої RAM
std::string IOSV8HeapFlags() {
  const uint64_t ram_mb =
      content::blinker_memory::DevicePhysicalMemory() / (1024 * 1024);
  int old_space_mb = 256;
  int semi_space_mb = 8;
  if (ram_mb >= 5500) {
    old_space_mb = 512;
    semi_space_mb = 16;
  } else if (ram_mb >= 3500) {
    old_space_mb = 384;
    semi_space_mb = 16;
  } else if (ram_mb < 1500) {
    // лишаємо місце для кадрів медіа і поверхонь компоситора
    // з 256MB old space одна важка вкладка на 1GB з'їдає майже весь бюджет
    // jetsam
    old_space_mb = 160;
    semi_space_mb = 4;
  }
  char buf[96];
  snprintf(buf, sizeof(buf), "--max-old-space-size=%d --max-semi-space-size=%d",
           old_space_mb, semi_space_mb);
  return std::string(buf);
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

  const std::string logging_dest =
      command_line.GetSwitchValueASCII(switches::kEnableLogging);
  if (logging_dest == "stderr") {
    dest = LoggingDest::kStderr;
  } else if (logging_dest == "system") {
    dest = LoggingDest::kSystem;
  }

#if BUILDFLAG(IS_WIN)
  // On Windows child process may be given a handle in the --log-file switch.
  base::win::ScopedHandle log_handle;
  if (logging_dest == "handle") {
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
    settings.logging_dest = logging::LOG_TO_STDERR;
  } else if (dest == LoggingDest::kSystem) {
    settings.logging_dest = logging::LOG_TO_SYSTEM_DEBUG_LOG;
  } else {
    // Includes both handle or provided filename on Windows.
    settings.logging_dest = logging::LOG_TO_ALL;
  }

  settings.delete_old = logging::APPEND_TO_OLD_LOG_FILE;
  logging::InitLogging(settings);
  logging::SetLogItems(true /* Process ID */, true /* Thread ID */,
                       true /* Timestamp */, false /* Tick count */);
#if BUILDFLAG(IS_IOS)
  if (!command_line.HasSwitch(switches::kEnableLogging)) {
    logging::SetMinLogLevel(logging::LOGGING_WARNING);
  }
#endif
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
  // BrowserEngineKit хоче iOS 17.4+, тому single process
  // спавн процесів BEK на iOS 15 падає
  command_line.AppendSwitch(switches::kSingleProcess);
  command_line.AppendSwitchASCII("enable-features",
                                 "WebContentsDiscard,GlobalPrivacyControlApi");
  // Web Bluetooth без сховища дозволів не працює, а перший доступ сторінки
  // (вхід у Google) валив процес
  {
    const std::string disabled =
        command_line.GetSwitchValueASCII(switches::kDisableBlinkFeatures);
    command_line.AppendSwitchASCII(
        switches::kDisableBlinkFeatures,
        disabled.empty() ? "WebBluetooth" : disabled + ",WebBluetooth");
  }

  // INFO в лог не пишемо, це переважно console.log сторінок
  // на 6 Plus файл за кілька місяців виріс до пів гігабайта
  if (!command_line.HasSwitch(switches::kLogFile)) {
    const char* full_log = BlinkFullLogPath();
    struct stat st;
    if (stat(full_log, &st) == 0 && st.st_size > 8 * 1024 * 1024) {
      const std::string old_log = std::string(full_log) + ".old";
      std::rename(full_log, old_log.c_str());
    }
    command_line.AppendSwitchASCII(switches::kLogFile, full_log);
  }
  if (!command_line.HasSwitch("js-flags")) {
    // пакет без JIT виконуваної пам'яті не потребує, а перевірка без дозволу
    // JIT
    // може закінчитись SIGKILL, як у LiveContainer на iOS 18
    const bool jit_bundle = IsIOSJITBundle();
    const bool runtime_jit_authorized = IsIOSRuntimeJITAuthorized();
    bool basic_exec_available = false;
    bool coderange_execution_available = false;
    if (jit_bundle) {
      basic_exec_available = ProbeIOSBasicExecutableMemory();
      if (basic_exec_available) {
        BLINKER_DIAG(
            "JITPROBE_BASIC_EXEC_OK: basic executable memory succeeded\n");
      }
      coderange_execution_available =
          ProbeIOSCodeRangePatternExecutableMemory();
      // обидві перевірки навмисно валять процес, тому лише за прапором
      // на Relaxin і RootHide (A16) застосунок гине до старту
      if (ReadIOSPrefInt(CFSTR("BlinkJITProbes"), 0) != 0) {
        ProbeIOSRwxExecutableMemory();
        ProbeIOSDualMappingExecutableMemory();
      }
    }
    const bool executable_jit_available =
        jit_bundle &&
        (runtime_jit_authorized ||
         (basic_exec_available && coderange_execution_available));
    if (!runtime_jit_authorized && executable_jit_available) {
      BLINKER_DIAG(
          "JIT_AUTH: executable-memory probes authorize palera1n JIT\n");
    }
    const int tier = executable_jit_available
                         ? ResolveIOSJitTier(coderange_execution_available)
                         : kTierJitless;

    std::string js_flags = IOSJitTierV8Flags(tier);
    if (!js_flags.empty()) {
      js_flags += " ";
    }
    js_flags += IOSV8HeapFlags();
    command_line.AppendSwitchASCII("js-flags", js_flags);

    BLINKER_DIAGF("JIT_TIER: %d (%s) js-flags=%s\n", tier, IOSJitTierName(tier), js_flags.c_str());
  }

  // сторож GPU вбиває завислий потік секунд за 5 і сторінка лишається чорна
  // вимкнено щоб бачити де стала ініціалізація
  command_line.AppendSwitch("disable-gpu-watchdog");

  // Програмно декодовані кадри VP9 ішли через пул MappableSharedImageVideoFramePool
  // і жоден не повертався. 720p ріс на 40 МБ за секунду до смерті застосунку
  // (YouTube на 13 Pro, 14 Pro Max і 6 Plus). Без пулу кадри йдуть звичайним шляхом
  command_line.AppendSwitch("disable-gpu-memory-buffer-video-frames");

  if (!command_line.HasSwitch("force-gpu-mem-available-mb")) {
    const uint64_t ram_mb =
        content::blinker_memory::DevicePhysicalMemory() / (1024 * 1024);
    const char* gpu_mem_mb = ram_mb >= 5500 ? "512"
                             : ram_mb >= 3500 ? "384"
                             : ram_mb >= 1500 ? "192"
                                              : "96";
    command_line.AppendSwitchASCII("force-gpu-mem-available-mb", gpu_mem_mb);

    // на 6 і 6 Plus масштаб 3x, поворот fullscreen YouTube дає поверхні
    // 2208x1242
    // за лімітом jetsam. З 2x виділень вдвічі менше
    if (ram_mb < 1500 &&
        !command_line.HasSwitch("force-device-scale-factor")) {
      command_line.AppendSwitchASCII("force-device-scale-factor", "2");
      BLINKER_DIAG(
          "MEMBUDGET: 1GB legacy compositor scale forced to 2x\n");
    }

    BLINKER_DIAGF("MEMBUDGET: device_ram=%lluMB gpu_mem=%sMB\n", static_cast<unsigned long long>(ram_mb), gpu_mem_mb);
  }

  bool graphite_os = false;
  if (__builtin_available(iOS 13.0, *)) {
    graphite_os = true;
  }
  if (!graphite_os ||
      (BlinkIOSGpuSupportsGraphite && !BlinkIOSGpuSupportsGraphite())) {
    command_line.AppendSwitch(switches::kDisableSkiaGraphite);
    BLINKER_DIAG("GPUFAMILY: legacy OS or GPU, Skia Graphite disabled\n");
  }

#if defined(BLINKER_LEGACY_LOW_MEMORY)
  // карантин звільнень PartitionAlloc на великому base::Value роздував список
  // до 32 МБ і вичерпував менший legacy пул
  const std::string legacy_disabled = ",PartitionAllocSchedulerLoopQuarantine";
#else
  const std::string legacy_disabled;
#endif
  // драйвер A8/A8X на iOS 12 падає на деяких renderbuffer у ANGLE Metal
  // композитинг лишається прискореним, WebGL не даємо
  if (!__builtin_available(iOS 13.0, *)) {
    command_line.AppendSwitch("disable-webgl");
    command_line.AppendSwitch("disable-webgpu");
    command_line.AppendSwitchASCII(
        "disable-features",
        "WebGPUService,avfoundation-overlays,overlay-fullscreen-video,"
        "BackForwardCache" +
            legacy_disabled);
    BLINKER_DIAG(
        "GPUFAMILY: legacy WebGL/WebGPU and black-screen AV video overlays disabled\n");
  } else {
    command_line.AppendSwitchASCII(
        "disable-features",
        "overlay-fullscreen-video,BackForwardCache" + legacy_disabled);
    BLINKER_DIAG(
        "VIDEO: native Apple video layer and PiP enabled with IOSurface fallback\n");
  }

  // SOCKS5 резолвить DNS на проксі, тому локальні DNS/UDP шляхи заборонені
  // щоб його не обійти
  const std::string proxy = content::blinker_proxy::SavedServer();
  if (!proxy.empty()) {
    command_line.AppendSwitchASCII("proxy-server", proxy);
    command_line.AppendSwitchASCII("proxy-bypass-list", "<-loopback>");
    command_line.AppendSwitch("disable-quic");
    command_line.AppendSwitchASCII("force-webrtc-ip-handling-policy",
                                   "disable_non_proxied_udp");
    const auto server = net::ProxyUriToProxyServer(
        proxy, net::ProxyServer::SCHEME_HTTP);
    command_line.AppendSwitchASCII(
        "host-resolver-rules",
        "MAP * ~NOTFOUND, EXCLUDE " + server.host_port_pair().host());
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
  // TODO(crbug.com/40062835): Clarify which users of
  // PoissonAllocationSampler we have in the ContentShell. Do we really need to
  // enforce it?
  const auto poisson_sampler_inclusion =
      (EXPENSIVE_TEST_LOGIC_IS_ON() ||
#if !BUILDFLAG(IS_ANDROID)
       switches::IsRunWebTestsSwitchPresent()
#else
       false
#endif
           )
          ? memory_system::DispatcherParameters::
                PoissonAllocationSamplerInclusion::kEnforce
          : memory_system::DispatcherParameters::
                PoissonAllocationSamplerInclusion::kDynamic;
  memory_system::Initializer()
      .SetDispatcherParameters(poisson_sampler_inclusion,
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
  renderer_client_ =
      std::make_unique<ShellContentRendererClient>(is_content_browsertests_);
  return renderer_client_.get();
}

ContentUtilityClient* ShellMainDelegate::CreateContentUtilityClient() {
  utility_client_ =
      std::make_unique<ShellContentUtilityClient>(is_content_browsertests_);
  return utility_client_.get();
}

}  // namespace content
