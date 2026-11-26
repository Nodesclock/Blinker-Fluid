// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/renderer/shell_content_renderer_client.h"

#include <string>

#include "base/auto_reset.h"
#include "base/base_switches.h"
#include "base/check_is_test.h"
#include "base/check_op.h"
#include "base/command_line.h"
#include "base/containers/flat_set.h"
#include "base/files/file.h"
#include "base/functional/bind.h"
#include "base/immediate_crash.h"
#include "base/notreached.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/single_thread_task_runner.h"
#include "base/test/allow_check_is_test_for_testing.h"
#include "base/types/pass_key.h"
#include "build/build_config.h"
#include "components/cdm/renderer/external_clear_key_key_system_info.h"
#include "components/network_hints/renderer/web_prescient_networking_impl.h"
#include "components/surface_embed/renderer/create_plugin.h"
#include "components/web_cache/renderer/web_cache_impl.h"
#include "content/common/pseudonymization_salt.h"
#include "content/common/skia_utils.h"
#include "content/public/common/content_switches.h"
#include "content/public/common/pseudonymization_util.h"
#include "content/public/common/web_identity.h"
#include "content/public/renderer/render_frame.h"
#include "content/public/renderer/render_thread.h"
#include "content/public/test/test_service.mojom.h"
#include "content/shell/browser/blinker_extension_messaging.h"
#include "content/shell/browser/blinker_ui_strings.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/common/main_frame_counter_test_impl.h"
#include "content/shell/common/blinker_error_page.h"
#include "content/shell/common/blinker_selection_color.h"
#include "content/shell/common/blinker_web_colors.h"
#include "content/shell/common/power_monitor_test_impl.h"
#include "content/shell/common/shell_switches.h"
#include "content/shell/renderer/memory_coordinator/memory_coordinator_test_impl.h"
#include "content/shell/renderer/shell_render_frame_observer.h"
#include "mojo/public/cpp/bindings/binder_map.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "net/base/net_errors.h"
#include "net/http/structured_headers.h"
#include "sandbox/policy/sandbox.h"
#include "third_party/blink/public/platform/url_loader_throttle_provider.h"
#include "third_party/blink/public/platform/web_runtime_features.h"
#include "third_party/blink/public/platform/web_security_origin.h"
#include "third_party/blink/public/platform/web_string.h"
#include "third_party/blink/public/platform/web_url_error.h"
#include "third_party/blink/public/web/modules/credentialmanagement/throttle_helper.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "third_party/blink/public/web/web_security_policy.h"
#include "third_party/blink/public/web/web_testing_support.h"
#include "third_party/blink/public/web/web_view.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/scheme_host_port.h"
#include "url/url_constants.h"
#include "v8/include/v8-initialization.h"
#include "v8/include/v8.h"

#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>

#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/blinker_extension_net_actions.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_private_logging.h"
#endif

#if BUILDFLAG(ENABLE_MOJO_CDM)
#include "base/feature_list.h"
#include "media/base/media_switches.h"
#endif

#if (BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)) && \
    (defined(ARCH_CPU_X86_64) || defined(ARCH_CPU_ARM64))
#define ENABLE_WEB_ASSEMBLY_TRAP_HANDLER_LINUX
#include "base/debug/stack_trace.h"
#include "v8/include/v8-wasm-trap-handler-posix.h"
#endif

namespace content {

namespace {

// A test service which can be driven by browser tests for various reasons.
class TestRendererServiceImpl : public mojom::TestService {
 public:
  explicit TestRendererServiceImpl(
      mojo::PendingReceiver<mojom::TestService> receiver)
      : receiver_(this, std::move(receiver)) {
    receiver_.set_disconnect_handler(base::BindOnce(
        &TestRendererServiceImpl::OnConnectionError, base::Unretained(this)));
  }

  TestRendererServiceImpl(const TestRendererServiceImpl&) = delete;
  TestRendererServiceImpl& operator=(const TestRendererServiceImpl&) = delete;

  ~TestRendererServiceImpl() override {}

 private:
  void OnConnectionError() { delete this; }

