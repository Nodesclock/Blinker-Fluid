// Copyright 2013 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_content_browser_client.h"

#include "build/build_config.h"
#if BUILDFLAG(IS_IOS)
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/blinker_tracking_params.h"
#include "content/shell/browser/blinker_extensions.h"
#endif

#include <stddef.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/containers/fixed_flat_set.h"
#include "base/containers/flat_set.h"
#include "base/feature_list.h"
#include "base/files/file.h"
#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/threading/sequence_local_storage_slot.h"
#include "build/build_config.h"
#include "cc/base/switches.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/custom_handlers/protocol_handler_throttle.h"
#include "components/custom_handlers/simple_protocol_handler_registry_factory.h"
#include "components/embedder_support/switches.h"
#include "components/embedder_support/user_agent_utils.h"
#include "components/metrics/client_info.h"
#include "components/metrics/metrics_service.h"
#include "components/network_hints/browser/simple_network_hints_handler_impl.h"
#include "components/performance_manager/embedder/binders.h"
#include "components/performance_manager/embedder/performance_manager_registry.h"
#include "components/prefs/json_pref_store.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service_factory.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "components/surface_embed/common/surface_embed.mojom.h"
#include "components/variations/service/variations_service.h"
#include "content/public/browser/client_certificate_delegate.h"
#include "content/public/browser/digital_identity_provider.h"
#include "content/public/browser/login_delegate.h"
#include "content/public/browser/navigation_throttle.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_util.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/network_service_instance.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/security_principal.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_view_delegate.h"
#include "content/public/common/content_features.h"
#include "content/public/common/content_switches.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/common/url_constants.h"
#include "content/public/test/setup_field_trials.h"
#include "content/shell/browser/rust_test_service_ffi.rs.h"
#include "content/shell/browser/shell.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/shell/browser/blinker_crx_installer.h"
#include "content/shell/browser/blinker_extension_net_actions.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_extension_url_loader_factory.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_browser_main_parts.h"
#include "content/shell/browser/shell_devtools_manager_delegate.h"
#include "content/shell/browser/shell_web_contents_view_delegate_creator.h"
#include "content/shell/common/blinker_low_memory.h"
#include "content/shell/common/rust_test.test-mojom.h"
#include "content/shell/common/shell_controller.test-mojom.h"
#include "content/shell/common/shell_paths.h"
#include "content/shell/common/shell_switches.h"
#include "media/mojo/buildflags.h"
#include "media/mojo/mojom/media_service.mojom.h"
#include "mojo/public/cpp/bindings/binder_map.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/bindings/self_owned_receiver.h"
#include "net/base/features.h"
#include "net/dns/public/dns_over_https_config.h"
#include "net/dns/public/insecure_dns_mode.h"
#include "net/dns/public/secure_dns_mode.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_config_with_annotation.h"
#include "net/ssl/client_cert_identity.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#if BUILDFLAG(IS_IOS)
#include <CoreFoundation/CoreFoundation.h>
#endif
#include "content/public/browser/browser_context.h"
#include "services/device/public/cpp/geolocation/location_system_permission_status.h"
#include "services/network/public/cpp/features.h"
#include "services/network/public/cpp/network_service_buildflags.h"
#include "services/network/public/cpp/permissions_policy/permissions_policy_declaration.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/transferable_directory.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/network_service.mojom.h"
#include "services/network/public/mojom/permissions_policy/permissions_policy_feature.mojom-shared.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "third_party/blink/public/common/features.h"
#include "third_party/blink/public/common/switches.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom.h"
#include "ui/base/ui_base_features.h"
#include "ui/base/ui_base_switches.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/url_canon.h"
#include "url/url_constants.h"

#if BUILDFLAG(IS_ANDROID)
#include "base/android/apk_assets.h"
#include "base/android/path_utils.h"
#include "base/memory/weak_ptr.h"
#include "content/shell/android/shell_descriptors.h"
#endif

#if BUILDFLAG(IS_ANDROID)
#include "components/crash/content/browser/crash_handler_host_linux.h"
#endif

#if BUILDFLAG(IS_MAC)
#include "services/device/public/cpp/test/fake_geolocation_system_permission_manager.h"
#endif

#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID)
#include "components/crash/core/app/crash_switches.h"
#include "components/crash/core/app/crashpad.h"
#include "content/public/common/content_descriptors.h"
#endif

#if BUILDFLAG(ENABLE_CAST_RENDERER)
#include "media/mojo/services/media_service_factory.h"  // nogncheck
#endif

#if BUILDFLAG(IS_CT_SUPPORTED)
#include "services/network/public/mojom/ct_log_info.mojom.h"
#endif

#if BUILDFLAG(IS_IOS)
#include "base/i18n/language_tag.h"
#include "base/i18n/tag_converters.h"
#include "components/application_locale_storage/application_locale_storage.h"  // nogncheck
#include "components/permissions/bluetooth_delegate_impl.h"
#include "content/shell/browser/bluetooth/shell_bluetooth_delegate_impl_client.h"
#include "ui/base/l10n/l10n_util_mac.h"
#endif

#if BUILDFLAG(IS_WIN)
#include "media/mojo/mojom/media_foundation_preferences.mojom.h"
#include "media/mojo/services/media_foundation_preferences.h"
#endif  // BUILDFLAG(IS_WIN)

#if BUILDFLAG(IS_IOS)
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_proxy_config.h"
#endif

namespace content {

namespace {

#if BUILDFLAG(IS_IOS)
#endif

using PerformanceManagerRegistry =
    performance_manager::PerformanceManagerRegistry;

// Tests may install their own ShellContentBrowserClient, track the list here.
// The list is ordered with oldest first and newer ones added after it.
std::vector<ShellContentBrowserClient*>&
GetShellContentBrowserClientInstancesImpl() {
  static base::NoDestructor<std::vector<ShellContentBrowserClient*>> instances;
  return *instances;
}

#if BUILDFLAG(IS_ANDROID)
int GetCrashSignalFD(const base::CommandLine& command_line) {
  return crashpad::CrashHandlerHost::Get()->GetDeathSignalSocket();
}
#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
int GetCrashSignalFD(const base::CommandLine& command_line) {
  int fd;
  pid_t pid;
  return crash_reporter::GetHandlerSocket(&fd, &pid) ? fd : -1;
}
#endif

class ShellControllerImpl : public mojom::ShellController {
 public:
  ShellControllerImpl() = default;
  ~ShellControllerImpl() override = default;

  // mojom::ShellController:
  void GetSwitchValue(const std::string& name,
                      GetSwitchValueCallback callback) override {
    const auto& command_line = *base::CommandLine::ForCurrentProcess();
    if (command_line.HasSwitch(name)) {
      std::move(callback).Run(command_line.GetSwitchValueASCII(name));
    } else {
      std::move(callback).Run(std::nullopt);
    }
  }

  void ExecuteJavaScript(const std::u16string& script,
                         ExecuteJavaScriptCallback callback) override {
    CHECK(!Shell::windows().empty());
    WebContents* contents = Shell::windows()[0]->web_contents();
    contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
        script, std::move(callback), ISOLATED_WORLD_ID_GLOBAL);
  }

