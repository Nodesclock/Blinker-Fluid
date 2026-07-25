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
#include <signal.h>
#include <string.h>
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

// Minimal signal handler for devices without a usable ReportCrash record.
extern "C" void BlinkCrashHandler(int sig) {
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
  sa.sa_handler = BlinkCrashHandler;
  sa.sa_flags = SA_ONSTACK;
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