  // mojom::TestService:
  void DoSomething(DoSomethingCallback callback) override {
    // Instead of responding normally, unbind the pipe, write some garbage,
    // and go away.
    const std::string kBadMessage = "This is definitely not a valid response!";
    mojo::ScopedMessagePipeHandle pipe = receiver_.Unbind().PassPipe();
    MojoResult rv = mojo::WriteMessageRaw(
        pipe.get(), kBadMessage.data(), kBadMessage.size(), nullptr, 0,
        MOJO_WRITE_MESSAGE_FLAG_NONE);
    DCHECK_EQ(rv, MOJO_RESULT_OK);

    // Deletes this.
    OnConnectionError();
  }

  void DoTerminateProcess(DoTerminateProcessCallback callback) override {
    NOTREACHED();
  }

  void DoCrashImmediately(DoCrashImmediatelyCallback callback) override {
    // This intentionally crashes the process and needs to be fatal regardless
    // of DCHECK level. This is unlike the other NOTREACHED()s which are not
    // expected to get called at all.
    base::ImmediateCrash();
  }

  void CreateFolder(CreateFolderCallback callback) override { NOTREACHED(); }

  void GetRequestorName(GetRequestorNameCallback callback) override {
    std::move(callback).Run("Not implemented.");
  }

  void CreateReadOnlySharedMemoryRegion(
      const std::string& message,
      CreateReadOnlySharedMemoryRegionCallback callback) override {
    NOTREACHED();
  }

  void CreateWritableSharedMemoryRegion(
      const std::string& message,
      CreateWritableSharedMemoryRegionCallback callback) override {
    NOTREACHED();
  }

  void CreateUnsafeSharedMemoryRegion(
      const std::string& message,
      CreateUnsafeSharedMemoryRegionCallback callback) override {
    NOTREACHED();
  }

  void CloneSharedMemoryContents(
      base::ReadOnlySharedMemoryRegion region,
      CloneSharedMemoryContentsCallback callback) override {
    NOTREACHED();
  }

  void IsProcessSandboxed(IsProcessSandboxedCallback callback) override {
    std::move(callback).Run(sandbox::policy::Sandbox::IsProcessSandboxed());
  }

  void PseudonymizeString(const std::string& value,
                          PseudonymizeStringCallback callback) override {
    std::move(callback).Run(
        PseudonymizationUtil::PseudonymizeStringForTesting(value));
  }

  void GetPseudonymizationSalt(
      GetPseudonymizationSaltCallback callback) override {
    std::move(callback).Run(content::GetPseudonymizationSalt());
  }

  void IsPseudonymizationSaltInitialized(
      IsPseudonymizationSaltInitializedCallback callback) override {
    std::move(callback).Run(content::IsSaltInitialized());
  }

  void IsSkiaInitialized(IsSkiaInitializedCallback callback) override {
    std::move(callback).Run(IsSkiaInitializedForTesting());
  }

  void PassWriteableFile(base::File file,
                         PassWriteableFileCallback callback) override {
    std::move(callback).Run();
  }

  void VerifyCheckIsTest(VerifyCheckIsTestCallback callback) override {
    CHECK_IS_TEST();
    std::move(callback).Run(true);
  }

  void WriteToPreloadedPipe() override { NOTREACHED(); }