  void ShutDown() override { Shell::Shutdown(); }
};

void BindRustTestServiceReceiver(
    RenderFrameHost* render_frame_host,
    mojo::PendingReceiver<content::rust_test::mojom::RustTestService>
        receiver) {
  auto pipe = std::make_unique<mojo::rust::ScopedMessagePipeHandleWrapper>(
      receiver.PassPipe());
  content::rust_test::BindRustTestService(std::move(pipe));
}

void BindNetworkHintsHandler(
    content::RenderFrameHost* frame_host,
    mojo::PendingReceiver<network_hints::mojom::NetworkHintsHandler> receiver) {
  DCHECK(frame_host);
  network_hints::SimpleNetworkHintsHandlerImpl::Create(frame_host,
                                                       std::move(receiver));
}

#if BUILDFLAG(IS_WIN)
void BindMediaFoundationPreferences(
    content::RenderFrameHost* frame_host,
    mojo::PendingReceiver<media::mojom::MediaFoundationPreferences> receiver) {
  // Passing in a NullCallback since we don't have MediaFoundationServiceMonitor
  // in content.
  MediaFoundationPreferencesImpl::Create(frame_host->GetSiteInstance()
                                             ->GetSecurityPrincipal()
                                             .GetDeprecatedSiteURL(),
                                         base::NullCallback(),
                                         std::move(receiver));
}
#endif  // BUILDFLAG(IS_WIN)

base::flat_set<url::Origin> GetIsolatedContextOriginSetFromFlag() {
  std::string cmdline_origins(
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kIsolatedContextOrigins));

  std::vector<std::string_view> origin_strings = base::SplitStringPiece(
      cmdline_origins, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);

  base::flat_set<url::Origin> origin_set;
  for (std::string_view origin_string : origin_strings) {
    url::Origin allowed_origin = url::Origin::Create(GURL(origin_string));
    if (!allowed_origin.opaque()) {
      origin_set.insert(allowed_origin);
    } else {
      LOG(ERROR) << "Error parsing IsolatedContext origin: " << origin_string;
    }
  }
  return origin_set;
}

// In content browser tests we allow more than one ShellContentBrowserClient
// to be created (actually, ContentBrowserTestContentBrowserClient). Any state
// needed should be added here so that it's shared between the instances.
struct SharedState {
  SharedState() {
#if BUILDFLAG(IS_MAC)
    location_manager =
        std::make_unique<device::FakeGeolocationSystemPermissionManager>();
    location_manager->SetSystemPermission(
        device::LocationSystemPermissionStatus::kAllowed);
#endif
  }

#if BUILDFLAG(IS_MAC)
  std::unique_ptr<device::FakeGeolocationSystemPermissionManager>
      location_manager;
#endif

  // Owned by content::BrowserMainLoop.
  raw_ptr<ShellBrowserMainParts, DanglingUntriaged> shell_browser_main_parts =
      nullptr;

  std::unique_ptr<PrefService> local_state;
};

SharedState& GetSharedState() {
  static SharedState* g_shared_state = nullptr;
  if (!g_shared_state) {
    g_shared_state = new SharedState();
  }
  return *g_shared_state;
}

std::unique_ptr<PrefService> CreateLocalState() {
  auto pref_registry = base::MakeRefCounted<PrefRegistrySimple>();
  metrics::MetricsService::RegisterPrefs(pref_registry.get());
  variations::VariationsService::RegisterPrefs(pref_registry.get());

  base::FilePath path;
  CHECK(base::PathService::Get(SHELL_DIR_USER_DATA, &path));
  path = path.AppendASCII("Local State");

  PrefServiceFactory pref_service_factory;
  pref_service_factory.set_user_prefs(
      base::MakeRefCounted<JsonPrefStore>(path));

  return pref_service_factory.Create(pref_registry);
}

bool AreIsolatedWebAppsEnabled() {
  return base::FeatureList::IsEnabled(features::kIsolatedWebApps);
}

// A dummy DigitalIdentityProvider that hangs (never invokes the callback) to
// simulate the browser waiting for user interaction on the selection UI.
// This is the default expectation for Digital Credential APIs in WPTs when
// no user interaction is simulated.
class ShellDigitalIdentityProvider : public content::DigitalIdentityProvider {
 public:
  ShellDigitalIdentityProvider() = default;
  ~ShellDigitalIdentityProvider() override = default;

  bool IsLastCommittedOriginLowRisk(
      content::RenderFrameHost& render_frame_host) const override {
    return false;
  }

  DigitalIdentityInterstitialAbortCallback ShowDigitalIdentityInterstitial(
      content::WebContents& web_contents,
      const url::Origin& origin,
      content::DigitalIdentityInterstitialType interstitial_type,
      DigitalIdentityInterstitialCallback callback) override {
    return base::OnceClosure();
  }

  void Get(content::WebContents* web_contents,
           const url::Origin& origin,
           base::ValueView request,
           DigitalIdentityCallback callback) override {}

  void Create(content::WebContents* web_contents,
              const url::Origin& origin,
              base::ValueView request,
              DigitalIdentityCallback callback) override {}
};

}  // namespace

std::string GetShellLanguage() {
#if BUILDFLAG(IS_IOS)
  CFStringRef key = CFSTR("BlinkLanguageAccept");
  CFPropertyListRef value =
      CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication);
  if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
    char buffer[128] = {};
    if (CFStringGetCString(static_cast<CFStringRef>(value), buffer,
                           sizeof(buffer), kCFStringEncodingUTF8)) {
      CFRelease(value);
      return buffer;
    }
  }
  if (value) {
    CFRelease(value);
  }
#endif
#if BUILDFLAG(IS_IOS)
  // Малі літери в регіоні видають автоматизацію, Chrome пише en-US
  return "en-US,en";
#else
  return "en-us,en";
#endif
}

blink::UserAgentMetadata GetShellUserAgentMetadata() {
  blink::UserAgentMetadata metadata;

#if BUILDFLAG(IS_IOS)
  // Тут Blink, а не WebKit, і CriOS з DOM Chromium дає неможливий відбиток, на
  // який реагують перевірки на ботів. Тому ідентичність мобільного Chromium.
  metadata.brand_version_list.emplace_back("Chromium",
                                           CONTENT_SHELL_MAJOR_VERSION);
  metadata.brand_version_list.emplace_back("Google Chrome",
                                           CONTENT_SHELL_MAJOR_VERSION);
  metadata.brand_version_list.emplace_back("Not-A.Brand", "99");
  metadata.brand_full_version_list.emplace_back("Chromium",
                                                CONTENT_SHELL_VERSION);
  metadata.brand_full_version_list.emplace_back("Google Chrome",
                                                CONTENT_SHELL_VERSION);
  metadata.brand_full_version_list.emplace_back("Not-A.Brand", "99.0.0.0");
  metadata.full_version = CONTENT_SHELL_VERSION;
  metadata.platform = "Android";
  metadata.platform_version = "15.0.0";
  metadata.architecture = "arm";
  metadata.model = "Pixel 8";
  metadata.mobile = true;
  metadata.bitness = "";
  metadata.wow64 = false;
  metadata.form_factors = {"Mobile"};
#else
  metadata.brand_version_list.emplace_back("content_shell",
                                           CONTENT_SHELL_MAJOR_VERSION);
  metadata.brand_full_version_list.emplace_back("content_shell",
                                                CONTENT_SHELL_VERSION);
  metadata.full_version = CONTENT_SHELL_VERSION;
  metadata.platform = "Unknown";
  metadata.architecture = embedder_support::GetCpuArchitecture();
  metadata.model = embedder_support::BuildModelInfo();

  metadata.bitness = embedder_support::GetCpuBitness();
  metadata.wow64 = embedder_support::IsWoW64();
  metadata.form_factors = {"Desktop"};
#endif

  return metadata;
}

ShellContentBrowserClient* ShellContentBrowserClient::Get() {
  auto& instances = GetShellContentBrowserClientInstancesImpl();
  return instances.empty() ? nullptr : instances.back();
}

