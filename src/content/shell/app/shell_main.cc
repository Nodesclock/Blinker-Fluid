// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "build/build_config.h"
#include "content/public/app/content_main.h"
#include "content/shell/app/shell_main_delegate.h"

#if BUILDFLAG(IS_WIN)
#include "base/command_line.h"
#include "base/win/dark_mode_support.h"
#include "base/win/win_util.h"
#include "content/public/app/sandbox_helper_win.h"
#include "sandbox/win/src/sandbox_types.h"
#endif

#if BUILDFLAG(IS_IOS)
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "base/at_exit.h"                                 // nogncheck
#include "base/command_line.h"                            // nogncheck
#include "build/ios_buildflags.h"                         // nogncheck
#include "content/public/common/content_switches.h"       // nogncheck
#include "content/shell/app/ios/shell_application_ios.h"
#include "content/shell/app/ios/web_tests_support_ios.h"
#include "content/shell/common/shell_switches.h"
#endif

#if BUILDFLAG(IS_WIN)

#if !defined(WIN_CONSOLE_APP)
int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int) {
#else
int main() {
  HINSTANCE instance = GetModuleHandle(NULL);
#endif
  // Load and pin user32.dll and uxtheme.dll to avoid having to load them once
  // tests start while on the main thread loop where blocking calls are
  // disallowed. This will also ensure the Windows dark mode support is enabled
  // for the app if available.
  base::win::PinUser32();
  base::win::AllowDarkModeForApp(true);

  // Sandbox initialization needs the command line before ContentMain().
  base::CommandLine::Init(0, nullptr);
  sandbox::SandboxInterfaceInfo sandbox_info = {nullptr};
  content::InitializeSandboxInfo(&sandbox_info);
  content::ShellMainDelegate delegate;

  content::ContentMainParams params(&delegate);
  params.instance = instance;
  params.sandbox_info = &sandbox_info;
  return content::ContentMain(std::move(params));
}

#elif BUILDFLAG(IS_IOS)

#define IOS_INIT_EXPORT __attribute__((visibility("default")))

extern "C" void BlinkBootLog(const char* stage);

// застосунок з контейнером (як з TrollStore) не пише в /var/mobile/Documents
// спершу контейнер, далі спільний шлях, далі $HOME/Documents
static char g_blink_docs_dir[PATH_MAX];
static char g_blink_boot_log_path[PATH_MAX];
static char g_blink_boot_log_prev_path[PATH_MAX];
static char g_blink_crash_signal_path[PATH_MAX];
static char g_blink_full_log_path[PATH_MAX];

extern "C" const char* BlinkIOSContainerDocumentsDirectory();

extern "C" const char* BlinkDocumentsDir() {
  if (g_blink_docs_dir[0]) {
    return g_blink_docs_dir;
  }
  // спершу Foundation, access(W_OK) на ранньому етапі проходить, а open()
  // після пісочниці вже заборонено
  const char* container_documents = BlinkIOSContainerDocumentsDirectory();
  if (container_documents && container_documents[0]) {
    strlcpy(g_blink_docs_dir, container_documents,
            sizeof(g_blink_docs_dir));
    mkdir(g_blink_docs_dir, 0755);
    if (access(g_blink_docs_dir, W_OK) == 0) {
      return g_blink_docs_dir;
    }
  }
  const char* kShared = "/var/mobile/Documents";
  if (access(kShared, W_OK) == 0) {
    strlcpy(g_blink_docs_dir, kShared, sizeof(g_blink_docs_dir));
    return g_blink_docs_dir;
  }
  const char* home = getenv("CFFIXED_USER_HOME");
  if (!home || !home[0]) {
    home = getenv("HOME");
  }
  if (home && home[0]) {
    snprintf(g_blink_docs_dir, sizeof(g_blink_docs_dir), "%s/Documents", home);
    mkdir(g_blink_docs_dir, 0755);
    if (access(g_blink_docs_dir, W_OK) == 0) {
      return g_blink_docs_dir;
    }
  }
  strlcpy(g_blink_docs_dir, "/tmp", sizeof(g_blink_docs_dir));
  return g_blink_docs_dir;
}

static const char* BlinkDocsFile(char* cache, size_t cache_size,
                                 const char* leaf) {
  if (!cache[0]) {
    snprintf(cache, cache_size, "%s/%s", BlinkDocumentsDir(), leaf);
  }
  return cache;
}

extern "C" const char* BlinkBootLogPath() {
  return BlinkDocsFile(g_blink_boot_log_path, sizeof(g_blink_boot_log_path),
                       "blink_boot.log");
}

extern "C" const char* BlinkBootLogPrevPath() {
  return BlinkDocsFile(g_blink_boot_log_prev_path,
                       sizeof(g_blink_boot_log_prev_path),
                       "blink_boot_prev.log");
}

extern "C" const char* BlinkCrashSignalPath() {
  return BlinkDocsFile(g_blink_crash_signal_path,
                       sizeof(g_blink_crash_signal_path),
                       ".blink_last_crash_signal");
}

extern "C" const char* BlinkFullLogPath() {
  return BlinkDocsFile(g_blink_full_log_path, sizeof(g_blink_full_log_path),
                       "content_shell_full.log");
}

// іде на завантаженні образу dyld, до main(). Нема рядка в логу значить
// падіння в loader або static init
__attribute__((constructor)) static void BlinkBootLogImageLoaded() {
  BlinkBootLogPath();
  BlinkBootLogPrevPath();
  BlinkCrashSignalPath();
  BlinkFullLogPath();
  BlinkBootLog("LOAD: dyld image loaded, constructors running (pre-main)");
}

// сторож JIT знижує рівень лише на SIGILL, SIGBUS, SIGSEGV і SIGTRAP
// тільки open, write і close
static void BlinkRecordCrashSignal(int sig) {
  static volatile sig_atomic_t recorded = 0;
  if (recorded) {
    return;
  }
  recorded = 1;
  int fd = open(BlinkCrashSignalPath(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return;
  }
  char digits[8];
  int t = 0, n = sig;
  if (n == 0) {
    digits[t++] = '0';
  }
  while (n > 0 && t < (int)sizeof(digits)) {
    digits[t++] = (char)('0' + n % 10);
    n /= 10;
  }
  char out[8];
  int len = 0;
  while (t > 0) {
    out[len++] = digits[--t];
  }
  ssize_t written = write(fd, out, len);
  (void)written;
  close(fd);
}

// без snprintf і malloc, бо кличеться з обробника сигналу
static void BlinkWriteHex(int fd, const char* label, uint64_t value) {
  char buf[64];
  size_t len = 0;
  while (label[len] && len < 32) {
    buf[len] = label[len];
    ++len;
  }
  buf[len++] = '0';
  buf[len++] = 'x';
  bool leading = true;
  for (int shift = 60; shift >= 0; shift -= 4) {
    const int nibble = (int)((value >> shift) & 0xF);
    if (nibble == 0 && leading && shift != 0) {
      continue;
    }
    leading = false;
    buf[len++] = (char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
  }
  buf[len++] = '\n';
  ssize_t written = write(fd, buf, len);
  (void)written;
}

static void BlinkLogRegionProt(int fd, const char* label, uint64_t addr) {
  vm_address_t region = (vm_address_t)addr;
  vm_size_t size = 0;
  natural_t depth = 0;
  vm_region_submap_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
  kern_return_t kr = vm_region_recurse_64(mach_task_self(), &region, &size,
                                          &depth, (vm_region_recurse_info_t)&info,
                                          &count);
  if (kr != KERN_SUCCESS) {
    BlinkWriteHex(fd, label, 0xDEAD0000u | (uint32_t)kr);
    return;
  }
  BlinkWriteHex(fd, label,
                ((uint64_t)(info.protection & 0xF) << 4) |
                    (uint64_t)(info.max_protection & 0xF));
  BlinkWriteHex(fd, "  region_base: ", (uint64_t)region);
  BlinkWriteHex(fd, "  region_size: ", (uint64_t)size);
}

extern "C" void BlinkCrashHandler(int sig);

extern "C" __attribute__((weak)) void BlinkIOSWxState(
    int* depth, int* whole_writable, unsigned long long* transitions,
    unsigned long long* failures);

// brk від CHECK або OOM теж дає SIGTRAP, і рівень сповзав до jitless
// після звичайних нестач пам'яті. Тому дивимось чи впав саме згенерований код
static bool BlinkFaultLooksLikeCodegen(int sig, siginfo_t* info, void* uap) {
#if defined(__arm64__) || defined(__aarch64__)
  ucontext_t* uc = (ucontext_t*)uap;
  if (!uc || !uc->uc_mcontext) {
    return true;
  }
  Dl_info dli;
  if (!dladdr((void*)uc->uc_mcontext->__ss.__pc, &dli) || !dli.dli_fbase) {
    return true;
  }
  if (sig == SIGTRAP || sig == SIGILL) {
    return false;
  }
  const uint64_t addr = info ? (uint64_t)info->si_addr : 0;
  if (addr < (1ull << 32)) {
    return false;
  }
  Dl_info fault_dli;
  return !(dladdr((void*)addr, &fault_dli) && fault_dli.dli_fbase);
#else
  return true;
#endif
}

extern "C" void BlinkCrashHandlerWithInfo(int sig, siginfo_t* info, void* uap) {
  BlinkRecordCrashSignal(BlinkFaultLooksLikeCodegen(sig, info, uap) ? sig : 0);
  int fd = open(BlinkBootLogPath(),
                O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd >= 0) {
    if (info) {
      BlinkWriteHex(fd, "CRASH_FAULT_ADDR: ", (uint64_t)info->si_addr);
      BlinkWriteHex(fd, "CRASH_FAULT_CODE: ", (uint64_t)(uint32_t)info->si_code);
      // 0x54 це здорова сторінка коду, 0x04 або 0x00 значить execute пропав
      BlinkLogRegionProt(fd, "CRASH_FAULT_PROT: ", (uint64_t)info->si_addr);
    }
    if (BlinkIOSWxState) {
      int depth = 0, whole = 0;
      unsigned long long trans = 0, fails = 0;
      BlinkIOSWxState(&depth, &whole, &trans, &fails);
      BlinkWriteHex(fd, "CRASH_WX_DEPTH: ", (uint64_t)depth);
      BlinkWriteHex(fd, "CRASH_WX_WHOLE_WRITABLE: ", (uint64_t)whole);
      BlinkWriteHex(fd, "CRASH_WX_TRANSITIONS: ", (uint64_t)trans);
      BlinkWriteHex(fd, "CRASH_WX_FAILURES: ", (uint64_t)fails);
    }
#if defined(__arm64__) || defined(__aarch64__)
    if (uap) {
      ucontext_t* uc = (ucontext_t*)uap;
      if (uc->uc_mcontext) {
        BlinkWriteHex(fd, "CRASH_PC: ", (uint64_t)uc->uc_mcontext->__ss.__pc);
        BlinkWriteHex(fd, "CRASH_LR: ", (uint64_t)uc->uc_mcontext->__ss.__lr);
        BlinkWriteHex(fd, "CRASH_SP: ", (uint64_t)uc->uc_mcontext->__ss.__sp);
        Dl_info dli;
        if (dladdr((void*)uc->uc_mcontext->__ss.__pc, &dli) && dli.dli_fbase) {
          BlinkWriteHex(fd, "CRASH_IMAGE_BASE: ", (uint64_t)dli.dli_fbase);
        }
        const uint64_t sp = (uint64_t)uc->uc_mcontext->__ss.__sp;
        uint64_t fp = (uint64_t)uc->uc_mcontext->__ss.__fp;
        BlinkWriteHex(fd, "CRASH_FRAME: ", (uint64_t)uc->uc_mcontext->__ss.__pc);
        BlinkWriteHex(fd, "CRASH_FRAME: ", (uint64_t)uc->uc_mcontext->__ss.__lr);
        for (int i = 0; i < 32; ++i) {
          // кадр має бути вище вказівника стека, вирівняний і недалеко,
          // інакше читання вбило б обробник до запису
          if (fp < sp || (fp & 0xf) != 0 || fp - sp > (16ull << 20)) {
            break;
          }
          const uint64_t* frame = (const uint64_t*)fp;
          const uint64_t next_fp = frame[0];
          const uint64_t lr = frame[1];
          if (!lr) {
            break;
          }
          BlinkWriteHex(fd, "CRASH_FRAME: ", lr);
          if (next_fp <= fp) {
            break;
          }
          fp = next_fp;
        }
      }
    }
#endif
    close(fd);
  }
  BlinkCrashHandler(sig);
}

extern "C" void BlinkCrashHandler(int sig) {
  BlinkRecordCrashSignal(sig);
  int fd = open(BlinkBootLogPath(),
                O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd >= 0) {
    char hdr[40] = "CRASH: signal ";
    int n = sig, len = (int)strlen(hdr);
    char tmp[8];
    int t = 0;
    if (n == 0) {
      tmp[t++] = '0';
    }
    while (n > 0) {
      tmp[t++] = (char)('0' + n % 10);
      n /= 10;
    }
    while (t > 0) {
      hdr[len++] = tmp[--t];
    }
    hdr[len++] = '\n';
    write(fd, hdr, len);
    void* frames[64];
    int nf = backtrace(frames, 64);
    backtrace_symbols_fd(frames, nf, fd);
    close(fd);
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

static char g_blink_altstack[65536];
extern "C" void BlinkArmCrashHandler(void) {
  stack_t ss;
  ss.ss_sp = g_blink_altstack;
  ss.ss_size = sizeof(g_blink_altstack);
  ss.ss_flags = 0;
  sigaltstack(&ss, nullptr);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = BlinkCrashHandlerWithInfo;
  sa.sa_flags = SA_ONSTACK | SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  const int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE};
  for (int s : sigs) {
    sigaction(s, &sa, nullptr);
  }
}

// пріоритет 101 іде до всіх звичайних static init і V8,
// обробник стоїть ще до збою
__attribute__((constructor(101))) static void BlinkInstallCrashHandler() {
  BlinkBootLog("CTOR101: earliest ctor, arming crash handler");
  BlinkArmCrashHandler();
}

extern "C" IOS_INIT_EXPORT int ChildProcessMain(int argc, const char** argv) {
  // Create this here since it's needed to start the crash handler.
  base::AtExitManager at_exit;
  base::CommandLine::Init(argc, argv);
  content::ShellMainDelegate delegate;
  content::ContentMainParams params(&delegate);
  params.argc = argc;
  params.argv = argv;
  return content::ContentMain(std::move(params));
}

extern "C" IOS_INIT_EXPORT int ContentAppMain(int argc, const char** argv) {
  BlinkBootLog("MAIN0: ContentAppMain entry (earliest framework code)");
  // Create this here since it's needed to start the crash handler.
  base::AtExitManager at_exit;

  // Check if this is the browser process or a subprocess. Only the browser
  // browser should run UIApplicationMain.
  base::CommandLine::Init(argc, argv);
  auto type = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
      switches::kProcessType);

  // The browser process has no --process-type argument.
  if (type.empty()) {
    if (switches::IsRunWebTestsSwitchPresent()) {
      // We create a simple UIApplication to run the web tests.
      return RunWebTestsFromIOSApp(argc, argv);
    } else {
      // We will create the ContentMainRunner once the UIApplication is ready.
      return RunShellApplication(argc, argv);
    }
  } else {
    content::ShellMainDelegate delegate;
    content::ContentMainParams params(&delegate);
    params.argc = argc;
    params.argv = argv;
    return content::ContentMain(std::move(params));
  }
}

#else

int main(int argc, const char** argv) {
  content::ShellMainDelegate delegate;
  content::ContentMainParams params(&delegate);
  params.argc = argc;
  params.argv = argv;
  return content::ContentMain(std::move(params));
}

#endif  // BUILDFLAG(IS_WIN)