  mojo::Receiver<mojom::TestService> receiver_;
};

class ShellContentRendererUrlLoaderThrottleProvider
    : public blink::URLLoaderThrottleProvider {
 public:
  ShellContentRendererUrlLoaderThrottleProvider()
      : main_thread_task_runner_(
            content::RenderThread::IsMainThread()
                ? base::SequencedTaskRunner::GetCurrentDefault()
                : nullptr) {}

  // This constructor works in conjunction with Clone().
  ShellContentRendererUrlLoaderThrottleProvider(
      const scoped_refptr<base::SequencedTaskRunner>& main_thread_task_runner,
      base::PassKey<ShellContentRendererUrlLoaderThrottleProvider>)
      : main_thread_task_runner_(std::move(main_thread_task_runner)) {}

  std::unique_ptr<URLLoaderThrottleProvider> Clone() override {
    return std::make_unique<ShellContentRendererUrlLoaderThrottleProvider>(
        main_thread_task_runner_,
        base::PassKey<ShellContentRendererUrlLoaderThrottleProvider>());
  }

  std::vector<std::unique_ptr<blink::URLLoaderThrottle>> CreateThrottles(
      base::optional_ref<const blink::LocalFrameToken> local_frame_token,
      const network::ResourceRequest& request) override {
    std::vector<std::unique_ptr<blink::URLLoaderThrottle>> throttles;
#if BUILDFLAG(IS_IOS)
    // Throttle браузера бачить лише навігації, тому фрейми і воркери
    // фільтруємо тут
    throttles.push_back(std::make_unique<BlinkerContentFilterThrottle>());
#endif
    if (local_frame_token.has_value()) {
      auto throttle = content::MaybeCreateIdentityUrlLoaderThrottle(
          base::BindRepeating(
              [](const blink::LocalFrameToken& token,
                 const scoped_refptr<base::SequencedTaskRunner>
                     main_thread_task_runner,
                 network::mojom::RequestDestination destination,
                 const std::optional<url::Origin>& initiator,
                 const url::Origin& idp_origin,
                 blink::mojom::IdpSigninStatus status) {
                if (content::RenderThread::IsMainThread()) {
                  blink::SetIdpSigninStatus(token, idp_origin, status);
                  return;
                }
                if (main_thread_task_runner) {
                  main_thread_task_runner->PostTask(
                      FROM_HERE, base::BindOnce(&blink::SetIdpSigninStatus,
                                                token, idp_origin, status));
                }
              },
              local_frame_token.value(), main_thread_task_runner_),
          content::GetSetLoginHeaderInProcessParser());
      if (throttle)
        throttles.push_back(std::move(throttle));
    }

    return throttles;
  }

  void SetOnline(bool is_online) override {}

 private:
  // Set only when `this` was created on the main thread, or cloned from a
  // provider which was created on the main thread.
  scoped_refptr<base::SequencedTaskRunner> main_thread_task_runner_;
};

void CreateRendererTestService(
    mojo::PendingReceiver<mojom::TestService> receiver) {
  // Owns itself.
  new TestRendererServiceImpl(std::move(receiver));
}

}  // namespace

ShellContentRendererClient::ShellContentRendererClient(bool is_browsertest) {
  if (is_browsertest &&
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kProcessType) == switches::kRendererProcess) {
    base::test::AllowCheckIsTestForTesting();
  }
}

ShellContentRendererClient::~ShellContentRendererClient() {
}

void ShellContentRendererClient::SetUpWebAssemblyTrapHandler() {
#if BUILDFLAG(IS_WIN) || BUILDFLAG(IS_MAC)
  // Mac and Windows use the default implementation (where the default v8 trap
  // handler gets set up).
  ContentRendererClient::SetUpWebAssemblyTrapHandler();
  return;
#else
  base::CommandLine* const command_line =
      base::CommandLine::ForCurrentProcess();
  const bool crash_reporter_enabled =
      command_line->HasSwitch(switches::kEnableCrashReporter)
#if BUILDFLAG(IS_POSIX)
      || command_line->HasSwitch(switches::kEnableCrashReporterForTesting)
#endif  // BUILDFLAG(IS_POSIX)
      ;

  if (crash_reporter_enabled) {
    // If either --enable-crash-reporter or --enable-crash-reporter-for-testing
    // is enabled it should take care of signal handling for us, use the default
    // implementation which doesn't register an additional handler.
    ContentRendererClient::SetUpWebAssemblyTrapHandler();
    return;
  }

  const bool use_v8_default_handler =
#if defined(ENABLE_WEB_ASSEMBLY_TRAP_HANDLER_LINUX)
      base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kDisableInProcessStackTraces)
#else
      true
#endif  // defined(ENABLE_WEB_ASSEMBLY_TRAP_HANDLER_LINUX)
      ;

  if (use_v8_default_handler) {
    // There is no signal handler yet, but it's okay if v8 registers one.
    v8::V8::EnableWebAssemblyTrapHandler(/*use_v8_signal_handler=*/true);
    return;
  }