ShellContentBrowserClient::ShellContentBrowserClient() {
  GetShellContentBrowserClientInstancesImpl().push_back(this);
#if BUILDFLAG(IS_IOS)
  // Блоклист реклами заповнюєм на старті, щоб перший запит вже був покритий.
  BlinkerContentFilter::GetInstance().EnsureLoaded();
  if (CFPropertyListRef saved =
          CFPreferencesCopyAppValue(CFSTR("BlinkAdBlockAllowedHosts"),
                                    kCFPreferencesCurrentApplication)) {
    if (CFGetTypeID(saved) == CFArrayGetTypeID()) {
      CFArrayRef hosts = static_cast<CFArrayRef>(saved);
      for (CFIndex i = 0; i < CFArrayGetCount(hosts); ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(hosts, i);
        char host[1024] = {};
        if (CFGetTypeID(value) == CFStringGetTypeID() &&
            CFStringGetCString(static_cast<CFStringRef>(value), host,
                               sizeof(host), kCFStringEncodingUTF8)) {
          BlinkerContentFilter::GetInstance().SetHostAllowlisted(host, true);
        }
      }
    }
    CFRelease(saved);
  }
#endif
}

ShellContentBrowserClient::~ShellContentBrowserClient() {
  std::erase(GetShellContentBrowserClientInstancesImpl(), this);
}

std::unique_ptr<BrowserMainParts>
ShellContentBrowserClient::CreateBrowserMainParts(
    bool /* is_integration_test */) {
  auto browser_main_parts = std::make_unique<ShellBrowserMainParts>();
  DCHECK(!GetSharedState().shell_browser_main_parts);
  GetSharedState().shell_browser_main_parts = browser_main_parts.get();
  return browser_main_parts;
}

bool ShellContentBrowserClient::HasCustomSchemeHandler(
    content::BrowserContext* browser_context,
    const std::string& scheme) {
  if (custom_handlers::ProtocolHandlerRegistry* protocol_handler_registry =
          custom_handlers::SimpleProtocolHandlerRegistryFactory::
              GetForBrowserContext(browser_context)) {
    return protocol_handler_registry->IsHandledProtocol(scheme);
  }
  return false;
}

std::vector<std::unique_ptr<blink::URLLoaderThrottle>>
ShellContentBrowserClient::CreateURLLoaderThrottles(
    const network::ResourceRequest& request,
    BrowserContext* browser_context,
    const base::RepeatingCallback<WebContents*()>& wc_getter,
    NavigationUIData* navigation_ui_data,
    FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id) {
  std::vector<std::unique_ptr<blink::URLLoaderThrottle>> result;

#if BUILDFLAG(IS_IOS)
  // Фільтр ще раз тут, бо конструктор клієнта міг відпрацювати зарано. Це
  // остання точка до першого запиту.
  BlinkerContentFilter::GetInstance().EnsureLoaded();
  // Коли фільтр вимкнений, throttle коштує одне атомарне читання.
  result.push_back(std::make_unique<BlinkerContentFilterThrottle>());
  if (request.destination == network::mojom::RequestDestination::kDocument) {
    result.push_back(std::make_unique<BlinkerTrackingParamThrottle>());
  }
#endif

  auto* factory = custom_handlers::SimpleProtocolHandlerRegistryFactory::
      GetForBrowserContext(browser_context);
  // null in unit tests.
  if (factory) {
    result.push_back(
        std::make_unique<custom_handlers::ProtocolHandlerThrottle>(*factory));
  }

  return result;
}

bool ShellContentBrowserClient::IsHandledURL(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  constexpr auto kProtocolList = base::MakeFixedFlatSet<std::string_view>({
      url::kHttpScheme,
      url::kHttpsScheme,
      url::kWsScheme,
      url::kWssScheme,
      url::kBlobScheme,
      url::kFileSystemScheme,
      kChromeUIScheme,
      kChromeUIUntrustedScheme,
      kChromeDevToolsScheme,
      url::kDataScheme,
      url::kFileScheme,
  });

  return kProtocolList.contains(url.scheme());
}

bool ShellContentBrowserClient::AreIsolatedWebAppsEnabled(
    BrowserContext* browser_context) {
  return ::content::AreIsolatedWebAppsEnabled();
}

void ShellContentBrowserClient::AppendExtraCommandLineSwitches(
    base::CommandLine* command_line,
    int child_process_id) {
  static const char* const kForwardSwitches[] = {
#if BUILDFLAG(IS_MAC)
      // Needed since on Mac, content_browsertests doesn't use
      // content_test_launcher.cc and instead uses shell_main.cc. So give a
      // signal
      // to shell_main.cc that it's a browser test.
      switches::kBrowserTest,
#endif
      switches::kCrashDumpsDir,
      switches::kEnableCrashReporter,
      switches::kExposeInternalsForTesting,
      switches::kRunWebTests,
      switches::kTestRegisterStandardScheme,
  };

  command_line->CopySwitchesFrom(*base::CommandLine::ForCurrentProcess(),
                                 kForwardSwitches);

#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kEnableCrashReporter)) {
    int fd;
    pid_t pid;
    if (crash_reporter::GetHandlerSocket(&fd, &pid)) {
      command_line->AppendSwitchASCII(
          crash_reporter::switches::kCrashpadHandlerPid,
          base::NumberToString(pid));
    }
  }
#endif  // BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)

  if (command_line->GetSwitchValueASCII(switches::kProcessType) ==
          switches::kRendererProcess &&
      ::content::AreIsolatedWebAppsEnabled()) {
    command_line->AppendSwitch(switches::kEnableIsolatedWebAppsInRenderer);
  }
}

device::GeolocationSystemPermissionManager*
ShellContentBrowserClient::GetGeolocationSystemPermissionManager() {
#if BUILDFLAG(IS_MAC)
  return GetSharedState().location_manager.get();
#elif BUILDFLAG(IS_IOS)
  // TODO(crbug.com/1431447, 1411704): Unify this to
  // FakeGeolocationSystemPermissionManager once exploring browser features in
  // ContentShell on iOS is done.
  return GetSharedState()
      .shell_browser_main_parts->GetGeolocationSystemPermissionManager();
#else
  return nullptr;
#endif
}

std::string ShellContentBrowserClient::GetAcceptLangs(BrowserContext* context) {
  return GetShellLanguage();
}

void ShellContentBrowserClient::UpdateRendererPreferencesForWorker(
    BrowserContext* browser_context,
    blink::RendererPreferences* out_prefs) {
  out_prefs->accept_languages = GetShellLanguage();
}

std::string ShellContentBrowserClient::GetDefaultDownloadName() {
  return "download";
}

std::unique_ptr<WebContentsViewDelegate>
ShellContentBrowserClient::GetWebContentsViewDelegate(
    WebContents* web_contents) {
  return CreateShellWebContentsViewDelegate(web_contents);
}

bool ShellContentBrowserClient::ShouldUrlUseApplicationIsolationLevel(
    BrowserContext* browser_context,
    const GURL& url) {
  if (!isolated_context_origins_) {
    isolated_context_origins_ = GetIsolatedContextOriginSetFromFlag();
  }

  GURL::Replacements replacements;
  replacements.ClearPort();
  return isolated_context_origins_->contains(
      url::Origin::Create(url.ReplaceComponents(replacements)));
}

GeneratedCodeCacheSettings
ShellContentBrowserClient::GetGeneratedCodeCacheSettings(
    content::BrowserContext* context) {
  // Дані OTR не мають потрапити в постійний code cache.
  if (context->IsOffTheRecord()) {
    return GeneratedCodeCacheSettings(false, 0, base::FilePath());
  }
  // If we pass 0 for size, disk_cache will pick a default size using the
  // heuristics based on available disk size. These are implemented in
  // disk_cache::PreferredCacheSize in net/disk_cache/cache_util.cc.
  return GeneratedCodeCacheSettings(true, 0, context->GetPath());
}

