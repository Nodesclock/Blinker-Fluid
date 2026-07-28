// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "build/build_config.h"
#include "content/public/app/content_main.h"
#include "content/shell/app/shell_main_delegate.h"

#if BUILDFLAG(IS_WIN)
#include "base/win/dark_mode_support.h"
#include "base/win/win_util.h"
#include "content/public/app/sandbox_helper_win.h"
#include "sandbox/win/src/sandbox_types.h"
#endif

#if BUILDFLAG(IS_IOS)
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
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

// Early startup logger defined by the iOS application layer.
extern "C" void BlinkBootLog(const char* stage);

// Runs at dyld image-load time, after the binary + dependent dylibs are mapped
// and C++/ObjC static initializers run, but before main(). If this never logs,
// the crash is in the loader/static-init itself (e.g. a bad dependency).
__attribute__((constructor)) static void BlinkBootLogImageLoaded() {
  BlinkBootLog("LOAD: dyld image loaded, constructors running (pre-main)");
}

// Records the fatal signal where the NEXT launch can read it, so a crash can be
// attributed. In particular the JIT tier guard only demotes the engine for
// signals that indicate generated code misbehaved (SIGILL/SIGBUS/SIGSEGV/
// SIGTRAP) — an unrelated SIGABRT (an uncaught ObjC exception, say) must not
// ratchet the engine down. Written with open/write/close only, which is
// async-signal-safe; the file is one decimal number.
extern "C" const char kBlinkLastCrashSignalPath[] =
    "/var/mobile/Documents/.blink_last_crash_signal";

static void BlinkRecordCrashSignal(int sig) {
  int fd = open(kBlinkLastCrashSignalPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
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

// Appends "<label>0x<hex>\n". Async-signal-safe (no snprintf, no malloc).
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

// Logs the VM protection of the page containing `addr` at crash time, encoded as
// (cur_prot << 4) | max_prot (VM_PROT_READ=1 WRITE=2 EXECUTE=4), plus the region
// base and size. Distinguishes a permission fault from a bad branch target.
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
  // Pack: [cur_prot:4][max_prot:4] in low byte, region base, region size.
  BlinkWriteHex(fd, label,
                ((uint64_t)(info.protection & 0xF) << 4) |
                    (uint64_t)(info.max_protection & 0xF));
  BlinkWriteHex(fd, "  region_base: ", (uint64_t)region);
  BlinkWriteHex(fd, "  region_size: ", (uint64_t)size);
}

// Minimal signal handler for devices without a usable ReportCrash record.
//
// The faulting PC and address matter more than the backtrace here: backtrace()
// walks the frame-pointer chain, which is meaningless once execution is inside
// V8-generated code, so a JIT fault shows up as a stack of repeated builtin
// trampolines that says nothing about where it actually died. si_addr and the
// saved PC identify the faulting instruction directly, and comparing them
// against the CodeRange says whether generated code was executing.
extern "C" void BlinkCrashHandler(int sig);

// Defined in v8 (code-memory-access.cc) only on the iOS mprotect-W^X build;
// weak so the symbol is optional on other configurations.
extern "C" __attribute__((weak)) void BlinkIOSWxState(
    int* depth, int* whole_writable, unsigned long long* transitions,
    unsigned long long* failures);

extern "C" void BlinkCrashHandlerWithInfo(int sig, siginfo_t* info, void* uap) {
  BlinkRecordCrashSignal(sig);
  int fd = open("/var/mobile/Documents/blink_boot.log",
                O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd >= 0) {
    if (info) {
      BlinkWriteHex(fd, "CRASH_FAULT_ADDR: ", (uint64_t)info->si_addr);
      BlinkWriteHex(fd, "CRASH_FAULT_CODE: ", (uint64_t)(uint32_t)info->si_code);
      // Real page protection at the fault address (cur<<4 | max; R=1 W=2 X=4).
      // 0x54 = cur RX / max RXW is a healthy code page; 0x04/0x00 = the page
      // lost execute or all access; region_base far from the fault = bad target.
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
      }
    }
#endif
    close(fd);
  }
  BlinkCrashHandler(sig);
}

extern "C" void BlinkCrashHandler(int sig) {
  BlinkRecordCrashSignal(sig);
  int fd = open("/var/mobile/Documents/blink_boot.log",
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

// Arms our crash handler via sigaction on an alternate stack (survives stack
// overflow). Exposed extern "C" so it can be RE-armed after Chromium installs
// its own signal handlers during startup (which otherwise replace ours, making
// post-startup crashes bypass this logger). Safe to call repeatedly.
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

// Priority 101 = runs before all default-priority static initializers (incl.
// V8's), so the handler is armed before whatever is crashing in static-init.
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