#if defined(ENABLE_WEB_ASSEMBLY_TRAP_HANDLER_LINUX)
  if (base::debug::SetStackDumpFirstChanceCallback(
          v8::TryHandleWebAssemblyTrapPosix)) {
    // Crashpad and Breakpad are disabled, but the in-process stack dump
    // handlers are enabled, so set the callback on the stack dump handlers.
    v8::V8::EnableWebAssemblyTrapHandler(/*use_v8_signal_handler=*/false);
    return;
  }

  // As the registration of the callback failed, we don't enable trap
  // handlers.
#endif  // defined(ENABLE_WEB_ASSEMBLY_TRAP_HANDLER_LINUX)
#endif  // BUILDFLAG(IS_WIN) || BUILDFLAG(IS_MAC)
}

void ShellContentRendererClient::
    SetRuntimeFeaturesDefaultsBeforeBlinkInitialization() {
  // Порти розширень дізнаються про закриття сторінки з події close.
  // Ключі командного рядка застосовуються після цього
  blink::WebRuntimeFeatures::EnableFeatureFromString("MessagePortCloseEvent",
                                                     true);
}

void ShellContentRendererClient::RenderThreadStarted() {
  web_cache_impl_ = std::make_unique<web_cache::WebCacheImpl>();

  // Без цього Blink відмовляє схемі ще до URLLoaderFactory, і fetch з
  // content script до своїх файлів не працює
  const blink::WebString scheme =
      blink::WebString::FromUtf8(kBlinkerExtensionScheme);
  blink::WebSecurityPolicy::RegisterURLSchemeAsSupportingFetchAPI(scheme);
  blink::WebSecurityPolicy::RegisterURLSchemeAsExtension(scheme);
  blink::WebSecurityPolicy::RegisterURLSchemeAsAllowingServiceWorkers(scheme);
  blink::WebSecurityPolicy::RegisterURLSchemeAsAllowedForReferrer(scheme);

  // redirect з declarativeNetRequest на ресурс розширення для підресурсів
  // можна виконати лише тут
  BlinkerInstallSubresourceRedirectHook();
}

void ShellContentRendererClient::ExposeInterfacesToBrowser(
    mojo::BinderMap* binders) {
  binders->Add<mojom::TestService>(
      &CreateRendererTestService,
      base::SingleThreadTaskRunner::GetCurrentDefault());
  binders->Add<mojom::MemoryCoordinatorTest>(
      base::BindRepeating(&MemoryCoordinatorTestImpl::Bind),
      base::SingleThreadTaskRunner::GetCurrentDefault());
  binders->Add<mojom::PowerMonitorTest>(
      &PowerMonitorTestImpl::MakeSelfOwnedReceiver,
      base::SingleThreadTaskRunner::GetCurrentDefault());
  binders->Add<mojom::MainFrameCounterTest>(
      &MainFrameCounterTestImpl::Bind,
      base::SingleThreadTaskRunner::GetCurrentDefault());
  binders->Add<web_cache::mojom::WebCache>(
      base::BindRepeating(&web_cache::WebCacheImpl::BindReceiver,
                          base::Unretained(web_cache_impl_.get())),
      base::SingleThreadTaskRunner::GetCurrentDefault());
}

void ShellContentRendererClient::RenderFrameCreated(RenderFrame* render_frame) {
  // TODO(danakj): The ShellRenderFrameObserver is doing stuff only for
  // browser tests. If we only create that for browser tests then the override
  // of this method in WebTestContentRendererClient would not be needed.
  new ShellRenderFrameObserver(render_frame);
}

bool ShellContentRendererClient::OverrideCreatePlugin(
    RenderFrame* render_frame,
    const blink::WebPluginParams& params,
    blink::WebPlugin** plugin) {
  // Tries to create a SurfaceEmbedWebPlugin for
  // <embed type="application/x-chromium-surface-embed">. The renderer process
  // will render an indication of error (a "sad webpage") in the plugin area if
  // the browser process does not provide the SurfaceEmbedHost interface.
  // Many embedders will choose to kill the renderer in that case, however.
  //
  // The interface is available in surface embed's content_browsertests /
  // components_browsertests by overriding
  // RegisterBrowserInterfaceBindersForFrame and is not available in the general
  // content_shell. content_shell's default browser-side implementation triggers
  // the fallback behavior, not a renderer crash.
  if (surface_embed::MaybeCreatePlugin(render_frame, params, plugin)) {
    return true;
  }

  return false;
}