base::OnceClosure ShellContentBrowserClient::SelectClientCertificate(
    BrowserContext* browser_context,
    ChildProcessId process_id,
    WebContents* web_contents,
    net::SSLCertRequestInfo* cert_request_info,
    net::ClientCertIdentityList client_certs,
    std::unique_ptr<ClientCertificateDelegate> delegate) {
  if (select_client_certificate_callback_ && web_contents) {
    return std::move(select_client_certificate_callback_)
        .Run(web_contents, cert_request_info, std::move(client_certs),
             std::move(delegate));
  }
  return base::OnceClosure();
}

SpeechRecognitionManagerDelegate*
ShellContentBrowserClient::CreateSpeechRecognitionManagerDelegate() {
  return new ShellSpeechRecognitionManagerDelegate();
}

// Ставить iOS UI вигляду, 0 за замовчуванням, 1 світла, 2 темна.
int g_blink_preferred_color_scheme = 0;

// Client hints UA під режим сайту, щоб Sec-CH-UA-Mobile і platform збігались
// з UA від toggleDesktopSite. Його бере і shell_platform_delegate_ios.mm.
blink::UserAgentMetadata GetShellUserAgentMetadataForSiteMode(bool desktop) {
  blink::UserAgentMetadata metadata = GetShellUserAgentMetadata();
  if (desktop) {
    metadata.platform = "macOS";
    metadata.platform_version = "10.15.7";
    metadata.architecture = "x86";
    metadata.model = "";
    metadata.mobile = false;
    metadata.bitness = "64";
    metadata.form_factors = {"Desktop"};
  }
  return metadata;
}

void ShellContentBrowserClient::OverrideWebPreferences(
    WebContents* web_contents,
    SiteInstance& main_frame_site,
    blink::web_pref::WebPreferences* prefs) {
  // content_shell жорстко ставить світлу prefers-color-scheme, а тут береться
  // вибір користувача, щоб сайти малювали свою темну тему.
  const bool dark = g_blink_preferred_color_scheme == 2 ||
                    base::CommandLine::ForCurrentProcess()->HasSwitch(
                        switches::kForceDarkMode);
  prefs->preferred_color_scheme =
      dark ? blink::mojom::PreferredColorScheme::kDark
           : blink::mojom::PreferredColorScheme::kLight;

  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          switches::kForceHighContrast)) {
    prefs->in_forced_colors = true;
    prefs->preferred_contrast = blink::mojom::PreferredContrast::kMore;
  } else {
    prefs->in_forced_colors = false;
    prefs->preferred_contrast = blink::mojom::PreferredContrast::kNoPreference;
  }

  prefs->double_tap_to_zoom_enabled = false;

#if BUILDFLAG(IS_IOS)
  // Повна версія сайту для вкладки. Ігнорує мобільний <meta viewport> і верстає
  // на ширину 980 CSS px, зменшену під екран. Ці 980 дає лише мобільний стиль
  // viewport, з kDefault ширина була ширина екрана і сайт лишався мобільним.
  const bool desktop = BlinkIsDesktopSite(web_contents);
  // Інакше Chromium вимикає viewport meta для кожного не Android UA override,
  // в тому числі для мобільного Safari під час старої автентифікації.
  prefs->viewport_meta_enabled = !desktop;
  if (desktop) {
    prefs->shrinks_viewport_contents_to_fit = true;
  }
#endif
}

std::unique_ptr<content::DevToolsManagerDelegate>
ShellContentBrowserClient::CreateDevToolsManagerDelegate() {
  return std::make_unique<ShellDevToolsManagerDelegate>(browser_context());
}

void ShellContentBrowserClient::ExposeInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    blink::AssociatedInterfaceRegistry* associated_registry,
    RenderProcessHost* render_process_host) {
  PerformanceManagerRegistry::GetInstance()->CreateProcessNode(
      render_process_host);
  PerformanceManagerRegistry::GetInstance()
      ->GetBinders()
      .ExposeInterfacesToRendererProcess(registry, render_process_host);
}

void ShellContentBrowserClient::ExposeInterfacesToChild(
    mojo::BinderMapWithContext<content::BrowserChildProcessHost*>* map) {
  PerformanceManagerRegistry::GetInstance()
      ->GetBinders()
      .ExposeInterfacesToBrowserChildProcess(map);
}

mojo::Remote<::media::mojom::MediaService>
ShellContentBrowserClient::RunSecondaryMediaService() {
  mojo::Remote<::media::mojom::MediaService> remote;
#if BUILDFLAG(ENABLE_CAST_RENDERER)
  static base::SequenceLocalStorageSlot<std::unique_ptr<::media::MediaService>>
      service;
  service.emplace(::media::CreateMediaServiceForTesting(
      remote.BindNewPipeAndPassReceiver()));
#endif
  return remote;
}

void ShellContentBrowserClient::RegisterBrowserInterfaceBindersForFrame(
    RenderFrameHost* render_frame_host,
    mojo::BinderMapWithContext<RenderFrameHost*>* map) {
  PerformanceManagerRegistry::GetInstance()
      ->GetBinders()
      .ExposeInterfacesToRenderFrame(map);
  map->Add<network_hints::mojom::NetworkHintsHandler>(&BindNetworkHintsHandler);
  map->Add<content::rust_test::mojom::RustTestService>(
      base::BindRepeating(&BindRustTestServiceReceiver));
#if BUILDFLAG(IS_WIN)
  map->Add<media::mojom::MediaFoundationPreferences>(
      &BindMediaFoundationPreferences);
#endif  // BUILDFLAG(IS_WIN)
}

void ShellContentBrowserClient::
    RegisterAssociatedInterfaceBindersForRenderFrameHost(
        RenderFrameHost&,
        blink::AssociatedInterfaceRegistry& associated_registry) {
  associated_registry.AddInterface<surface_embed::mojom::SurfaceEmbedHost>(
      base::BindRepeating(
          [](mojo::PendingAssociatedReceiver<
              surface_embed::mojom::SurfaceEmbedHost> receiver) {
            // Since ShellContentRenderClient can try to create a
            // SurfaceEmbedWebPlugin on any page, we have to handle its binding
            // on any page, so the renderer doesn't get killed. We don't want
            // the operation to actually succeed in general, however, so we
            // just let the endpoint get closed by going out of scope unbound.
            // Tests that need the functionality can override this method to
            // provide it.
          }));
}

void ShellContentBrowserClient::OpenURL(
    SiteInstance* site_instance,
    const OpenURLParams& params,
    base::OnceCallback<void(WebContents*)> callback) {
  std::move(callback).Run(
      Shell::CreateNewWindow(site_instance->GetBrowserContext(), params.url,
                             nullptr, gfx::Size())
          ->web_contents());
}

namespace {

// Посилання на .crx стає встановленням. Показати .crx браузер не може, а
// завантажений файл користувачу нічим відкрити.
class BlinkerCrxNavigationThrottle : public NavigationThrottle {
 public:
  explicit BlinkerCrxNavigationThrottle(NavigationThrottleRegistry& registry)
      : NavigationThrottle(registry) {}

  const char* GetNameForLogging() override {
    return "BlinkerCrxNavigationThrottle";
  }

 private:
  ThrottleCheckResult WillStartRequest() override {
    return Handle(/*by_mime_type=*/false);
  }
  ThrottleCheckResult WillRedirectRequest() override {
    return Handle(/*by_mime_type=*/false);
  }
  // URL не завжди видає пакет, Web Store віддає його з шляху без ".crx", а тип
  // каже Content-Type. Chrome теж дивиться на нього.
  ThrottleCheckResult WillProcessResponse() override {
    return Handle(/*by_mime_type=*/true);
  }

  ThrottleCheckResult Handle(bool by_mime_type) {
    NavigationHandle* handle = navigation_handle();
    // Тільки справжня навігація верхнього рівня, subframe чи підресурс з .crx
    // нічого не встановлюють.
    if (!handle || !handle->IsInPrimaryMainFrame()) {
      return PROCEED;
    }
    bool is_crx = BlinkerIsCrxUrl(handle->GetURL());
    if (!is_crx && by_mime_type) {
      const net::HttpResponseHeaders* headers = handle->GetResponseHeaders();
      std::string mime;
      is_crx = headers && headers->GetMimeType(&mime) &&
               (mime == "application/x-chrome-extension" ||
                mime == "application/x-crx");
    }
    if (!is_crx) {
      return PROCEED;
    }
    WebContents* contents = handle->GetWebContents();
    if (!contents) {
      return PROCEED;
    }
    const GURL url = handle->GetURL();
    BlinkerDownloadAndInstallCrx(
        contents->GetBrowserContext(), url,
        base::BindOnce(
            [](base::WeakPtr<WebContents> contents,
               BlinkerCrxInstallResult result) {
              if (!contents) {
                return;
              }
              if (result.ok) {
                // Нове розширення підхоплюєм без перезапуску.
                BlinkerWebExtensionRegistry::GetInstance().LoadAll();
              }
              // Сторінка з результатом завжди, інакше встановлення не
              // відрізнити від посилання, що нічого не зробило.
              contents->GetController().LoadURLWithParams(
                  NavigationController::LoadURLParams(GURL(
                      base::StrCat({kBlinkerExtensionScheme, "://",
                                    kBlinkerInstallHost, "/"}))));
            },
            contents->GetWeakPtr()));
    return CANCEL_AND_IGNORE;
  }
};

}  // namespace

void ShellContentBrowserClient::CreateThrottlesForNavigation(
    NavigationThrottleRegistry& registry) {
  if (create_throttles_for_navigation_callback_) {
    create_throttles_for_navigation_callback_.Run(registry);
  }
  registry.AddThrottle(
      std::make_unique<BlinkerCrxNavigationThrottle>(registry));
}

#if BUILDFLAG(IS_IOS)
// Визначено в shell_platform_delegate_ios.mm.
int BlinkShowLoginPrompt(
    WebContents* contents,
    const std::string& host,
    const std::string& realm,
    bool proxy,
    bool retry,
    base::OnceCallback<void(std::optional<net::AuthCredentials>)> done);
void BlinkCancelLoginPrompt(int token);

namespace {

// Без делегата Chromium одразу скасовує запит, і сайт з HTTP Basic чи Digest
// показує 401 без можливості увійти.
class BlinkerLoginDelegate : public LoginDelegate {
 public:
  BlinkerLoginDelegate(const net::AuthChallengeInfo& info,
                       WebContents* contents,
                       bool retry,
                       LoginAuthRequiredCallback callback)
      : callback_(std::move(callback)) {
    GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE,
        base::BindOnce(&BlinkerLoginDelegate::Show,
                       weak_factory_.GetWeakPtr(),
                       contents ? contents->GetWeakPtr() : nullptr,
                       info.challenger.host(), info.realm, info.is_proxy,
                       retry));
  }
  BlinkerLoginDelegate(const BlinkerLoginDelegate&) = delete;
  BlinkerLoginDelegate& operator=(const BlinkerLoginDelegate&) = delete;
  ~BlinkerLoginDelegate() override {
    if (token_) {
      BlinkCancelLoginPrompt(token_);
    }
  }

 private:
  void Show(base::WeakPtr<WebContents> contents,
            const std::string& host,
            const std::string& realm,
            bool proxy,
            bool retry) {
    token_ = BlinkShowLoginPrompt(
        contents.get(), host, realm, proxy, retry,
        base::BindOnce(&BlinkerLoginDelegate::Done,
                       weak_factory_.GetWeakPtr()));
    if (!token_) {
      Done(std::nullopt);
    }
  }

  void Done(std::optional<net::AuthCredentials> credentials) {
    token_ = 0;
    if (callback_) {
      std::move(callback_).Run(credentials);
    }
  }

  LoginAuthRequiredCallback callback_;
  int token_ = 0;
  base::WeakPtrFactory<BlinkerLoginDelegate> weak_factory_{this};
};

}  // namespace
#endif

std::unique_ptr<LoginDelegate> ShellContentBrowserClient::CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    WebContents* web_contents,
    BrowserContext* browser_context,
    const GlobalRequestID& request_id,
    bool is_request_for_primary_main_frame_navigation,
    bool is_request_for_navigation,
    const GURL& url,
    scoped_refptr<net::HttpResponseHeaders> response_headers,
    bool first_auth_attempt,
    bool do_not_prompt_for_login,
    GuestPageHolder* guest,
    LoginDelegate::LoginAuthRequiredCallback auth_required_callback) {
  // `login_request_callback_` stands in for a login dialog, which must not be
  // shown for requests that must not prompt for login.
  if (do_not_prompt_for_login) {
    return nullptr;
  }
  if (!login_request_callback_.is_null()) {
    std::move(login_request_callback_)
        .Run(is_request_for_primary_main_frame_navigation,
             is_request_for_navigation);
    return nullptr;
  }
#if BUILDFLAG(IS_IOS)
  if (web_contents) {
    return std::make_unique<BlinkerLoginDelegate>(
        auth_info, web_contents, !first_auth_attempt,
        std::move(auth_required_callback));
  }
#endif
  return nullptr;
}

base::DictValue ShellContentBrowserClient::GetNetLogConstants() {
  base::DictValue client_constants;
  client_constants.Set("name", "content_shell");
  base::CommandLine::StringType command_line =
      base::CommandLine::ForCurrentProcess()->GetCommandLineString();
#if BUILDFLAG(IS_WIN)
  client_constants.Set("command_line", base::WideToUTF8(command_line));
#else
  client_constants.Set("command_line", command_line);
#endif
  base::DictValue constants;
  constants.Set("clientInfo", std::move(client_constants));
  return constants;
}

base::FilePath
ShellContentBrowserClient::GetSandboxedStorageServiceDataDirectory() {
  return browser_context()->GetPath();
}

base::FilePath ShellContentBrowserClient::GetFirstPartySetsDirectory() {
  return browser_context()->GetPath();
}

std::optional<base::FilePath>
ShellContentBrowserClient::GetLocalTracesDirectory() {
  return browser_context()->GetPath();
}

std::string ShellContentBrowserClient::GetUserAgent() {
  const auto custom_ua = embedder_support::GetUserAgentFromCommandLine();
  if (custom_ua.has_value()) {
    return custom_ua.value();
  }

#if BUILDFLAG(IS_IOS)
  const std::string identity_ua =
      BlinkIdentityUserAgent(BlinkUserAgentIdentity());
  if (!identity_ua.empty()) {
    return identity_ua;
  }
  // Цілісна ідентичність Blink/Android замість неможливого відбитку
  // CriOS+Blink. Це лиш вигляд, челенджі воно не обходить.
  return base::StringPrintf(
      "Mozilla/5.0 (Linux; Android 15; Pixel 8) "
      "AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/%s Mobile Safari/537.36",
      CONTENT_SHELL_VERSION);
#else
  std::string product =
      base::StringPrintf("Chrome/%s.0.0.0", CONTENT_SHELL_MAJOR_VERSION);
#if BUILDFLAG(IS_ANDROID)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          embedder_support::kUseMobileUserAgent)) {
    product += " Mobile";
  }
#endif

  return embedder_support::BuildUnifiedPlatformUserAgentFromProduct(product);
#endif
}

blink::UserAgentMetadata ShellContentBrowserClient::GetUserAgentMetadata() {
  return GetShellUserAgentMetadata();
}