void ShellContentRendererClient::PrepareErrorPage(
    RenderFrame* render_frame,
    const blink::WebURLError& error,
    const std::string& http_method,
    content::mojom::AlternativeErrorPageOverrideInfoPtr
        alternative_error_page_info,
    std::string* error_html) {
  if (error_html && error_html->empty()) {
#if BUILDFLAG(IS_IOS)
    const GURL url(error.url());
    *error_html = BlinkerErrorPageHtml(
        error.reason(), 0, net::ErrorToString(error.reason()), url.host(),
        render_frame && render_frame->IsMainFrame(),
        BlinkerInterfaceLanguage(),
        [](std::string_view text) { return BlinkerLocalizedUTF8(text); });
#else
    *error_html =
        "<head><title>Error</title></head><body>Could not load the requested "
        "resource.<br/>Error code: " +
        base::NumberToString(error.reason()) +
        (error.reason() < 0 ? " (" + net::ErrorToString(error.reason()) + ")"
                            : "") +
        "</body>";
#endif
  }
}

void ShellContentRendererClient::PrepareErrorPageForHttpStatusError(
    content::RenderFrame* render_frame,
    const blink::WebURLError& error,
    const std::string& http_method,
    int http_status,
    content::mojom::AlternativeErrorPageOverrideInfoPtr
        alternative_error_page_info,
    std::string* error_html) {
  if (error_html) {
#if BUILDFLAG(IS_IOS)
    const GURL url(error.url());
    *error_html = BlinkerErrorPageHtml(
        error.reason(), http_status, std::string(), url.host(),
        render_frame && render_frame->IsMainFrame(),
        BlinkerInterfaceLanguage(),
        [](std::string_view text) { return BlinkerLocalizedUTF8(text); });
#else
    *error_html =
        "<head><title>Error</title></head><body>Server returned HTTP status " +
        base::NumberToString(http_status) + "</body>";
#endif
  }
}

void ShellContentRendererClient::DidInitializeWorkerContextOnWorkerThread(
    v8::Local<v8::Context> context) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kExposeInternalsForTesting)) {
    blink::WebTestingSupport::InjectInternalsObject(context);
  }
}

std::unique_ptr<blink::URLLoaderThrottleProvider>
ShellContentRendererClient::CreateURLLoaderThrottleProvider(
    blink::URLLoaderThrottleProviderType provider_type) {
  return std::make_unique<ShellContentRendererUrlLoaderThrottleProvider>();
}

#if BUILDFLAG(ENABLE_MOJO_CDM)
std::unique_ptr<media::KeySystemSupportRegistration>
ShellContentRendererClient::GetSupportedKeySystems(
    content::RenderFrame* render_frame,
    media::GetSupportedKeySystemsCB cb) {
  media::KeySystemInfos key_systems;
  if (base::FeatureList::IsEnabled(media::kExternalClearKeyForTesting))
    key_systems.push_back(
        std::make_unique<cdm::ExternalClearKeyKeySystemInfo>());
  std::move(cb).Run(std::move(key_systems), /*pending_key_systems=*/{});
  return nullptr;
}
#endif

std::unique_ptr<blink::WebPrescientNetworking>
ShellContentRendererClient::CreatePrescientNetworking(
    RenderFrame* render_frame) {
  return std::make_unique<network_hints::WebPrescientNetworkingImpl>(
      render_frame);
}