void ShellContentBrowserClient::OverrideURLLoaderFactoryParams(
    BrowserContext* browser_context,
    const url::Origin& origin,
    bool is_for_isolated_world,
    bool is_for_service_worker,
    network::mojom::URLLoaderFactoryParams* factory_params) {
  if (url_loader_factory_params_callback_) {
    url_loader_factory_params_callback_.Run(
        factory_params, origin, is_for_isolated_world, is_for_service_worker);
  }
}

#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID)
void ShellContentBrowserClient::GetAdditionalMappedFilesForChildProcess(
    const base::CommandLine& command_line,
    int child_process_id,
    content::PosixFileDescriptorInfo* mappings) {
#if BUILDFLAG(IS_ANDROID)
  mappings->ShareWithRegion(
      kShellPakDescriptor,
      base::GlobalDescriptors::GetInstance()->Get(kShellPakDescriptor),
      base::GlobalDescriptors::GetInstance()->GetRegion(kShellPakDescriptor));
#endif
  int crash_signal_fd = GetCrashSignalFD(command_line);
  if (crash_signal_fd >= 0) {
    mappings->Share(kCrashDumpSignal, crash_signal_fd);
  }
}
#endif  // BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) ||
        // BUILDFLAG(IS_ANDROID)

// Note that ShellContentBrowserClient overrides this method to work around
// test flakiness that happens when NetworkService::SetTestDohConfigForTesting()
// is used.
// TODO(crbug.com/41494161): Remove that override once the flakiness is fixed.
#if BUILDFLAG(IS_IOS)
namespace {

// Шаблон DoH з налаштувань, порожній значить вимкнено.
std::string BlinkerSecureDnsTemplate() {
  std::string result;
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  CFPropertyListRef value = CFPreferencesCopyAppValue(
      CFSTR("BlinkSecureDNS"), kCFPreferencesCurrentApplication);
  if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
    char buffer[1024];
    if (CFStringGetCString(static_cast<CFStringRef>(value), buffer,
                           sizeof(buffer), kCFStringEncodingUTF8)) {
      result = buffer;
    }
  }
  if (value) {
    CFRelease(value);
  }
  // Mullvad закрив публічний DoH 2 листопада 2026. У строгому режимі мертвий
  // сервер означає, що жодна сторінка не відкриється, тому збережений вибір
  // (зі списку чи свій) переходить на Quad9.
  if (base::ToLowerASCII(result).find("mullvad.net/") != std::string::npos) {
    result = "https://dns.quad9.net/dns-query";
    CFStringRef replacement = CFStringCreateWithCString(
        kCFAllocatorDefault, result.c_str(), kCFStringEncodingUTF8);
    if (replacement) {
      CFPreferencesSetAppValue(CFSTR("BlinkSecureDNS"), replacement,
                               kCFPreferencesCurrentApplication);
      CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
      CFRelease(replacement);
    }
  }
  return result;
}

// Строгий режим, як "свій постачальник" у Chrome. Якщо сервер DoH
// недоступний, сторінки не відкриються, але й мимо нього нічого не піде.
void ConfigureBlinkerSecureDns(network::mojom::NetworkService* service) {
  if (!service) {
    return;
  }
  std::optional<net::DnsOverHttpsConfig> config =
      net::DnsOverHttpsConfig::FromString(BlinkerSecureDnsTemplate());
  const bool secure = config && !config->servers().empty();
  service->ConfigureStubHostResolver(
      net::InsecureDnsMode::kDisabled,
      base::FeatureList::IsEnabled(net::features::kHappyEyeballsV3),
      secure ? net::SecureDnsMode::kSecure : net::SecureDnsMode::kOff,
      secure ? *config : net::DnsOverHttpsConfig(),
      /*additional_dns_types_enabled=*/true,
      /*fallback_doh_nameservers=*/{});
  BLINKER_DIAG(secure ? "SECURE_DNS: on" : "SECURE_DNS: off");
}

}  // namespace

void BlinkerApplySecureDnsSetting() {
  ConfigureBlinkerSecureDns(GetNetworkService());
}

bool BlinkerIsValidSecureDnsTemplate(const std::string& value) {
  std::optional<net::DnsOverHttpsConfig> config =
      net::DnsOverHttpsConfig::FromString(value);
  return config && !config->servers().empty();
}
#endif  // BUILDFLAG(IS_IOS)

void ShellContentBrowserClient::OnNetworkServiceCreated(
    network::mojom::NetworkService* network_service) {
#if BUILDFLAG(IS_IOS)
  if (!BlinkerSecureDnsTemplate().empty()) {
    ConfigureBlinkerSecureDns(network_service);
    return;
  }
#endif
  // TODO(bashi): Consider enabling this for Android. Excluded because the
  // built-in resolver may not work on older SDK versions.
#if !BUILDFLAG(IS_ANDROID)
  if (base::FeatureList::IsEnabled(net::features::kAsyncDns)) {
    network_service->ConfigureStubHostResolver(
        net::InsecureDnsMode::kEnabledBuiltIn,
        base::FeatureList::IsEnabled(net::features::kHappyEyeballsV3),
        net::SecureDnsMode::kAutomatic, net::DnsOverHttpsConfig(),
        /*additional_dns_types_enabled=*/true,
        /*fallback_doh_nameservers=*/{});
  }
#endif
}

void ShellContentBrowserClient::ConfigureNetworkContextParams(
    BrowserContext* context,
    bool in_memory,
    const base::FilePath& relative_partition_path,
    network::mojom::NetworkContextParams* network_context_params,
    cert_verifier::mojom::CertVerifierCreationParams*
        cert_verifier_creation_params) {
  ConfigureNetworkContextParamsForShell(context, network_context_params,
                                        cert_verifier_creation_params);
}

std::vector<base::FilePath>
ShellContentBrowserClient::GetNetworkContextsParentDirectory() {
  return {browser_context()->GetPath()};
}

#if BUILDFLAG(IS_IOS)
base::i18n::LanguageTag ShellContentBrowserClient::GetApplicationLocale() {
  if (!application_locale_storage_) {
    application_locale_storage_ = std::make_unique<ApplicationLocaleStorage>();
    if (std::optional<base::i18n::LanguageTag> locale_override =
            base::i18n::GetLanguageTagFromString(
                l10n_util::GetLocaleOverride())) {
      application_locale_storage_->SetTag(*std::move(locale_override));
    }
  }

  return application_locale_storage_->GetTag();
}

BluetoothDelegate* ShellContentBrowserClient::GetBluetoothDelegate() {
#if BUILDFLAG(IS_IOS)
  // Сховища дозволів (chooser context) у shell нема, а BluetoothDelegateImpl
  // одразу підписується на нього. Без делегата WebBluetoothServiceImpl просто
  // нічого не дозволяє.
  return nullptr;
#else
  if (!bluetooth_delegate_) {
    bluetooth_delegate_ = std::make_unique<permissions::BluetoothDelegateImpl>(
        std::make_unique<ShellBluetoothDelegateImplClient>());
  }
  return bluetooth_delegate_.get();
#endif
}
#endif

void ShellContentBrowserClient::BindBrowserControlInterface(
    mojo::ScopedMessagePipeHandle pipe) {
  if (!pipe.is_valid()) {
    return;
  }
  mojo::MakeSelfOwnedReceiver(
      std::make_unique<ShellControllerImpl>(),
      mojo::PendingReceiver<mojom::ShellController>(std::move(pipe)));
}

void ShellContentBrowserClient::set_browser_main_parts(
    ShellBrowserMainParts* parts) {
  GetSharedState().shell_browser_main_parts = parts;
}

ShellBrowserContext* ShellContentBrowserClient::browser_context() {
  return GetSharedState().shell_browser_main_parts->browser_context();
}

ShellBrowserContext*
ShellContentBrowserClient::off_the_record_browser_context() {
  return GetSharedState()
      .shell_browser_main_parts->off_the_record_browser_context();
}

ShellBrowserMainParts* ShellContentBrowserClient::shell_browser_main_parts() {
  return GetSharedState().shell_browser_main_parts;
}

void ShellContentBrowserClient::ConfigureNetworkContextParamsForShell(
    BrowserContext* context,
    network::mojom::NetworkContextParams* context_params,
    cert_verifier::mojom::CertVerifierCreationParams*
        cert_verifier_creation_params) {
  context_params->user_agent = GetUserAgent();
#if BUILDFLAG(IS_IOS)
  // Вагові коефіцієнти як у Chrome, інакше антибот це помічає
  context_params->accept_language =
      net::HttpUtil::GenerateAcceptLanguageHeader(GetAcceptLangs(context));
#else
  context_params->accept_language = GetAcceptLangs(context);
#endif
#if BUILDFLAG(IS_IOS)
  BLINKER_DIAGF("LANGUAGE: Accept-Language=%s",
                context_params->accept_language.c_str());
#endif
  context_params->enable_zstd = true;
  bool block_third_party_cookies = context->IsOffTheRecord();
#if BUILDFLAG(IS_IOS)
  block_third_party_cookies |= CFPreferencesGetAppBooleanValue(
      CFSTR("BlinkBlockThirdPartyCookies"), kCFPreferencesCurrentApplication,
      nullptr);
#endif
  if (block_third_party_cookies) {
    context_params->cookie_manager_params =
        network::mojom::CookieManagerParams::New();
    context_params->cookie_manager_params->block_third_party_cookies = true;
  }
  auto exempt_header =
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          "cors_exempt_header_list");
  if (!exempt_header.empty()) {
    context_params->cors_exempt_header_list.push_back(exempt_header);
  }
  context_params->device_bound_sessions_enabled =
      base::FeatureList::IsEnabled(net::features::kDeviceBoundSessions);

  // HTTP кеш обмежений, для постійних профілів він на диску.
  context_params->http_cache_enabled = true;
  context_params->http_cache_max_size = 80 * 1024 * 1024;
  if (BlinkerLowMemoryDevice()) {
    // В private режимі кеш у пам'яті і конкурує з ресурсами сторінок.
    context_params->http_cache_max_size = 24 * 1024 * 1024;
  }
  if (!context->IsOffTheRecord()) {
#if BUILDFLAG(IS_IOS)
    {
      BLINKER_DIAGF("PROFILE_STORE: path=%s",
                    context->GetPath().value().c_str());
      BLINKER_DIAG("PROFILE_STORE: localStorage persistent");
      BLINKER_DIAG("PROFILE_STORE: IndexedDB persistent");
    }
#endif
    if (!context_params->file_paths) {
      context_params->file_paths =
          network::mojom::NetworkContextFilePaths::New();
    }
    if (!context_params->file_paths->http_cache_directory) {
      context_params->file_paths->http_cache_directory =
          network::TransferableDirectory(context->GetPath());
    }

    // SQLite сховище cookies профілю, сесійні cookies теж зберігаєм.
    context_params->file_paths->data_directory =
        network::TransferableDirectory(context->GetPath());
    context_params->file_paths->cookie_database_name =
        base::FilePath(FILE_PATH_LITERAL("Cookies"));
    context_params->restore_old_session_cookies = true;
    context_params->persist_session_cookies = true;
#if BUILDFLAG(IS_IOS)
    BLINKER_DIAG("PROFILE_STORE: cookies persistent");
#endif
    // На iOS content_shell не ініціалізує OSCrypt. Базу береже пісочниця.
    context_params->enable_encrypted_cookies = false;
  }

#if BUILDFLAG(IS_IOS)
  // Беремо налаштування з запуску, щоб нові і private контексти не розходились
  // з мережевим сервісом, коли зміну збережено на наступний запуск.
  const std::string proxy = blinker_proxy::EffectiveServer(
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("proxy-server"));
  if (!proxy.empty()) {
    net::ProxyConfig proxy_config;
    proxy_config.proxy_rules().ParseFromString(proxy);
    proxy_config.proxy_rules().bypass_rules.AddRulesToSubtractImplicit();
    context_params->initial_proxy_config = net::ProxyConfigWithAnnotation(
        proxy_config, MISSING_TRAFFIC_ANNOTATION);
  }
#endif
}

void ShellContentBrowserClient::GetHyphenationDictionary(
    base::OnceCallback<void(const base::FilePath&)> callback) {
  // If we have the source tree, return the dictionary files in the tree.
  base::FilePath dir;
  if (base::PathService::Get(base::DIR_SRC_TEST_DATA_ROOT, &dir)) {
    dir = dir.AppendASCII("third_party")
              .AppendASCII("hyphenation-patterns")
              .AppendASCII("hyb");
    std::move(callback).Run(dir);
  }
  // No need to callback if there were no dictionaries.
}

bool ShellContentBrowserClient::HasErrorPage(int http_status_code) {
  return http_status_code >= 400 && http_status_code < 600;
}

namespace {

// Для chrome.tabs.onUpdated
// onRemoved. Живе рівно стільки, скільки
// WebContents.
class BlinkerExtensionTabObserver : public WebContentsObserver {
 public:
  explicit BlinkerExtensionTabObserver(WebContents* contents)
      : WebContentsObserver(contents) {}

 private:
  // Сторінка розширення тут без devtools, тож консоль документів розширень іде
  // в лог браузера. Консоль звичайних сторінок туди не потрапляє.
  void OnDidAddMessageToConsole(RenderFrameHost* source_frame,
                                blink::mojom::ConsoleMessageLevel log_level,
                                const std::u16string& message,
                                int32_t line_no,
                                const std::u16string& source_id,
                                const std::optional<std::u16string>&
                                    untrusted_stack_trace) override {
    if (!source_frame ||
        !source_frame->GetLastCommittedURL().SchemeIs(
            kBlinkerExtensionScheme)) {
      return;
    }
    static const char* kLevels[] = {"verbose", "info", "warning", "error"};
    const size_t level = static_cast<size_t>(log_level);
    const std::string source = base::UTF16ToUTF8(source_id);
    BLINKER_LOGF("EXTLOG[%s] %s:%d %.400s",
                 level < std::size(kLevels) ? kLevels[level] : "?",
                 source.c_str(), line_no,
                 base::UTF16ToUTF8(message).c_str());
  }