namespace {

GURL DocumentUrl(const blink::WebLocalFrame* frame) {
  GURL url(frame->GetDocument().Url());
  return url.is_empty() ? GURL(url::kAboutBlankURL) : url;
}

// Порожній документ, який оболонка кладе під рідну стартову сторінку, коли
// розширення малюють у ній (Shell::LoadURLForFrame). Хост ніколи не
// розв'язується, тож справжня сторінка не може тут опинитись.
bool IsStartPageFrame(const blink::WebLocalFrame* frame) {
  return !frame->Parent() && DocumentUrl(frame) == GURL(kBlinkerStartPageUrl);
}

BlinkerFrameUrls FrameUrlsForInjection(const blink::WebLocalFrame* frame) {
  BlinkerFrameUrls urls;
  if (IsStartPageFrame(frame)) {
    urls.document = GURL(kBlinkerStartPageUrl);
    urls.start_page = true;
    return urls;
  }
  urls.document = DocumentUrl(frame);
  const GURL& document = urls.document;
  const bool is_about = document.SchemeIs(url::kAboutScheme);
  if (!is_about && !document.SchemeIs(url::kDataScheme) &&
      !document.SchemeIsBlob() && !document.SchemeIsFileSystem()) {
    return urls;
  }
  const url::Origin origin = frame->GetSecurityOrigin();
  const url::SchemeHostPort& tuple = origin.GetTupleOrPrecursorTupleIfOpaque();
  if (!tuple.IsValid()) {
    return urls;
  }
  urls.origin = tuple.GetURL();
  if (!is_about) {
    return urls;
  }
  base::flat_set<const blink::WebFrame*> visited;
  const blink::WebFrame* current = frame;
  while (visited.insert(current).second) {
    const blink::WebFrame* next =
        current->Parent() ? current->Parent() : current->Opener();
    if (!next || !next->IsWebLocalFrame()) {
      break;
    }
    const blink::WebLocalFrame* local = next->ToWebLocalFrame();
    if (local->GetDocument().IsNull() ||
        url::Origin(local->GetSecurityOrigin())
                .GetTupleOrPrecursorTupleIfOpaque() != tuple) {
      break;
    }
    GURL url = DocumentUrl(local);
    if (!url.SchemeIs(url::kAboutScheme)) {
      urls.about_parent = std::move(url);
      break;
    }
    current = next;
  }
  return urls;
}

void RunBlinkerContentScripts(RenderFrame* render_frame,
                              BlinkerContentScript::RunAt run_at) {
  if (!render_frame) {
    return;
  }
  blink::WebLocalFrame* frame = render_frame->GetWebFrame();
  if (!frame) {
    return;
  }
  // Blink кличе синхронно з appendChild іншого скрипта. Початковий документ
  // нового фрейму не чіпаєм, бо шім ставить міст у міст до кінця купи V8
  static int injection_depth = 0;
  const GURL document_url(frame->GetDocument().Url());
  const bool initial_document =
      document_url.is_empty() || document_url.IsAboutBlank();
  // Сам міст chrome.* не потребує. Шім сторінки розширення в ньому
  // першим відповідав воркеру noReceiver і tabs.sendMessage не доходив
  const bool bridge_document =
      document_url.SchemeIs(kBlinkerExtensionScheme) &&
      document_url.path() == base::StrCat({"/", kBlinkerBridgePath});
  if (bridge_document ||
      (initial_document &&
       (injection_depth > 0 ||
        frame->AssignedName().Utf8() == "__blinker_bridge"))) {
    return;
  }
  base::AutoReset<int> depth_scope(&injection_depth, injection_depth + 1);
  BlinkerWebExtensionRegistry& registry =
      BlinkerWebExtensionRegistry::GetInstance();
  registry.MarkRendererInjectionActive();
  // RunScriptsAtDocumentIdle приходить десятки разів на секунду,
  // тому скрипт раз на window
  if (ShellRenderFrameObserver* observer =
          ShellRenderFrameObserver::ForFrame(render_frame)) {
    if (!observer->FirstInjectionForWindow(static_cast<int>(run_at))) {
      return;
    }
  }
  std::vector<BlinkerWebExtensionRegistry::PreparedInjection> injections =
      registry.PrepareInjections(FrameUrlsForInjection(frame), run_at,
                                 render_frame->IsMainFrame());
  for (const auto& injection : injections) {
    const std::string& program = injection.program->as_string();
    if (injection.is_css) {
      frame->GetDocument().InsertStyleSheet(
          blink::WebString::FromUtf8(program));
      continue;
    }
    const blink::WebScriptSource source(blink::WebString::FromUtf8(program));
    if (injection.world_id == kBlinkerMainWorldId) {
      frame->ExecuteScript(source);
    } else {
      frame->ExecuteScriptInIsolatedWorld(injection.world_id, source,
                                          blink::BackForwardCacheAware::kAllow);
    }
  }
}

std::string BlinkerStringPref(const char* name) {
#if BUILDFLAG(IS_IOS)
  CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, name,
                                              kCFStringEncodingUTF8);
  if (!key) {
    return std::string();
  }
  CFPropertyListRef value =
      CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication);
  CFRelease(key);
  if (!value) {
    return std::string();
  }
  std::string out;
  if (CFGetTypeID(value) == CFStringGetTypeID()) {
    char buffer[32] = {};
    if (CFStringGetCString(static_cast<CFStringRef>(value), buffer,
                           sizeof(buffer), kCFStringEncodingUTF8)) {
      out = buffer;
    }
  }
  CFRelease(value);
  return out;