  void DidStartNavigation(NavigationHandle* handle) override {
    BlinkerWebNavigationStarted(handle);
  }
  void DidFinishNavigation(NavigationHandle* handle) override {
    BlinkerWebNavigationFinished(handle);
    if (handle->IsInPrimaryMainFrame() && handle->HasCommitted()) {
      BlinkerNoteTabNavigated(web_contents(), handle);
      BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
    }
  }
  void DOMContentLoaded(RenderFrameHost* frame) override {
    BlinkerWebNavigationParsed(frame);
  }
  void DidFinishLoad(RenderFrameHost* frame, const GURL& url) override {
    BlinkerWebNavigationLoaded(frame, url);
  }
  void DidFailLoad(RenderFrameHost* frame,
                   const GURL& url,
                   int error_code) override {
    BlinkerWebNavigationFailed(frame, error_code);
  }
  void RenderFrameDeleted(RenderFrameHost* frame) override {
    BlinkerWebNavigationFrameDeleted(frame);
  }
  void RenderFrameHostChanged(RenderFrameHost* old_host,
                              RenderFrameHost* new_host) override {
    if (old_host) {
      BlinkerWebNavigationFramesReplaced(old_host);
    }
  }
  void DidOpenRequestedURL(WebContents* new_contents,
                           RenderFrameHost* source_render_frame_host,
                           const GURL& url,
                           const Referrer& referrer,
                           WindowOpenDisposition disposition,
                           ui::PageTransition transition,
                           bool started_from_context_menu,
                           bool renderer_initiated) override {
    // Як WebNavigationTabObserver, лише коли з'являється нове вікно.
    if (disposition == WindowOpenDisposition::kSingletonTab ||
        disposition == WindowOpenDisposition::kNewForegroundTab ||
        disposition == WindowOpenDisposition::kNewBackgroundTab ||
        disposition == WindowOpenDisposition::kNewPopup ||
        disposition == WindowOpenDisposition::kNewWindow ||
        disposition == WindowOpenDisposition::kOffTheRecord) {
      BlinkerWebNavigationTargetCreated(source_render_frame_host, new_contents,
                                        url);
    }
  }
  void DidStartLoading() override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
  }
  void DidStopLoading() override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
  }
  void OnAudioStateChanged(bool audible) override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
  }
  void DidUpdateAudioMutingState(bool muted) override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
  }
  void TitleWasSet(NavigationEntry* entry) override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onUpdated");
  }
  void DidUpdateFaviconURL(
      RenderFrameHost* render_frame_host,
      const std::vector<blink::mojom::FaviconURLPtr>& candidates,
      blink::mojom::FaviconUpdateReason reason) override {
    if (!render_frame_host || !render_frame_host->IsInPrimaryMainFrame()) {
      return;
    }
    for (const blink::mojom::FaviconURLPtr& candidate : candidates) {
      if (candidate->icon_type == blink::mojom::FaviconIconType::kFavicon) {
        BlinkerNoteTabFavicon(web_contents(), candidate->icon_url);
        return;
      }
    }
  }
  void OnVisibilityChanged(Visibility visibility) override {
    if (visibility == Visibility::VISIBLE) {
      BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onActivated");
    }
  }
  void WebContentsDestroyed() override {
    BlinkerNotifyExtensionTabEvent(web_contents(), "tabs.onRemoved");
    delete this;
  }
};


}  // namespace

void ShellContentBrowserClient::WillCreateURLLoaderFactory(
    BrowserContext* browser_context,
    RenderFrameHost* frame,
    int render_process_id,
    URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    std::optional<int64_t> navigation_id,
    ukm::SourceIdObj ukm_source_id,
    network::URLLoaderFactoryBuilder& factory_builder,
    mojo::PendingRemote<network::mojom::TrustedURLLoaderHeaderClient>*
        header_client,
    bool* bypass_redirect_checks,
    bool* disable_secure_dns,
    network::mojom::URLLoaderFactoryOverridePtr* factory_override,
    scoped_refptr<base::SequencedTaskRunner> navigation_response_task_runner,
    bool is_for_network_service) {
  // Ставиться коли є хоч одне розширення, бо фабрика будується на початку
  // документа, а воркер додає правила коли схоче. Без правил запит іде як є.
  if (BlinkerWebExtensionRegistry::GetInstance().enabled_count() > 0) {
    BlinkerInstallDnrRedirectInterceptor(factory_builder);
  }
}

void ShellContentBrowserClient::OnWebContentsCreated(
    WebContents* web_contents) {
  PerformanceManagerRegistry::GetInstance()->MaybeCreatePageNodeForWebContents(
      web_contents);
  // Сам видаляється разом з WebContents.
  new BlinkerExtensionTabObserver(web_contents);
  BlinkerNotifyExtensionTabEvent(web_contents, "tabs.onCreated");
}

void ShellContentBrowserClient::CreateFeatureListAndFieldTrials() {
  GetSharedState().local_state = CreateLocalState();
  SetupFieldTrials();
}

std::unique_ptr<DigitalIdentityProvider>
ShellContentBrowserClient::CreateDigitalIdentityProvider() {
  return std::make_unique<ShellDigitalIdentityProvider>();
}

// Tests may install their own ShellContentBrowserClient, track the list here.
// The list is ordered with oldest first and newer ones added after it.
// static
const std::vector<ShellContentBrowserClient*>&
ShellContentBrowserClient::GetShellContentBrowserClientInstances() {
  return GetShellContentBrowserClientInstancesImpl();
}


// Ресурси розширень. Обидва хуки дають ту саму фабрику, і для файлів content
// script та сторінок розширення, і для відкриття сторінки розширення
// документом.
void ShellContentBrowserClient::RegisterNonNetworkSubresourceURLLoaderFactories(
    int render_process_id,
    int render_frame_id,
    const std::optional<url::Origin>& request_initiator_origin,
    NonNetworkURLLoaderFactoryMap* factories) {
  if (factories) {
    factories->emplace(kBlinkerExtensionScheme,
                       BlinkerExtensionURLLoaderFactory::CreateForFrame(
                           GlobalRenderFrameHostId(render_process_id,
                                                   render_frame_id)));
  }
}

// Перевірка оновлення знову тягне скрипт воркера, без цього вона падає і
// воркер після зміни файлів не оновлюється.
void ShellContentBrowserClient::
    RegisterNonNetworkServiceWorkerUpdateURLLoaderFactories(
        BrowserContext* browser_context,
        NonNetworkURLLoaderFactoryMap* factories) {
  if (factories) {
    factories->emplace(kBlinkerExtensionScheme,
                       BlinkerExtensionURLLoaderFactory::Create());
  }
}

mojo::PendingRemote<network::mojom::URLLoaderFactory>
ShellContentBrowserClient::CreateNonNetworkNavigationURLLoaderFactory(
    const std::string& scheme,
    FrameTreeNodeId frame_tree_node_id) {
  if (scheme == kBlinkerExtensionScheme) {
    return BlinkerExtensionURLLoaderFactory::Create(frame_tree_node_id);
  }
  return {};
}

// Сховище розширення не ділиться за сторінкою, що його вбудувала. Інакше міст
// не бачив би воркера, а chrome.storage був би свій для кожного сайту.
bool ShellContentBrowserClient::ShouldUseFirstPartyStorageKey(
    const url::Origin& origin) {
  return origin.scheme() == kBlinkerExtensionScheme;
}

#if BUILDFLAG(IS_IOS)
extern "C" bool BlinkShouldBlockPopupFromHost(const char* host);
extern "C" void BlinkNotifyPopupBlocked(const char* host, const char* url);
#endif

bool ShellContentBrowserClient::CanCreateWindow(
    RenderFrameHost* opener,
    const GURL& opener_url,
    const GURL& opener_top_level_frame_url,
    const url::Origin& source_origin,
    content::mojom::WindowContainerType container_type,
    const GURL& target_url,
    const Referrer& referrer,
    const std::string& frame_name,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& features,
    bool user_gesture,
    bool opener_suppressed,
    bool* no_javascript_access) {
  *no_javascript_access = false;
#if BUILDFLAG(IS_IOS)
  if (opener_url.SchemeIs(kBlinkerExtensionScheme) ||
      opener_top_level_frame_url.SchemeIs(kBlinkerExtensionScheme)) {
    return true;
  }
  const GURL& site = opener_top_level_frame_url.is_valid()
                         ? opener_top_level_frame_url
                         : opener_url;
  const std::string host(site.host());
  if (!user_gesture && BlinkShouldBlockPopupFromHost(host.c_str())) {
    BLINKER_DIAG("POPUP: blocked, no user gesture");
    BlinkNotifyPopupBlocked(host.c_str(), target_url.spec().c_str());
    return false;
  }
  BlinkerContentFilter& filter = BlinkerContentFilter::GetInstance();
  if (target_url.SchemeIsHTTPOrHTTPS() &&
      filter.ShouldBlock(target_url, site, BlinkerResourceType::kPopup)) {
    BLINKER_DIAG("POPUP: blocked by filter list");
    filter.RecordBlocked(host);
    return false;
  }
#endif
  return true;
}

}  // namespace content