#else
  return std::string();
#endif
}

bool RainbowCaretEnabled() {
  return BlinkerStringPref(kBlinkerSelectionColorKey) ==
         kBlinkerSelectionRainbow;
}

void ApplyBlinkerSelectionColor(RenderFrame* render_frame) {
  blink::WebLocalFrame* frame = render_frame->GetWebFrame();
  if (!frame || frame->GetDocument().IsNull() ||
      !BlinkerWebColorsApplyTo(GURL(frame->GetDocument().Url()))) {
    return;
  }
  const std::string css =
      BlinkerSelectionCss(BlinkerStringPref(kBlinkerSelectionColorKey));
  if (css.empty()) {
    return;
  }
  // Стиль авторського рівня, бо підсвітка виділення з таблиці користувача
  // не малюється хоч getComputedStyle її бачить
  const blink::WebStyleSheetKey key =
      blink::WebString::FromUtf8(kBlinkerSelectionSheetKey);
  frame->GetDocument().InsertStyleSheet(blink::WebString::FromUtf8(css), &key,
                                        blink::WebCssOrigin::kAuthor);
}

void ApplyBlinkerWebColors(RenderFrame* render_frame) {
  blink::WebLocalFrame* frame = render_frame->GetWebFrame();
  if (!frame || frame->GetDocument().IsNull() ||
      !BlinkerWebColorsApplyTo(GURL(frame->GetDocument().Url()))) {
    return;
  }
  const std::string css =
      BlinkerWebColorsCss(BlinkerStringPref(kBlinkerWebTextColorKey),
                          BlinkerStringPref(kBlinkerWebLinkColorKey));
  if (css.empty()) {
    return;
  }
  const blink::WebStyleSheetKey key =
      blink::WebString::FromUtf8(kBlinkerWebColorsSheetKey);
  frame->GetDocument().InsertStyleSheet(blink::WebString::FromUtf8(css), &key,
                                        blink::WebCssOrigin::kUser);
}

}  // namespace

void ShellContentRendererClient::RunScriptsAtDocumentStart(
    RenderFrame* render_frame) {
  ApplyBlinkerWebColors(render_frame);
  ApplyBlinkerSelectionColor(render_frame);
  // Кольорова каретка блимає і в згаслій фазі проступала б каретка рушія
  if (ShellRenderFrameObserver* observer =
          ShellRenderFrameObserver::ForFrame(render_frame)) {
    observer->SetEngineCaretHidden(RainbowCaretEnabled());
  }
  RunBlinkerContentScripts(render_frame,
                           BlinkerContentScript::RunAt::kDocumentStart);
}

void ShellContentRendererClient::RunScriptsAtDocumentEnd(
    RenderFrame* render_frame) {
  RunBlinkerContentScripts(render_frame,
                           BlinkerContentScript::RunAt::kDocumentEnd);
}

void ShellContentRendererClient::RunScriptsAtDocumentIdle(
    RenderFrame* render_frame) {
  RunBlinkerContentScripts(render_frame,
                           BlinkerContentScript::RunAt::kDocumentIdle);
}

}  // namespace content
