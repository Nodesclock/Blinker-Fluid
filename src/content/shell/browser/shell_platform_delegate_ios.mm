// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_platform_delegate.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreLocation/CoreLocation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <PassKit/PassKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <notify.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <limits>
#include <map>

#include "content/shell/common/blinker_bookmarks_html.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_low_memory.h"
#include "content/shell/common/blinker_private_logging.h"
#include "content/shell/common/blinker_proxy_config.h"
#include "content/shell/common/blinker_update_asset.h"
#include "content/shell/common/blinker_selection_color.h"
#include "content/shell/common/blinker_web_colors.h"

extern "C" void BlinkPrepareForRestart();
extern "C" void BlinkMoveShellWindow(size_t from, size_t to);
extern "C" AVSampleBufferDisplayLayer* BlinkCurrentVideoSampleBufferLayer();

extern "C" int BlinkIOSSystemPermissionStatus(int permission) {
  if (permission == 0) {
    CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
    return status == kCLAuthorizationStatusAuthorizedAlways ||
           status == kCLAuthorizationStatusAuthorizedWhenInUse;
  }
  AVMediaType media_type =
      permission == 1 ? AVMediaTypeAudio : AVMediaTypeVideo;
  return [AVCaptureDevice authorizationStatusForMediaType:media_type] ==
         AVAuthorizationStatusAuthorized;
}

#include "base/apple/foundation_util.h"
#include "base/command_line.h"
#include "base/files/file.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/hash/hash.h"
#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/timer/timer.h"
#include "base/trace_event/trace_config.h"
#include "base/version_info/version_info.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_ios.h"
#include "content/browser/screen_orientation/screen_orientation_provider.h"
#include "content/public/browser/browser_accessibility_state.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/ssl_status.h"
#include "content/public/common/mhtml_generation_params.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/scoped_accessibility_mode.h"
#include "content/public/browser/screen_orientation_delegate.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/stop_find_action.h"
#include "content/shell/app/resource.h"
#include "content/shell/browser/blinker_content_filter.h"
#include "content/shell/browser/blinker_extensions.h"
#include "content/shell/browser/blinker_session_store.h"
#include "content/shell/browser/blinker_ui_strings.h"
#include "content/shell/browser/blinker_tracking_params.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/browser/blinker_filter_subscriptions.h"
#include "content/shell/browser/color_chooser/shell_color_chooser_ios.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_browser_main_parts.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/browser/shell_file_select_helper.h"
#include "content/shell/common/blinker_script_executor.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/auth.h"
#include "net/base/filename_util.h"
#include "net/cert/cert_status_flags.h"
#include "third_party/zlib/google/zip.h"
#include "services/device/public/mojom/screen_orientation.mojom-shared.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "services/service_manager/public/cpp/interface_provider.h"
#include "services/tracing/public/cpp/perfetto/perfetto_config.h"
#include "services/tracing/public/mojom/constants.mojom.h"
#include "third_party/blink/public/common/renderer_preferences/renderer_preferences.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "third_party/blink/public/mojom/frame/find_in_page.mojom.h"
#include "third_party/perfetto/include/perfetto/tracing/core/trace_config.h"
#include "third_party/perfetto/include/perfetto/tracing/tracing.h"
#include "ui/accessibility/ax_mode.h"
#include "ui/display/screen.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/native_theme/native_theme.h"

namespace content {
// Визначено в shell_content_browser_client.cc. Ставить його UI вигляду тут, а
// OverrideWebPreferences по ньому задає prefers-color-scheme.
extern int g_blink_preferred_color_scheme;
// Визначено в shell_content_browser_client.cc. Client hints UA під режим
// сайту (Sec-CH-UA-Mobile
// platform).
blink::UserAgentMetadata GetShellUserAgentMetadataForSiteMode(bool desktop);
// Визначено в shell.cc. true, поки йде ланцюжок редиректів входу, щоб не міняти
// UA і режим сайту посеред входу.
bool BlinkShellIsInAuthFlow();
bool BlinkShellTabIsInAuthFlow(WebContents* contents);
}  // namespace content

static NSString* BlinkL(NSString* english) NS_FORMAT_ARGUMENT(1);
static NSString* const kBlinkDownloadAttentionChanged =
    @"BlinkDownloadAttentionChanged";
static NSString* const kBlinkGoogleAvatarFile = @"google-profile-avatar.png";
static NSString* const kBlinkGoogleSecondaryAvatarFile =
    @"google-secondary-profile-avatar.png";
static UIImage* g_private_google_avatar;
static UIImage* g_private_google_secondary_avatar;
static NSString* g_private_google_email;
static NSString* g_private_google_avatar_url;
static NSString* g_private_google_secondary_avatar_url;

// NSURLSession не бере проксі Chromium. Дивимось і поточну конфігурацію, і
// налаштування на наступний запуск, навіть некоректні.
static bool BlinkNativeNetworkingBlocked() {
  return content::blinker_logging::IsPrivateSession() ||
         base::CommandLine::ForCurrentProcess()->HasSwitch("proxy-server") ||
         !content::blinker_proxy::SavedServer().empty();
}

static NSURLSession* BlinkNativeSession() {
  static NSURLSession* session = [] {
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil;
    config.URLCache = nil;
    config.timeoutIntervalForRequest = 15;
    return [NSURLSession sessionWithConfiguration:config];
  }();
  return session;
}

// Іконки ярликів головної. Беремо з самого сайту, сторонній сервіс іконок
// дізнався б, що в людини на головній.
static NSString* const kBlinkIconUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 "
    @"Safari/604.1";

static NSString* BlinkShortcutIconPath(NSString* host) {
  NSString* caches = NSSearchPathForDirectoriesInDomains(
                         NSCachesDirectory, NSUserDomainMask, YES)
                         .firstObject;
  NSString* dir =
      [caches stringByAppendingPathComponent:@"BlinkShortcutIcons"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSString* safe = [[host.lowercaseString
      componentsSeparatedByCharactersInSet:
          [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
      componentsJoinedByString:@"_"];
  return [dir stringByAppendingPathComponent:
                  [safe stringByAppendingPathExtension:@"png"]];
}

// .ico несе кілька розмірів, а UIImage бере перший, часто 16px.
static UIImage* BlinkLargestIconFromData(NSData* data) {
  if (!data.length) {
    return nil;
  }
  CGImageSourceRef source =
      CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
  if (!source) {
    return nil;
  }
  size_t best_width = 0;
  size_t best_index = SIZE_MAX;
  const size_t count = CGImageSourceGetCount(source);
  for (size_t i = 0; i < count; ++i) {
    CFDictionaryRef props =
        CGImageSourceCopyPropertiesAtIndex(source, i, nullptr);
    if (!props) {
      continue;
    }
    NSNumber* width = ((__bridge NSDictionary*)props)[(
        __bridge NSString*)kCGImagePropertyPixelWidth];
    CFRelease(props);
    if (width.unsignedLongValue > best_width) {
      best_width = width.unsignedLongValue;
      best_index = i;
    }
  }
  UIImage* image = nil;
  if (best_index != SIZE_MAX && best_width >= 16) {
    CGImageRef cg =
        CGImageSourceCreateImageAtIndex(source, best_index, nullptr);
    if (cg) {
      image = [UIImage imageWithCGImage:cg];
      CGImageRelease(cg);
    }
  }
  CFRelease(source);
  return image;
}

static NSString* BlinkHTMLAttribute(NSString* tag, NSString* name) {
  NSString* pattern = [NSString
      stringWithFormat:@"\\b%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
                       name];
  NSRegularExpression* re = [NSRegularExpression
      regularExpressionWithPattern:pattern
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  NSTextCheckingResult* m =
      [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
  if (!m) {
    return nil;
  }
  for (NSUInteger g = 1; g <= 3; ++g) {
    NSRange r = [m rangeAtIndex:g];
    if (r.location != NSNotFound) {
      return [tag substringWithRange:r];
    }
  }
  return nil;
}

// Іконки, які сторінка сама оголосила, від найбільшої растрової. SVG UIImage
// не читає.
static NSArray<NSURL*>* BlinkDeclaredIcons(NSString* html, NSURL* base) {
  NSRegularExpression* links = [NSRegularExpression
      regularExpressionWithPattern:@"<link\\b[^>]*>"
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  NSMutableArray<NSDictionary*>* found = [NSMutableArray array];
  for (NSTextCheckingResult* m in
       [links matchesInString:html options:0
                        range:NSMakeRange(0, html.length)]) {
    NSString* tag = [html substringWithRange:m.range];
    NSString* rel = [BlinkHTMLAttribute(tag, @"rel") lowercaseString];
    NSString* href = BlinkHTMLAttribute(tag, @"href");
    if (!rel.length || !href.length || [rel containsString:@"mask-icon"] ||
        ![rel containsString:@"icon"]) {
      continue;
    }
    NSString* type = [BlinkHTMLAttribute(tag, @"type") lowercaseString];
    NSString* path = [[href componentsSeparatedByString:@"?"].firstObject
        lowercaseString];
    if ([type containsString:@"svg"] || [path hasSuffix:@".svg"]) {
      continue;
    }
    NSURL* url = [NSURL URLWithString:href relativeToURL:base].absoluteURL;
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
      continue;
    }
    const BOOL touch = [rel containsString:@"apple-touch-icon"];
    NSInteger size = touch ? 180 : ([path hasSuffix:@".ico"] ? 32 : 16);
    for (NSString* entry in [BlinkHTMLAttribute(tag, @"sizes")
             componentsSeparatedByString:@" "]) {
      size = MAX(size, [[entry componentsSeparatedByString:@"x"]
                               .firstObject integerValue]);
    }
    [found addObject:@{
      @"url" : url,
      @"score" : @(size * 2 + (touch ? 1 : 0)),
    }];
  }
  [found sortUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                 NSDictionary* b) {
    return [b[@"score"] compare:a[@"score"]];
  }];
  NSMutableArray<NSURL*>* urls = [NSMutableArray array];
  for (NSDictionary* entry in found) {
    if (![urls containsObject:entry[@"url"]]) {
      [urls addObject:entry[@"url"]];
    }
  }
  return urls;
}

static void BlinkFetchFirstIcon(NSArray<NSURL*>* candidates,
                                NSUInteger index,
                                void (^done)(UIImage*)) {
  if (index >= candidates.count) {
    done(nil);
    return;
  }
  NSMutableURLRequest* request =
      [NSMutableURLRequest requestWithURL:candidates[index]];
  [request setValue:kBlinkIconUserAgent forHTTPHeaderField:@"User-Agent"];
  [[BlinkNativeSession()
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          const NSInteger status =
              [response isKindOfClass:NSHTTPURLResponse.class]
                  ? ((NSHTTPURLResponse*)response).statusCode
                  : 0;
          UIImage* image =
              status == 200 ? BlinkLargestIconFromData(data) : nil;
          if (image) {
            done(image);
            return;
          }
          BlinkFetchFirstIcon(candidates, index + 1, done);
        }] resume];
}

static NSArray* BlinkDefaultShortcuts(void) {
  return @[
    @{@"title" : @"GitHub", @"url" : @"https://github.com"},
    @{@"title" : @"Reddit", @"url" : @"https://www.reddit.com"},
    @{@"title" : @"YouTube", @"url" : @"https://www.youtube.com"},
    @{@"title" : @"Google", @"url" : @"https://www.google.com"},
    @{@"title" : @"Gmail", @"url" : @"https://mail.google.com"},
    @{@"title" : @"Proton", @"url" : @"https://mail.proton.me"},
    @{@"title" : @"ChatGPT", @"url" : @"https://chatgpt.com"},
    @{@"title" : @"Claude", @"url" : @"https://claude.ai/new"},
  ];
}

static NSString* BlinkGoogleAvatarPath(void) {
  NSString* documents = NSSearchPathForDirectoriesInDomains(
                            NSDocumentDirectory, NSUserDomainMask, YES)
                            .firstObject;
  return [documents stringByAppendingPathComponent:kBlinkGoogleAvatarFile];
}

static NSString* BlinkGoogleSecondaryAvatarPath(void) {
  NSString* documents = NSSearchPathForDirectoriesInDomains(
                            NSDocumentDirectory, NSUserDomainMask, YES)
                            .firstObject;
  return [documents
      stringByAppendingPathComponent:kBlinkGoogleSecondaryAvatarFile];
}

// Google віддає ту саму аватарку з URL, що різняться лиш розміром кропу
// (=s200-c чи =s400-c). Цей суфікс не рахуєм окремим акаунтом.
static NSString* BlinkGoogleAvatarIdentity(NSString* value) {
  NSRange sizeSuffix = [value rangeOfString:@"=" options:NSBackwardsSearch];
  return sizeSuffix.location == NSNotFound
             ? value
             : [value substringToIndex:sizeSuffix.location];
}

namespace content {
void BlinkObserveGoogleAvatarURL(Shell* shell, const char* value) {
  if (!shell || !shell->web_contents() || !value || !value[0] ||
      shell->web_contents()->GetBrowserContext()->IsOffTheRecord() ||
      BlinkNativeNetworkingBlocked()) {
    return;
  }
  NSString* avatarURL = base::SysUTF8ToNSString(value);
  const BOOL privateSession =
      shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  const GURL pageURL = shell->web_contents()->GetLastCommittedURL();
  NSString* pageHost = base::SysUTF8ToNSString(pageURL.host());
  const BOOL chooser = [pageHost isEqualToString:@"accounts.google.com"] &&
                       [base::SysUTF8ToNSString(pageURL.path())
                           containsString:@"AccountChooser"];
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* primaryURL = privateSession
                             ? g_private_google_avatar_url
                             : [defaults stringForKey:@"BlinkGoogleAvatarURL"];
  NSString* secondaryURL =
      privateSession ? g_private_google_secondary_avatar_url
                     : [defaults stringForKey:@"BlinkGoogleSecondaryAvatarURL"];
  NSString* avatarIdentity = BlinkGoogleAvatarIdentity(avatarURL);
  NSString* primaryIdentity = BlinkGoogleAvatarIdentity(primaryURL);
  NSString* secondaryIdentity = BlinkGoogleAvatarIdentity(secondaryURL);
  BOOL storeSecondary = chooser && primaryIdentity.length &&
                        ![primaryIdentity isEqualToString:avatarIdentity];
  if ((storeSecondary && [secondaryIdentity isEqualToString:avatarIdentity]) ||
      (!storeSecondary && [primaryIdentity isEqualToString:avatarIdentity])) {
    return;
  }
  NSURL* url = [NSURL URLWithString:avatarURL];
  if (!url) {
    return;
  }
  [[BlinkNativeSession()
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response,
                          NSError* error) {
        NSHTTPURLResponse* http =
            [response isKindOfClass:[NSHTTPURLResponse class]]
                ? (NSHTTPURLResponse*)response
                : nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 ||
            data.length == 0 || data.length > 2 * 1024 * 1024) {
          return;
        }
        UIImage* image = [UIImage imageWithData:data];
        if (!image || image.size.width < 24 || image.size.height < 24) {
          return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          if (privateSession) {
            if (storeSecondary) {
              g_private_google_secondary_avatar = image;
              g_private_google_secondary_avatar_url = [avatarURL copy];
            } else {
              if (g_private_google_avatar && primaryURL.length &&
                  ![primaryURL isEqualToString:avatarURL]) {
                g_private_google_secondary_avatar = g_private_google_avatar;
                g_private_google_secondary_avatar_url = primaryURL;
              }
              g_private_google_avatar = image;
              g_private_google_avatar_url = [avatarURL copy];
            }
          } else {
            if (storeSecondary) {
              [data writeToFile:BlinkGoogleSecondaryAvatarPath()
                     atomically:YES];
              [defaults setObject:avatarURL
                           forKey:@"BlinkGoogleSecondaryAvatarURL"];
            } else {
              if (primaryURL.length &&
                  ![primaryURL isEqualToString:avatarURL]) {
                NSData* oldPrimary =
                    [NSData dataWithContentsOfFile:BlinkGoogleAvatarPath()];
                [oldPrimary writeToFile:BlinkGoogleSecondaryAvatarPath()
                             atomically:YES];
                [defaults setObject:primaryURL
                             forKey:@"BlinkGoogleSecondaryAvatarURL"];
              }
              [data writeToFile:BlinkGoogleAvatarPath() atomically:YES];
              [defaults setObject:avatarURL forKey:@"BlinkGoogleAvatarURL"];
            }
            [defaults setBool:YES forKey:@"BlinkGoogleAccountSeen"];
          }
          BLINKER_DIAG(storeSecondary
                           ? "GOOGLE_ACCOUNT: secondary avatar cached"
                           : "GOOGLE_ACCOUNT: selected avatar cached");
        });
      }] resume];
}

// Аватарка з уже завантаженого документа акаунта Google. Мережева відповідь
// не приходить, коли картинка взялась з кешу, тоді акаунт не бачили б до
// перезапуску. Тому дивимось у сам документ і кілька разів, бо віджет ogs
// з'являється пізно.
void BlinkScanGoogleAvatars(WebContents* contents) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  Shell* shell = Shell::FromWebContents(contents);
  if (!shell) {
    return;
  }
  base::WeakPtr<WebContents> weak_contents = contents->GetWeakPtr();
  contents->ForEachRenderFrameHost([shell,
                                    weak_contents](RenderFrameHost* frame) {
    const std::string host(frame->GetLastCommittedURL().host());
    if ((host != "accounts.google.com" && host != "myaccount.google.com" &&
         host != "ogs.google.com") ||
        !frame->IsRenderFrameLive()) {
      return;
    }
    static const char kScript[] =
        "(function(){var list=document.querySelectorAll('img');"
        "for(var i=0;i<list.length;i++){var s=list[i].currentSrc||list[i].src||"
        "'';if(/^https:\\/\\/(lh3\\.googleusercontent\\.com|[a-z0-9-]+"
        "\\.ggpht\\.com)\\/a(-)?\\//.test(s))return s;}return '';})()";
    auto executor = std::make_unique<mojo::Remote<mojom::BlinkerScriptExecutor>>();
    frame->GetRemoteInterfaces()->GetInterface(
        executor->BindNewPipeAndPassReceiver());
    mojom::BlinkerScriptExecutor* raw = executor->get();
    raw->Execute(
        0, frame->GetLastCommittedURL(), {kScript},
        base::BindOnce(
            [](std::unique_ptr<mojo::Remote<mojom::BlinkerScriptExecutor>> keep,
               base::WeakPtr<WebContents> weak_contents,
               std::optional<base::Value> result,
               const std::optional<std::string>& error,
               const std::string& document_id) {
              if (!weak_contents || !result || !result->is_string() ||
                  result->GetString().empty()) {
                return;
              }
              if (Shell* shell = Shell::FromWebContents(weak_contents.get())) {
                BlinkObserveGoogleAvatarURL(shell, result->GetString().c_str());
              }
            },
            std::move(executor), weak_contents));
  });
}
}  // namespace content

static UIImage* BlinkSystemImage(NSString* name) {
  if (@available(iOS 13.0, *)) {
    return [UIImage systemImageNamed:name];
  }
  // На iOS 12 SF Symbols нема, збірка для нього везе їх готовими PNG. Крапки в
  // назві imageNamed прийняв би за розширення, тому в файлах підкреслення.
  NSString* file = [@"sf_" stringByAppendingString:
                               [name stringByReplacingOccurrencesOfString:@"."
                                                               withString:@"_"]];
  UIImage* symbol = [UIImage imageNamed:file];
  if (!symbol) {
    return nil;
  }
  // Значки різної ширини, а комірка iOS 12 ставить текст одразу за значком, тож
  // кладем кожен по центру однакового поля.
  const CGSize canvas = CGSizeMake(28, 28);
  UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
  [symbol drawInRect:CGRectMake((canvas.width - symbol.size.width) / 2,
                                (canvas.height - symbol.size.height) / 2,
                                symbol.size.width, symbol.size.height)];
  UIImage* centered = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [centered imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

extern "C" UIImage* BlinkMenuSymbol(NSString* name) {
  return BlinkSystemImage(name);
}

// Поля пошуку стоять на темному, тож колір підказки заданий явно.
static void BlinkSetSearchPlaceholder(UITextField* field, UIColor* color) {
  field.attributedPlaceholder = [[NSAttributedString alloc]
      initWithString:BlinkL(@"Search or type URL")
          attributes:@{NSForegroundColorAttributeName : color}];
}

static UIImage* BlinkCircularMenuIcon(UIImage* source) {
  if (!source) {
    return nil;
  }
  const CGSize size = CGSizeMake(28, 28);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [[UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, size}] addClip];
  const CGFloat scale =
      MAX(size.width / source.size.width, size.height / source.size.height);
  const CGSize drawn =
      CGSizeMake(source.size.width * scale, source.size.height * scale);
  const CGRect rect =
      CGRectMake((size.width - drawn.width) * 0.5,
                 (size.height - drawn.height) * 0.5, drawn.width, drawn.height);
  [source drawInRect:rect];
  UIImage* result = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return result;
}

static UIImage* BlinkSwitchAccountIcon(UIImage* primary,
                                       UIImage* secondary,
                                       UIColor* badgeColor) {
  if (!primary) {
    return nil;
  }
  const CGSize canvas = CGSizeMake(32, 32);
  UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
  [BlinkCircularMenuIcon(primary) drawInRect:CGRectMake(0, 0, 28, 28)];
  CGRect badgeRect = CGRectMake(19, 19, 13, 13);
  [[UIColor colorWithWhite:0.09 alpha:1.0] setFill];
  [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(badgeRect, -1.5, -1.5)]
      fill];
  if (secondary) {
    [BlinkCircularMenuIcon(secondary) drawInRect:badgeRect];
  } else {
    [badgeColor setFill];
    [[UIBezierPath bezierPathWithOvalInRect:badgeRect] fill];
    [[UIColor whiteColor] setStroke];
    UIBezierPath* plus = [UIBezierPath bezierPath];
    plus.lineWidth = 1.6;
    plus.lineCapStyle = kCGLineCapRound;
    [plus moveToPoint:CGPointMake(22, 25.5)];
    [plus addLineToPoint:CGPointMake(29, 25.5)];
    [plus moveToPoint:CGPointMake(25.5, 22)];
    [plus addLineToPoint:CGPointMake(25.5, 29)];
    [plus stroke];
  }
  UIImage* result = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return result;
}

API_AVAILABLE(ios(15.0))
@interface BlinkSampleBufferPiPBridge
    : NSObject <AVPictureInPictureControllerDelegate,
                AVPictureInPictureSampleBufferPlaybackDelegate>
- (void)startWhenReadyWithAttempt:(NSInteger)attempt;
- (void)stop;
@end

API_AVAILABLE(ios(15.0))
@implementation BlinkSampleBufferPiPBridge {
  AVPictureInPictureController* _controller;
  AVSampleBufferDisplayLayer* __weak _sourceLayer;
}

- (void)startWhenReadyWithAttempt:(NSInteger)attempt {
  if (_controller.pictureInPictureActive) {
    return;
  }
  AVSampleBufferDisplayLayer* layer = BlinkCurrentVideoSampleBufferLayer();
  if (!layer || layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
    if (attempt < 12) {
      __weak BlinkSampleBufferPiPBridge* weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
                       [weakSelf startWhenReadyWithAttempt:attempt + 1];
                     });
    } else {
      BLINKER_DIAG(
          "NATIVE_PIP: no live Apple video layer; kept inline fullscreen");
    }
    return;
  }

  AVAudioSession* audio = AVAudioSession.sharedInstance;
  [audio setCategory:AVAudioSessionCategoryPlayback
                mode:AVAudioSessionModeMoviePlayback
             options:0
               error:nil];
  [audio setActive:YES error:nil];

  _sourceLayer = layer;
  AVPictureInPictureControllerContentSource* source =
      [[AVPictureInPictureControllerContentSource alloc]
          initWithSampleBufferDisplayLayer:layer
                          playbackDelegate:self];
  _controller =
      [[AVPictureInPictureController alloc] initWithContentSource:source];
  _controller.delegate = self;
  _controller.requiresLinearPlayback = NO;
  [_controller startPictureInPicture];
  BLINKER_DIAG("NATIVE_PIP: start requested with AVSampleBufferDisplayLayer");
}

- (void)stop {
  if (_controller.pictureInPictureActive) {
    [_controller stopPictureInPicture];
  }
  _controller.delegate = nil;
  _controller = nil;
  _sourceLayer = nil;
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController*)controller {
  BLINKER_DIAG("NATIVE_PIP: Apple PiP started");
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
    failedToStartPictureInPictureWithError:(NSError*)error {
  BLINKER_DIAG("NATIVE_PIP: Apple PiP failed to start");
  _controller = nil;
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
                        setPlaying:(BOOL)playing {
  // Медіа годинник лишається за Chromium. Нативні кнопки приймаємо без свого
  // AVPlayer, щоб не було другого годинника.
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:
    (AVPictureInPictureController*)controller {
  return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:
    (AVPictureInPictureController*)controller {
  return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
         didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

- (void)pictureInPictureController:(AVPictureInPictureController*)controller
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
  completionHandler();
}

@end

static BlinkSampleBufferPiPBridge* g_blink_pip_bridge API_AVAILABLE(ios(15.0));

static void BlinkSetNativeVideoPiP(bool entering) {
  // PiP на iOS 15 тримає IOSurface поки шар на сторінці, і fullscreen відео
  // набирає тисячі регіонів VM до kill. Тому там звичайний fullscreen.
  if (@available(iOS 16.0, *)) {
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
      BLINKER_DIAG("NATIVE_PIP: unsupported on this device");
      return;
    }
    if (!g_blink_pip_bridge) {
      g_blink_pip_bridge = [[BlinkSampleBufferPiPBridge alloc] init];
    }
    if (entering) {
      [g_blink_pip_bridge startWhenReadyWithAttempt:0];
    } else {
      [g_blink_pip_bridge stop];
    }
  } else if (entering) {
    BLINKER_DIAG("NATIVE_PIP: disabled on iOS 15 to prevent IOSurface leak");
  }
}

namespace {

// Пошуковики для довгого натискання на рядок адреси. Порожній шаблон означає
// None, і введене завжди вважається адресою.
struct SearchEngine {
  const char* name;
  const char* query;  // префікс пошуку, термін дописується в кінець
  // Ендпоінт підказок OpenSearch ["query", ["a", "b", ...]]. Порожній
  // значить підказок нема і стартова сторінка без списку.
  const char* suggest;
};
constexpr std::array kSearchEngines = {
    SearchEngine{"Google", "https://www.google.com/search?q=",
                 "https://suggestqueries.google.com/complete/"
                 "search?client=firefox&q="},
    SearchEngine{"DuckDuckGo", "https://duckduckgo.com/?q=",
                 "https://duckduckgo.com/ac/?type=list&q="},
    SearchEngine{"Bing", "https://www.bing.com/search?q=",
                 "https://api.bing.com/osjson.aspx?query="},
    SearchEngine{"Yahoo", "https://search.yahoo.com/search?p=",
                 "https://search.yahoo.com/sugg/os?output=fxjson&command="},
    SearchEngine{"Yandex", "https://yandex.com/search/?text=",
                 "https://suggest.yandex.com/suggest-ff.cgi?part="},
};
content::Shell* KeyWindowShell();
int g_search_engine = 0;  // Google за замовчуванням.
bool g_blink_app_unlocked = false;

// Чи це приватний сеанс. Контекст обирається раз на запуск, тож значення і тема
// з нього не змінюються до перезапуску.
// Тривалість і крива останнього сповіщення клавіатури, їх ставить вікно
// сторінки.
static NSTimeInterval g_blink_keyboard_duration = 0.25;
static NSInteger g_blink_keyboard_curve = 7;

bool BlinkPrivateSession() {
  static bool active = [[NSUserDefaults standardUserDefaults]
      boolForKey:@"BlinkPrivateBrowsing"];
  return active;
}

struct BlinkThemeColorOption {
  const char* name;
  int red;
  int green;
  int blue;
};

// Перший колір той самий помаранчевий з червоним, що був завжди.
constexpr BlinkThemeColorOption kBlinkThemeColors[] = {
    {"Blinker Fluid Orange", 224, 71, 40}, {"Chromium Blue", 26, 115, 232},
    {"Green", 38, 140, 74},                {"Tor Purple", 125, 70, 152},
    {"Pink", 206, 52, 128},                {"Teal", 0, 128, 140},
    {"Incognito Graphite", 70, 72, 78},
};
constexpr NSInteger kBlinkGraphiteThemeIndex = 6;
constexpr NSInteger kBlinkChromiumThemeIndex = 1;

NSInteger BlinkThemeColorIndex() {
  const NSInteger index = [[NSUserDefaults standardUserDefaults]
      integerForKey:@"BlinkThemeColor"];
  return index >= 0 && index < static_cast<NSInteger>(std::size(
                                   kBlinkThemeColors))
             ? index
             : 0;
}

// Колір теми для панелей. Обирається в налаштуваннях, у приватному сеансі
// завжди графітовий, як вікно інкогніто в Chrome.
UIColor* BlinkerThemeColor() {
  const BlinkThemeColorOption& option =
      kBlinkThemeColors[BlinkPrivateSession() ? kBlinkGraphiteThemeIndex
                                              : BlinkThemeColorIndex()];
  return [UIColor colorWithRed:option.red / 255.0
                         green:option.green / 255.0
                          blue:option.blue / 255.0
                         alpha:1.0];
}

// Колір акценту для тексту і іконок меню та стартової. Іде за кольором теми.
// Графіт на темному списку майже не видно, тому його акцент світлий сірий.
UIColor* BlinkerAccentColor() {
  if (BlinkPrivateSession() ||
      BlinkThemeColorIndex() == kBlinkGraphiteThemeIndex) {
    return [UIColor colorWithRed:189 / 255.0
                           green:193 / 255.0
                            blue:198 / 255.0
                           alpha:1.0];
  }
  return BlinkerThemeColor();
}

// Лого стартової. Тема Chromium Blue показує справжній знак Chromium.
UIImage* BlinkStartLogo() {
  if (!BlinkPrivateSession() &&
      BlinkThemeColorIndex() == kBlinkChromiumThemeIndex) {
    if (UIImage* chromium = [UIImage imageNamed:@"chromium_logo"]) {
      return chromium;
    }
  }
  return [UIImage imageNamed:@"blinker_logo"];
}

// Іконка застосунку на екрані Додому іде за темою. Лише Chromium Blue має
// свою, решта тем лишає основну. Система показує алерт, і поки він висить,
// alternateIconName ще старий, тож без черги кожне вікно слало б свій виклик і
// іконка скакала. Виклики зливаються, а читається тема вже в момент заміни.
void BlinkApplyAppIconForTheme() {
  static BOOL pending = NO;
  static BOOL scheduled = NO;
  if (scheduled) {
    return;
  }
  scheduled = YES;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        scheduled = NO;
        UIApplication* application = UIApplication.sharedApplication;
        if (!application.supportsAlternateIcons || pending ||
            application.applicationState != UIApplicationStateActive) {
          return;
        }
        NSString* wanted = BlinkThemeColorIndex() == kBlinkChromiumThemeIndex
                               ? @"ChromiumBlue"
                               : nil;
        NSString* current = application.alternateIconName;
        if ((!current && !wanted) || [current isEqualToString:wanted]) {
          return;
        }
        pending = YES;
        BLINKER_LOGF("APP_ICON: set %s", wanted ? wanted.UTF8String : "primary");
        [application setAlternateIconName:wanted
                        completionHandler:^(NSError* error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                            pending = NO;
                            BLINKER_LOGF("APP_ICON: done %s",
                                         error ? "failed" : "ok");
                            // Тему могли змінити, поки висів алерт.
                            if (!error) {
                              BlinkApplyAppIconForTheme();
                            }
                          });
                        }];
      });
}
UIColor* BlinkLabelColor() {
  if (@available(iOS 13.0, *)) {
    return UIColor.labelColor;
  }
  return UIColor.blackColor;
}
UIColor* BlinkerTorColor() {
  return [UIColor colorWithRed:159 / 255.0
                         green:102 / 255.0
                          blue:224 / 255.0
                         alpha:1.0];
}

constexpr ui::AXMode kVoiceOverEnabledAXMode =
    ui::kAXModeComplete | ui::AXMode::kFromPlatform | ui::AXMode::kScreenReader;

// Зберігає адреси вкладок, щоб пережили перезапуск, відновлює їх
// ShellBrowserMainParts. Стан UIKit не відновлюєм, бо це давало цикл падінь.
NSString* BlinkZoomKey(content::Shell* shell) {
  if (!shell || !shell->web_contents()) {
    return nil;
  }
  // В private ключа нема, бо в ньому хост і запис лишив би слід куди ходив
  // користувач. Zoom діє на живу сторінку, просто не запамятовується.
  if (shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
    return nil;
  }
  std::string host(shell->web_contents()->GetLastCommittedURL().host());
  if (host.empty()) {
    return nil;
  }
  return [@"BlinkZoom_" stringByAppendingString:base::SysUTF8ToNSString(host)];
}

int BlinkCurrentPageZoomPercent(content::Shell* shell) {
  NSString* key = BlinkZoomKey(shell);
  NSInteger stored =
      key ? [[NSUserDefaults standardUserDefaults] integerForKey:key] : 0;
  return stored > 0 ? static_cast<int>(stored)
                    : content::BlinkDefaultZoomPercent();
}

UIImage* BlinkCaptureTabPreview(content::Shell* shell);
static bool BlinkImageIsUniform(UIImage* image);

std::map<content::Shell*, GURL> g_crash_restore_urls;
std::map<content::Shell*, GURL> g_crash_restore_inflight;
bool g_restoring_crash_tabs = false;

NSString* BlinkTabURL(content::Shell* shell) {
  if (!shell || !shell->web_contents()) {
    return nil;
  }
  auto pending_crash = g_crash_restore_urls.find(shell);
  GURL url = pending_crash != g_crash_restore_urls.end()
                 ? pending_crash->second
                 : content::PeekPendingRestoreURL(shell);
  auto restoring = g_crash_restore_inflight.find(shell);
  if (restoring != g_crash_restore_inflight.end()) {
    url = restoring->second;
  }
  if (!url.is_valid()) {
    url = shell->web_contents()->GetLastCommittedURL();
  }
  if (!url.is_valid()) {
    url = shell->web_contents()->GetVisibleURL();
  }
  if (!url.is_valid() || url.IsAboutBlank()) {
    return @"about:blank";
  }
  return url.SchemeIsHTTPOrHTTPS() || content::BlinkerIsSavedPageURL(url)
             ? base::SysUTF8ToNSString(url.spec())
             : nil;
}

NSString* BlinkTabPreviewPath(NSString* url) {
  if (!url.length || [url isEqualToString:@"about:blank"]) {
    return nil;
  }
  NSArray<NSString*>* caches = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  if (!caches.count) {
    return nil;
  }
  NSString* directory =
      [caches.firstObject stringByAppendingPathComponent:@"TabPreviews"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  uint32_t hash = base::PersistentHash(base::SysNSStringToUTF8(url));
  return [directory
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%08x.jpg", hash]];
}

void BlinkSaveTabPreview(content::Shell* shell, UIImage* image) {
  // Перевірка тут, а не у викликах, бо прев'ю це знімок сторінки, і приватний
  // сеанс не має лишати його на диску.
  if (shell && shell->web_contents() &&
      shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  NSString* path = BlinkTabPreviewPath(BlinkTabURL(shell));
  if (!path || !image) {
    return;
  }
  NSData* data = UIImageJPEGRepresentation(image, 0.72);
  if (data) {
    [data writeToFile:path atomically:YES];
  }
}

UIImage* BlinkLoadTabPreview(content::Shell* shell) {
  if (content::BlinkerLowMemoryDevice()) {
    return nil;
  }
  if (!shell || !shell->web_contents() ||
      shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
    return nil;
  }
  NSString* path = BlinkTabPreviewPath(BlinkTabURL(shell));
  UIImage* saved = path ? [UIImage imageWithContentsOfFile:path] : nil;
  return saved && !BlinkImageIsUniform(saved) ? saved : nil;
}

void BlinkSaveOpenTabs(bool persistPreviews = false) {
  if (g_restoring_crash_tabs || [[NSUserDefaults standardUserDefaults]
                                    arrayForKey:@"BlinkPendingCrashTabs"]
                                    .count) {
    return;
  }
  for (content::Shell* shell : content::Shell::windows()) {
    if (shell->web_contents() &&
        shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
      return;
    }
  }
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  content::Shell* activeShell = KeyWindowShell();
  NSInteger activeIndex = -1;
  NSDictionary* existing = [[NSUserDefaults standardUserDefaults]
      dictionaryForKey:@"BlinkTabTitlesByURL"];
  NSMutableDictionary<NSString*, NSString*>* titles =
      [NSMutableDictionary dictionary];
  for (content::Shell* s : content::Shell::windows()) {
    if (!s->web_contents()) {
      continue;
    }
    NSString* url = BlinkTabURL(s);
    if (!url) {
      continue;
    }
    [urls addObject:url];
    if (s == activeShell) {
      activeIndex = static_cast<NSInteger>(urls.count) - 1;
    }
    std::u16string title = s->web_contents()->GetTitle();
    NSString* value = title.empty() ? nil : base::SysUTF16ToNSString(title);
    if (!value.length || [value isEqualToString:@"about:blank"]) {
      value = existing[url];
    }
    if (!value.length || [value isEqualToString:@"about:blank"]) {
      GURL parsed(base::SysNSStringToUTF8(url));
      value = parsed.SchemeIsHTTPOrHTTPS() && !parsed.host().empty()
                  ? base::SysUTF8ToNSString(parsed.host())
                  : BlinkL(@"New Tab");
    }
    titles[url] = value;
    if (persistPreviews) {
      BlinkSaveTabPreview(s, BlinkCaptureTabPreview(s));
    }
  }
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setObject:urls forKey:@"BlinkOpenTabs"];
  [d setObject:titles forKey:@"BlinkTabTitlesByURL"];
  // Без ключового вікна лишаємо те, що було записано раніше
  if (activeIndex >= 0) {
    [d setInteger:activeIndex forKey:@"BlinkActiveTabIndex"];
    [d setObject:urls[activeIndex] forKey:@"BlinkActiveTabURL"];
  }
  std::vector<std::pair<content::WebContents*, std::string>> sessions;
  for (content::Shell* s : content::Shell::windows()) {
    NSString* url = s->web_contents() ? BlinkTabURL(s) : nil;
    if (url.length && ![url isEqualToString:@"about:blank"]) {
      sessions.emplace_back(s->web_contents(), base::SysNSStringToUTF8(url));
    }
  }
  content::BlinkerSaveTabSessions(sessions);
  if (persistPreviews) {
    content::BlinkerFlushSessionWrites();
  }
  // Скид на диск потрібен лише перед виходом, коли одразу йде _exit(0).
  if (persistPreviews) {
    [d synchronize];
  }
}

NSCache<NSValue*, UIImage*>* BlinkTabPreviewCache() {
  static NSCache<NSValue*, UIImage*>* cache = [] {
    NSCache<NSValue*, UIImage*>* value = [[NSCache alloc] init];
    value.countLimit = 24;
    return value;
  }();
  return cache;
}

// Знімок вкладки, яку ще жодного разу не показували, суцільний білий чи чорний.
// Такий не годиться як мініатюра, тож у списку краще монограма.
static bool BlinkImageIsUniform(UIImage* image) {
  CGImageRef cg = image.CGImage;
  if (!cg) {
    return true;
  }
  constexpr size_t kSide = 12;
  uint8_t pixels[kSide * kSide * 4] = {};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels, kSide, kSide, 8, kSide * 4, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (!context) {
    return false;
  }
  CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), cg);
  CGContextRelease(context);
  int lowest[3] = {255, 255, 255};
  int highest[3] = {0, 0, 0};
  for (size_t i = 0; i < kSide * kSide; ++i) {
    for (int channel = 0; channel < 3; ++channel) {
      const int value = pixels[i * 4 + channel];
      lowest[channel] = std::min(lowest[channel], value);
      highest[channel] = std::max(highest[channel], value);
    }
  }
  return highest[0] - lowest[0] < 6 && highest[1] - lowest[1] < 6 &&
         highest[2] - lowest[2] < 6;
}

UIImage* BlinkCaptureTabPreview(content::Shell* shell) {
  // На 1 ГБ список вкладок бере назви та іконки, а знімок вікна тимчасово
  // виділяє повноекранні буфери плюс мініатюру.
  if (content::BlinkerLowMemoryDevice()) {
    return nil;
  }
  if (!shell) {
    return nil;
  }
  NSValue* key = [NSValue valueWithPointer:shell];
  UIWindow* window = shell->window().Get();
  if (!window || window.hidden || CGRectIsEmpty(window.bounds)) {
    return [BlinkTabPreviewCache() objectForKey:key];
  }
  const CGFloat sourceWidth = MAX(window.bounds.size.width, 1);
  const CGFloat sourceHeight = MAX(window.bounds.size.height, 1);
  const CGSize size = CGSizeMake(320, 320 * sourceHeight / sourceWidth);
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:size];
  UIImage* image =
      [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        const CGFloat scale = size.width / sourceWidth;
        CGContextScaleCTM(context.CGContext, scale, scale);
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
      }];
  if (!image || BlinkImageIsUniform(image)) {
    return [BlinkTabPreviewCache() objectForKey:key];
  }
  [BlinkTabPreviewCache() setObject:image forKey:key];
  BlinkSaveTabPreview(shell, image);
  return image;
}

}  // namespace

// Підпис пошуку на стартовій має колір теми. У private він сірий, як усе інше.
static UIColor* BlinkStartSearchPlaceholderColor() {
  UIColor* accent = BlinkerAccentColor();
  return BlinkPrivateSession() ? [accent colorWithAlphaComponent:0.8] : accent;
}

namespace content {

// Той самий пошуковик, що й у рядку адреси. Живе тут, бо тут і список, і вибір
// користувача. Розширенню віддається лише готовий URL.
std::string BlinkerSearchURLForQuery(std::string_view query) {
  if (query.empty()) {
    return std::string();
  }
  const std::string from_extension = BlinkerExtensionSearchURL(query);
  if (!from_extension.empty()) {
    return from_extension;
  }
  const SearchEngine& engine = kSearchEngines[g_search_engine];
  if (engine.query[0] == '\0') {
    return std::string();  // "None", рядок адреси приймає лише URL.
  }
  return std::string(engine.query) +
         base::EscapeQueryParamValue(std::string(query), true);
}

}  // namespace content

extern "C" void BlinkSearchSelectedText(const char* text) {
  content::Shell* source = KeyWindowShell();
  if (!source || !source->web_contents() || !text || !text[0]) {
    return;
  }
  const GURL url(content::BlinkerSearchURLForQuery(text));
  if (!url.is_valid()) {
    return;
  }
  content::Shell::CreateNewWindow(source->web_contents()->GetBrowserContext(),
                                  url, nullptr, gfx::Size());
}

extern "C" void BlinkPersistOpenTabs() {
  BlinkSaveOpenTabs(true);
}

static BOOL g_blink_kiosk_mode = NO;
static void BlinkSetKioskMode(BOOL on);

static NSString* const kBlinkBlockPopupsKey = @"BlinkBlockPopups";
static NSString* const kBlinkPopupAllowedHostsKey = @"BlinkPopupAllowedHosts";

static BOOL BlinkBlockPopupsEnabled() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  return [d objectForKey:kBlinkBlockPopupsKey] == nil ||
         [d boolForKey:kBlinkBlockPopupsKey];
}

static NSArray<NSString*>* BlinkPopupAllowedHosts();

static NSString* BlinkPopupSettingsSubtitle() {
  if (!BlinkBlockPopupsEnabled()) {
    return BlinkL(@"Off");
  }
  const NSUInteger allowed = BlinkPopupAllowedHosts().count;
  return allowed ? [NSString stringWithFormat:BlinkL(@"%@, %lu allowed"),
                                              BlinkL(@"On"),
                                              static_cast<unsigned long>(allowed)]
                 : BlinkL(@"On");
}

// У приватному режимі дозволи живуть до кінця сеансу, на диск не пишуться.
static NSMutableSet<NSString*>* BlinkSessionPopupHosts() {
  static NSMutableSet<NSString*>* hosts = [NSMutableSet set];
  return hosts;
}

static NSArray<NSString*>* BlinkPopupAllowedHosts() {
  return [[NSUserDefaults standardUserDefaults]
             stringArrayForKey:kBlinkPopupAllowedHostsKey]
             ?: @[];
}

static void BlinkAllowPopupsForHost(NSString* host) {
  if (!host.length) {
    return;
  }
  if (content::blinker_logging::IsPrivateSession()) {
    [BlinkSessionPopupHosts() addObject:host];
    return;
  }
  NSMutableArray<NSString*>* hosts = [BlinkPopupAllowedHosts() mutableCopy];
  if (![hosts containsObject:host]) {
    [hosts addObject:host];
    [[NSUserDefaults standardUserDefaults] setObject:hosts
                                              forKey:kBlinkPopupAllowedHostsKey];
  }
}

extern "C" bool BlinkShouldBlockPopupFromHost(const char* host) {
  if (!BlinkBlockPopupsEnabled()) {
    return false;
  }
  NSString* h = host ? @(host) : @"";
  return !h.length || (![BlinkPopupAllowedHosts() containsObject:h] &&
                       ![BlinkSessionPopupHosts() containsObject:h]);
}

@interface BlinkerPopupBar : UIView
@property(nonatomic, copy) NSString* host;
@property(nonatomic, copy) NSString* url;
@property(nonatomic, assign) NSInteger count;
@property(nonatomic, strong) UILabel* label;
@property(nonatomic, strong) NSTimer* hideTimer;
@end

@implementation BlinkerPopupBar
@end

static __weak BlinkerPopupBar* g_popup_bar;

static void BlinkHidePopupBar() {
  BlinkerPopupBar* bar = g_popup_bar;
  g_popup_bar = nil;
  [bar.hideTimer invalidate];
  [UIView animateWithDuration:0.2
      animations:^{
        bar.alpha = 0;
      }
      completion:^(BOOL) {
        [bar removeFromSuperview];
      }];
}

@interface BlinkerPopupBarTarget : NSObject
+ (instancetype)shared;
@end

@implementation BlinkerPopupBarTarget
+ (instancetype)shared {
  static BlinkerPopupBarTarget* target = [[BlinkerPopupBarTarget alloc] init];
  return target;
}
- (void)allowTapped:(UIButton*)sender {
  BlinkerPopupBar* bar = g_popup_bar;
  NSString* host = bar.host;
  NSString* url = bar.url;
  BlinkHidePopupBar();
  BlinkAllowPopupsForHost(host);
  content::Shell* shell = KeyWindowShell();
  const GURL target(base::SysNSStringToUTF8(url ?: @""));
  if (shell && target.is_valid()) {
    content::Shell::CreateNewWindow(shell->web_contents()->GetBrowserContext(),
                                    target, nullptr, gfx::Size());
  }
}
- (void)closeTapped:(UIButton*)sender {
  BlinkHidePopupBar();
}
- (void)timerFired:(NSTimer*)timer {
  BlinkHidePopupBar();
}
@end

extern "C" void BlinkNotifyPopupBlocked(const char* host, const char* url) {
  NSString* hostText = host ? @(host) : @"";
  NSString* urlText = url ? @(url) : @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    content::Shell* shell = KeyWindowShell();
    UIWindow* window = shell ? shell->window().Get() : nil;
    if (!window) {
      return;
    }
    BlinkerPopupBar* bar = g_popup_bar;
    if (bar && bar.window == window && [bar.host isEqualToString:hostText]) {
      bar.count += 1;
    } else {
      if (bar) {
        [bar.hideTimer invalidate];
        [bar removeFromSuperview];
      }
      bar = [[BlinkerPopupBar alloc] initWithFrame:CGRectZero];
      bar.count = 1;
      bar.translatesAutoresizingMaskIntoConstraints = NO;
      bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.97];
      bar.layer.cornerRadius = 14;
      bar.layer.shadowColor = UIColor.blackColor.CGColor;
      bar.layer.shadowOpacity = 0.3;
      bar.layer.shadowRadius = 8;
      bar.layer.shadowOffset = CGSizeMake(0, 3);
      bar.accessibilityIdentifier = @"BlinkerPopupBlockedBar";

      UIImageView* icon = [[UIImageView alloc]
          initWithImage:BlinkSystemImage(@"macwindow.badge.plus")];
      icon.tintColor = [UIColor colorWithWhite:0.75 alpha:1.0];
      icon.contentMode = UIViewContentModeScaleAspectFit;
      [icon setContentHuggingPriority:UILayoutPriorityRequired
                              forAxis:UILayoutConstraintAxisHorizontal];

      UILabel* label = [[UILabel alloc] init];
      label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
      label.textColor = UIColor.whiteColor;
      label.adjustsFontSizeToFitWidth = YES;
      label.minimumScaleFactor = 0.8;
      bar.label = label;

      UIButton* allow = [UIButton buttonWithType:UIButtonTypeSystem];
      [allow setTitle:BlinkL(@"Allow") forState:UIControlStateNormal];
      allow.titleLabel.font = [UIFont systemFontOfSize:14
                                                weight:UIFontWeightSemibold];
      allow.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
      [allow setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
      allow.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
      allow.layer.cornerRadius = 8;
      allow.accessibilityIdentifier = @"BlinkerPopupAllow";
      [allow setContentHuggingPriority:UILayoutPriorityRequired
                               forAxis:UILayoutConstraintAxisHorizontal];
      [allow addTarget:[BlinkerPopupBarTarget shared]
                    action:@selector(allowTapped:)
          forControlEvents:UIControlEventTouchUpInside];

      UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
      [close setTitle:@"✕" forState:UIControlStateNormal];
      close.titleLabel.font = [UIFont systemFontOfSize:15];
      [close setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0]
                  forState:UIControlStateNormal];
      [close setContentHuggingPriority:UILayoutPriorityRequired
                               forAxis:UILayoutConstraintAxisHorizontal];
      [close addTarget:[BlinkerPopupBarTarget shared]
                    action:@selector(closeTapped:)
          forControlEvents:UIControlEventTouchUpInside];

      UIStackView* row = [[UIStackView alloc]
          initWithArrangedSubviews:@[ icon, label, allow, close ]];
      row.translatesAutoresizingMaskIntoConstraints = NO;
      row.axis = UILayoutConstraintAxisHorizontal;
      row.alignment = UIStackViewAlignmentCenter;
      row.spacing = 10;
      [bar addSubview:row];
      [window addSubview:bar];

      const BOOL toolbarBottom = [[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkToolbarBottom"];
      UILayoutGuide* safe = window.safeAreaLayoutGuide;
      [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:bar.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor
                                          constant:12],
        [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor
                                           constant:-10],
        [icon.widthAnchor constraintEqualToConstant:20],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                          constant:10],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                           constant:-10],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                         constant:toolbarBottom ? -66 : -12],
      ]];
      g_popup_bar = bar;
    }
    bar.host = hostText;
    bar.url = urlText;
    bar.label.text =
        bar.count > 1
            ? [NSString stringWithFormat:@"%ld %@", static_cast<long>(bar.count),
                                         BlinkL(@"popups blocked")]
            : BlinkL(@"Popup blocked");
    [bar.hideTimer invalidate];
    bar.hideTimer =
        [NSTimer scheduledTimerWithTimeInterval:6
                                         target:[BlinkerPopupBarTarget shared]
                                       selector:@selector(timerFired:)
                                       userInfo:nil
                                        repeats:NO];
  });
}

// Банер chrome.notifications у браузері. Системне сповіщення вимагало б дозволу
// і не показувалося б, поки застосунок на екрані.

@interface BlinkerNotificationBanner : UIView
@property(nonatomic, copy) NSString* extensionId;
@property(nonatomic, copy) NSString* notificationId;
@end

@implementation BlinkerNotificationBanner
@end

namespace {

// Не більше одного банера, другий заміняє перший, як системні сповіщення.
BlinkerNotificationBanner* __strong g_notification_banner = nil;

void BlinkerDismissBanner(BOOL byUser, BOOL tellExtension) {
  BlinkerNotificationBanner* banner = g_notification_banner;
  if (!banner) {
    return;
  }
  g_notification_banner = nil;
  NSString* extensionId = banner.extensionId;
  NSString* notificationId = banner.notificationId;
  [UIView animateWithDuration:0.2
      animations:^{
        banner.alpha = 0;
        banner.transform = CGAffineTransformMakeTranslation(0, -20);
      }
      completion:^(BOOL finished) {
        [banner removeFromSuperview];
      }];
  if (tellExtension && extensionId.length) {
    content::BlinkerNotificationDismissed(
        base::SysNSStringToUTF8(extensionId),
        base::SysNSStringToUTF8(notificationId), byUser);
  }
}

}  // namespace

@interface BlinkerNotificationTarget : NSObject
+ (instancetype)shared;
- (void)bannerTapped:(UITapGestureRecognizer*)gesture;
- (void)buttonTapped:(UIButton*)sender;
- (void)closeTapped:(UIButton*)sender;
- (void)timedOut;
@end

@implementation BlinkerNotificationTarget
+ (instancetype)shared {
  static BlinkerNotificationTarget* shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[BlinkerNotificationTarget alloc] init];
  });
  return shared;
}
- (void)bannerTapped:(UITapGestureRecognizer*)gesture {
  BlinkerNotificationBanner* banner = g_notification_banner;
  if (!banner) {
    return;
  }
  content::BlinkerNotificationActivated(
      base::SysNSStringToUTF8(banner.extensionId),
      base::SysNSStringToUTF8(banner.notificationId), -1);
  BlinkerDismissBanner(/*byUser=*/YES, /*tellExtension=*/YES);
}
- (void)buttonTapped:(UIButton*)sender {
  BlinkerNotificationBanner* banner = g_notification_banner;
  if (!banner) {
    return;
  }
  content::BlinkerNotificationActivated(
      base::SysNSStringToUTF8(banner.extensionId),
      base::SysNSStringToUTF8(banner.notificationId),
      static_cast<int>(sender.tag));
  BlinkerDismissBanner(/*byUser=*/YES, /*tellExtension=*/YES);
}
- (void)closeTapped:(UIButton*)sender {
  BlinkerDismissBanner(/*byUser=*/YES, /*tellExtension=*/YES);
}
- (void)timedOut {
  // Банер з таймаутом користувач не закривав, а onClosed у Chrome цю різницю
  // передає.
  BlinkerDismissBanner(/*byUser=*/NO, /*tellExtension=*/YES);
}
@end

extern "C" void BlinkShowExtensionNotification(const char* extension_id,
                                               const char* notification_id,
                                               const char* source_name,
                                               const char* title,
                                               const char* message,
                                               const char* icon_path,
                                               const char* buttons) {
  NSString* extensionId = extension_id ? @(extension_id) : @"";
  NSString* notificationId = notification_id ? @(notification_id) : @"";
  NSString* source = source_name ? @(source_name) : @"";
  NSString* titleText = title ? @(title) : @"";
  NSString* messageText = message ? @(message) : @"";
  NSString* iconPath = icon_path ? @(icon_path) : @"";
  NSArray<NSString*>* buttonTitles =
      (buttons && buttons[0]) ? [@(buttons) componentsSeparatedByString:@"\n"]
                              : @[];
  dispatch_async(dispatch_get_main_queue(), ^{
    content::Shell* shell = KeyWindowShell();
    UIWindow* window = shell ? shell->window().Get() : nil;
    if (!window) {
      return;
    }
    // Новий банер закриває попереднє сповіщення, якщо це не оновлення того
    // самого. Інакше onClosed прийшов би для того, що досі на екрані.
    BlinkerNotificationBanner* current = g_notification_banner;
    const BOOL sameNotification =
        current && [current.extensionId isEqualToString:extensionId] &&
        [current.notificationId isEqualToString:notificationId];
    BlinkerDismissBanner(/*byUser=*/NO, /*tellExtension=*/!sameNotification);

    BlinkerNotificationBanner* banner =
        [[BlinkerNotificationBanner alloc] initWithFrame:CGRectZero];
    banner.extensionId = extensionId;
    banner.notificationId = notificationId;
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.97];
    banner.layer.cornerRadius = 14;
    banner.layer.shadowColor = UIColor.blackColor.CGColor;
    banner.layer.shadowOpacity = 0.35;
    banner.layer.shadowRadius = 10;
    banner.layer.shadowOffset = CGSizeMake(0, 4);

    UIImageView* icon = nil;
    if (iconPath.length) {
      UIImage* image = [UIImage imageWithContentsOfFile:iconPath];
      if (image) {
        icon = [[UIImageView alloc] initWithImage:image];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.layer.cornerRadius = 4;
        icon.clipsToBounds = YES;
      }
    }

    UILabel* sourceLabel = [[UILabel alloc] init];
    sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    sourceLabel.text = source;
    sourceLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    sourceLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UILabel* titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = titleText;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.numberOfLines = 2;

    UILabel* messageLabel = [[UILabel alloc] init];
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    messageLabel.text = messageText;
    messageLabel.font = [UIFont systemFontOfSize:13];
    messageLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    messageLabel.numberOfLines = 3;

    UIStackView* text = [[UIStackView alloc]
        initWithArrangedSubviews:messageText.length
                                     ? @[ sourceLabel, titleLabel, messageLabel ]
                                     : @[ sourceLabel, titleLabel ]];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15];
    [close setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0]
                forState:UIControlStateNormal];
    [close addTarget:[BlinkerNotificationTarget shared]
                  action:@selector(closeTapped:)
        forControlEvents:UIControlEventTouchUpInside];

    UIStackView* row = [[UIStackView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 10;
    if (icon) {
      [row addArrangedSubview:icon];
      [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:32],
        [icon.heightAnchor constraintEqualToConstant:32],
      ]];
    }
    [row addArrangedSubview:text];
    [row addArrangedSubview:close];

    UIStackView* column =
        [[UIStackView alloc] initWithArrangedSubviews:@[ row ]];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 10;

    if (buttonTitles.count) {
      UIStackView* actions = [[UIStackView alloc] init];
      actions.axis = UILayoutConstraintAxisHorizontal;
      actions.spacing = 8;
      actions.distribution = UIStackViewDistributionFillEqually;
      NSInteger index = 0;
      for (NSString* buttonTitle in buttonTitles) {
        if (!buttonTitle.length) {
          ++index;
          continue;
        }
        UIButton* action = [UIButton buttonWithType:UIButtonTypeSystem];
        [action setTitle:buttonTitle forState:UIControlStateNormal];
        action.titleLabel.font = [UIFont systemFontOfSize:14
                                                   weight:UIFontWeightMedium];
        [action setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        action.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
        action.layer.cornerRadius = 8;
        action.tag = index++;
        [action.heightAnchor constraintEqualToConstant:34].active = YES;
        [action addTarget:[BlinkerNotificationTarget shared]
                      action:@selector(buttonTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [actions addArrangedSubview:action];
      }
      if (actions.arrangedSubviews.count) {
        [column addArrangedSubview:actions];
      }
    }

    [banner addSubview:column];
    [window addSubview:banner];
    g_notification_banner = banner;

    UILayoutGuide* safe = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
      [column.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11],
      [column.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor
                                           constant:12],
      [column.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor
                                            constant:-12],
      [column.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor
                                          constant:-11],
      // Під панеллю інструментів, бо вона браузерна.
      [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:56],
      [banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                           constant:10],
      [banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                            constant:-10],
    ]];

    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:[BlinkerNotificationTarget shared]
                action:@selector(bannerTapped:)];
    [banner addGestureRecognizer:tap];

    banner.alpha = 0;
    banner.transform = CGAffineTransformMakeTranslation(0, -20);
    [UIView animateWithDuration:0.22
                     animations:^{
                       banner.alpha = 1;
                       banner.transform = CGAffineTransformIdentity;
                     }];
    [[BlinkerNotificationTarget shared]
        performSelector:@selector(timedOut)
             withObject:nil
             afterDelay:8.0];
  });
}

extern "C" void BlinkHideExtensionNotification(const char* extension_id,
                                               const char* notification_id) {
  NSString* extensionId = extension_id ? @(extension_id) : @"";
  NSString* notificationId = notification_id ? @(notification_id) : @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    BlinkerNotificationBanner* banner = g_notification_banner;
    if (!banner || ![banner.extensionId isEqualToString:extensionId] ||
        ![banner.notificationId isEqualToString:notificationId]) {
      return;
    }
    // Розширення саме прибрало банер, казати йому нічого.
    BlinkerDismissBanner(/*byUser=*/NO, /*tellExtension=*/NO);
  });
}

extern "C" void BlinkPresentWalletPass(const char* path) {
  NSString* file = path ? @(path) : @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    content::Shell* shell = KeyWindowShell();
    UIViewController* presenter = shell ? shell->window().Get().rootViewController
                                        : nil;
    while (presenter.presentedViewController) {
      presenter = presenter.presentedViewController;
    }
    if (!presenter) {
      return;
    }
    NSData* data = [NSData dataWithContentsOfFile:file];
    NSError* error = nil;
    PKPass* pass =
        data.length ? [[PKPass alloc] initWithData:data error:&error] : nil;
    PKAddPassesViewController* add =
        pass && [PKAddPassesViewController canAddPasses]
            ? [[PKAddPassesViewController alloc] initWithPass:pass]
            : nil;
    if (add) {
      [presenter presentViewController:add animated:YES completion:nil];
      return;
    }
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:BlinkL(@"Can't add this pass")
                         message:BlinkL(@"The file was saved to Downloads.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
  });
}

extern "C" void BlinkMarkDownloadAttention() {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"BlinkDownloadAttention"];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kBlinkDownloadAttentionChanged
                      object:nil];
  });
}

// Мости вікон для shell.cc, бо там нема UIKit. Вікно входу Google
// AddNewContents тримає як Shell, а window.close() вертає екран відкривачу.

// Робить UIWindow для |shell| key і видимим в активній сцені, як при
// перемиканні вкладок.
extern "C" void BlinkPresentShellWindow(content::Shell* shell) {
  if (!shell) {
    return;
  }
  UIWindow* win = shell->window().Get();
  if (!win) {
    return;
  }
  if (@available(iOS 13.0, *)) {
    if (!win.windowScene) {
      for (content::Shell* s : content::Shell::windows()) {
        if (s == shell) {
          continue;
        }
        UIWindow* w = s->window().Get();
        if (w && w.windowScene) {
          win.windowScene = w.windowScene;
          break;
        }
      }
    }
  }
  for (content::Shell* candidate : content::Shell::windows()) {
    UIWindow* candidateWindow = candidate->window().Get();
    if (candidate != shell && candidateWindow && !candidateWindow.hidden) {
      BlinkCaptureTabPreview(candidate);
    }
  }
  if (shell->web_contents()) {
    shell->web_contents()->WasShown();
  }
  win.hidden = NO;
  [win makeKeyAndVisible];
  // Решту ховаємо після показу нової, щоб між ними не було порожнього кадру.
  for (content::Shell* candidate : content::Shell::windows()) {
    if (candidate == shell) {
      continue;
    }
    UIWindow* candidateWindow = candidate->window().Get();
    if (candidateWindow) {
      candidateWindow.hidden = YES;
    }
    if (candidate->web_contents()) {
      candidate->web_contents()->WasHidden();
    }
  }
  BLINKER_DIAG("AUTH_POPUP_GUARD: shell window presented");
}

extern "C" void BlinkHideShellWindow(content::Shell* shell) {
  if (!shell) {
    return;
  }
  UIWindow* win = shell->window().Get();
  if (win) {
    win.hidden = YES;
  }
  if (shell->web_contents()) {
    shell->web_contents()->WasHidden();
  }
}

static NSString* const kBlinkMemorySaverKey = @"BlinkMemorySaver";
static NSString* const kBlinkMemorySaverSitesKey = @"BlinkMemorySaverSites";

// 0 вимкнено, 1 помірний, 2 збалансований (як було до налаштування), 3 макс.
static NSInteger BlinkMemorySaverLevel() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if (![d objectForKey:kBlinkMemorySaverKey]) {
    return 2;
  }
  return std::clamp<NSInteger>([d integerForKey:kBlinkMemorySaverKey], 0, 3);
}

// У приватному режимі винятки живуть до кінця сеансу, на диск не пишуться.
static NSMutableSet<NSString*>* BlinkSessionMemorySaverSites() {
  static NSMutableSet<NSString*>* hosts = [NSMutableSet set];
  return hosts;
}

static NSArray<NSString*>* BlinkMemorySaverSites() {
  return [[NSUserDefaults standardUserDefaults]
             stringArrayForKey:kBlinkMemorySaverSitesKey]
             ?: @[];
}

// Вкладку з винятку або з якої грає звук просто так не присипляєм.
static bool BlinkTabStaysActive(content::WebContents* contents) {
  if (contents->IsCurrentlyAudible()) {
    return true;
  }
  const std::string host(contents->GetLastCommittedURL().host());
  if (host.empty()) {
    return false;
  }
  NSString* h = base::SysUTF8ToNSString(host);
  return [BlinkMemorySaverSites() containsObject:h] ||
         [BlinkSessionMemorySaverSites() containsObject:h];
}

// proactive значить по таймеру чи ліміту вкладок. Під тиском пам'яті винятки
// не діють, інакше jetsam вб'є застосунок разом з усіма вкладками.
static void BlinkDiscardBackgroundTabsExcept(content::Shell* keep,
                                             bool proactive) {
  for (content::Shell* candidate : content::Shell::windows()) {
    if (candidate == keep || !candidate->web_contents()) {
      continue;
    }
    content::WebContents* contents = candidate->web_contents();
    if (proactive && BlinkTabStaysActive(contents)) {
      continue;
    }
    contents->WasHidden();
    contents->SetPageFrozen(true);
    content::NavigationEntry* last =
        contents->GetController().GetLastCommittedEntry();
    if (!contents->WasDiscarded() && last && !last->IsInitialEntry() &&
        !contents->HasUncommittedNavigationInPrimaryMainFrame()) {
      contents->Discard(base::DoNothing());
      BLINKER_DIAG("TAB_LIFECYCLE: discarded inactive renderer");
    }
  }
}

namespace {

// Фонова вкладка без дотиків стільки хвилин засинає навіть без нестачі
// пам'яті. Відновиться вона з запису навігації. 0 значить ніколи.
int MemorySaverIdleMinutes(NSInteger level) {
  switch (level) {
    case 0:
      return 0;
    case 1:
      return content::BlinkerLowMemoryDevice() ? 10 : 30;
    case 3:
      return content::BlinkerLowMemoryDevice() ? 1 : 2;
    default:
      return content::BlinkerLowMemoryDevice() ? 2 : 10;
  }
}

// Скільки вкладок може бути живими, поки нова не присипить решту.
size_t MemorySaverResidentTabLimit(NSInteger level) {
  switch (level) {
    case 0:
      return std::numeric_limits<size_t>::max();
    case 1:
      return content::BlinkerLowMemoryDevice() ? 4 : 8;
    case 3:
      return content::BlinkerLowMemoryDevice() ? 2 : 3;
    default:
      return content::BlinkerLowMemoryDevice() ? 3 : 6;
  }
}

constexpr int64_t kIdleTabSweepSeconds = 60;

std::map<content::Shell*, double>& TabLastActiveTime() {
  static base::NoDestructor<std::map<content::Shell*, double>> times;
  return *times;
}

content::Shell* KeyWindowShell() {
  for (content::Shell* candidate : content::Shell::windows()) {
    UIWindow* window = candidate->window().Get();
    if (window && window.isKeyWindow) {
      return candidate;
    }
  }
  return nullptr;
}

}  // namespace

namespace {

// Маска орієнтації, яку попросила сторінка, або all. iOS крутить лиш у ті
// орієнтації, які віддає supportedInterfaceOrientations.
UIInterfaceOrientationMask g_orientation_mask = UIInterfaceOrientationMaskAll;

UIInterfaceOrientationMask MaskForLock(
    device::mojom::ScreenOrientationLockType lock) {
  using LockType = device::mojom::ScreenOrientationLockType;
  switch (lock) {
    case LockType::PORTRAIT_PRIMARY:
      return UIInterfaceOrientationMaskPortrait;
    case LockType::PORTRAIT_SECONDARY:
      return UIInterfaceOrientationMaskPortraitUpsideDown;
    case LockType::PORTRAIT:
      return UIInterfaceOrientationMaskPortrait |
             UIInterfaceOrientationMaskPortraitUpsideDown;
    case LockType::LANDSCAPE_PRIMARY:
      return UIInterfaceOrientationMaskLandscapeRight;
    case LockType::LANDSCAPE_SECONDARY:
      return UIInterfaceOrientationMaskLandscapeLeft;
    case LockType::LANDSCAPE:
      return UIInterfaceOrientationMaskLandscape;
    default:
      return UIInterfaceOrientationMaskAll;
  }
}

void ApplyOrientationMask(UIInterfaceOrientationMask mask) {
  g_orientation_mask = mask;
  content::Shell* shell = KeyWindowShell();
  UIWindow* window = shell ? shell->window().Get() : nil;
  UIViewController* root = window.rootViewController;
  if (!root) {
    return;
  }
  if (@available(iOS 16.0, *)) {
    UIWindowScene* scene = window.windowScene;
    if (scene) {
      UIWindowSceneGeometryPreferencesIOS* preferences =
          [[UIWindowSceneGeometryPreferencesIOS alloc]
              initWithInterfaceOrientations:mask];
      [scene requestGeometryUpdateWithPreferences:preferences
                                     errorHandler:^(NSError* error){
                                     }];
    }
    [root setNeedsUpdateOfSupportedInterfaceOrientations];
  } else {
    // До iOS 16 публічного запиту повороту нема, так роблять всі браузери з
    // fullscreen відео на цих версіях.
    UIInterfaceOrientation target = (mask & UIInterfaceOrientationMaskLandscape)
                                        ? UIInterfaceOrientationLandscapeRight
                                        : UIInterfaceOrientationPortrait;
    if (mask != UIInterfaceOrientationMaskAll) {
      [[UIDevice currentDevice] setValue:@(target) forKey:@"orientation"];
    }
    [UIViewController attemptRotationToDeviceOrientation];
  }
}

// Без цього screen.orientation.lock() відхиляється, і плеєр YouTube, що блокує
// орієнтацію при переході у fullscreen, лишається чорним.
class BlinkerScreenOrientationDelegate
    : public content::ScreenOrientationDelegate {
 public:
  bool FullScreenRequired(content::WebContents* web_contents) override {
    return true;
  }

  void Lock(content::WebContents* web_contents,
            device::mojom::ScreenOrientationLockType lock) override {
    BLINKER_DIAG("ORIENTATION: lock requested");
    ApplyOrientationMask(MaskForLock(lock));
  }

  bool ScreenOrientationProviderSupported(
      content::WebContents* web_contents) override {
    return true;
  }

  void Unlock(content::WebContents* web_contents) override {
    BLINKER_DIAG("ORIENTATION: unlocked");
    ApplyOrientationMask(UIInterfaceOrientationMaskAll);
  }
};

}  // namespace

extern "C" UIInterfaceOrientationMask BlinkSupportedOrientations(void) {
  return g_orientation_mask;
}

// Fullscreen міняє viewport, а не орієнтацію. UIKit лишає поточну орієнтацію
// і блок повороту, а сторінка може окремо кликати Screen Orientation API.
extern "C" void BlinkInstallOrientationDelegate(void) {
  static base::NoDestructor<BlinkerScreenOrientationDelegate> delegate;
  content::ScreenOrientationProvider::SetDelegate(delegate.get());
  BLINKER_DIAG("ORIENTATION: delegate installed");
}

// Для кожної нової вкладки, shell.cc кличе з конструктора Shell.
void BlinkApplyPrivacyRendererPrefs(blink::RendererPreferences* prefs) {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  const bool ask_not_to_track = [d boolForKey:@"BlinkGlobalPrivacyControl"];
  prefs->enable_do_not_track = ask_not_to_track;
  prefs->is_global_privacy_control_setting_enabled = ask_not_to_track;
  content::BlinkerSetTrackingParamStripping(
      [d boolForKey:@"BlinkStripTrackingParams"]);
}

static bool g_blink_fresh_start_pending = false;

// Fresh Start. До відновлення вкладок прибираєм усе, що лишає слід перегляду.
// Cookies і сховища сайтів чистяться трохи пізніше, коли є профіль.
extern "C" void BlinkApplyFreshStart(void) {
  content::BlinkerDeleteLegacyClosedTabs();
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if (![d boolForKey:@"BlinkFreshStart"]) {
    return;
  }
  for (NSString* key in @[
         @"BlinkOpenTabs", @"BlinkPendingCrashTabs", @"BlinkTabTitlesByURL",
         @"BlinkActiveTabIndex", @"BlinkActiveTabURL", @"BlinkHistory"
       ]) {
    [d removeObjectForKey:key];
  }
  for (NSString* key in d.dictionaryRepresentation.allKeys) {
    if ([key hasPrefix:@"BlinkZoom_"]) {
      [d removeObjectForKey:key];
    }
  }
  // Домашню сторінку при збої ховали тимчасово, без запиту про відновлення
  // вона б так і лишилась схованою.
  if (NSString* homepage = [d stringForKey:@"BlinkCrashHomepage"]) {
    [d setObject:homepage forKey:@"BlinkHomepage"];
    [d removeObjectForKey:@"BlinkCrashHomepage"];
  }
  [d synchronize];
  NSString* caches = NSSearchPathForDirectoriesInDomains(
                         NSCachesDirectory, NSUserDomainMask, YES)
                         .firstObject;
  if (caches) {
    [NSFileManager.defaultManager
        removeItemAtPath:[caches stringByAppendingPathComponent:@"TabPreviews"]
                   error:nil];
  }
  content::BlinkerDeleteTabSessions();
  g_blink_fresh_start_pending = true;
  BLINKER_DIAG("FRESH_START: cleared history, tabs and previews");
}

static void BlinkFinishFreshStart() {
  if (!g_blink_fresh_start_pending) {
    return;
  }
  g_blink_fresh_start_pending = false;
  content::BlinkClearAllSiteData(
      content::ShellContentBrowserClient::Get()->browser_context());
}

extern "C" void BlinkNoteTabActivated(content::Shell* shell) {
  if (shell) {
    TabLastActiveTime()[shell] = CFAbsoluteTimeGetCurrent();
  }
}

// Чистить вкладки, які давно не чіпали. Тригери тиску і кількості реагують
// коли вже погано, а цей не дає до того дійти.
extern "C" void BlinkDiscardIdleBackgroundTabs(void) {
  std::map<content::Shell*, double>& times = TabLastActiveTime();
  const double now = CFAbsoluteTimeGetCurrent();
  content::Shell* keep = KeyWindowShell();
  if (!keep && !content::Shell::windows().empty()) {
    keep = content::Shell::windows().front();
  }

  // Викидаєм записи закритих вкладок, щоб не розіменувати звільнений Shell.
  std::map<content::Shell*, double> live;
  for (content::Shell* candidate : content::Shell::windows()) {
    auto found = times.find(candidate);
    live[candidate] = found == times.end() ? now : found->second;
  }
  times.swap(live);

  for (content::Shell* candidate : content::Shell::windows()) {
    if (candidate == keep) {
      times[candidate] = now;
      continue;
    }
    content::WebContents* contents = candidate->web_contents();
    if (!contents || contents->WasDiscarded() ||
        contents->HasUncommittedNavigationInPrimaryMainFrame() ||
        BlinkTabStaysActive(contents)) {
      continue;
    }
    const int idle_minutes = MemorySaverIdleMinutes(BlinkMemorySaverLevel());
    if (idle_minutes == 0 || now - times[candidate] < idle_minutes * 60.0) {
      continue;
    }
    contents->WasHidden();
    contents->SetPageFrozen(true);
    contents->Discard(base::DoNothing());
    BLINKER_DIAG("TAB_LIFECYCLE: discarded idle background tab");
  }
}

extern "C" void BlinkStartIdleTabSweep(void) {
  static dispatch_source_t timer = nullptr;
  if (timer) {
    return;
  }
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                 dispatch_get_main_queue());
  dispatch_source_set_timer(
      timer,
      dispatch_time(DISPATCH_TIME_NOW, kIdleTabSweepSeconds * NSEC_PER_SEC),
      kIdleTabSweepSeconds * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    BlinkDiscardIdleBackgroundTabs();
  });
  dispatch_resume(timer);
}

extern "C" void BlinkDiscardBackgroundTabs(content::Shell* keep) {
  // Звичайний тригер (нова вкладка), скидаєм тільки коли вкладок вже багато.
  if (content::Shell::windows().size() <
      MemorySaverResidentTabLimit(BlinkMemorySaverLevel())) {
    return;
  }
  // Без `keep` лишається видима вкладка. З першою в списку посилання, відкрите
  // у фоні, перезавантажувало сторінку, на якій людина лишилась.
  if (!keep) {
    keep = KeyWindowShell();
  }
  if (!keep) {
    keep = content::Shell::windows().front();
  }
  BlinkDiscardBackgroundTabsExcept(keep, /*proactive=*/true);
}

// Тиск пам'яті. Тут поріг кількості вкладок не діє, бо інакше jetsam вб'є всі
// вкладки. Вкладка ключового вікна лишається завжди.
extern "C" void BlinkDiscardBackgroundTabsUnderPressure(void) {
  if (content::Shell::windows().size() < 2) {
    return;
  }
  content::Shell* keep = nullptr;
  for (content::Shell* candidate : content::Shell::windows()) {
    UIWindow* window = candidate->window().Get();
    if (window && window.isKeyWindow) {
      keep = candidate;
      break;
    }
  }
  if (!keep) {
    keep = content::Shell::windows().front();
  }
  BLINKER_DIAG("TAB_LIFECYCLE: memory pressure -> shedding background tabs");
  BlinkDiscardBackgroundTabsExcept(keep, /*proactive=*/false);
}

// Перед window.close(). Якщо закривається вкладка ключового вікна, спершу
// активуємо іншу, бажано відкривача, інакше екран лишиться мертвим.
extern "C" void BlinkActivateShell(content::Shell* shell);

extern "C" void BlinkShellWillCloseReactivate(
    content::Shell* closing,
    content::WebContents* preferred_opener) {
  UIWindow* closingWin = closing ? closing->window().Get() : nil;
  if (!closingWin || !closingWin.isKeyWindow) {
    return;
  }
  // Попап розширення стоїть над вкладкою, з якої його відкрили, туди і вертаємось.
  if (!preferred_opener && closing->web_contents()) {
    preferred_opener =
        content::BlinkerExtensionPageOpener(closing->web_contents());
  }
  content::Shell* replacement = nullptr;
  if (preferred_opener) {
    for (content::Shell* s : content::Shell::windows()) {
      if (s != closing && s->web_contents() == preferred_opener) {
        replacement = s;
        break;
      }
    }
  }
  if (!replacement) {
    // Без відкривача береться вкладка, на якій людина була востаннє, а не перша
    // в списку: та могла бути скинута і показати чорний екран.
    const std::map<content::Shell*, double>& times = TabLastActiveTime();
    double best = -1;
    for (content::Shell* s : content::Shell::windows()) {
      if (s == closing) {
        continue;
      }
      const auto found = times.find(s);
      const double when = found == times.end() ? 0 : found->second;
      if (!replacement || when > best) {
        replacement = s;
        best = when;
      }
    }
  }
  if (!replacement) {
    return;
  }
  UIWindow* win = replacement->window().Get();
  if (!win) {
    return;
  }
  if (@available(iOS 13.0, *)) {
    if (closingWin.windowScene) {
      win.windowScene = closingWin.windowScene;
    }
  }
  [win makeKeyAndVisible];
  // Попап при відкритті сховав цю вкладку через WasHidden, а makeKeyAndVisible
  // показує лиш вікно. Без WasShown сторінка лишається сірою до перемикання.
  if (content::WebContents* contents = replacement->web_contents()) {
    contents->WasShown();
  }
  BlinkNoteTabActivated(replacement);
  // Далі той самий шлях, що й при перемиканні вкладок: він розморожує сторінку,
  // перезавантажує скинуту і піднімає відкладену. Без цього вкладка, яку
  // присипив менеджер пам'яті, поки стояв попап, лишалась порожньою.
  BlinkActivateShell(replacement);
  BLINKER_DIAG("AUTH_POPUP_GUARD: reactivated previous window after close");
}

@interface TracingHandler : NSObject {
 @private
  std::unique_ptr<perfetto::TracingSession> _tracingSession;
  NSFileHandle* _traceFileHandle;
}

- (void)startWithHandler:(void (^)())startHandler
             stopHandler:(void (^)())stopHandler
              categories:(const char*)categories;
- (void)stop;
- (BOOL)isTracing;

@end

// Стрілки пошуку малюємо самі, бо SF Symbols на iOS 12 нема.
static UIImage* BlinkChevronImage(BOOL up) {
  UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
  UIBezierPath* path = [UIBezierPath bezierPath];
  path.lineWidth = 2;
  path.lineCapStyle = kCGLineCapRound;
  path.lineJoinStyle = kCGLineJoinRound;
  [path moveToPoint:CGPointMake(5, up ? 14 : 8)];
  [path addLineToPoint:CGPointMake(11, up ? 8 : 14)];
  [path addLineToPoint:CGPointMake(17, up ? 14 : 8)];
  [UIColor.blackColor setStroke];
  [path stroke];
  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

typedef void (^BlinkFindReplyBlock)(int matches, int ordinal);

// Слухає відповіді пошуку Chromium, щоб показати номер збігу.
class BlinkFindObserver : public content::WebContentsObserver {
 public:
  BlinkFindObserver(content::WebContents* contents, BlinkFindReplyBlock block)
      : content::WebContentsObserver(contents), block_(block) {}

  void DidReceiveFindReply(int request_id,
                           int number_of_matches,
                           const gfx::Rect& selection_rect,
                           int active_match_ordinal,
                           bool final_update) override {
    if (block_) {
      block_(number_of_matches, active_match_ordinal);
    }
  }

 private:
  BlinkFindReplyBlock block_;
};

// Вузька панель пошуку, як у Safari і Chrome. Стоїть над клавіатурою, поле
// зліва, лічильник, дві стрілки і Done.
@interface BlinkFindBar : UIView <UITextFieldDelegate> {
 @private
  base::WeakPtr<content::WebContents> _webContents;
  std::unique_ptr<BlinkFindObserver> _observer;
  UITextField* _field;
  UILabel* _count;
}
@property(nonatomic, copy) void (^onDone)(void);
- (instancetype)initWithWebContents:(content::WebContents*)webContents;
- (void)focus;
@end

@implementation BlinkFindBar

- (instancetype)initWithWebContents:(content::WebContents*)webContents {
  if ((self = [super initWithFrame:CGRectZero])) {
    _webContents = webContents->GetWeakPtr();
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    __weak BlinkFindBar* weakSelf = self;
    _observer = std::make_unique<BlinkFindObserver>(
        webContents, ^(int matches, int ordinal) {
          [weakSelf showMatches:matches ordinal:ordinal];
        });

    UIView* line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    [self addSubview:line];

    _field = [[UITextField alloc] init];
    _field.delegate = self;
    _field.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _field.layer.cornerRadius = 9;
    _field.font = [UIFont systemFontOfSize:15];
    _field.textColor = UIColor.whiteColor;
    _field.tintColor = BlinkerAccentColor();
    _field.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:BlinkL(@"Find in Page")
            attributes:@{
              NSForegroundColorAttributeName : [UIColor colorWithWhite:0.6
                                                                 alpha:1.0]
            }];
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.textContentType = UITextContentTypeURL;
    _field.returnKeyType = UIReturnKeySearch;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    UIView* padding =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    _field.leftView = padding;
    _field.leftViewMode = UITextFieldViewModeAlways;
    [_field addTarget:self
                  action:@selector(textChanged)
        forControlEvents:UIControlEventEditingChanged];

    _count = [[UILabel alloc] init];
    _count.font = [UIFont monospacedDigitSystemFontOfSize:13
                                                   weight:UIFontWeightRegular];
    _count.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _count.textAlignment = NSTextAlignmentRight;
    [_count setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];

    UIButton* up = [self arrowButton:YES];
    UIButton* down = [self arrowButton:NO];
    UIButton* done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:BlinkL(@"Done") forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [done setTitleColor:BlinkerAccentColor() forState:UIControlStateNormal];
    [done addTarget:self
                  action:@selector(finish)
        forControlEvents:UIControlEventTouchUpInside];

    UIStackView* row = [[UIStackView alloc]
        initWithArrangedSubviews:@[ _field, _count, up, down, done ]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    [self addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
      [line.topAnchor constraintEqualToAnchor:self.topAnchor],
      [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [line.heightAnchor constraintEqualToConstant:0.5],
      [_field.heightAnchor constraintEqualToConstant:32],
      [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
      [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
      [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-10],
      [row.bottomAnchor
          constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                         constant:-6],
    ]];
  }
  return self;
}

- (UIButton*)arrowButton:(BOOL)up {
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setImage:BlinkChevronImage(up) forState:UIControlStateNormal];
  button.tintColor = UIColor.whiteColor;
  button.accessibilityLabel =
      BlinkL(up ? @"Previous Match" : @"Next Match");
  [button.widthAnchor constraintEqualToConstant:34].active = YES;
  [button.heightAnchor constraintEqualToConstant:32].active = YES;
  [button addTarget:self
                action:up ? @selector(previous) : @selector(next)
      forControlEvents:UIControlEventTouchUpInside];
  return button;
}

- (void)focus {
  [_field becomeFirstResponder];
}

- (void)showMatches:(int)matches ordinal:(int)ordinal {
  _count.text = _field.text.length
                    ? [NSString stringWithFormat:@"%d/%d", MAX(ordinal, 0),
                                                 MAX(matches, 0)]
                    : @"";
}

- (void)runForward:(BOOL)forward newSession:(BOOL)newSession {
  if (!_webContents || _field.text.length == 0) {
    return;
  }
  auto options = blink::mojom::FindOptions::New();
  options->forward = forward;
  options->new_session = newSession;
  _webContents->Find(base::SysNSStringToUTF16(_field.text), std::move(options),
                     /*skip_delay=*/true, [](int request_id) {});
}

- (void)textChanged {
  if (_field.text.length == 0) {
    _count.text = @"";
    if (_webContents) {
      _webContents->StopFinding(content::STOP_FIND_ACTION_CLEAR_SELECTION);
    }
    return;
  }
  [self runForward:YES newSession:YES];
}

- (void)previous {
  [self runForward:NO newSession:NO];
}

- (void)next {
  [self runForward:YES newSession:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField {
  [self runForward:YES newSession:NO];
  return NO;
}

- (void)finish {
  if (_webContents) {
    _webContents->StopFinding(content::STOP_FIND_ACTION_KEEP_SELECTION);
  }
  [_field resignFirstResponder];
  if (_onDone) {
    _onDone();
  }
}

@end

@class BlinkerStartPageView;
@class BlinkerPullGesture;

@interface ContentShellWindowDelegate
    : UIViewController <UITextFieldDelegate,
                        UIPopoverPresentationControllerDelegate,
                        UIDocumentPickerDelegate> {
 @private
  raw_ptr<content::Shell> _shell;
  // Поки YES, меню і сторінки відкриваються без анімації.
  BOOL _rebuildingMenu;
  std::unique_ptr<content::ScopedAccessibilityMode> _scopedAccessibilityMode;
}
@property(nonatomic, strong) UIStackView* toolbarBackgroundView;
// Справжній UIView під вмістом стеку, бо UIStackView до iOS 13 фон малював
// ненадійно.
@property(nonatomic, strong) UIView* toolbarPaintView;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* topPosConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* bottomPosConstraints;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* contentHorizontalConstraints;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* fullscreenConstraints;
@property(nonatomic, assign) CGFloat keyboardViewportInset;
@property(nonatomic, assign) CGFloat webKeyboardInset;
@property(nonatomic, assign) CGFloat nativeKeyboardInset;
- (void)refreshKeyboardInset;
@property(nonatomic, strong) BlinkerStartPageView* startPage;
@property(nonatomic, strong) UIView* findBar;
@property(nonatomic, strong) UIStackView* toolbarContentView;
@property(nonatomic, strong) UIButton* backButton;
@property(nonatomic, strong) UIButton* forwardButton;
@property(nonatomic, strong) UIButton* reloadOrStopButton;
@property(nonatomic, strong) UIButton* menuButton;
@property(nonatomic, strong) UITextField* urlField;
@property(nonatomic, strong) UIView* contentView;
@property(nonatomic, strong) UIProgressView* loadingProgressView;
@property(nonatomic, strong) UIActivityIndicatorView* pullSpinner;
@property(nonatomic, strong) BlinkerPullGesture* pullGesture;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* loadingProgressConstraints;
@property(nonatomic, strong) UIView* privacyLockView;
@property(nonatomic, strong) UIView* switcherCoverView;
@property(nonatomic, strong) CLLocationManager* permissionLocationManager;
@property(nonatomic, strong) TracingHandler* tracingHandler;
@property(nonatomic, strong) UILongPressGestureRecognizer* kioskExitGesture;
@property(nonatomic, assign) BOOL kioskLayoutApplied;
// Кнопки зліва в рядку адреси, замок сайту і звук вкладки.
@property(nonatomic, strong) UIButton* siteButton;
@property(nonatomic, strong) UIButton* audioButton;
@property(nonatomic, strong) UIView* siteButtonsView;
// Що імпортуєм з вибраного файлу, BlinkImportKind.
@property(nonatomic, assign) NSInteger pendingImportKind;
@property(nonatomic, copy) NSString* lastWebStorePrompt;

+ (UIColor*)backgroundColorDefault;
+ (UIColor*)backgroundColorTracing;
- (id)initWithShell:(content::Shell*)shell;
- (content::Shell*)shell;
- (UIStackView*)createToolbarBackgroundView;
- (UIStackView*)createToolbarContentView;
- (UIButton*)makeButton:(NSString*)imageName action:(SEL)action;
- (UITextField*)makeURLBar;
- (void)back;
- (void)forward;
- (void)reloadOrStop;
- (void)restartApplication;
- (void)togglePrivateBrowsing;
- (void)applyToolbarPosition;
- (UIImage*)googleProfileImage;
- (UIImage*)googleSecondaryProfileImage;
- (NSString*)googleProfileSubtitle;
- (void)showFindInPage;
- (void)refreshAppearance;
- (void)showMainMenu;
- (void)showSettings;
- (void)openUserInput:(NSString*)input;
- (void)handleURLBarSwipe:(UISwipeGestureRecognizer*)gesture;
- (void)navigateByEdgeSwipe:(NSInteger)direction;
- (void)switchToTab:(content::Shell*)shell direction:(NSInteger)direction;
- (void)showTabWindow:(content::Shell*)shell;
- (void)updateDownloadAttentionBadge;
- (void)setURL:(NSString*)url;
- (void)setContents:(UIView*)content;
- (void)stopTracing;
- (void)startTracingWithCategories:(const char*)categories;
- (void)voiceOverStatusDidChange;
- (void)updatePullToRefreshProgress:(CGFloat)progress;
- (void)finishPullToRefresh:(BOOL)triggered;
- (void)showCrashRestorePrompt;
- (void)updateSiteButtons;
- (void)showSiteSettings;
@end

// Свайп від бокового краю назад чи вперед. Як і BlinkerPullGesture лише
// стежить за дотиками, сторінка їх теж отримує
@interface BlinkerEdgeSwipeGesture
    : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, weak) ContentShellWindowDelegate* swipeController;
@property(nonatomic, assign) CGPoint origin;
@property(nonatomic, assign) CGPoint current;
@property(nonatomic, assign) NSTimeInterval startTime;
// -1 від лівого краю, 1 від правого, 0 жест не стежимо
@property(nonatomic, assign) NSInteger direction;
@end

@implementation BlinkerEdgeSwipeGesture
- (instancetype)init {
  if ((self = [super initWithTarget:nil action:nil])) {
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    self.delegate = self;
  }
  return self;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)other {
  return NO;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)other {
  return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer*)other {
  return YES;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  self.direction = 0;
  if (event.allTouches.count != 1) {
    return;
  }
  self.origin = [touches.anyObject locationInView:self.view];
  self.current = self.origin;
  self.startTime = event.timestamp;
  const CGFloat width = self.view.bounds.size.width;
  if (self.origin.x < 20) {
    self.direction = -1;
  } else if (self.origin.x > width - 20) {
    self.direction = 1;
  }
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (!self.direction) {
    return;
  }
  self.current = [touches.anyObject locationInView:self.view];
  if (fabs(self.current.y - self.origin.y) > 120) {
    self.direction = 0;
  }
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  const NSInteger direction = self.direction;
  self.direction = 0;
  if (!direction) {
    return;
  }
  // Швидкий і переважно горизонтальний рух, повільне тягнення ручки
  // виділення біля краю сюди не потрапляє
  const CGFloat moved = self.current.x - self.origin.x;
  const CGFloat sideways = fabs(self.current.y - self.origin.y);
  const BOOL quick = event.timestamp - self.startTime < 0.8;
  if (quick && sideways < fabs(moved) * 0.6 &&
      ((direction < 0 && moved > 90) || (direction > 0 && moved < -90))) {
    [self.swipeController navigateByEdgeSwipe:direction];
  }
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  self.direction = 0;
}
@end

// Слідкуєм за дотиками, не забираючи їх у Blink. Overscroll рендерера лиш
// сигнал, в ньому і fling, і це не хід пальця в точках UIKit.
@interface BlinkerPullGesture
    : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property(nonatomic, weak) ContentShellWindowDelegate* pullController;
@property(nonatomic, assign) BOOL tracking;
@property(nonatomic, assign) BOOL eligible;
@property(nonatomic, assign) CGPoint origin;
@property(nonatomic, assign) CGPoint current;
@property(nonatomic, assign) CGFloat overscrollOrigin;
- (void)reportOverscroll:(CGFloat)points allowed:(BOOL)allowed;
@end

@implementation BlinkerPullGesture
- (instancetype)init {
  if ((self = [super initWithTarget:nil action:nil])) {
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    self.delegate = self;
  }
  return self;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)other {
  return NO;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)other {
  return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer*)other {
  return YES;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (event.allTouches.count != 1 || self.tracking) {
    [self cancelPull];
    return;
  }
  self.tracking = YES;
  self.eligible = NO;
  self.origin = [touches.anyObject locationInView:self.view];
  self.current = self.origin;
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (!self.tracking) {
    return;
  }
  self.current = [touches.anyObject locationInView:self.view];
  if (fabs(self.current.x - self.origin.x) > 70 ||
      self.pullController.keyboardViewportInset > 0) {
    [self cancelPull];
    return;
  }
  if (self.eligible) {
    [self.pullController updatePullToRefreshProgress:[self progress]];
  }
}
- (CGFloat)progress {
  // 180 точок після першого не спожитого overscroll. Рух назад скасовує, а
  // короткий перехід порогу refresh не запускає.
  return MAX(0, self.current.y - self.overscrollOrigin) / 180.0;
}
- (void)reportOverscroll:(CGFloat)points allowed:(BOOL)allowed {
  if (!self.tracking) {
    return;
  }
  if (!allowed || self.pullController.keyboardViewportInset > 0) {
    [self cancelPull];
    return;
  }
  if (points <= 0) {
    self.eligible = NO;
    [self.pullController updatePullToRefreshProgress:0];
  } else if (!self.eligible) {
    self.eligible = YES;
    self.overscrollOrigin = self.current.y;
  }
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (self.tracking) {
    self.current = [touches.anyObject locationInView:self.view];
    BOOL commit = self.eligible && [self progress] >= 1 &&
                  self.pullController.keyboardViewportInset == 0;
    [self.pullController finishPullToRefresh:commit];
  }
  self.tracking = NO;
  self.eligible = NO;
  // Recognizer тільки спостерігає, fail не чіпає жести Blink.
  self.state = UIGestureRecognizerStateFailed;
}
- (void)cancelPull {
  [self.pullController finishPullToRefresh:NO];
  self.tracking = NO;
  self.eligible = NO;
  self.state = UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self cancelPull];
}
- (void)reset {
  [super reset];
  self.tracking = NO;
  self.eligible = NO;
}
@end

extern "C" void BlinkOverscrollPull(float pull_points, bool allowed) {
  content::Shell* shell = KeyWindowShell();
  UIWindow* window = shell ? shell->window().Get() : nil;
  if ([window.rootViewController
          isKindOfClass:[ContentShellWindowDelegate class]]) {
    ContentShellWindowDelegate* owner =
        (ContentShellWindowDelegate*)window.rootViewController;
    [owner.pullGesture reportOverscroll:pull_points allowed:allowed];
  }
}

// Модальний список для вкладок, закладок і завантажень.
@interface BlinkListVC : UITableViewController
@property(nonatomic, strong) NSMutableArray<NSString*>* titles;
@property(nonatomic, strong) NSMutableArray<NSString*>* subtitles;
@property(nonatomic, strong) NSArray<NSString*>* imageNames;
@property(nonatomic, strong) NSArray* rowImages;
@property(nonatomic, strong) NSArray<NSString*>* sectionTitles;
@property(nonatomic, strong) NSArray<NSNumber*>* sectionStarts;
@property(nonatomic, strong) NSIndexSet* disabledRows;
@property(nonatomic, strong) NSIndexSet* checkedRows;
@property(nonatomic, strong) NSIndexSet* badgedRows;
// Кольори заголовків рядків, паралельно до titles (NSNull це звичайний).
@property(nonatomic, strong) NSArray* titleColors;
@property(nonatomic, assign) NSInteger protectedIndex;  // -1 значить нема
@property(nonatomic, strong) NSIndexSet* protectedRows;
@property(nonatomic, assign) BOOL reloadAfterDelete;
@property(nonatomic, assign) BOOL isTabList;  // YES пише логи TAB_MANAGER_UI
// Рядки це дані людини (історія, закладки, завантаження), їх не перекладаєм.
@property(nonatomic, assign) BOOL literalRows;
@property(nonatomic, copy) NSString* sourceTitle;
// Абзац сірим над списком, англійський ключ ui_strings.json.
@property(nonatomic, copy) NSString* headerNote;
- (void)applyInterfaceLanguage;
- (void)applyNavigationBarAppearance;
@property(nonatomic, assign) BOOL compactRows;
@property(nonatomic, assign) BOOL dismissOnSelect;
@property(nonatomic, assign) BOOL dismissOnAdd;
@property(nonatomic, copy) void (^onSelect)(NSInteger);
@property(nonatomic, copy) void (^onDelete)(NSInteger);  // nil без видалення
@property(nonatomic, copy) void (^onRefresh)(void);
@property(nonatomic, strong) NSTimer* refreshTimer;
@property(nonatomic, copy) void (^onAdd)(void);  // nil без кнопки +
@end

@implementation BlinkListVC
- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStylePlain])) {
    _protectedIndex = -1;
    _dismissOnSelect = YES;
    _dismissOnAdd = YES;
  }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  if (!self.literalRows) {
    self.sourceTitle = self.title;
  }
  [self applyInterfaceLanguage];
  if (self.navigationController.viewControllers.firstObject == self) {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(doneTapped)];
  }
  if (self.onAdd) {
    UIBarButtonItem* add = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(addTapped)];
    if (self.dismissOnAdd) {
      self.navigationItem.leftBarButtonItem = add;
    } else {
      self.navigationItem.rightBarButtonItem = add;
    }
  }
  UIColor* bg = [UIColor colorWithWhite:0.09 alpha:1.0];
  self.tableView.backgroundColor = bg;
  self.tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
  // Рядок росте під опис, тож довгий текст переноситься одним розміром, а не
  // стискається і не обрізається трьома крапками.
  if (self.isTabList) {
    self.tableView.rowHeight = 76;
  } else {
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = self.compactRows ? 48 : 58;
  }
  self.tableView.tableFooterView = [[UIView alloc] init];
  [self applyNavigationBarAppearance];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self layoutHeaderNote];
}

- (void)layoutHeaderNote {
  if (!self.headerNote.length) {
    return;
  }
  const CGFloat width = self.tableView.bounds.size.width;
  UIView* header = self.tableView.tableHeaderView;
  UILabel* label = header.subviews.firstObject;
  if (!header) {
    header = [[UIView alloc] init];
    label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    [header addSubview:label];
  }
  label.text = BlinkL(self.headerNote);
  const CGSize fit =
      [label sizeThatFits:CGSizeMake(width - 32, CGFLOAT_MAX)];
  const CGRect frame = CGRectMake(0, 0, width, ceil(fit.height) + 24);
  label.frame = CGRectMake(16, 14, width - 32, ceil(fit.height));
  // Таблиця перераховує відступ лиш коли заголовок присвоєно заново.
  if (!CGRectEqualToRect(header.frame, frame) ||
      self.tableView.tableHeaderView != header) {
    header.frame = frame;
    self.tableView.tableHeaderView = header;
  }
}

// Мову могли змінити поки екран був у стеку, тож заголовок перекладаєм заново.
- (void)applyInterfaceLanguage {
  if (self.sourceTitle.length) {
    self.title = BlinkL(self.sourceTitle);
  }
}

// Панель навігації спільна для всіх екранів цього контролера, тож кожен екран
// фарбує її під себе при кожній появі.
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self applyNavigationBarAppearance];
  [self applyInterfaceLanguage];
  if (self.onRefresh) {
    self.onRefresh();
    __weak BlinkListVC* weakSelf = self;
    [self.refreshTimer invalidate];
    self.refreshTimer =
        [NSTimer scheduledTimerWithTimeInterval:1
                                        repeats:YES
                                          block:^(NSTimer* timer) {
                                            BlinkListVC* list = weakSelf;
                                            if (!list) {
                                              [timer invalidate];
                                              return;
                                            }
                                            if (list.onRefresh) {
                                              list.onRefresh();
                                            }
                                          }];
  }
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [self.refreshTimer invalidate];
  self.refreshTimer = nil;
}

- (void)applyNavigationBarAppearance {
  UINavigationBar* bar = self.navigationController.navigationBar;
  if (!bar) {
    return;
  }
  UIColor* barColor = BlinkerThemeColor();
  bar.tintColor = [UIColor whiteColor];
  if (@available(iOS 13.0, *)) {
    UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithOpaqueBackground];
    // Компактні рядки міняють лиш щільність таблиці і не мають тихо
    // перефарбувати панель навігації.
    ap.backgroundColor = barColor;
    ap.titleTextAttributes =
        @{NSForegroundColorAttributeName : UIColor.whiteColor};
    bar.standardAppearance = ap;
    bar.scrollEdgeAppearance = ap;
    bar.compactAppearance = ap;
  } else {
    bar.translucent = NO;
    bar.barTintColor = barColor;
    bar.titleTextAttributes =
        @{NSForegroundColorAttributeName : UIColor.whiteColor};
  }
}
- (void)doneTapped {
  [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)addTapped {
  if (self.isTabList) {
    BLINKER_DIAG("TAB_MANAGER_UI: plus tapped");
    BLINKER_DIAG("TAB_MANAGER_UI: requested new tab");
  }
  void (^add)(void) = self.onAdd;
  if (!self.dismissOnAdd) {
    if (add) {
      add();
    }
    return;
  }
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (add) {
                               add();
                             }
                           }];
}
- (void)backTapped {
  [self.navigationController popViewControllerAnimated:YES];
}
- (NSInteger)globalRowForIndexPath:(NSIndexPath*)ip {
  if (!self.sectionStarts.count) {
    return ip.row;
  }
  return self.sectionStarts[ip.section].integerValue + ip.row;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return self.sectionStarts.count ? self.sectionStarts.count : 1;
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {
  if (!self.sectionStarts.count) {
    return self.titles.count;
  }
  NSInteger start = self.sectionStarts[s].integerValue;
  NSInteger end = s + 1 < (NSInteger)self.sectionStarts.count
                      ? self.sectionStarts[s + 1].integerValue
                      : self.titles.count;
  return MAX(0, end - start);
}
- (NSString*)tableView:(UITableView*)tableView
    titleForHeaderInSection:(NSInteger)section {
  return section < (NSInteger)self.sectionTitles.count
             ? BlinkL(self.sectionTitles[section])
             : nil;
}
// Перекладені заголовки секцій бувають довші за англійські.
- (void)tableView:(UITableView*)tableView
    willDisplayHeaderView:(UIView*)view
               forSection:(NSInteger)section {
  if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
    UITableViewHeaderFooterView* header = (UITableViewHeaderFooterView*)view;
    UILabel* label = header.textLabel;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    // Список завжди темний, а iOS 12 без темної теми малює світлу смугу.
    label.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    UIView* background = [[UIView alloc] init];
    background.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    header.backgroundView = background;
  }
}
- (UITableViewCell*)tableView:(UITableView*)t
        cellForRowAtIndexPath:(NSIndexPath*)ip {
  NSInteger row = [self globalRowForIndexPath:ip];
  UITableViewCell* c = [t dequeueReusableCellWithIdentifier:@"c"];
  if (!c) {
    c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:@"c"];
  }
  c.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
  const BOOL translate = !self.literalRows && !self.isTabList;
  c.textLabel.text = translate ? BlinkL(self.titles[row]) : self.titles[row];
  c.textLabel.numberOfLines = self.isTabList ? 1 : 2;
  c.textLabel.adjustsFontSizeToFitWidth = NO;
  UIColor* titleColor = UIColor.whiteColor;
  if (row < (NSInteger)self.titleColors.count &&
      [self.titleColors[row] isKindOfClass:[UIColor class]]) {
    titleColor = self.titleColors[row];
  }
  c.textLabel.textColor = titleColor;
  c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
  NSString* subtitle =
      (row < (NSInteger)self.subtitles.count) ? self.subtitles[row] : @"";
  c.detailTextLabel.text = translate ? BlinkL(subtitle) : subtitle;
  c.detailTextLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
  c.detailTextLabel.font = [UIFont systemFontOfSize:13];
  c.detailTextLabel.adjustsFontSizeToFitWidth = NO;
  // Адреса лишається одним рядком з обрізанням, речення переноситься.
  const BOOL sentence = !self.isTabList && ![subtitle containsString:@"://"] &&
                        [subtitle containsString:@" "];
  c.detailTextLabel.numberOfLines = sentence ? 0 : 1;
  c.detailTextLabel.lineBreakMode =
      sentence ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
  if (row < (NSInteger)self.rowImages.count &&
      [self.rowImages[row] isKindOfClass:[UIImage class]]) {
    c.imageView.image = self.rowImages[row];
    c.imageView.contentMode = UIViewContentModeScaleAspectFill;
    c.imageView.clipsToBounds = NO;
    c.imageView.layer.cornerRadius = 0;
    c.imageView.tintColor = BlinkerAccentColor();
  } else if (row < (NSInteger)self.imageNames.count) {
    UIImage* icon = BlinkSystemImage(self.imageNames[row]);
    c.imageView.image = icon;
    c.imageView.tintColor = BlinkerAccentColor();
  } else {
    c.imageView.image = nil;
  }
  UIView* sel = [[UIView alloc] init];
  sel.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
  c.selectedBackgroundView = sel;
  c.selectionStyle = [self.disabledRows containsIndex:row]
                         ? UITableViewCellSelectionStyleNone
                         : UITableViewCellSelectionStyleDefault;
  c.accessoryType = [self.checkedRows containsIndex:row]
                        ? UITableViewCellAccessoryCheckmark
                        : UITableViewCellAccessoryNone;
  if ([self.badgedRows containsIndex:row]) {
    UILabel* badge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    badge.text = @"!";
    badge.textAlignment = NSTextAlignmentCenter;
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = UIColor.systemRedColor;
    badge.font = [UIFont boldSystemFontOfSize:12];
    badge.layer.cornerRadius = 9;
    badge.clipsToBounds = YES;
    c.accessoryView = badge;
  } else {
    c.accessoryView = nil;
  }
  c.tintColor = BlinkerAccentColor();
  return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
  [t deselectRowAtIndexPath:ip animated:NO];
  NSInteger row = [self globalRowForIndexPath:ip];
  if ([self.disabledRows containsIndex:row]) {
    return;
  }
  if (self.isTabList) {
    BLINKER_DIAGF("TAB_MANAGER_UI: existing tab tapped id=%ld", (long)row);
    BLINKER_DIAGF("TAB_MANAGER_UI: requested switch to tab id=%ld", (long)row);
  }
  void (^sel)(NSInteger) = self.onSelect;
  if (!self.dismissOnSelect) {
    if (sel) {
      sel(row);
    }
    return;
  }
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (sel) {
                               sel(row);
                             }
                           }];
}
- (BOOL)tableView:(UITableView*)t canEditRowAtIndexPath:(NSIndexPath*)ip {
  return self.onDelete != nil &&
         [self globalRowForIndexPath:ip] != self.protectedIndex &&
         ![self.protectedRows containsIndex:[self globalRowForIndexPath:ip]];
}
- (void)tableView:(UITableView*)t
    commitEditingStyle:(UITableViewCellEditingStyle)style
     forRowAtIndexPath:(NSIndexPath*)ip {
  if (style != UITableViewCellEditingStyleDelete || !self.onDelete) {
    return;
  }
  NSInteger row = [self globalRowForIndexPath:ip];
  if (self.isTabList) {
    BLINKER_DIAGF("TAB_MANAGER_UI: close tapped id=%ld", (long)row);
  }
  self.onDelete(row);
  if (self.reloadAfterDelete) {
    [t reloadData];
    return;
  }
  [self.titles removeObjectAtIndex:row];
  if (row < (NSInteger)self.subtitles.count) {
    [self.subtitles removeObjectAtIndex:row];
  }
  if (row < (NSInteger)self.imageNames.count) {
    NSMutableArray* images = [self.imageNames mutableCopy];
    [images removeObjectAtIndex:row];
    self.imageNames = images;
  }
  if (self.protectedIndex > row) {
    self.protectedIndex--;
  }
  [t deleteRowsAtIndexPaths:@[ ip ]
           withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

@interface BlinkBookmarkEditorVC : UIViewController
@property(nonatomic, assign) BOOL folderMode;
@property(nonatomic, strong) UITextField* nameField;
@property(nonatomic, strong) UITextField* urlField;
@property(nonatomic, copy) NSString* initialName;
@property(nonatomic, copy) NSString* initialURL;
@property(nonatomic, copy) void (^onSave)(NSString*, NSString*);
@end

@implementation BlinkBookmarkEditorVC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = BlinkL(self.folderMode ? @"New Folder" : @"New Bookmark");
  self.view.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                           target:self
                           action:@selector(save)];
  _nameField =
      [self fieldWithPlaceholder:BlinkL(self.folderMode ? @"Folder name"
                                                         : @"Name")];
  NSMutableArray* fields = [NSMutableArray arrayWithObject:_nameField];
  if (!self.folderMode) {
    _urlField = [self fieldWithPlaceholder:@"https://example.com"];
    _urlField.keyboardType = UIKeyboardTypeURL;
    [fields addObject:_urlField];
    _nameField.text = self.initialName;
    _urlField.text = self.initialURL;
  }
  UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:fields];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 14;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                       constant:24],
    [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                        constant:20],
    [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                         constant:-20],
  ]];
  [_nameField becomeFirstResponder];
}
- (UITextField*)fieldWithPlaceholder:(NSString*)placeholder {
  UITextField* field = [[UITextField alloc] init];
  field.placeholder = placeholder;
  field.textColor = UIColor.whiteColor;
  field.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
  field.layer.cornerRadius = 12;
  field.layer.borderWidth = 1;
  field.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1].CGColor;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  UIView* pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
  field.leftView = pad;
  field.leftViewMode = UITextFieldViewModeAlways;
  [field.heightAnchor constraintEqualToConstant:50].active = YES;
  return field;
}
- (void)save {
  NSString* name = [_nameField.text
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  NSString* url = [_urlField.text
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (!name.length || (!self.folderMode && !url.length)) {
    return;
  }
  if (!self.folderMode && ![url containsString:@"://"]) {
    url = [@"https://" stringByAppendingString:url];
  }
  if (!self.folderMode && ![NSURL URLWithString:url].host.length) {
    return;
  }
  if (self.onSave) {
    self.onSave(name, url ?: @"");
  }
  // Назад до списку закладок, а не до вибору виду
  NSArray<UIViewController*>* stack = self.navigationController.viewControllers;
  if (stack.count >= 3) {
    [self.navigationController popToViewController:stack[stack.count - 3]
                                          animated:YES];
  } else {
    [self.navigationController popViewControllerAnimated:YES];
  }
}
@end

// Колір монограми з назви сайту, щоб однакові сайти мали однаковий значок.
static UIColor* BlinkMonogramColor(NSString* seed) {
  const NSUInteger hash = seed.hash;
  return [UIColor colorWithHue:(hash % 360) / 360.0
                    saturation:0.45
                    brightness:0.62
                         alpha:1.0];
}

// Одноколірна копія шаблонного значка. imageWithTintColor є лише з iOS 13.
static UIImage* BlinkTintedImage(UIImage* image, UIColor* color) {
  if (!image) {
    return nil;
  }
  UIGraphicsBeginImageContextWithOptions(image.size, NO, 0);
  [image drawAtPoint:CGPointZero];
  CGContextRef context = UIGraphicsGetCurrentContext();
  CGContextSetBlendMode(context, kCGBlendModeSourceIn);
  [color setFill];
  CGContextFillRect(context, CGRectMake(0, 0, image.size.width, image.size.height));
  UIImage* tinted = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return tinted;
}

// Перша літера хоста, бо значків сайтів у списку вкладок нема. Для порожньої
// вкладки нейтральний квадрат із глобусом.
static UIImage* BlinkMonogramImage(NSString* title, CGFloat side) {
  if ([title isEqualToString:BlinkL(@"New Tab")]) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [[UIColor colorWithWhite:0.32 alpha:1.0] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                cornerRadius:side * 0.22] fill];
    [BlinkTintedImage(BlinkSystemImage(@"globe"), UIColor.whiteColor)
        drawInRect:CGRectMake(side * 0.16, side * 0.16, side * 0.68,
                              side * 0.68)];
    UIImage* neutral = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return neutral;
  }
  NSString* letter = title.length
                         ? [[title substringToIndex:1] uppercaseString]
                         : @"?";
  UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
  [BlinkMonogramColor(title) setFill];
  [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                              cornerRadius:side * 0.22] fill];
  NSDictionary* attributes = @{
    NSFontAttributeName : [UIFont systemFontOfSize:side * 0.62
                                            weight:UIFontWeightSemibold],
    NSForegroundColorAttributeName : UIColor.whiteColor
  };
  const CGSize text = [letter sizeWithAttributes:attributes];
  [letter drawAtPoint:CGPointMake((side - text.width) / 2,
                                  (side - text.height) / 2)
       withAttributes:attributes];
  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image;
}

// Стан вкладки для значка в кутку знімка.
typedef NS_ENUM(NSInteger, BlinkTabState) {
  BlinkTabStateNormal,
  BlinkTabStateSleeping,
  BlinkTabStateMuted,
  BlinkTabStateAudible,
};

@interface BlinkTabCardCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView* preview;
@property(nonatomic, strong) UILabel* titleLabel;
@property(nonatomic, strong) UIImageView* faviconView;
@property(nonatomic, strong) UIButton* closeButton;
@property(nonatomic, strong) UIImageView* stateBadge;
@property(nonatomic, strong) UILabel* placeholderLetter;
- (void)configureWithTitle:(NSString*)title
                   preview:(UIImage*)preview
                     state:(BlinkTabState)state
                   current:(BOOL)current;
@end

@implementation BlinkTabCardCell {
  UIView* _shadowView;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.contentView.backgroundColor = UIColor.clearColor;
    self.contentView.clipsToBounds = NO;
    _shadowView = [[UIView alloc] init];
    _shadowView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    _shadowView.layer.cornerRadius = 18;
    _shadowView.layer.shadowColor = UIColor.blackColor.CGColor;
    _shadowView.layer.shadowOpacity = 0.35;
    _shadowView.layer.shadowRadius = 9;
    _shadowView.layer.shadowOffset = CGSizeMake(0, 4);
    if (@available(iOS 13.0, *)) {
      _shadowView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _preview = [[UIImageView alloc] init];
    _preview.contentMode = UIViewContentModeScaleAspectFill;
    _preview.clipsToBounds = YES;
    _preview.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    _preview.layer.cornerRadius = 18;
    _preview.layer.borderWidth = 0.5;
    _preview.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    if (@available(iOS 13.0, *)) {
      _preview.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _placeholderLetter = [[UILabel alloc] init];
    _placeholderLetter.font = [UIFont systemFontOfSize:44
                                                weight:UIFontWeightSemibold];
    _placeholderLetter.textColor = [UIColor colorWithWhite:0.32 alpha:1];
    _placeholderLetter.textAlignment = NSTextAlignmentCenter;
    _faviconView = [[UIImageView alloc] init];
    _faviconView.layer.cornerRadius = 3.5;
    _faviconView.clipsToBounds = YES;
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _stateBadge = [[UIImageView alloc] init];
    _stateBadge.tintColor = UIColor.whiteColor;
    _stateBadge.contentMode = UIViewContentModeCenter;
    _stateBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _stateBadge.layer.cornerRadius = 12;
    _stateBadge.clipsToBounds = YES;
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setImage:BlinkSystemImage(@"xmark.circle.fill")
                  forState:UIControlStateNormal];
    _closeButton.tintColor = UIColor.whiteColor;
    _closeButton.backgroundColor =
        [[UIColor colorWithWhite:0.5 alpha:1] colorWithAlphaComponent:0.6];
    _closeButton.layer.cornerRadius = 12;
    _closeButton.clipsToBounds = YES;
    _closeButton.accessibilityLabel = BlinkL(@"Close");
    UIStackView* caption = [[UIStackView alloc]
        initWithArrangedSubviews:@[ _faviconView, _titleLabel ]];
    caption.spacing = 5;
    caption.alignment = UIStackViewAlignmentCenter;
    caption.tag = 7;
    for (UIView* view in @[
           _shadowView, _preview, _placeholderLetter, _stateBadge,
           _closeButton, caption
         ]) {
      view.translatesAutoresizingMaskIntoConstraints = NO;
      [self.contentView addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
      [_shadowView.topAnchor constraintEqualToAnchor:_preview.topAnchor],
      [_shadowView.leadingAnchor constraintEqualToAnchor:_preview.leadingAnchor],
      [_shadowView.trailingAnchor
          constraintEqualToAnchor:_preview.trailingAnchor],
      [_shadowView.bottomAnchor constraintEqualToAnchor:_preview.bottomAnchor],
      [_preview.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                         constant:2],
      [_preview.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:2],
      [_preview.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-2],
      [_preview.bottomAnchor
          constraintEqualToAnchor:caption.topAnchor
                         constant:-8],
      [_placeholderLetter.centerXAnchor
          constraintEqualToAnchor:_preview.centerXAnchor],
      [_placeholderLetter.centerYAnchor
          constraintEqualToAnchor:_preview.centerYAnchor],
      [caption.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
      [caption.heightAnchor constraintEqualToConstant:20],
      [caption.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
      [caption.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor
                                      constant:6],
      [caption.trailingAnchor
          constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor
                                   constant:-6],
      [_faviconView.widthAnchor constraintEqualToConstant:16],
      [_faviconView.heightAnchor constraintEqualToConstant:16],
      [_closeButton.topAnchor constraintEqualToAnchor:_preview.topAnchor
                                             constant:9],
      [_closeButton.trailingAnchor
          constraintEqualToAnchor:_preview.trailingAnchor
                         constant:-9],
      [_closeButton.widthAnchor constraintEqualToConstant:24],
      [_closeButton.heightAnchor constraintEqualToConstant:24],
      [_stateBadge.topAnchor constraintEqualToAnchor:_preview.topAnchor
                                            constant:9],
      [_stateBadge.leadingAnchor constraintEqualToAnchor:_preview.leadingAnchor
                                                constant:9],
      [_stateBadge.widthAnchor constraintEqualToConstant:24],
      [_stateBadge.heightAnchor constraintEqualToConstant:24],
    ]];
  }
  return self;
}

// Кнопка закриття мала, тож дотик трохи поза її краєм теж її.
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  const CGRect target = CGRectInset(_closeButton.frame, -10, -10);
  if (CGRectContainsPoint(target, point) && !_closeButton.hidden) {
    return _closeButton;
  }
  return [super hitTest:point withEvent:event];
}

- (void)configureWithTitle:(NSString*)title
                   preview:(UIImage*)preview
                     state:(BlinkTabState)state
                   current:(BOOL)current {
  self.titleLabel.text = title;
  self.faviconView.image = BlinkMonogramImage(title, 16);
  const BOOL hasImage = preview.size.width > 0;
  self.preview.image = hasImage ? preview : nil;
  self.placeholderLetter.hidden = hasImage;
  self.placeholderLetter.text =
      title.length ? [[title substringToIndex:1] uppercaseString] : @"";
  // Приспана вкладка ще не завантажена, тож її знімок тьмяніший.
  self.preview.alpha = state == BlinkTabStateSleeping ? 0.55 : 1.0;
  self.preview.layer.borderWidth = current ? 2.5 : 0.5;
  self.preview.layer.borderColor =
      current ? BlinkerAccentColor().CGColor
              : [UIColor colorWithWhite:0.3 alpha:1].CGColor;
  NSString* badge = nil;
  if (state == BlinkTabStateMuted) {
    badge = @"speaker.slash.fill";
  } else if (state == BlinkTabStateAudible) {
    badge = @"speaker.wave.2.fill";
  }
  self.stateBadge.hidden = badge == nil;
  self.stateBadge.image = badge ? BlinkSystemImage(badge) : nil;
}

- (void)prepareForReuse {
  [super prepareForReuse];
  self.preview.image = nil;
}
@end

@interface BlinkTabsVC : UIViewController <UICollectionViewDataSource,
                                           UICollectionViewDelegate>
@property(nonatomic, strong) UICollectionView* collectionView;
@property(nonatomic, strong) NSMutableArray<NSString*>* titles;
@property(nonatomic, strong) NSMutableArray<NSString*>* urls;
@property(nonatomic, strong) NSMutableArray<UIImage*>* previews;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* states;
@property(nonatomic, assign) NSInteger currentIndex;
@property(nonatomic, assign) BOOL privateMode;
@property(nonatomic, assign) BOOL reordering;
@property(nonatomic, copy) void (^onSelect)(NSInteger);
@property(nonatomic, copy) BOOL (^onClose)(NSInteger);
@property(nonatomic, copy) void (^onRefresh)(void);
@property(nonatomic, strong) NSTimer* refreshTimer;
@property(nonatomic, copy) void (^onAdd)(void);
@property(nonatomic, copy) void (^onReorder)(NSInteger, NSInteger);
- (instancetype)initWithCollectionViewLayout:(UICollectionViewFlowLayout*)layout;
@end

@implementation BlinkTabsVC {
  UICollectionViewFlowLayout* _layout;
  UIImageView* _privateIcon;
}

- (instancetype)initWithCollectionViewLayout:(UICollectionViewFlowLayout*)layout {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    _layout = layout;
    _currentIndex = -1;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = BlinkL(@"Tabs");
  UIColor* background = [UIColor colorWithWhite:0.055 alpha:1];
  self.view.backgroundColor = background;
  self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                           collectionViewLayout:_layout];
  self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
  self.collectionView.backgroundColor = background;
  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;
  self.collectionView.alwaysBounceVertical = YES;
  [self.collectionView registerClass:[BlinkTabCardCell class]
          forCellWithReuseIdentifier:@"tab"];
  [self.view addSubview:self.collectionView];
  UILongPressGestureRecognizer* reorder = [[UILongPressGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(reorderGesture:)];
  reorder.minimumPressDuration = 0.35;
  [self.collectionView addGestureRecognizer:reorder];

  UIView* bar = [[UIView alloc] init];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  bar.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
  UIView* line = [[UIView alloc] init];
  line.translatesAutoresizingMaskIntoConstraints = NO;
  line.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
  [bar addSubview:line];
  [self.view addSubview:bar];

  _privateIcon = [[UIImageView alloc] initWithImage:BlinkSystemImage(@"eye.slash")];
  _privateIcon.tintColor = BlinkerAccentColor();
  _privateIcon.hidden = !self.privateMode;
  _privateIcon.translatesAutoresizingMaskIntoConstraints = NO;

  UIButton* add = [UIButton buttonWithType:UIButtonTypeSystem];
  [add setImage:BlinkSystemImage(@"plus") forState:UIControlStateNormal];
  add.tintColor = UIColor.whiteColor;
  add.backgroundColor = BlinkerThemeColor();
  add.layer.cornerRadius = 25;
  add.translatesAutoresizingMaskIntoConstraints = NO;
  add.accessibilityLabel = BlinkL(@"New Tab");
  [add addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];

  UIButton* done = [UIButton buttonWithType:UIButtonTypeSystem];
  [done setTitle:BlinkL(@"Done") forState:UIControlStateNormal];
  done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
  [done setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  done.translatesAutoresizingMaskIntoConstraints = NO;
  [done addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
  [bar addSubview:_privateIcon];
  [bar addSubview:add];
  [bar addSubview:done];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.collectionView.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [self.collectionView.bottomAnchor constraintEqualToAnchor:bar.topAnchor],
    [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [bar.topAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-66],
    [line.topAnchor constraintEqualToAnchor:bar.topAnchor],
    [line.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
    [line.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
    [line.heightAnchor constraintEqualToConstant:0.5],
    [add.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:20],
    [add.topAnchor constraintEqualToAnchor:bar.topAnchor constant:8],
    [add.widthAnchor constraintEqualToConstant:50],
    [add.heightAnchor constraintEqualToConstant:50],
    [_privateIcon.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
    [_privateIcon.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
    [done.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-20],
    [done.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
    [done.heightAnchor constraintEqualToConstant:44],
  ]];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.navigationController setNavigationBarHidden:YES animated:NO];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // Стовпців стільки, щоб картка не ставала ширшою за 220 і не вужчою за 150.
  const CGFloat width = self.collectionView.bounds.size.width;
  const CGFloat inset = 16;
  const CGFloat gap = 14;
  NSInteger columns = MAX(2, (NSInteger)floor((width - inset * 2 + gap) / (190 + gap)));
  const CGFloat card = floor((width - inset * 2 - gap * (columns - 1)) / columns);
  const CGSize size = CGSizeMake(card, floor(card * 1.32) + 28);
  if (!CGSizeEqualToSize(_layout.itemSize, size)) {
    _layout.itemSize = size;
    _layout.sectionInset = UIEdgeInsetsMake(16, inset, 24, inset);
    _layout.minimumInteritemSpacing = gap;
    _layout.minimumLineSpacing = 18;
    [_layout invalidateLayout];
  }
}

- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)add {
  void (^handler)(void) = self.onAdd;
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (handler) {
                               handler();
                             }
                           }];
}

- (NSInteger)collectionView:(UICollectionView*)view
     numberOfItemsInSection:(NSInteger)section {
  return self.titles.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)view
                 cellForItemAtIndexPath:(NSIndexPath*)path {
  BlinkTabCardCell* cell = [view dequeueReusableCellWithReuseIdentifier:@"tab"
                                                           forIndexPath:path];
  const NSInteger i = path.item;
  const BlinkTabState state = i < (NSInteger)self.states.count
                                  ? (BlinkTabState)self.states[i].integerValue
                                  : BlinkTabStateNormal;
  [cell configureWithTitle:self.titles[i]
                   preview:self.previews[i]
                     state:state
                   current:i == self.currentIndex];
  cell.accessibilityLabel = self.titles[i];
  cell.accessibilityHint = self.urls[i];
  [cell.closeButton removeTarget:nil
                          action:NULL
                forControlEvents:UIControlEventAllEvents];
  [cell.closeButton addTarget:self
                       action:@selector(closeTapped:)
             forControlEvents:UIControlEventTouchUpInside];
  return cell;
}

- (void)collectionView:(UICollectionView*)view
    didSelectItemAtIndexPath:(NSIndexPath*)path {
  NSInteger index = path.item;
  void (^handler)(NSInteger) = self.onSelect;
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (handler) {
                               handler(index);
                             }
                           }];
}

- (BOOL)collectionView:(UICollectionView*)view
    canMoveItemAtIndexPath:(NSIndexPath*)path {
  return self.titles.count > 1;
}

- (void)collectionView:(UICollectionView*)view
    moveItemAtIndexPath:(NSIndexPath*)from
            toIndexPath:(NSIndexPath*)to {
  NSInteger fromIndex = from.item;
  NSInteger toIndex = to.item;
  if (fromIndex == toIndex || fromIndex >= (NSInteger)self.titles.count ||
      toIndex >= (NSInteger)self.titles.count) {
    return;
  }
  for (NSMutableArray* list in @[ self.titles, self.urls, self.previews, self.states ]) {
    if (fromIndex < (NSInteger)list.count) {
      id item = list[fromIndex];
      [list removeObjectAtIndex:fromIndex];
      [list insertObject:item atIndex:MIN(toIndex, (NSInteger)list.count)];
    }
  }
  if (self.currentIndex == fromIndex) {
    self.currentIndex = toIndex;
  } else if (fromIndex < self.currentIndex && toIndex >= self.currentIndex) {
    --self.currentIndex;
  } else if (fromIndex > self.currentIndex && toIndex <= self.currentIndex) {
    ++self.currentIndex;
  }
  if (self.onReorder) {
    self.onReorder(fromIndex, toIndex);
  }
}

// Довге натискання бере картку і носить її по сітці. Контролер колекції робив
// це сам, а тут вигляд свій.
- (void)reorderGesture:(UILongPressGestureRecognizer*)gesture {
  UICollectionView* view = self.collectionView;
  const CGPoint point = [gesture locationInView:view];
  switch (gesture.state) {
    case UIGestureRecognizerStateBegan: {
      NSIndexPath* path = [view indexPathForItemAtPoint:point];
      if (!path || self.titles.count < 2 ||
          ![view beginInteractiveMovementForItemAtIndexPath:path]) {
        return;
      }
      self.reordering = YES;
      [UIView animateWithDuration:0.15
                       animations:^{
                         [view cellForItemAtIndexPath:path].transform =
                             CGAffineTransformMakeScale(1.04, 1.04);
                       }];
      break;
    }
    case UIGestureRecognizerStateChanged:
      if (self.reordering) {
        [view updateInteractiveMovementTargetPosition:point];
      }
      break;
    case UIGestureRecognizerStateEnded:
      if (self.reordering) {
        self.reordering = NO;
        [view endInteractiveMovement];
      }
      break;
    default:
      if (self.reordering) {
        self.reordering = NO;
        [view cancelInteractiveMovement];
      }
      break;
  }
}

- (void)closeTapped:(UIButton*)button {
  // Рядок беремо з комірки, а не з тегу, бо при перестановці комірки не
  // переналаштовуються і старий тег закрив би не ту вкладку.
  UIView* cell = button.superview;
  while (cell && ![cell isKindOfClass:[UICollectionViewCell class]]) {
    cell = cell.superview;
  }
  NSIndexPath* path =
      cell ? [self.collectionView indexPathForCell:(UICollectionViewCell*)cell]
           : nil;
  if (!path) {
    return;
  }
  NSInteger index = path.item;
  if (self.onClose && !self.onClose(index)) {
    return;
  }
  [self.titles removeObjectAtIndex:index];
  [self.urls removeObjectAtIndex:index];
  [self.previews removeObjectAtIndex:index];
  if (index < (NSInteger)self.states.count) {
    [self.states removeObjectAtIndex:index];
  }
  if (index < self.currentIndex) {
    --self.currentIndex;
  }
  [self.collectionView performBatchUpdates:^{
    [self.collectionView deleteItemsAtIndexPaths:@[ path ]];
  }
                                completion:nil];
}
@end

// Рідна стартова сторінка поверх порожньої вкладки, тож у рядку адреси вона не
// з'являється.
@interface BlinkerStartPageView
    : UIView <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy) void (^onNavigate)(NSString*);
- (void)applyInterfaceLanguage;
// Прозорий фон, щоб скрипт розширення, який малює у порожній сторінці під
// екраном, був видно між елементами.
- (void)setSeeThrough:(BOOL)seeThrough;
@end

@implementation BlinkerStartPageView {
  UITextField* _search;
  UIStackView* _shortcutGrid;
  UITableView* _suggestions;
  NSArray<NSString*>* _suggestionTitles;
  NSURLSessionDataTask* _suggestionTask;
  int64_t _suggestionGeneration;
  BOOL _seeThrough;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor colorWithRed:0.055
                                           green:0.055
                                            blue:0.063
                                           alpha:1.0];

    UIImageView* logo =
        [[UIImageView alloc] initWithImage:BlinkStartLogo()];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo.widthAnchor constraintEqualToConstant:120].active = YES;
    [logo.heightAnchor constraintEqualToConstant:120].active = YES;

    _search = [[UITextField alloc] init];
    BlinkSetSearchPlaceholder(_search, BlinkStartSearchPlaceholderColor());
    _search.backgroundColor = [UIColor colorWithRed:0.122
                                              green:0.122
                                               blue:0.137
                                              alpha:1.0];
    _search.textColor = [UIColor whiteColor];
    _search.font = [UIFont systemFontOfSize:17];
    _search.layer.cornerRadius = 26;
    if (@available(iOS 13.0, *)) {
      _search.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _search.layer.borderWidth = 1;
    _search.layer.borderColor = BlinkerAccentColor().CGColor;
    if (@available(iOS 13.0, *)) {
    } else {
      _search.keyboardAppearance = UIKeyboardAppearanceDark;
    }
    _search.delegate = self;
    [_search addTarget:self
                  action:@selector(searchTextChanged)
        forControlEvents:UIControlEventEditingChanged];
    _search.returnKeyType = UIReturnKeyGo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.textContentType = UITextContentTypeURL;
    _search.keyboardType = UIKeyboardTypeWebSearch;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    UIView* searchIconContainer =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    UIImageView* searchIcon = [[UIImageView alloc]
        initWithImage:BlinkSystemImage(@"magnifyingglass")];
    searchIcon.tintColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    searchIcon.frame = CGRectMake(14, 12, 20, 20);
    [searchIconContainer addSubview:searchIcon];
    _search.leftView = searchIconContainer;
    _search.leftViewMode = UITextFieldViewModeAlways;
    [_search.heightAnchor constraintEqualToConstant:52].active = YES;

    _shortcutGrid = [self makeShortcutGrid];

    UIStackView* column = [[UIStackView alloc]
        initWithArrangedSubviews:@[ logo, _search, _shortcutGrid ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentCenter;
    column.spacing = 16;
    [column setCustomSpacing:28 afterView:_search];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];

    NSLayoutConstraint* width =
        [column.widthAnchor constraintEqualToConstant:540];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
      [column.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [column.centerYAnchor constraintEqualToAnchor:self.centerYAnchor
                                           constant:-36],
      [column.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                      constant:24],
      [column.trailingAnchor
          constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                   constant:-24],
      [_search.widthAnchor constraintEqualToAnchor:column.widthAnchor],
      width,
    ]];
  }
  return self;
}

// Прозорий екран пропускає дотики повз свої елементи до сторінки під ним, там
// Shimeji можна тягати. Порожнє місце екрана нічого не робило.
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  UIView* hit = [super hitTest:point withEvent:event];
  return _seeThrough && hit == self ? nil : hit;
}

- (void)setSeeThrough:(BOOL)seeThrough {
  _seeThrough = seeThrough;
  self.backgroundColor = seeThrough ? [UIColor clearColor]
                                    : [UIColor colorWithRed:0.055
                                                      green:0.055
                                                       blue:0.063
                                                      alpha:1.0];
}

- (NSArray*)shortcutDefinitions {
  NSArray* saved =
      [[NSUserDefaults standardUserDefaults] arrayForKey:@"BlinkShortcuts"];
  if (saved.count == 8) {
    NSString* seventh = [saved[6][@"title"] lowercaseString];
    NSString* eighth = [saved[7][@"title"] lowercaseString];
    if ([seventh isEqualToString:@"discord"] &&
        [eighth isEqualToString:@"gemini"]) {
      NSMutableArray* migrated = [saved mutableCopy];
      migrated[6] = @{@"title" : @"ChatGPT", @"url" : @"https://chatgpt.com"};
      migrated[7] = @{@"title" : @"Claude", @"url" : @"https://claude.ai/new"};
      [[NSUserDefaults standardUserDefaults] setObject:migrated
                                                forKey:@"BlinkShortcuts"];
      return migrated;
    }
    return saved;
  }
  return BlinkDefaultShortcuts();
}

- (UIStackView*)rowWithLinks:(NSArray*)links startIndex:(NSInteger)startIndex {
  NSMutableArray* buttons = [NSMutableArray array];
  NSInteger index = startIndex;
  for (NSDictionary* link in links) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString* title = link[@"title"] ?: BlinkL(@"Site");
    NSString* initial =
        title.length ? [[title substringToIndex:1] uppercaseString] : @"•";
    button.backgroundColor = UIColor.clearColor;
    button.accessibilityIdentifier = link[@"url"];
    button.tag = index++;
    [button.widthAnchor constraintEqualToConstant:64].active = YES;
    [button.heightAnchor constraintEqualToConstant:94].active = YES;

    UIView* iconSurface = [[UIView alloc] init];
    iconSurface.translatesAutoresizingMaskIntoConstraints = NO;
    iconSurface.userInteractionEnabled = NO;
    iconSurface.backgroundColor = [UIColor colorWithRed:0.055
                                                  green:0.055
                                                   blue:0.063
                                                  alpha:1.0];
    iconSurface.layer.cornerRadius = 29;
    if (@available(iOS 13.0, *)) {
      iconSurface.layer.cornerCurve = kCACornerCurveContinuous;
    }
    iconSurface.layer.borderWidth = 1;
    iconSurface.layer.borderColor = BlinkerAccentColor().CGColor;
    UILabel* monogram = [[UILabel alloc] init];
    monogram.translatesAutoresizingMaskIntoConstraints = NO;
    monogram.text = initial;
    monogram.textAlignment = NSTextAlignmentCenter;
    monogram.font = [UIFont systemFontOfSize:25 weight:UIFontWeightSemibold];
    monogram.textColor = BlinkerAccentColor();
    monogram.tag = 701;
    UIImageView* favicon = [[UIImageView alloc] init];
    favicon.translatesAutoresizingMaskIntoConstraints = NO;
    favicon.contentMode = UIViewContentModeScaleAspectFill;
    favicon.clipsToBounds = YES;
    favicon.layer.cornerRadius = 21;
    favicon.tag = 702;
    UILabel* caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = title;
    caption.textAlignment = NSTextAlignmentCenter;
    caption.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    // Текст стартової помаранчевий, як і решта Blinker. Сайти мають свої
    // кольори.
    caption.textColor = BlinkerAccentColor();
    caption.numberOfLines = 2;
    caption.adjustsFontSizeToFitWidth = YES;
    caption.minimumScaleFactor = 0.8;
    [button addSubview:iconSurface];
    [iconSurface addSubview:monogram];
    [iconSurface addSubview:favicon];
    [button addSubview:caption];
    [NSLayoutConstraint activateConstraints:@[
      [iconSurface.topAnchor constraintEqualToAnchor:button.topAnchor],
      [iconSurface.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
      [iconSurface.widthAnchor constraintEqualToConstant:58],
      [iconSurface.heightAnchor constraintEqualToConstant:58],
      [monogram.leadingAnchor
          constraintEqualToAnchor:iconSurface.leadingAnchor],
      [monogram.trailingAnchor
          constraintEqualToAnchor:iconSurface.trailingAnchor],
      [monogram.topAnchor constraintEqualToAnchor:iconSurface.topAnchor],
      [monogram.bottomAnchor constraintEqualToAnchor:iconSurface.bottomAnchor],
      [favicon.leadingAnchor constraintEqualToAnchor:iconSurface.leadingAnchor
                                            constant:8],
      [favicon.trailingAnchor constraintEqualToAnchor:iconSurface.trailingAnchor
                                             constant:-8],
      [favicon.topAnchor constraintEqualToAnchor:iconSurface.topAnchor
                                        constant:8],
      [favicon.bottomAnchor constraintEqualToAnchor:iconSurface.bottomAnchor
                                           constant:-8],
      [caption.topAnchor constraintEqualToAnchor:iconSurface.bottomAnchor
                                        constant:3],
      [caption.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
      [caption.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
      [caption.bottomAnchor
          constraintLessThanOrEqualToAnchor:button.bottomAnchor],
    ]];
    [self loadFaviconForURL:link[@"url"]
                   intoView:favicon
                   fallback:monogram
                buttonIndex:button.tag];
    [button addTarget:self
                  action:@selector(linkTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer* hold = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(shortcutHeld:)];
    [button addGestureRecognizer:hold];
    [buttons addObject:button];
  }
  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.distribution = UIStackViewDistributionEqualSpacing;
  row.spacing = 12;
  return row;
}

- (void)loadFaviconForURL:(NSString*)value
                 intoView:(UIImageView*)imageView
                 fallback:(UILabel*)fallback
              buttonIndex:(NSInteger)buttonIndex {
  NSURLComponents* components = [NSURLComponents componentsWithString:value];
  if (!components.host.length ||
      ![components.scheme.lowercaseString isEqualToString:@"https"]) {
    return;
  }
  NSString* cachePath = BlinkShortcutIconPath(components.host);
  void (^show)(UIImage*) = ^(UIImage* image) {
    UIButton* button = (UIButton*)imageView.superview.superview;
    if (!image || button.tag != buttonIndex) {
      return;
    }
    imageView.image = image;
    fallback.hidden = YES;
  };
  NSDictionary* attributes =
      [[NSFileManager defaultManager] attributesOfItemAtPath:cachePath
                                                       error:nil];
  UIImage* cached = attributes ? [UIImage imageWithContentsOfFile:cachePath]
                               : nil;
  show(cached);
  const BOOL fresh =
      cached && -[attributes.fileModificationDate timeIntervalSinceNow] <
                    7 * 24 * 3600;
  if (fresh || BlinkNativeNetworkingBlocked()) {
    return;
  }
  NSURL* page = components.URL;
  NSURLComponents* root = [[NSURLComponents alloc] init];
  root.scheme = @"https";
  root.host = components.host;
  root.port = components.port;
  NSArray<NSURL*>* wellKnown = @[
    [root.URL URLByAppendingPathComponent:@"apple-touch-icon.png"],
    [root.URL URLByAppendingPathComponent:@"apple-touch-icon-precomposed.png"],
    [root.URL URLByAppendingPathComponent:@"favicon.ico"],
  ];
  void (^finish)(UIImage*) = ^(UIImage* image) {
    if (!image) {
      return;  // Лишаєм монограму.
    }
    [UIImagePNGRepresentation(image) writeToFile:cachePath atomically:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
      show(image);
    });
  };
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:page];
  [request setValue:kBlinkIconUserAgent forHTTPHeaderField:@"User-Agent"];
  [[BlinkNativeSession()
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          NSMutableArray<NSURL*>* candidates = [NSMutableArray array];
          if (data.length) {
            NSData* head = data.length > 262144
                               ? [data subdataWithRange:NSMakeRange(0, 262144)]
                               : data;
            NSString* html =
                [[NSString alloc] initWithData:head
                                      encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithData:head
                                             encoding:NSISOLatin1StringEncoding];
            if (html.length) {
              [candidates
                  addObjectsFromArray:BlinkDeclaredIcons(
                                          html, response.URL ?: page)];
            }
          }
          for (NSURL* url in wellKnown) {
            if (url && ![candidates containsObject:url]) {
              [candidates addObject:url];
            }
          }
          BlinkFetchFirstIcon(candidates, 0, finish);
        }] resume];
}

- (UIStackView*)makeShortcutGrid {
  NSArray* links = [self shortcutDefinitions];
  UIStackView* row1 =
      [self rowWithLinks:[links subarrayWithRange:NSMakeRange(0, 4)]
              startIndex:0];
  UIStackView* row2 =
      [self rowWithLinks:[links subarrayWithRange:NSMakeRange(4, 4)]
              startIndex:4];
  UIStackView* grid =
      [[UIStackView alloc] initWithArrangedSubviews:@[ row1, row2 ]];
  grid.axis = UILayoutConstraintAxisVertical;
  grid.spacing = 18;
  grid.hidden =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkHideShortcuts"];
  return grid;
}

- (UIViewController*)owningViewController {
  UIResponder* next = self;
  while ((next = next.nextResponder)) {
    if ([next isKindOfClass:[UIViewController class]]) {
      return (UIViewController*)next;
    }
  }
  return nil;
}

- (void)rebuildShortcutGrid {
  UIStackView* replacement = [self makeShortcutGrid];
  UIStackView* column = (UIStackView*)_shortcutGrid.superview;
  NSInteger index = [column.arrangedSubviews indexOfObject:_shortcutGrid];
  [column removeArrangedSubview:_shortcutGrid];
  [_shortcutGrid removeFromSuperview];
  _shortcutGrid = replacement;
  [column insertArrangedSubview:_shortcutGrid atIndex:index];
}

- (void)shortcutHeld:(UILongPressGestureRecognizer*)gesture {
  if (gesture.state != UIGestureRecognizerStateBegan) {
    return;
  }
  [[[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
  [self editShortcutAtIndex:gesture.view.tag];
}

- (void)editShortcutAtIndex:(NSInteger)index {
  NSArray* links = [self shortcutDefinitions];
  if (index < 0 || index >= (NSInteger)links.count) {
    return;
  }
  UIViewController* presenter = [self owningViewController];
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  if (!presenter) {
    return;
  }
  NSDictionary* link = links[index];
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Edit Shortcut")
                       message:nil
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Name");
    field.text = link[@"title"];
    field.autocapitalizationType = UITextAutocapitalizationTypeWords;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Address");
    field.text = link[@"url"];
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  __weak UIAlertController* weakAlert = alert;
  __weak __typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Reset All")
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction*) {
                                 [[NSUserDefaults standardUserDefaults]
                                     removeObjectForKey:@"BlinkShortcuts"];
                                 [weakSelf rebuildShortcutGrid];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Save")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction*) {
                                 [weakSelf
                                     saveShortcutAtIndex:index
                                                   title:weakAlert.textFields[0]
                                                             .text
                                                 address:weakAlert.textFields[1]
                                                             .text];
                               }]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)saveShortcutAtIndex:(NSInteger)index
                      title:(NSString*)title
                    address:(NSString*)address {
  NSString* trimmed = [address
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (trimmed.length && ![trimmed containsString:@"://"]) {
    trimmed = [@"https://" stringByAppendingString:trimmed];
  }
  NSURLComponents* components = [NSURLComponents componentsWithString:trimmed];
  NSString* scheme = components.scheme.lowercaseString;
  const BOOL web =
      [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
  if (!components.host.length || !web) {
    return;
  }
  NSString* name = [title
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (!name.length) {
    name = [components.host hasPrefix:@"www."]
               ? [components.host substringFromIndex:4]
               : components.host;
  }
  NSMutableArray* links = [[self shortcutDefinitions] mutableCopy];
  if (index < 0 || index >= (NSInteger)links.count) {
    return;
  }
  links[index] = @{@"title" : name, @"url" : components.URL.absoluteString};
  [[NSUserDefaults standardUserDefaults] setObject:links
                                            forKey:@"BlinkShortcuts"];
  [self rebuildShortcutGrid];
}

- (void)linkTapped:(UIButton*)button {
  UIImpactFeedbackGenerator* feedback = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  if (self.onNavigate && button.accessibilityIdentifier.length) {
    self.onNavigate(button.accessibilityIdentifier);
  }
}

- (void)applyInterfaceLanguage {
  BlinkSetSearchPlaceholder(_search, BlinkStartSearchPlaceholderColor());
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField {
  [textField resignFirstResponder];
  if (self.onNavigate && textField.text.length) {
    self.onNavigate(textField.text);
    textField.text = @"";
  }
  [self hideSuggestions];
  return YES;
}

#pragma mark - Search suggestions

// Підказки є лиш на стартовій сторінці. В рядку адреси їх нема навмисно,
// інакше початок кожного URL, що редагуєш, ішов би пошуковику.
- (UITableView*)suggestionTable {
  if (_suggestions) {
    return _suggestions;
  }
  _suggestions = [[UITableView alloc] initWithFrame:CGRectZero
                                              style:UITableViewStylePlain];
  _suggestions.dataSource = self;
  _suggestions.delegate = self;
  _suggestions.backgroundColor = [UIColor colorWithRed:0.122
                                                 green:0.122
                                                  blue:0.137
                                                 alpha:1.0];
  _suggestions.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
  _suggestions.layer.cornerRadius = 12;
  _suggestions.clipsToBounds = YES;
  _suggestions.hidden = YES;
  _suggestions.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_suggestions];
  [NSLayoutConstraint activateConstraints:@[
    [_suggestions.leadingAnchor constraintEqualToAnchor:_search.leadingAnchor],
    [_suggestions.trailingAnchor
        constraintEqualToAnchor:_search.trailingAnchor],
    [_suggestions.topAnchor constraintEqualToAnchor:_search.bottomAnchor
                                           constant:8],
    [_suggestions.heightAnchor constraintLessThanOrEqualToConstant:220],
  ]];
  return _suggestions;
}

- (void)hideSuggestions {
  _suggestionTitles = nil;
  [_suggestionTask cancel];
  _suggestionTask = nil;
  _suggestions.hidden = YES;
}

- (void)searchTextChanged {
  NSString* term = _search.text ?: @"";
  // Private сесія ніколи не віддає введене пошуковику. В звичайній підказки
  // вмикаються явно.
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  const BOOL enabled =
      [defaults boolForKey:@"BlinkSearchSuggestions"];
  // Цей запит іде через NSURLSession, який не знає про проксі браузера. Із
  // заданим проксі підказок немає, щоб не видати введене напряму.
  const BOOL proxied = BlinkNativeNetworkingBlocked();
  if (!enabled || proxied || BlinkPrivateSession()) {
    [self hideSuggestions];
    return;
  }
  if (term.length < 2) {
    [self hideSuggestions];
    return;
  }
  const SearchEngine& engine = kSearchEngines[g_search_engine];
  if (engine.suggest[0] == '\0') {
    [self hideSuggestions];
    return;
  }

  NSString* escaped = [term stringByAddingPercentEncodingWithAllowedCharacters:
                                [NSCharacterSet URLQueryAllowedCharacterSet]];
  NSURL* url =
      [NSURL URLWithString:[NSString stringWithFormat:@"%s%@", engine.suggest,
                                                      escaped ?: @""]];
  if (!url) {
    [self hideSuggestions];
    return;
  }

  const int64_t generation = ++_suggestionGeneration;
  [_suggestionTask cancel];
  __weak BlinkerStartPageView* weakSelf = self;
  _suggestionTask = [BlinkNativeSession()
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response,
                          NSError* error) {
        if (error || !data) {
          return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:nil];
        // Підказки OpenSearch мають вигляд ["typed", ["first", "second", ...],
        // ...].
        if (![parsed isKindOfClass:NSArray.class] || [parsed count] < 2 ||
            ![parsed[1] isKindOfClass:NSArray.class]) {
          return;
        }
        NSMutableArray<NSString*>* titles = [NSMutableArray array];
        for (id entry in parsed[1]) {
          if ([entry isKindOfClass:NSString.class] && titles.count < 6) {
            [titles addObject:entry];
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          BlinkerStartPageView* strongSelf = weakSelf;
          if (!strongSelf || generation != strongSelf->_suggestionGeneration) {
            return;
          }
          [strongSelf showSuggestions:titles];
        });
      }];
  [_suggestionTask resume];
}

- (void)showSuggestions:(NSArray<NSString*>*)titles {
  _suggestionTitles = titles;
  UITableView* table = [self suggestionTable];
  table.hidden = titles.count == 0;
  [self bringSubviewToFront:table];
  [table reloadData];
}

- (NSInteger)tableView:(UITableView*)table
    numberOfRowsInSection:(NSInteger)section {
  return _suggestionTitles.count;
}

- (UITableViewCell*)tableView:(UITableView*)table
        cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell =
      [table dequeueReusableCellWithIdentifier:@"suggestion"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:@"suggestion"];
    cell.backgroundColor = UIColor.clearColor;
  }
  cell.textLabel.textColor = BlinkerAccentColor();
  cell.textLabel.text = _suggestionTitles[path.row];
  cell.imageView.image = BlinkSystemImage(@"magnifyingglass");
  cell.imageView.tintColor = BlinkerAccentColor();
  return cell;
}

- (void)tableView:(UITableView*)table
    didSelectRowAtIndexPath:(NSIndexPath*)path {
  [table deselectRowAtIndexPath:path animated:NO];
  if (path.row >= (NSInteger)_suggestionTitles.count) {
    return;
  }
  NSString* chosen = _suggestionTitles[path.row];
  [_search resignFirstResponder];
  [self hideSuggestions];
  _search.text = @"";
  if (self.onNavigate) {
    self.onNavigate(chosen);
  }
}

@end

// Колір каретки і виділення одразу у відкритих вкладках, а для веселки ще й
// ховає каретку рушія. Нові документи рендерер налаштовує сам.
static void BlinkApplySelectionColorToOpenTabs(NSString* preference) {
  const std::string pref = base::SysNSStringToUTF8(preference ?: @"");
  const std::string css = content::BlinkerSelectionCss(pref);
  const bool rainbow = pref == content::kBlinkerSelectionRainbow;
  for (content::Shell* shell : content::Shell::windows()) {
    content::WebContents* contents = shell ? shell->web_contents() : nullptr;
    if (!contents) {
      continue;
    }
    contents->ForEachRenderFrameHost([&css, rainbow](
                                         content::RenderFrameHost* frame) {
      const GURL url = frame->GetLastCommittedURL();
      if (!frame->IsRenderFrameLive() ||
          !content::BlinkerWebColorsApplyTo(url)) {
        return;
      }
      mojo::Remote<content::mojom::BlinkerScriptExecutor> executor;
      frame->GetRemoteInterfaces()->GetInterface(
          executor.BindNewPipeAndPassReceiver());
      executor->SetEngineCaretHidden(rainbow);
      executor->RemoveCSS(url, content::kBlinkerSelectionSheetKey, false,
                          base::DoNothing());
      if (!css.empty()) {
        executor->InsertCSS(url, content::kBlinkerSelectionSheetKey, css, false,
                            base::DoNothing());
      }
    });
  }
}

static NSString* BlinkThemeColorName() {
  return BlinkL(@(kBlinkThemeColors[BlinkThemeColorIndex()].name));
}

static NSString* BlinkMemorySaverTitle(NSInteger level) {
  NSArray<NSString*>* names = @[ @"Off", @"Moderate", @"Balanced", @"Maximum" ];
  return BlinkL(names[std::clamp<NSInteger>(level, 0, 3)]);
}

static NSArray<NSString*>* BlinkPrivacyOptionKeys() {
  return @[
    @"BlinkGlobalPrivacyControl", @"BlinkBlockThirdPartyCookies",
    @"BlinkStripTrackingParams", @"BlinkPrivacyCover", @"BlinkFreshStart"
  ];
}

static NSString* BlinkPrivacyOptionsSubtitle() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  unsigned long enabled = 0;
  for (NSString* key in BlinkPrivacyOptionKeys()) {
    enabled += [d boolForKey:key] ? 1 : 0;
  }
  return enabled ? [NSString stringWithFormat:BlinkL(@"%lu on"), enabled]
                 : BlinkL(@"Off");
}

static UIImage* BlinkColorDot(UIColor* color) {
  const CGSize size = CGSizeMake(22, 22);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [color setFill];
  [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 20, 20)] fill];
  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image;
}

static UIColor* BlinkColorFromHex(const char* hex) {
  unsigned int rgb = 0;
  if (!content::BlinkerIsWebColorHex(hex) ||
      ![[NSScanner scannerWithString:[@(hex) substringFromIndex:1]]
          scanHexInt:&rgb]) {
    return nil;
  }
  return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                         green:((rgb >> 8) & 0xff) / 255.0
                          blue:(rgb & 0xff) / 255.0
                         alpha:1.0];
}

static UIColor* BlinkerOrangeColor() {
  return [UIColor colorWithRed:kBlinkThemeColors[0].red / 255.0
                         green:kBlinkThemeColors[0].green / 255.0
                          blue:kBlinkThemeColors[0].blue / 255.0
                         alpha:1.0];
}

// Кружечок веселки, три смужки кольорів, як у рядку вибору кольору.
static UIImage* BlinkRainbowDot() {
  const CGSize size = CGSizeMake(22, 22);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  CGContextRef context = UIGraphicsGetCurrentContext();
  CGContextAddEllipseInRect(context, CGRectMake(1, 1, 20, 20));
  CGContextClip(context);
  NSArray<UIColor*>* stripes = @[
    [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1],
    [UIColor colorWithRed:1 green:0.8 blue:0 alpha:1],
    [UIColor colorWithRed:0.2 green:0.78 blue:0.35 alpha:1],
    [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1],
  ];
  for (NSUInteger i = 0; i < stripes.count; ++i) {
    [stripes[i] setFill];
    UIRectFill(CGRectMake(1 + i * 5, 1, 5, 20));
  }
  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image;
}

static NSString* BlinkSelectionColorName() {
  NSString* value = [[NSUserDefaults standardUserDefaults]
      stringForKey:@(content::kBlinkerSelectionColorKey)];
  if (!value.length) {
    return BlinkL(@(kBlinkThemeColors[0].name));
  }
  if ([value isEqualToString:@(content::kBlinkerSelectionRainbow)]) {
    return @"RGB";
  }
  for (const content::BlinkerWebColorOption& option :
       content::kBlinkerWebColors) {
    if ([value isEqualToString:@(option.hex)]) {
      return BlinkL(@(option.name));
    }
  }
  return BlinkL(@(kBlinkThemeColors[0].name));
}

static NSInteger BlinkWebColorIndex(const char* key) {
  NSString* hex = [[NSUserDefaults standardUserDefaults] stringForKey:@(key)];
  for (size_t i = 1; i < std::size(content::kBlinkerWebColors); ++i) {
    if ([hex isEqualToString:@(content::kBlinkerWebColors[i].hex)]) {
      return static_cast<NSInteger>(i);
    }
  }
  return 0;
}

static NSString* BlinkWebColorName(const char* key) {
  return BlinkL(@(content::kBlinkerWebColors[BlinkWebColorIndex(key)].name));
}

// Новий колір одразу у відкритих вкладках. Нові документи бере рендерер сам.
static void BlinkApplyWebColorsToOpenTabs() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  const std::string css = content::BlinkerWebColorsCss(
      base::SysNSStringToUTF8(
          [d stringForKey:@(content::kBlinkerWebTextColorKey)] ?: @""),
      base::SysNSStringToUTF8(
          [d stringForKey:@(content::kBlinkerWebLinkColorKey)] ?: @""));
  for (content::Shell* shell : content::Shell::windows()) {
    content::WebContents* contents = shell ? shell->web_contents() : nullptr;
    if (!contents) {
      continue;
    }
    contents->ForEachRenderFrameHost([&css](content::RenderFrameHost* frame) {
      const GURL url = frame->GetLastCommittedURL();
      if (!frame->IsRenderFrameLive() ||
          !content::BlinkerWebColorsApplyTo(url)) {
        return;
      }
      mojo::Remote<content::mojom::BlinkerScriptExecutor> executor;
      frame->GetRemoteInterfaces()->GetInterface(
          executor.BindNewPipeAndPassReceiver());
      executor->RemoveCSS(url, content::kBlinkerWebColorsSheetKey, true,
                          base::DoNothing());
      if (!css.empty()) {
        executor->InsertCSS(url, content::kBlinkerWebColorsSheetKey, css, true,
                            base::DoNothing());
      }
    });
  }
}

// Найверхній показаний контролер, з нього показуєм алерти і листи.
static UIViewController* BlinkTopViewController(UIViewController* root) {
  UIViewController* top = root;
  while (top.presentedViewController &&
         !top.presentedViewController.isBeingDismissed) {
    top = top.presentedViewController;
  }
  return top;
}

// Смужка над панеллю з однією дією, як у блокатора спливаючих вікон.
@interface BlinkerActionBar : UIView
@property(nonatomic, copy) dispatch_block_t action;
@end

@implementation BlinkerActionBar
- (void)actionTapped {
  dispatch_block_t action = self.action;
  [self removeFromSuperview];
  if (action) {
    action();
  }
}
- (void)closeTapped {
  [self removeFromSuperview];
}
@end

static __weak BlinkerActionBar* g_action_bar;

static void BlinkShowActionBar(UIWindow* window,
                               NSString* iconName,
                               NSString* text,
                               NSString* buttonTitle,
                               dispatch_block_t action) {
  if (!window) {
    return;
  }
  [g_action_bar removeFromSuperview];
  BlinkerActionBar* bar = [[BlinkerActionBar alloc] initWithFrame:CGRectZero];
  bar.action = action;
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.97];
  bar.layer.cornerRadius = 14;
  bar.layer.shadowColor = UIColor.blackColor.CGColor;
  bar.layer.shadowOpacity = 0.3;
  bar.layer.shadowRadius = 8;
  bar.layer.shadowOffset = CGSizeMake(0, 3);
  bar.accessibilityIdentifier = @"BlinkerActionBar";

  UIImageView* icon =
      [[UIImageView alloc] initWithImage:BlinkSystemImage(iconName)];
  icon.tintColor = [UIColor colorWithWhite:0.75 alpha:1.0];
  icon.contentMode = UIViewContentModeScaleAspectFit;

  UILabel* label = [[UILabel alloc] init];
  label.text = text;
  label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
  label.textColor = UIColor.whiteColor;
  label.numberOfLines = 2;
  label.adjustsFontSizeToFitWidth = YES;
  label.minimumScaleFactor = 0.8;

  NSMutableArray* views = [NSMutableArray arrayWithObjects:icon, label, nil];
  if (buttonTitle.length) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:buttonTitle forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14
                                               weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    button.layer.cornerRadius = 8;
    button.accessibilityIdentifier = @"BlinkerActionBarButton";
    [button setContentHuggingPriority:UILayoutPriorityRequired
                              forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:
                                                UILayoutConstraintAxisHorizontal];
    [button addTarget:bar
                  action:@selector(actionTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [views addObject:button];
  }
  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  [close setTitle:@"✕" forState:UIControlStateNormal];
  close.titleLabel.font = [UIFont systemFontOfSize:15];
  [close setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0]
              forState:UIControlStateNormal];
  [close setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
  [close addTarget:bar
                action:@selector(closeTapped)
      forControlEvents:UIControlEventTouchUpInside];
  [views addObject:close];

  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:views];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 10;
  [bar addSubview:row];
  [window addSubview:bar];
  const BOOL toolbarBottom =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkToolbarBottom"];
  UILayoutGuide* safe = window.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [row.topAnchor constraintEqualToAnchor:bar.topAnchor constant:8],
    [row.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-8],
    [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
    [row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor
                                       constant:-10],
    [icon.widthAnchor constraintEqualToConstant:20],
    [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
    [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                       constant:-10],
    [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                     constant:toolbarBottom ? -66 : -12],
  ]];
  g_action_bar = bar;
  __weak BlinkerActionBar* weakBar = bar;
  // З кнопкою довше, щоб встигли натиснути.
  const int64_t seconds = buttonTitle.length ? 15 : 9;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   [weakBar removeFromSuperview];
                 });
}

extern "C" void BlinkActivateShell(content::Shell* shell);

// Показує вкладку з контролера видимої, як кнопка нової вкладки. Вікно нової
// вкладки ще без windowScene, і власний контролер ставив йому nil, екран
// лишався чорним.
static void BlinkShowTabFromVisible(content::Shell* target) {
  content::Shell* visible = KeyWindowShell();
  UIViewController* root =
      visible ? visible->window().Get().rootViewController : nil;
  if ([root isKindOfClass:[ContentShellWindowDelegate class]]) {
    [(ContentShellWindowDelegate*)root showTabWindow:target];
    return;
  }
  BlinkActivateShell(target);
}

// Посилання з меню довгого натискання. У фоні лишаємось на своїй вкладці.
extern "C" void BlinkOpenURLInNewTab(const char* spec, bool background) {
  content::Shell* source = KeyWindowShell();
  const GURL url(spec ? spec : "");
  if (!source || !source->web_contents() || !url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  const size_t before = content::Shell::windows().size();
  content::Shell* created = content::Shell::CreateNewWindow(
      source->web_contents()->GetBrowserContext(), url, nullptr, gfx::Size());
  BLINKER_DIAGF("LINK_MENU: new tab background=%d created=%d tabs=%zu->%zu",
               background, created != nullptr, before,
               content::Shell::windows().size());
  if (!created) {
    return;
  }
  // CreateNewWindow вікна не показує, як і кнопка нової вкладки.
  BlinkShowTabFromVisible(background ? source : created);
  BlinkSaveOpenTabs();
  if (!background) {
    return;
  }
  BlinkShowActionBar(source->window().Get(), @"square.on.square",
                     BlinkL(@"Opened in a new tab"), BlinkL(@"Show"), ^{
                       for (content::Shell* shell : content::Shell::windows()) {
                         if (shell == created) {
                           BlinkShowTabFromVisible(shell);
                           return;
                         }
                       }
                     });
}

@interface BlinkerPhotoSaver : NSObject
@end

@implementation BlinkerPhotoSaver
- (void)image:(UIImage*)image
    didFinishSavingWithError:(NSError*)error
                 contextInfo:(void*)context {
  dispatch_async(dispatch_get_main_queue(), ^{
    content::Shell* shell = KeyWindowShell();
    UIWindow* window = shell ? shell->window().Get() : nil;
    if (!error) {
      BlinkShowActionBar(window, @"square.and.arrow.down",
                         BlinkL(@"Saved to Photos"), nil, nil);
      return;
    }
    // Найчастіше це заборонений доступ до Фото.
    BlinkShowActionBar(
        window, @"exclamationmark.triangle.fill",
        BlinkL(@"Couldn't save the image"), BlinkL(@"Settings"), ^{
          [UIApplication.sharedApplication
                        openURL:[NSURL URLWithString:
                                           UIApplicationOpenSettingsURLString]
                        options:@{}
              completionHandler:nil];
        });
  });
}
@end

extern "C" void BlinkSaveImageToPhotos(UIImage* image) {
  static BlinkerPhotoSaver* saver = [[BlinkerPhotoSaver alloc] init];
  if (!image) {
    content::Shell* shell = KeyWindowShell();
    BlinkShowActionBar(shell ? shell->window().Get() : nil,
                       @"exclamationmark.triangle.fill",
                       BlinkL(@"Couldn't save the image"), nil, nil);
    return;
  }
  UIImageWriteToSavedPhotosAlbum(
      image, saver, @selector(image:didFinishSavingWithError:contextInfo:),
      nullptr);
}

// "Система" це справжній вигляд iOS.
static UIUserInterfaceStyle BlinkResolvedWebStyle(UIUserInterfaceStyle chosen) {
  if (chosen == UIUserInterfaceStyleLight ||
      chosen == UIUserInterfaceStyleDark) {
    return chosen;
  }
  if (@available(iOS 13.0, *)) {
    return UIScreen.mainScreen.traitCollection.userInterfaceStyle ==
                   UIUserInterfaceStyleDark
               ? UIUserInterfaceStyleDark
               : UIUserInterfaceStyleLight;
  }
  return UIUserInterfaceStyleLight;
}

static void BlinkSetWebColorScheme(UIUserInterfaceStyle style) {
  // OverrideWebPreferences читає цю глобальну, 2 темна, решта світла.
  content::g_blink_preferred_color_scheme = (int)style;
  BLINKER_LOGF("APPEARANCE: web %s state=%d",
               style == UIUserInterfaceStyleDark ? "dark" : "light",
               (int)UIApplication.sharedApplication.applicationState);
  using CS = ui::NativeTheme::PreferredColorScheme;
  const CS scheme =
      style == UIUserInterfaceStyleDark ? CS::kDark : CS::kLight;
  if (ui::NativeTheme* web = ui::NativeTheme::GetInstanceForWeb()) {
    web->set_preferred_color_scheme(scheme);
    web->NotifyOnNativeThemeUpdated();
  }
  for (content::Shell* shell : content::Shell::windows()) {
    if (shell->web_contents()) {
      shell->web_contents()->NotifyPreferencesChanged();
    }
  }
}

// При "Система" йде за iOS без перезавантаження, media query оновлюється сам.
static void BlinkFollowSystemAppearance() {
  // Виходячи з застосунку iOS міняє вигляд туди й назад для знімків
  // перемикача, ще в стані inactive. Перемальовка всіх вкладок тоді ж валила
  // GPU після фонового очищення, тож справжній вигляд беремо лиш активним.
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                  BlinkFollowSystemAppearance();
                }];
  });
  const UIApplicationState state = UIApplication.sharedApplication.applicationState;
  // Перший раз ставимо одразу, бо при запуску застосунок ще inactive.
  if (state != UIApplicationStateActive &&
      content::g_blink_preferred_color_scheme != 0) {
    BLINKER_DIAGF("APPEARANCE: skipped state=%d", (int)state);
    return;
  }
  const NSInteger chosen =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"BlinkAppearance"];
  if (chosen == UIUserInterfaceStyleLight ||
      chosen == UIUserInterfaceStyleDark) {
    return;
  }
  const UIUserInterfaceStyle style =
      BlinkResolvedWebStyle(UIUserInterfaceStyleUnspecified);
  if (content::g_blink_preferred_color_scheme != (int)style) {
    BlinkSetWebColorScheme(style);
  }
}

// Назва збереженої сторінки замість шляху file:// у контейнері.
static NSString* BlinkSavedPageName(NSString* url) {
  const GURL parsed(base::SysNSStringToUTF8(url ?: @""));
  if (!content::BlinkerIsSavedPageURL(parsed)) {
    return nil;
  }
  NSString* name = [base::SysUTF8ToNSString(parsed.ExtractFileName())
                       stringByRemovingPercentEncoding]
                       .stringByDeletingPathExtension;
  return name.length ? name : nil;
}

// Строгий DoH, як "свій постачальник" у Chrome.
struct BlinkSecureDnsProvider {
  const char* name;
  const char* detail;
  const char* doh_template;
};
constexpr BlinkSecureDnsProvider kBlinkSecureDnsProviders[] = {
    {"Cloudflare", "1.1.1.1", "https://chrome.cloudflare-dns.com/dns-query"},
    {"Quad9", "Blocks known malicious sites",
     "https://dns.quad9.net/dns-query"},
    {"Google", "8.8.8.8", "https://dns.google/dns-query{?dns}"},
    {"AdGuard", "Blocks ads and trackers",
     "https://dns.adguard-dns.com/dns-query"},
};

static NSString* BlinkSecureDnsSubtitle() {
  NSString* value =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"BlinkSecureDNS"];
  if (!value.length) {
    return BlinkL(@"Off");
  }
  for (const BlinkSecureDnsProvider& provider : kBlinkSecureDnsProviders) {
    if ([value isEqualToString:@(provider.doh_template)]) {
      return @(provider.name);
    }
  }
  return BlinkL(@"Custom");
}

// Перевірені з Blinker Fluid розширення з Chrome Web Store.
struct BlinkRecommendedExtension {
  const char* id;
  const char* name;
  const char* about;
  // Шматок назви з маніфесту малими літерами, бо вручну встановлене має свій
  // id.
  const char* match;
};
constexpr BlinkRecommendedExtension kBlinkRecommendedExtensions[] = {
    {"ddkjiahejlhfcafbddmgiahcphecmpfh", "uBlock Origin Lite",
     "Blocks ads and trackers", "ublock origin lite"},
    {"eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader",
     "Dark mode for every website", "dark reader"},
    {"pkehgijcmpdhfbdbbnkijodmdjhbjlgp", "Privacy Badger",
     "Learns to block invisible trackers", "privacy badger"},
    {"mnjggcdmjocbbbhaepdhchncahnbgone", "SponsorBlock",
     "Skips sponsor segments in YouTube videos", "sponsorblock"},
    {"gebbhagfogifgggkldgodflihgfeippi", "Return YouTube Dislike",
     "Shows dislike counts on YouTube", "return youtube dislike"},
    {"edibdbjcniadpccecjdfdjjppcpchdlm", "I still don't care about cookies",
     "Hides cookie banners", "care about cookies"},
    {"aapbdbdomjkkjkaonfhkkikfgjllcleb", "Google Translate",
     "Translates selected text and whole pages", "google translate"},
    {"jinjaccalgkegednnccohejagnlnfdag", "Violentmonkey", "Runs userscripts",
     "violentmonkey"},
    {"dhdgffkkebhmkfjojejmpbldmpobfkfo", "Tampermonkey", "Runs userscripts",
     "tampermonkey"},
    {"clngdbkpkpeebahjckkjfobafhncgmne", "Stylus",
     "Your own styles for websites", "stylus"},
    {"hlepfoohegkhhmjieoechaddaejaokhf", "Refined GitHub",
     "Makes GitHub easier to use", "refined github"},
    {"dbepggeogbaibhgnhhndojpepiihcmeb", "Vimium",
     "Keyboard shortcuts for browsing", "vimium"},
    {"bcjindcccaagfpapjjmafapmmgkkhgoa", "JSON Formatter",
     "Makes JSON readable", "json formatter"},
    {"doojmbjmlfjjnbmnoijecmcbfeoakpjm", "NoScript",
     "Lets you choose which sites can run scripts", "noscript"},
};

static NSString* BlinkWebStoreInstallURL(NSString* extensionId) {
  return [NSString
      stringWithFormat:@"https://clients2.google.com/service/update2/"
                       @"crx?response=redirect&prodversion=%s&acceptformat="
                       @"crx2,crx3&x=id%%3D%@%%26uc",
                       CONTENT_SHELL_VERSION, extensionId];
}

// id розширення зі сторінки Chrome Web Store або nil.
static NSString* BlinkWebStoreExtensionId(const GURL& url) {
  if (!url.SchemeIs("https") || (url.host() != "chromewebstore.google.com" &&
                                 url.host() != "chrome.google.com")) {
    return nil;
  }
  const std::string path(url.path());
  if (path.find("/detail/") == std::string::npos) {
    return nil;
  }
  std::vector<std::string> parts = base::SplitString(
      path, "/", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (parts.empty()) {
    return nil;
  }
  const std::string& id = parts.back();
  if (id.size() != 32 ||
      !std::all_of(id.begin(), id.end(),
                   [](char c) { return c >= 'a' && c <= 'p'; })) {
    return nil;
  }
  return base::SysUTF8ToNSString(id);
}

// Розгорнуте вручну розширення лежить під своїм іменем теки, тож звіряєм
// і назву.
static BOOL BlinkExtensionInstalled(NSString* extensionId,
                                    const char* match = nullptr) {
  const std::string id = base::SysNSStringToUTF8(extensionId);
  for (const auto& extension :
       content::BlinkerWebExtensionRegistry::GetInstance().extensions()) {
    if (extension->id == id ||
        (match && base::ToLowerASCII(extension->name).find(match) !=
                      std::string::npos)) {
      return YES;
    }
  }
  return NO;
}

static void BlinkDisallowPopupsForHost(NSString* host) {
  [BlinkSessionPopupHosts() removeObject:host];
  NSMutableArray<NSString*>* hosts = [BlinkPopupAllowedHosts() mutableCopy];
  if ([hosts containsObject:host]) {
    [hosts removeObject:host];
    [[NSUserDefaults standardUserDefaults] setObject:hosts
                                              forKey:kBlinkPopupAllowedHostsKey];
  }
}

static BOOL BlinkHostStaysActive(NSString* host) {
  return [BlinkMemorySaverSites() containsObject:host] ||
         [BlinkSessionMemorySaverSites() containsObject:host];
}

static void BlinkSetHostStaysActive(NSString* host, BOOL on) {
  if (!host.length) {
    return;
  }
  if (content::blinker_logging::IsPrivateSession()) {
    if (on) {
      [BlinkSessionMemorySaverSites() addObject:host];
    } else {
      [BlinkSessionMemorySaverSites() removeObject:host];
    }
    return;
  }
  NSMutableArray<NSString*>* hosts = [BlinkMemorySaverSites() mutableCopy];
  [hosts removeObject:host];
  if (on) {
    [hosts addObject:host];
  }
  [[NSUserDefaults standardUserDefaults] setObject:hosts
                                            forKey:kBlinkMemorySaverSitesKey];
}

// Адреси з історії Chrome Takeout (BrowserHistory.json) чи експорту Safari
// (History.json), новіші першими.
static NSArray<NSString*>* BlinkHistoryURLsFromJSON(NSData* data) {
  if (!data) {
    return nil;
  }
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  id items = nil;
  if ([root isKindOfClass:NSDictionary.class]) {
    items = root[@"Browser History"] ?: root[@"history"];
  } else if ([root isKindOfClass:NSArray.class]) {
    items = root;
  }
  if (![items isKindOfClass:NSArray.class]) {
    return nil;
  }
  NSMutableArray<NSDictionary*>* visits = [NSMutableArray array];
  for (id item in items) {
    if (![item isKindOfClass:NSDictionary.class] ||
        ![item[@"url"] isKindOfClass:NSString.class]) {
      continue;
    }
    NSString* url = item[@"url"];
    if (![url hasPrefix:@"https://"] && ![url hasPrefix:@"http://"]) {
      continue;
    }
    id time = item[@"time_usec"];
    [visits addObject:@{
      @"url" : url,
      @"time" : [time isKindOfClass:NSNumber.class] ? time : @0
    }];
  }
  [visits sortWithOptions:NSSortStable
          usingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            return [b[@"time"] compare:a[@"time"]];
          }];
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (NSDictionary* visit in visits) {
    [urls addObject:visit[@"url"]];
  }
  return urls;
}

static void BlinkCollectBookmarkNodes(
    NSArray* items,
    std::vector<content::BlinkerBookmarkNode>* out) {
  for (id item in items) {
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    content::BlinkerBookmarkNode node;
    NSString* title = [item[@"title"] isKindOfClass:NSString.class]
                          ? item[@"title"]
                          : @"";
    node.title = base::SysNSStringToUTF8(title);
    if ([item[@"dateAdded"] isKindOfClass:NSNumber.class]) {
      node.add_date = [item[@"dateAdded"] longLongValue] / 1000;
    }
    if ([item[@"url"] isKindOfClass:NSString.class]) {
      node.url = base::SysNSStringToUTF8(item[@"url"]);
      if (node.url.empty()) {
        continue;
      }
    } else {
      BlinkCollectBookmarkNodes(item[@"children"], &node.children);
    }
    out->push_back(std::move(node));
  }
}

static NSMutableArray* BlinkBookmarkItemsFromNodes(
    const std::vector<content::BlinkerBookmarkNode>& nodes,
    NSUInteger* links) {
  NSMutableArray* items = [NSMutableArray array];
  for (const content::BlinkerBookmarkNode& node : nodes) {
    NSMutableDictionary* item = [NSMutableDictionary dictionary];
    item[@"title"] = base::SysUTF8ToNSString(node.title);
    if (node.add_date > 0) {
      item[@"dateAdded"] = @(node.add_date * 1000);
    }
    if (node.is_folder()) {
      item[@"children"] = BlinkBookmarkItemsFromNodes(node.children, links);
    } else {
      item[@"url"] = base::SysUTF8ToNSString(node.url);
      ++*links;
    }
    [items addObject:item];
  }
  return items;
}

typedef NS_ENUM(NSInteger, BlinkImportKind) {
  BlinkImportNone,
  BlinkImportBookmarks,
  BlinkImportHistory,
  BlinkImportExtensions,
};

typedef NS_ENUM(NSInteger, BlinkSiteRow) {
  BlinkSiteRowConnection,
  BlinkSiteRowDesktop,
  BlinkSiteRowAdBlock,
  BlinkSiteRowPopups,
  BlinkSiteRowZoom,
  BlinkSiteRowKeepAwake,
  BlinkSiteRowSound,
  BlinkSiteRowClearData,
};

// Екран оновлення. Нотатки релізу це markdown з GitHub, тут з них роблять
// заголовки і рядки, які читаються без тісного тексту алерта.
@interface BlinkUpdateSheetVC : UIViewController
@property(nonatomic, copy) NSString* headline;
@property(nonatomic, copy) NSString* installedVersion;
@property(nonatomic, copy) NSString* latestVersion;
@property(nonatomic, copy) NSString* notes;
@property(nonatomic, copy) NSString* primaryTitle;
@property(nonatomic, copy) dispatch_block_t primaryAction;
@end

@implementation BlinkUpdateSheetVC

static UILabel* BlinkUpdateLabel(CGFloat size,
                                 UIFontWeight weight,
                                 UIColor* color) {
  UILabel* label = [[UILabel alloc] init];
  label.numberOfLines = 0;
  label.font = [UIFont systemFontOfSize:size weight:weight];
  label.textColor = color;
  return label;
}

// Розбирає **жирний**, `код` і [текст](посилання), решту лишає як є.
static NSAttributedString* BlinkUpdateInline(NSString* line,
                                             CGFloat size,
                                             UIColor* color) {
  NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];
  UIFont* regular = [UIFont systemFontOfSize:size];
  UIFont* bold = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
  UIFont* mono = [UIFont fontWithName:@"Menlo" size:size - 1] ?: regular;
  NSString* text = line;
  NSRegularExpression* link =
      [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]\\([^)]*\\)"
                                                options:0
                                                  error:nil];
  text = [link stringByReplacingMatchesInString:text
                                        options:0
                                          range:NSMakeRange(0, text.length)
                                   withTemplate:@"$1"];
  __block BOOL isBold = NO;
  __block BOOL isCode = NO;
  NSMutableString* run = [NSMutableString string];
  void (^flush)(void) = ^{
    if (!run.length) {
      return;
    }
    UIFont* font = isCode ? mono : (isBold ? bold : regular);
    [result appendAttributedString:
                [[NSAttributedString alloc]
                    initWithString:[run copy]
                        attributes:@{
                          NSFontAttributeName : font,
                          NSForegroundColorAttributeName :
                              isCode ? BlinkerAccentColor() : color
                        }]];
    [run setString:@""];
  };
  for (NSUInteger i = 0; i < text.length; ++i) {
    unichar c = [text characterAtIndex:i];
    if (c == '*' && i + 1 < text.length &&
        [text characterAtIndex:i + 1] == '*') {
      flush();
      isBold = !isBold;
      ++i;
    } else if (c == '`') {
      flush();
      isCode = !isCode;
    } else {
      [run appendFormat:@"%C", c];
    }
  }
  flush();
  return result;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  UIColor* background = [UIColor colorWithWhite:0.09 alpha:1.0];
  self.view.backgroundColor = background;
  self.title = BlinkL(@"Check for Updates");
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(closeTapped)];
  UINavigationBar* bar = self.navigationController.navigationBar;
  if (@available(iOS 13.0, *)) {
    UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = BlinkerThemeColor();
    ap.titleTextAttributes =
        @{NSForegroundColorAttributeName : UIColor.whiteColor};
    bar.standardAppearance = ap;
    bar.scrollEdgeAppearance = ap;
    bar.compactAppearance = ap;
  } else {
    bar.translucent = NO;
    bar.barTintColor = BlinkerThemeColor();
    bar.titleTextAttributes =
        @{NSForegroundColorAttributeName : UIColor.whiteColor};
  }
  bar.tintColor = UIColor.whiteColor;

  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.alwaysBounceVertical = YES;
  [self.view addSubview:scroll];

  UIStackView* column = [[UIStackView alloc] init];
  column.axis = UILayoutConstraintAxisVertical;
  column.spacing = 12;
  column.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:column];

  UIView* footer = [[UIView alloc] init];
  footer.translatesAutoresizingMaskIntoConstraints = NO;
  footer.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
  [self.view addSubview:footer];
  UIStackView* buttons = [[UIStackView alloc] init];
  buttons.axis = UILayoutConstraintAxisVertical;
  buttons.spacing = 8;
  buttons.translatesAutoresizingMaskIntoConstraints = NO;
  [footer addSubview:buttons];

  UILabel* headline = BlinkUpdateLabel(24, UIFontWeightBold, UIColor.whiteColor);
  headline.text = self.headline;
  [column addArrangedSubview:headline];

  UIStackView* chips = [[UIStackView alloc] init];
  chips.spacing = 8;
  chips.alignment = UIStackViewAlignmentLeading;
  for (NSArray* pair in @[
         @[ BlinkL(@"Installed"), self.installedVersion ?: @"" ],
         @[ BlinkL(@"Latest"), self.latestVersion ?: @"" ]
       ]) {
    UILabel* chip = BlinkUpdateLabel(13, UIFontWeightMedium,
                                     [UIColor colorWithWhite:0.85 alpha:1.0]);
    chip.text = [NSString stringWithFormat:@"  %@ %@  ", pair[0], pair[1]];
    chip.numberOfLines = 1;
    chip.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    chip.layer.cornerRadius = 11;
    chip.clipsToBounds = YES;
    [chip.heightAnchor constraintEqualToConstant:24].active = YES;
    [chips addArrangedSubview:chip];
  }
  UIView* spacer = [[UIView alloc] init];
  [chips addArrangedSubview:spacer];
  [column addArrangedSubview:chips];
  [column setCustomSpacing:20 afterView:chips];

  UIColor* body = [UIColor colorWithWhite:0.82 alpha:1.0];
  for (NSString* raw in [self.notes componentsSeparatedByString:@"\n"]) {
    NSString* line = [raw stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!line.length) {
      continue;
    }
    // Рядок цілком жирний це заголовок розділу. Заголовок з номером версії
    // повторює шапку, тож його пропускаємо.
    const BOOL wholeBold = [line hasPrefix:@"**"] && [line hasSuffix:@"**"] &&
                           line.length > 4 &&
                           [line rangeOfString:@"**"
                                       options:0
                                         range:NSMakeRange(2, line.length - 4)]
                                   .location == NSNotFound;
    const BOOL bulleted = [line hasPrefix:@"- "] || [line hasPrefix:@"* "];
    if (wholeBold) {
      NSString* heading = [line substringWithRange:NSMakeRange(2, line.length - 4)];
      if ([heading hasPrefix:@"("]) {
        continue;
      }
      heading = [heading stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@":"]];
      UILabel* label =
          BlinkUpdateLabel(15, UIFontWeightSemibold, BlinkerAccentColor());
      label.text = heading;
      [column setCustomSpacing:6 afterView:column.arrangedSubviews.lastObject];
      [column addArrangedSubview:label];
      [column setCustomSpacing:8 afterView:label];
    } else if (bulleted) {
      UIStackView* row = [[UIStackView alloc] init];
      row.spacing = 10;
      row.alignment = UIStackViewAlignmentTop;
      UIView* dot = [[UIView alloc] init];
      dot.backgroundColor = BlinkerAccentColor();
      dot.layer.cornerRadius = 3;
      dot.translatesAutoresizingMaskIntoConstraints = NO;
      UIView* dotHolder = [[UIView alloc] init];
      [dotHolder addSubview:dot];
      [NSLayoutConstraint activateConstraints:@[
        [dotHolder.widthAnchor constraintEqualToConstant:6],
        [dot.widthAnchor constraintEqualToConstant:6],
        [dot.heightAnchor constraintEqualToConstant:6],
        [dot.leadingAnchor constraintEqualToAnchor:dotHolder.leadingAnchor],
        [dot.topAnchor constraintEqualToAnchor:dotHolder.topAnchor constant:8],
      ]];
      UILabel* label = BlinkUpdateLabel(15, UIFontWeightRegular, body);
      label.attributedText =
          BlinkUpdateInline([line substringFromIndex:2], 15, body);
      [row addArrangedSubview:dotHolder];
      [row addArrangedSubview:label];
      [column addArrangedSubview:row];
    } else {
      UILabel* label = BlinkUpdateLabel(15, UIFontWeightRegular, body);
      label.attributedText = BlinkUpdateInline(line, 15, body);
      [column addArrangedSubview:label];
    }
  }

  if (self.primaryTitle.length && self.primaryAction) {
    UIButton* primary = [UIButton buttonWithType:UIButtonTypeSystem];
    [primary setTitle:self.primaryTitle forState:UIControlStateNormal];
    [primary setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    primary.titleLabel.font =
        [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    primary.backgroundColor = BlinkerThemeColor();
    primary.layer.cornerRadius = 14;
    [primary.heightAnchor constraintEqualToConstant:50].active = YES;
    [primary addTarget:self
                  action:@selector(primaryTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [buttons addArrangedSubview:primary];
  }
  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  [close setTitle:self.primaryAction ? BlinkL(@"Not Now") : BlinkL(@"OK")
         forState:UIControlStateNormal];
  [close setTitleColor:[UIColor colorWithWhite:0.75 alpha:1.0]
              forState:UIControlStateNormal];
  close.titleLabel.font = [UIFont systemFontOfSize:17];
  [close.heightAnchor constraintEqualToConstant:44].active = YES;
  [close addTarget:self
                action:@selector(closeTapped)
      forControlEvents:UIControlEventTouchUpInside];
  [buttons addArrangedSubview:close];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
    [column.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:20],
    [column.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor
                                        constant:-20],
    [column.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                         constant:20],
    [column.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-40],
    [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [buttons.topAnchor constraintEqualToAnchor:footer.topAnchor constant:12],
    [buttons.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor
                                          constant:20],
    [buttons.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor
                                           constant:-20],
    [buttons.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                         constant:-8],
  ]];
}

- (void)closeTapped {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)primaryTapped {
  dispatch_block_t action = self.primaryAction;
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (action) {
                               action();
                             }
                           }];
}
@end

@implementation ContentShellWindowDelegate
@synthesize backButton = _backButton;
@synthesize contentView = _contentView;
@synthesize pullSpinner = _pullSpinner;
@synthesize urlField = _urlField;
@synthesize forwardButton = _forwardButton;
@synthesize reloadOrStopButton = _reloadOrStopButton;
@synthesize menuButton = _menuButton;
@synthesize toolbarBackgroundView = _toolbarBackgroundView;
@synthesize toolbarContentView = _toolbarContentView;
@synthesize tracingHandler = _tracingHandler;

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (UIColor*)backgroundColorDefault {
  return BlinkerThemeColor();
}

+ (UIColor*)backgroundColorTracing {
  return [UIColor colorWithRed:234.0 / 255.0
                         green:67.0 / 255.0
                          blue:53.0 / 255.0
                         alpha:1.0];
}

#if BUILDFLAG(IS_IOS_TVOS)
- (void)pressesBegan:(NSSet<UIPress*>*)presses
           withEvent:(UIPressesEvent*)event {
  for (UIPress* press in presses) {
    if (press.type == UIPressTypeMenu) {
      if (!content::Shell::ShouldHideToolbar() &&
          _shell->web_contents()->GetContentNativeView().Get().focused) {
        _toolbarContentView.userInteractionEnabled = YES;
        [self setNeedsFocusUpdate];
        return;
      }
    }
  }
  [super pressesBegan:presses withEvent:event];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext*)context
       withAnimationCoordinator:(UIFocusAnimationCoordinator*)coordinator {
  if (_shell) {
    const UIView* nativeWebContentsView =
        _shell->web_contents()->GetContentNativeView().Get();
    if (context.nextFocusedView == nativeWebContentsView) {
      _toolbarContentView.userInteractionEnabled = NO;
      _shell->web_contents()->Focus();
    }
  }
}

- (NSArray<id<UIFocusEnvironment>>*)preferredFocusEnvironments {
  return _toolbarContentView.userInteractionEnabled ? @[ _toolbarContentView ]
                                                    : @[ _contentView ];
}
#endif

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  // Після запуску показуємо вкладку, на якій закрили застосунок, а не першу
  static dispatch_once_t activeOnce;
  dispatch_once(&activeOnce, ^{
    const int index = content::TakeRestoreActiveTabIndex();
    auto tabs = content::Shell::windows();
    if (index > 0 && static_cast<size_t>(index) < tabs.size() && _shell &&
        tabs[index].get() != _shell) {
      [self showTabWindow:tabs[index].get()];
    }
  });
  [self showCrashRestorePrompt];
}

- (void)showCrashRestorePrompt {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSArray* saved = [defaults arrayForKey:@"BlinkPendingCrashTabs"];
  if (!saved.count || !_shell || !_shell->web_contents() ||
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord() ||
      !self.view.window.isKeyWindow || self.presentedViewController ||
      ([defaults boolForKey:@"BlinkAppLock"] && !g_blink_app_unlocked)) {
    return;
  }
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Restore previous tabs?")
                       message:BlinkL(@"Blinker didn't close normally. Reopen your "
                               @"previous tabs, or start with a new tab.")
                preferredStyle:UIAlertControllerStyleAlert];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:BlinkL(@"New Session")
                              style:UIAlertActionStyleCancel
                            handler:^(UIAlertAction* action) {
                              [defaults
                                  removeObjectForKey:@"BlinkPendingCrashTabs"];
                              BlinkSaveOpenTabs();
                            }]];
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:BlinkL(@"Restore")
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction* action) {
                              ContentShellWindowDelegate* owner = weakSelf;
                              if (!owner || !owner->_shell) {
                                return;
                              }
                              std::vector<GURL> urls;
                              for (id item in saved) {
                                if (![item isKindOfClass:NSString.class]) {
                                  continue;
                                }
                                GURL url(base::SysNSStringToUTF8(item));
                                if (url.is_valid() &&
                                    (url.SchemeIsHTTPOrHTTPS() ||
                                     url.IsAboutBlank())) {
                                  urls.push_back(url);
                                }
                                if (urls.size() == 12) {
                                  break;
                                }
                              }
                              // Перевзводим до навігації, щоб нове
                              // падіння сторінки не дало циклу.
                              [defaults setObject:@"running"
                                           forKey:@"BlinkLaunchState"];
                              [defaults
                                  removeObjectForKey:@"BlinkPendingCrashTabs"];
                              [defaults setObject:saved
                                           forKey:@"BlinkOpenTabs"];
                              [defaults synchronize];
                              if (urls.empty()) {
                                BlinkSaveOpenTabs();
                                return;
                              }
                              g_restoring_crash_tabs = true;
                              content::Shell* first = owner->_shell;
                              auto* context =
                                  first->web_contents()->GetBrowserContext();
                              // Перша вкладка теж нова, бо стек історії
                              // відновлюється лиш у свіжу.
                              content::Shell* restored =
                                  content::Shell::CreateNewWindow(
                                      context, GURL(), nullptr, gfx::Size());
                              for (size_t i = 1; i < urls.size(); ++i) {
                                content::Shell* tab =
                                    content::Shell::CreateNewWindow(
                                        context, GURL(), nullptr,
                                        gfx::Size());
                                if (tab) {
                                  g_crash_restore_urls[tab] = urls[i];
                                  tab->window().Get().hidden = YES;
                                  tab->web_contents()->WasHidden();
                                }
                              }
                              if (restored) {
                                g_crash_restore_inflight[restored] =
                                    urls.front();
                                if (!content::BlinkerRestoreTabSession(
                                        restored->web_contents(),
                                        urls.front())) {
                                  restored->LoadURL(urls.front());
                                }
                                // Без анімації. Перша вкладка закривається
                                // нижче, і анімоване перемикання встигало
                                // взяти сцену вже з закритого вікна.
                                [owner showTabWindow:restored];
                                g_restoring_crash_tabs = false;
                                BlinkSaveOpenTabs();
                                // Порожня стартова вкладка вже не потрібна.
                                dispatch_async(dispatch_get_main_queue(), ^{
                                  for (content::Shell* s :
                                       content::Shell::windows()) {
                                    if (s == first &&
                                        content::Shell::windows().size() > 1) {
                                      s->Close();
                                      BlinkSaveOpenTabs();
                                      break;
                                    }
                                  }
                                });
                                return;
                              }
                              [owner switchToTab:first direction:0];
                              g_crash_restore_inflight[first] = urls.front();
                              first->LoadURL(urls.front());
                              g_restoring_crash_tabs = false;
                              BlinkSaveOpenTabs();
                            }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  // Темний фон кореня, щоб край під home indicator не блимав білим при
  // запуску, повороті чи зсуві клавіатури.
  self.view.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];

  self.contentView = [[UIView alloc] init];
  [self.view addSubview:_contentView];
  self.pullGesture = [[BlinkerPullGesture alloc] init];
  self.pullGesture.pullController = self;
  content::BlinkerFilterSubscriptions::GetInstance().Start(
      _shell->web_contents()->GetBrowserContext(),
      base::apple::GetUserDocumentPath());
  [_contentView addGestureRecognizer:self.pullGesture];
  // Свайп від краю екрана: зліва назад, справа вперед, як у Safari
  BlinkerEdgeSwipeGesture* edgeSwipe = [[BlinkerEdgeSwipeGesture alloc] init];
  edgeSwipe.swipeController = self;
  [_contentView addGestureRecognizer:edgeSwipe];

  if (!content::Shell::ShouldHideToolbar()) {
    self.toolbarBackgroundView = [self createToolbarBackgroundView];
    self.toolbarContentView = [self createToolbarContentView];

    self.backButton = [self makeButton:@"ic_back" action:@selector(back)];
    self.forwardButton = [self makeButton:@"ic_forward"
                                   action:@selector(forward)];
    self.reloadOrStopButton = [self makeButton:@"ic_reload"
                                        action:@selector(reloadOrStop)];
    self.menuButton = [self makeButton:@"ic_menu"
                                action:@selector(showMainMenu)];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(updateDownloadAttentionBadge)
               name:kBlinkDownloadAttentionChanged
             object:nil];
    [self updateDownloadAttentionBadge];
    // Клавіатура рідних полів, зокрема адресного рядка, не проходить через
    // сторінку, тож панель внизу слухає її сама.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(nativeKeyboardFrameChanged:)
               name:UIKeyboardWillChangeFrameNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(nativeKeyboardFrameChanged:)
               name:UIKeyboardWillHideNotification
             object:nil];
    self.urlField = [self makeURLBar];
    // Панель в private і так графітова через backgroundColorDefault, тут лиш
    // підпис порожнього поля.
    if (_shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
      _urlField.placeholder = BlinkL(@"Private Browsing");
    }
    self.tracingHandler = [[TracingHandler alloc] init];

    [self.view addSubview:_toolbarBackgroundView];
    [_toolbarBackgroundView addArrangedSubview:_toolbarContentView];

    [_toolbarContentView addArrangedSubview:_backButton];
    [_toolbarContentView addArrangedSubview:_forwardButton];
    [_toolbarContentView addArrangedSubview:_reloadOrStopButton];
    [_toolbarContentView addArrangedSubview:_menuButton];
    [_toolbarContentView addArrangedSubview:_urlField];

    self.loadingProgressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleBar];
    _loadingProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingProgressView.progressTintColor = BlinkerAccentColor();
    _loadingProgressView.trackTintColor = UIColor.clearColor;
    _loadingProgressView.hidden = YES;
    [self.view addSubview:_loadingProgressView];

    self.view.accessibilityElements = @[ _toolbarBackgroundView, _contentView ];
    self.view.isAccessibilityElement = NO;

    _toolbarBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_toolbarBackgroundView.leadingAnchor
          constraintEqualToAnchor:self.view.leadingAnchor],
      [_toolbarBackgroundView.trailingAnchor
          constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    _toolbarContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_toolbarContentView.heightAnchor
          constraintEqualToAnchor:_backButton.heightAnchor
                       multiplier:2.0],
    ]];
  }

  _contentView.translatesAutoresizingMaskIntoConstraints = NO;
  self.contentHorizontalConstraints = @[
    [_contentView.leadingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_contentView.trailingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
  ];
  [NSLayoutConstraint activateConstraints:_contentHorizontalConstraints];
  [self applyToolbarPosition];

  if (UIAccessibilityIsVoiceOverRunning()) {
    _scopedAccessibilityMode =
        content::BrowserAccessibilityState::GetInstance()
            ->CreateScopedModeForProcess(kVoiceOverEnabledAXMode);
  }

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(voiceOverStatusDidChange)
             name:UIAccessibilityVoiceOverStatusDidChangeNotification
           object:nil];

  UIView* webContentsView = _shell->web_contents()->GetNativeView().Get();
  [_contentView addSubview:webContentsView];

  if (@available(ios 17.0, *)) {
    NSArray<UITrait>* traits = @[ UITraitUserInterfaceStyle.self ];
    [self registerForTraitChanges:traits
                       withTarget:self
                           action:@selector(darkModeDidChange)];
  }
  [self darkModeDidChange];

  // Вертаєм збережений вигляд (prefers-color-scheme і хром iOS).
  NSInteger appearance =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"BlinkAppearance"];
  if (appearance == UIUserInterfaceStyleLight ||
      appearance == UIUserInterfaceStyleDark) {
    // Лише ставимо схему, без перезавантаження. viewDidLoad йде для кожного
    // нового вікна, і перезавантаження всіх вкладок тут вбивало вікно входу, бо
    // відкривача перезавантажувало ще до показу вікна.
    if (content::g_blink_preferred_color_scheme != appearance) {
      BlinkSetWebColorScheme(BlinkResolvedWebStyle(
          static_cast<UIUserInterfaceStyle>(appearance)));
    }
    if (@available(iOS 13.0, *)) {
      self.view.window.overrideUserInterfaceStyle =
          (UIUserInterfaceStyle)appearance;
    }
  }

  [self setURL:base::SysUTF8ToNSString(
                   _shell->web_contents()->GetVisibleURL().spec())];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(blinkDidEnterBackground)
             name:UIApplicationDidEnterBackgroundNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(blinkWillEnterForeground)
             name:UIApplicationWillEnterForegroundNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(blinkWillResignActive)
             name:UIApplicationWillResignActiveNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(blinkDidBecomeActive)
             name:UIApplicationDidBecomeActiveNotification
           object:nil];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updatePrivacyLock];
  });
}

- (void)blinkDidEnterBackground {
  if (![[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkAppLock"]) {
    return;
  }
  g_blink_app_unlocked = false;
  [self updatePrivacyLock];
}

- (void)blinkWillEnterForeground {
  [self updatePrivacyLock];
}

// Знімок для перемикача програм iOS робить одразу після втрати фокусу, тож
// сторінку закриваєм саме тут, а не при переході у фон.
- (void)blinkWillResignActive {
  if (_switcherCoverView ||
      ![[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkPrivacyCover"]) {
    return;
  }
  // На вікно, щоб закрити і відкрите меню чи налаштування.
  UIView* host = self.view.window ?: self.view;
  UIView* cover = [[UIView alloc] initWithFrame:host.bounds];
  cover.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  cover.backgroundColor = [UIColor colorWithRed:0.055
                                          green:0.055
                                           blue:0.063
                                          alpha:1.0];
  UIImageView* logo =
      [[UIImageView alloc] initWithImage:BlinkStartLogo()];
  logo.contentMode = UIViewContentModeScaleAspectFit;
  logo.frame = CGRectMake(0, 0, 96, 96);
  logo.center = CGPointMake(CGRectGetMidX(cover.bounds),
                            CGRectGetMidY(cover.bounds));
  logo.autoresizingMask =
      UIViewAutoresizingFlexibleLeftMargin |
      UIViewAutoresizingFlexibleRightMargin |
      UIViewAutoresizingFlexibleTopMargin |
      UIViewAutoresizingFlexibleBottomMargin;
  [cover addSubview:logo];
  [host addSubview:cover];
  self.switcherCoverView = cover;
}

- (void)blinkDidBecomeActive {
  BlinkApplyAppIconForTheme();
  [_switcherCoverView removeFromSuperview];
  self.switcherCoverView = nil;
}

- (void)updatePrivacyLock {
  BOOL enabled =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkAppLock"];
  if (!enabled || g_blink_app_unlocked) {
    [_privacyLockView removeFromSuperview];
    self.privacyLockView = nil;
    return;
  }
  if (_privacyLockView) {
    return;
  }
  UIView* cover = [[UIView alloc] init];
  cover.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1];
  cover.translatesAutoresizingMaskIntoConstraints = NO;
  UIImageView* icon =
      [[UIImageView alloc] initWithImage:BlinkSystemImage(@"lock.shield.fill")];
  icon.tintColor = BlinkerAccentColor();
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel* title = [[UILabel alloc] init];
  title.text = BlinkL(@"Blinker Fluid Locked");
  title.textColor = UIColor.whiteColor;
  title.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
  title.translatesAutoresizingMaskIntoConstraints = NO;
  UIButton* unlock = [UIButton buttonWithType:UIButtonTypeSystem];
  [unlock setTitle:BlinkL(@"Open with Face ID or Password") forState:UIControlStateNormal];
  unlock.titleLabel.font = [UIFont systemFontOfSize:16
                                             weight:UIFontWeightSemibold];
  unlock.tintColor = UIColor.whiteColor;
  unlock.backgroundColor = BlinkerAccentColor();
  unlock.layer.cornerRadius = 14;
  unlock.translatesAutoresizingMaskIntoConstraints = NO;
  [unlock addTarget:self
                action:@selector(unlockBlinker)
      forControlEvents:UIControlEventTouchUpInside];
  [cover addSubview:icon];
  [cover addSubview:title];
  [cover addSubview:unlock];
  [self.view addSubview:cover];
  [NSLayoutConstraint activateConstraints:@[
    [cover.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [cover.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [cover.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [cover.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [icon.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
    [icon.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor
                                       constant:-65],
    [icon.widthAnchor constraintEqualToConstant:62],
    [icon.heightAnchor constraintEqualToConstant:62],
    [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
    [title.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
    [unlock.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
    [unlock.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
    [unlock.widthAnchor constraintEqualToConstant:270],
    [unlock.heightAnchor constraintEqualToConstant:50],
  ]];
  self.privacyLockView = cover;
}

- (void)unlockBlinker {
  LAContext* context = [[LAContext alloc] init];
  context.localizedCancelTitle = BlinkL(@"Cancel");
  NSError* error = nil;
  if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                            error:&error]) {
    return;
  }
  [context
       evaluatePolicy:LAPolicyDeviceOwnerAuthentication
      localizedReason:BlinkL(@"Unlock your Blinker Fluid browsing session")
                reply:^(BOOL success, NSError* authError) {
                  if (!success) {
                    return;
                  }
                  dispatch_async(dispatch_get_main_queue(), ^{
                    g_blink_app_unlocked = true;
                    for (content::Shell* shell : content::Shell::windows()) {
                      UIWindow* window = shell->window().Get();
                      if ([window.rootViewController
                              isKindOfClass:[ContentShellWindowDelegate
                                                class]]) {
                        [(ContentShellWindowDelegate*)
                                window.rootViewController updatePrivacyLock];
                        [(ContentShellWindowDelegate*)window
                                .rootViewController showCrashRestorePrompt];
                      }
                    }
                  });
                }];
}

- (void)darkModeDidChange {
  BlinkFollowSystemAppearance();
  if (@available(iOS 13.0, *)) {
    BOOL darkModeEnabled =
        (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    _urlField.backgroundColor =
        darkModeEnabled ? [UIColor darkGrayColor] : [UIColor whiteColor];
  } else {
    _urlField.backgroundColor = [UIColor darkGrayColor];
  }
}

- (id)initWithShell:(content::Shell*)shell {
  if ((self = [super init])) {
    _shell = shell;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSInteger se = [defaults integerForKey:@"BlinkSearchEngine"];
    // Вибір зберігається номером. На п'ятому місці раніше був другий Google, а
    // тепер Yandex, тож старий вибір переходить на Google один раз.
    if (![defaults boolForKey:@"BlinkSearchEngineYandexMigrated"]) {
      if (se == 4) {
        se = 0;
        [defaults setInteger:se forKey:@"BlinkSearchEngine"];
      }
      [defaults setBool:YES forKey:@"BlinkSearchEngineYandexMigrated"];
    }
    if (se >= 0 && se < (NSInteger)std::size(kSearchEngines)) {
      g_search_engine = (int)se;
    }
  }
  return self;
}

- (content::Shell*)shell {
  return _shell;
}

- (UIButton*)makeButton:(NSString*)imageName action:(SEL)action {
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImage* image = [UIImage imageNamed:imageName];
  if (image) {
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  } else {
    // Каталоги з новіших Xcode можуть не віддати іменовані картинки на старих
    // iOS, тоді кнопка лишається видимою, а не з nil картинкою.
    NSString* fallback = @"?";
    if ([imageName isEqualToString:@"ic_back"]) {
      fallback = @"‹";
    } else if ([imageName isEqualToString:@"ic_forward"]) {
      fallback = @"›";
    } else if ([imageName isEqualToString:@"ic_reload"]) {
      fallback = @"↻";
    } else if ([imageName isEqualToString:@"ic_stop"]) {
      fallback = @"×";
    } else if ([imageName isEqualToString:@"ic_menu"]) {
      fallback = @"⋮";
    }
    [button setTitle:fallback forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:28.0];
  }
  [button setImage:image forState:UIControlStateNormal];
  button.tintColor = [UIColor whiteColor];
  button.imageView.tintColor = [UIColor whiteColor];
  [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
#if BUILDFLAG(IS_IOS_TVOS)
  [button addTarget:self
                action:action
      forControlEvents:UIControlEventPrimaryActionTriggered];
#else
  // Тап може дати і TouchUpInside, і PrimaryActionTriggered, тоді навігація
  // (особливо Back) йшла двічі. Тому на iOS одна подія.
  [button addTarget:self
                action:action
      forControlEvents:UIControlEventTouchUpInside];
#endif
  return button;
}

- (UITextField*)makeURLBar {
  UITextField* field = [[UITextField alloc] init];
  BlinkSetSearchPlaceholder(field, [UIColor colorWithWhite:0.7 alpha:1.0]);
  field.tintColor = _toolbarBackgroundView.backgroundColor;
  [field setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                           forAxis:UILayoutConstraintAxisHorizontal];
  field.delegate = self;
  field.borderStyle = UITextBorderStyleRoundedRect;
  if (@available(iOS 13.0, *)) {
  } else {
    // На iOS 12 темної теми нема. Поле те саме, лише кольори як у темній.
    field.textColor = UIColor.whiteColor;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
  }
  field.keyboardType = UIKeyboardTypeWebSearch;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  // з типом URL автозаповнення паролів не пхає сюди логін
  field.textContentType = UITextContentTypeURL;
  self.siteButtonsView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 30)];
  self.siteButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.audioButton = [UIButton buttonWithType:UIButtonTypeSystem];
  for (UIButton* button in @[ self.siteButton, self.audioButton ]) {
    button.tintColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 5, 6, 3);
    [self.siteButtonsView addSubview:button];
  }
  self.siteButton.accessibilityLabel = BlinkL(@"Site Settings");
  self.siteButton.accessibilityIdentifier = @"BlinkerSiteButton";
  self.audioButton.accessibilityIdentifier = @"BlinkerAudioButton";
  [self.siteButton addTarget:self
                      action:@selector(showSiteSettings)
            forControlEvents:UIControlEventTouchUpInside];
  [self.audioButton addTarget:self
                       action:@selector(toggleTabMute)
             forControlEvents:UIControlEventTouchUpInside];
  field.leftView = self.siteButtonsView;
  field.leftViewMode = UITextFieldViewModeNever;
  UILongPressGestureRecognizer* longPress =
      [[UILongPressGestureRecognizer alloc]
          initWithTarget:self
                  action:@selector(showSearchEngineMenu:)];
  [field addGestureRecognizer:longPress];
  for (NSNumber* direction in @[
         @(UISwipeGestureRecognizerDirectionLeft),
         @(UISwipeGestureRecognizerDirectionRight)
       ]) {
    UISwipeGestureRecognizer* swipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleURLBarSwipe:)];
    swipe.direction = static_cast<UISwipeGestureRecognizerDirection>(
        direction.unsignedIntegerValue);
    [field addGestureRecognizer:swipe];
  }
  return field;
}

- (void)updateDownloadAttentionBadge {
  if (!_menuButton) {
    return;
  }
  constexpr NSInteger kBadgeTag = 0xB11D;
  UILabel* badge = (UILabel*)[_menuButton viewWithTag:kBadgeTag];
  BOOL visible = [[NSUserDefaults standardUserDefaults]
      boolForKey:@"BlinkDownloadAttention"];
  if (!visible) {
    [badge removeFromSuperview];
    return;
  }
  if (badge) {
    return;
  }
  badge = [[UILabel alloc] init];
  badge.tag = kBadgeTag;
  badge.translatesAutoresizingMaskIntoConstraints = NO;
  badge.text = @"!";
  badge.textAlignment = NSTextAlignmentCenter;
  badge.textColor = UIColor.whiteColor;
  badge.backgroundColor = UIColor.systemRedColor;
  badge.font = [UIFont boldSystemFontOfSize:10];
  badge.layer.cornerRadius = 7;
  badge.clipsToBounds = YES;
  badge.isAccessibilityElement = NO;
  [_menuButton addSubview:badge];
  [NSLayoutConstraint activateConstraints:@[
    [badge.widthAnchor constraintEqualToConstant:14],
    [badge.heightAnchor constraintEqualToConstant:14],
    [badge.topAnchor constraintEqualToAnchor:_menuButton.topAnchor constant:-2],
    [badge.trailingAnchor constraintEqualToAnchor:_menuButton.trailingAnchor
                                         constant:2],
  ]];
}

- (void)handleURLBarSwipe:(UISwipeGestureRecognizer*)gesture {
  if (gesture.state != UIGestureRecognizerStateEnded || !_shell) {
    return;
  }
  [_urlField resignFirstResponder];
  const auto& windows = content::Shell::windows();
  auto current = std::find(windows.begin(), windows.end(), _shell);
  if (current == windows.end()) {
    return;
  }
  const int index = static_cast<int>(current - windows.begin());
  const int delta =
      gesture.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : -1;
  const int target = index + delta;
  if (target >= 0 && target < static_cast<int>(windows.size())) {
    BLINKER_DIAG(delta > 0 ? "TAB_SWIPE: next" : "TAB_SWIPE: previous");
    [self switchToTab:windows[target] direction:delta];
    return;
  }
  BLINKER_DIAG("TAB_SWIPE: edge reached, opening new tab");
  CGFloat distance = MAX(_urlField.bounds.size.width * 0.45, 80);
  [UIView animateWithDuration:0.12
      animations:^{
        self->_urlField.transform = CGAffineTransformMakeTranslation(
            delta > 0 ? -distance : distance, 0);
        self->_urlField.alpha = 0;
      }
      completion:^(BOOL finished) {
        self->_urlField.transform = CGAffineTransformIdentity;
        self->_urlField.alpha = 1;
        [self openNewTab];
      }];
}

- (void)switchToTab:(content::Shell*)shell direction:(NSInteger)direction {
  if (!shell || shell == _shell) {
    return;
  }
  CGFloat distance = MAX(_urlField.bounds.size.width * 0.45, 80);
  [UIView animateWithDuration:0.12
      delay:0
      options:UIViewAnimationOptionCurveEaseIn
      animations:^{
        self->_urlField.transform = CGAffineTransformMakeTranslation(
            direction > 0 ? -distance : distance, 0);
        self->_urlField.alpha = 0;
      }
      completion:^(BOOL finished) {
        [self showTabWindow:shell];
        UIWindow* window = shell->window().Get();
        ContentShellWindowDelegate* incoming =
            [window.rootViewController
                isKindOfClass:[ContentShellWindowDelegate class]]
                ? (ContentShellWindowDelegate*)window.rootViewController
                : nil;
        UITextField* incomingField = incoming.urlField;
        self->_urlField.transform = CGAffineTransformIdentity;
        self->_urlField.alpha = 1;
        if (!incomingField) {
          return;
        }
        incomingField.transform = CGAffineTransformMakeTranslation(
            direction > 0 ? distance : -distance, 0);
        incomingField.alpha = 0;
        [UIView animateWithDuration:0.18
                              delay:0
             usingSpringWithDamping:0.88
              initialSpringVelocity:0.25
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                           incomingField.transform = CGAffineTransformIdentity;
                           incomingField.alpha = 1;
                         }
                         completion:nil];
      }];
}

- (UIStackView*)createToolbarBackgroundView {
  UIStackView* toolbarBackgroundView = [[UIStackView alloc] init];

  toolbarBackgroundView.backgroundColor =
      [ContentShellWindowDelegate backgroundColorDefault];
  // На iOS 12 UIStackView не малював backgroundColor, тож фарбуєм і його шар,
  // щоб панель була видна на всіх версіях.
  toolbarBackgroundView.layer.backgroundColor =
      [ContentShellWindowDelegate backgroundColorDefault].CGColor;
  toolbarBackgroundView.opaque = YES;

  // На iOS 11 і 12 колір UIStackView може дати прозору чи чорну панель, тож за
  // вмістом лежить звичайний UIView з кольором.
  UIView* paintView = [[UIView alloc] init];
  paintView.translatesAutoresizingMaskIntoConstraints = NO;
  paintView.userInteractionEnabled = NO;
  paintView.backgroundColor =
      [ContentShellWindowDelegate backgroundColorDefault];
  paintView.opaque = YES;
  [toolbarBackgroundView addSubview:paintView];
  [NSLayoutConstraint activateConstraints:@[
    [paintView.topAnchor
        constraintEqualToAnchor:toolbarBackgroundView.topAnchor],
    [paintView.bottomAnchor
        constraintEqualToAnchor:toolbarBackgroundView.bottomAnchor],
    [paintView.leadingAnchor
        constraintEqualToAnchor:toolbarBackgroundView.leadingAnchor],
    [paintView.trailingAnchor
        constraintEqualToAnchor:toolbarBackgroundView.trailingAnchor],
  ]];
  self.toolbarPaintView = paintView;
  toolbarBackgroundView.alignment = UIStackViewAlignmentBottom;
  toolbarBackgroundView.axis = UILayoutConstraintAxisHorizontal;

  toolbarBackgroundView.layoutMarginsRelativeArrangement = YES;
  toolbarBackgroundView.preservesSuperviewLayoutMargins = YES;

  return toolbarBackgroundView;
}

- (UIStackView*)createToolbarContentView {
  UIStackView* toolbarContentView = [[UIStackView alloc] init];

  // Старі UIStackView backgroundColor малюють ненадійно.
  UIColor* toolbarColor = [ContentShellWindowDelegate backgroundColorDefault];
  toolbarContentView.backgroundColor = toolbarColor;
  toolbarContentView.layer.backgroundColor = toolbarColor.CGColor;
  toolbarContentView.opaque = YES;

#if BUILDFLAG(IS_IOS_TVOS)
  toolbarContentView.userInteractionEnabled = NO;
#endif

  toolbarContentView.alignment = UIStackViewAlignmentCenter;
  toolbarContentView.axis = UILayoutConstraintAxisHorizontal;
  toolbarContentView.spacing = 16.0;

  return toolbarContentView;
}

- (void)navigateByEdgeSwipe:(NSInteger)direction {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  content::NavigationController& controller =
      _shell->web_contents()->GetController();
  if (direction < 0 ? controller.CanGoBack() : controller.CanGoForward()) {
    _shell->GoBackOrForward(direction < 0 ? -1 : 1);
  }
}

- (void)back {
  _shell->GoBackOrForward(-1);
}

- (void)forward {
  _shell->GoBackOrForward(1);
}

- (void)reloadOrStop {
  UIImpactFeedbackGenerator* feedback = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  GURL url = _shell->web_contents()->GetLastCommittedURL();
  if (!url.is_valid()) {
    url = _shell->web_contents()->GetVisibleURL();
  }
  if (url.is_valid()) {
    _shell->LoadURL(url);
  }
}

- (void)togglePrivateBrowsing {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  BOOL enabled = ![defaults boolForKey:@"BlinkPrivateBrowsing"];
  [defaults setBool:enabled forKey:@"BlinkPrivateBrowsing"];
  [defaults synchronize];

  // Приватний контекст обирається на старті, тож перемикач діє з наступного
  // запуску. Пропонуємо перезапустити зараз.
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Private Browsing")
                       message:BlinkL(@"Blinker Fluid will close. Open it "
                                      @"again to apply.")
                preferredStyle:UIAlertControllerStyleAlert];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [alert
      addAction:[UIAlertAction actionWithTitle:BlinkL(@"Restart Blinker Fluid")
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf restartApplication];
                                       }]];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Later")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)restartApplication {
  BLINKER_DIAG("APP_RESTART: requested");
  BlinkPersistOpenTabs();
  BlinkPrepareForRestart();

  NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
  void* jailbreak =
      dlopen("/var/jb/usr/lib/libjailbreak.dylib", RTLD_NOW | RTLD_LOCAL);
  if (jailbreak && bundleID.length) {
    using ExecCmdNoWait = int (*)(pid_t*, const char*, ...);
    auto execCmd =
        reinterpret_cast<ExecCmdNoWait>(dlsym(jailbreak, "exec_cmd_nowait"));
    if (execCmd) {
      NSString* command =
          [NSString stringWithFormat:@"/var/jb/usr/bin/sleep 0.35; "
                                      "/var/jb/usr/bin/uiopen --bundleid '%@'",
                                     bundleID];
      pid_t child = 0;
      int result = execCmd(&child, "/var/jb/usr/bin/sh", "-c",
                           command.fileSystemRepresentation, nullptr);
      if (result == 0) {
        BLINKER_DIAG("APP_RESTART: relaunch helper scheduled");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
                         // Не exit, бо статичні деструктори тягнуть
                         // ContentMainRunnerImpl::Shutdown() і падають.
                         _exit(0);
                       });
        return;
      }
      BLINKER_DIAGF("APP_RESTART: helper failed error=%d", result);
    }
    dlclose(jailbreak);
  }

  // Помічника для перезапуску нема, на Dopamine exec_cmd_nowait з пісочниці
  // вертає 1. Просто виходим, налаштування діє з наступного запуску.
  BLINKER_DIAG("APP_RESTART: no relaunch helper; quitting for manual reopen");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   // Не exit, з тієї ж причини, що вище.
                   _exit(0);
                 });
}

// Вкладки. Кожна це content::Shell зі своїм UIWindow, і перемикання робить її
// вікно ключовим. Приватна вкладка має приватний контекст.
- (int)tabIdForShell:(content::Shell*)shell {
  int idx = 0;
  for (content::Shell* s : content::Shell::windows()) {
    if (s == shell) {
      return idx;
    }
    ++idx;
  }
  return -1;
}

- (void)logTab:(const char*)action shell:(content::Shell*)shell {
  BLINKER_DIAGF("TAB_MANAGER: %s id=%d tab_count=%zu", action,
                [self tabIdForShell:shell], content::Shell::windows().size());
}

- (void)showTabWindow:(content::Shell*)shell {
  if (!shell) {
    return;
  }
  BlinkNoteTabActivated(shell);
  BlinkStartIdleTabSweep();
  // Порожня вкладка, відкрита чи відновлена до того, як розширення стало
  // малювати на стартовій сторінці, має звичайний about:blank без мосту до
  // розширення. Завантажуємо її наново, тепер Shell зробить документ надійним.
  if (shell->web_contents() && !shell->web_contents()->IsLoading() &&
      content::BlinkerWebExtensionRegistry::GetInstance()
          .StartPageHasContentScripts()) {
    content::NavigationEntry* blank =
        shell->web_contents()->GetController().GetVisibleEntry();
    if ((!blank || blank->GetVirtualURL().is_empty() ||
         blank->GetVirtualURL().IsAboutBlank()) &&
        (!blank || blank->GetBaseURLForDataURL().is_empty())) {
      shell->LoadURL(GURL("about:blank"));
    }
  }
  if (shell->web_contents() && shell->web_contents()->WasDiscarded()) {
    GURL reload = shell->web_contents()->GetLastCommittedURL();
    shell->web_contents()->SetPageFrozen(false);
    if (reload.is_valid() && (reload.SchemeIsHTTPOrHTTPS() ||
                              content::BlinkerIsSavedPageURL(reload))) {
      BLINKER_DIAG("TAB_LIFECYCLE: reloading discarded tab");
      // Як Chrome, перезавантаження того самого запису, тож історія назад і
      // вперед лишається. LoadURL робив новий запис.
      content::NavigationController& controller =
          shell->web_contents()->GetController();
      controller.SetNeedsReload();
      controller.LoadIfNecessary();
      if (!controller.GetPendingEntry()) {
        shell->LoadURL(reload);
      }
    }
  }
  GURL pending = content::TakePendingRestoreURL(shell);
  auto crash_tab = g_crash_restore_urls.find(shell);
  if (crash_tab != g_crash_restore_urls.end()) {
    pending = crash_tab->second;
    g_crash_restore_inflight[shell] = pending;
    g_crash_restore_urls.erase(crash_tab);
  }
  if (pending.is_valid() &&
      (pending.SchemeIsHTTPOrHTTPS() ||
       content::BlinkerIsSavedPageURL(pending)) &&
      shell->web_contents()) {
    BLINKER_DIAG("SESSION_RESTORE: loading deferred tab");
    if (content::BlinkerRestoreTabSession(shell->web_contents(), pending)) {
      BLINKER_DIAG("SESSION_RESTORE: restored back and forward history");
    } else {
      shell->LoadURL(pending);
    }
  }
  [self logTab:"switched to tab" shell:shell];
  // У кожної вкладки свій UIWindow. Знімок беремо, поки стара ще видна. Нову
  // показуємо першою і лише тоді ховаємо решту, інакше між ними видно порожній
  // екран, це і було мигання.
  for (content::Shell* candidate : content::Shell::windows()) {
    UIWindow* candidateWindow = candidate->window().Get();
    if (candidate != shell && candidateWindow && !candidateWindow.hidden) {
      BlinkCaptureTabPreview(candidate);
    }
  }
  if (shell->web_contents()) {
    shell->web_contents()->SetPageFrozen(false);
    shell->web_contents()->WasShown();
  }
  UIWindow* win = shell->window().Get();
  if (win) {
    if (@available(iOS 13.0, *)) {
      UIWindowScene* scene = self.view.window.windowScene;
      // Вікно цієї вкладки могло вже закритись. Без сцени новий екран чорний.
      for (UIScene* candidate in UIApplication.sharedApplication
               .connectedScenes) {
        if (scene) {
          break;
        }
        if ([candidate isKindOfClass:[UIWindowScene class]]) {
          scene = (UIWindowScene*)candidate;
        }
      }
      if (scene) {
        win.windowScene = scene;
      }
    }
    win.hidden = NO;
    [win makeKeyAndVisible];
  }
  for (content::Shell* candidate : content::Shell::windows()) {
    if (candidate == shell) {
      continue;
    }
    UIWindow* candidateWindow = candidate->window().Get();
    if (candidateWindow) {
      candidateWindow.hidden = YES;
    }
    if (candidate->web_contents()) {
      candidate->web_contents()->WasHidden();
      candidate->web_contents()->SetPageFrozen(true);
    }
  }
  BlinkDiscardBackgroundTabs(shell);
  // Перемикання не змінює кількість вкладок і не створює WebContents.
  BLINKER_DIAGF("TAB_MANAGER: active tab id=%d web_contents=%p",
                [self tabIdForShell:shell],
                shell -> web_contents() ? (void*)shell -> web_contents()
                                        : nullptr);
  BLINKER_DIAG(shell->web_contents()
                   ? "TAB_MANAGER: invariant ok"
                   : "TAB_MANAGER: invariant failed active_missing");
}

- (void)openNewTab {
  BLINKER_DIAG("TAB_MANAGER: new tab requested");
  const size_t before = content::Shell::windows().size();
  content::BrowserContext* context =
      _shell && _shell->web_contents()
          ? _shell->web_contents()->GetBrowserContext()
          : content::ShellContentBrowserClient::Get()->browser_context();
  // Нова вкладка відкриває свою домашню сторінку, якщо задана, інакше порожню
  // з нативною стартовою.
  NSString* homepage =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"BlinkHomepage"];
  GURL url = homepage.length ? GURL(base::SysNSStringToUTF8(homepage))
                             : GURL("about:blank");
  if (!url.is_valid()) {
    url = GURL("about:blank");
  }
  // Сторінка нової вкладки від розширення, як у Chrome, крім приватного режиму.
  const GURL override_url = content::BlinkerNewTabOverrideURL();
  if (override_url.is_valid() && !context->IsOffTheRecord()) {
    url = override_url;
  }
  content::Shell* newShell =
      content::Shell::CreateNewWindow(context, url, nullptr, gfx::Size());
  if (!newShell) {
    BLINKER_DIAG("TAB_MANAGER: new tab request safely refused");
    const size_t after = content::Shell::windows().size();
    BLINKER_DIAG(after == before
                     ? "TAB_MANAGER: invariant ok blocked_no_count_change"
                     : "TAB_MANAGER: invariant failed blocked_changed_count");
    return;
  }
  [self logTab:"new tab created" shell:newShell];
  const size_t after = content::Shell::windows().size();
  BLINKER_DIAG(after == before + 1
                   ? "TAB_MANAGER: invariant ok"
                   : "TAB_MANAGER: invariant failed reason=new tab did not "
                     "add exactly one");
  [self showTabWindow:newShell];
  BlinkSaveOpenTabs();
}

- (void)presentList:(BlinkListVC*)vc {
  if ([self.presentedViewController
          isKindOfClass:[UINavigationController class]]) {
    UINavigationController* existing =
        (UINavigationController*)self.presentedViewController;
    // Кожен відкритий список, а не лиш меню. Налаштування сайту з рядка адреси
    // теж відкривають підсторінки, а показати другий модальний контролер поверх
    // першого UIKit не дає.
    if ([existing.topViewController isKindOfClass:[BlinkListVC class]] &&
        [existing.viewControllers.firstObject
            isKindOfClass:[BlinkListVC class]]) {
      vc.dismissOnAdd = NO;
      [existing pushViewController:vc animated:!_rebuildingMenu];
      vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
          initWithImage:BlinkSystemImage(@"chevron.left")
                  style:UIBarButtonItemStylePlain
                 target:vc
                 action:@selector(backTapped)];
      if (vc.onAdd) {
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                 target:vc
                                 action:@selector(addTapped)];
      } else {
        vc.navigationItem.rightBarButtonItem = nil;
      }
      return;
    }
  }
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  [self presentViewController:nav animated:!_rebuildingMenu completion:nil];
}

- (void)loadURLString:(NSString*)urlStr {
  GURL u(base::SysNSStringToUTF8(urlStr));
  if (u.is_valid() && _shell) {
    _shell->LoadURL(u);
  }
}

- (void)goHome {
  // Порожня вкладка, а setURL покаже над нею стартову сторінку.
  if (_shell) {
    _shell->LoadURL(GURL("about:blank"));
  }
}

- (void)showTabSwitcher {
  BLINKER_DIAG("TAB_MANAGER: tab button tapped");
  BLINKER_DIAG("TAB_MANAGER_UI: tab manager opened");
  [self logTab:"active tab" shell:_shell];
  UICollectionViewFlowLayout* layout =
      [[UICollectionViewFlowLayout alloc] init];
  BlinkTabsVC* vc = [[BlinkTabsVC alloc] initWithCollectionViewLayout:layout];
  vc.titles = [NSMutableArray array];
  vc.urls = [NSMutableArray array];
  vc.previews = [NSMutableArray array];
  vc.states = [NSMutableArray array];
  vc.privateMode = BlinkPrivateSession();
  NSMutableArray<NSValue*>* shells = [NSMutableArray array];
  NSDictionary<NSString*, NSString*>* savedTitles =
      [[NSUserDefaults standardUserDefaults]
          dictionaryForKey:@"BlinkTabTitlesByURL"]
          ?: @{};
  for (content::Shell* s : content::Shell::windows()) {
    NSString* url = BlinkTabURL(s) ?: @"about:blank";
    std::u16string t = s->web_contents()->GetTitle();
    NSString* title =
        t.empty() ? savedTitles[url] : base::SysUTF16ToNSString(t);
    if (!title.length || [title isEqualToString:@"about:blank"]) {
      GURL parsed(base::SysNSStringToUTF8(url));
      title = parsed.SchemeIsHTTPOrHTTPS() && !parsed.host().empty()
                  ? base::SysUTF8ToNSString(parsed.host())
                  : BlinkL(@"New Tab");
    }
    [vc.titles addObject:title];
    // Приспана Memory Saver вкладка перезавантажиться, коли її відкриють.
    BlinkTabState state = BlinkTabStateNormal;
    if (s->web_contents()->IsAudioMuted()) {
      state = BlinkTabStateMuted;
    } else if (s->web_contents()->IsCurrentlyAudible()) {
      state = BlinkTabStateAudible;
    } else if (s->web_contents()->WasDiscarded()) {
      state = BlinkTabStateSleeping;
    }
    [vc.states addObject:@(state)];
    if (s == _shell) {
      vc.currentIndex = static_cast<NSInteger>(vc.titles.count) - 1;
    }
    [vc.urls addObject:BlinkSavedPageName(url) ? BlinkL(@"Saved Page") : url];
    UIImage* preview = BlinkCaptureTabPreview(s);
    if (!preview) {
      preview = BlinkLoadTabPreview(s);
    }
    [vc.previews addObject:preview ?: [[UIImage alloc] init]];
    [shells addObject:[NSValue valueWithPointer:s]];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    content::Shell* sel = (content::Shell*)[shells[i] pointerValue];
    const size_t before = content::Shell::windows().size();
    BLINKER_DIAGF("TAB_MANAGER: selected existing tab id=%d",
                  [weakSelf tabIdForShell:sel]);
    [weakSelf showTabWindow:sel];
    BLINKER_DIAGF(
        "TAB_MANAGER: switched to existing WebContents=%p",
        sel && sel->web_contents() ? (void*)sel->web_contents() : nullptr);
    if (content::Shell::windows().size() == before) {
      BLINKER_DIAG("TAB_MANAGER: selection did not create new tab");
      BLINKER_DIAG("TAB_MANAGER: invariant ok select_no_count_change");
    } else {
      BLINKER_DIAG("TAB_MANAGER: invariant failed select_created_tab");
    }
  };
  vc.onAdd = ^{
    BLINKER_DIAG("TAB_MANAGER: new tab requested");
    [weakSelf openNewTab];
  };
  vc.onReorder = ^(NSInteger from, NSInteger to) {
    // Порядок вкладок для всіх інших читачів у Shell::windows(), тож
    // переставляємо запис там.
    auto windows = content::Shell::windows();
    if (from < 0 || to < 0 || from >= (NSInteger)windows.size() ||
        to >= (NSInteger)windows.size() || from >= (NSInteger)shells.count ||
        to >= (NSInteger)shells.count) {
      return;
    }
    // Порядок вікон міняє Shell
    BlinkMoveShellWindow(static_cast<size_t>(from), static_cast<size_t>(to));
    NSValue* movedValue = shells[from];
    [shells removeObjectAtIndex:from];
    [shells insertObject:movedValue atIndex:to];
    BLINKER_DIAGF("TAB_MANAGER: reordered tab %ld -> %ld", (long)from,
                  (long)to);
    BlinkSaveOpenTabs();
  };
  vc.onClose = ^BOOL(NSInteger i) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf) {
      return NO;
    }
    content::Shell* s = (content::Shell*)[shells[i] pointerValue];
    if (content::Shell::windows().size() <= 1) {
      // Остання вкладка лишається, але стає порожньою, як нова
      BLINKER_DIAG("TAB_MANAGER: final tab reset to the start page");
      s->LoadURL(GURL(url::kAboutBlankURL));
      [strongSelf dismissViewControllerAnimated:YES completion:nil];
      return NO;
    }
    [strongSelf logTab:"close tab requested" shell:s];
    if (s == strongSelf->_shell) {
      for (content::Shell* replacement : content::Shell::windows()) {
        if (replacement != s) {
          content::Shell* selectedReplacement = replacement;
          [strongSelf
              dismissViewControllerAnimated:NO
                                 completion:^{
                                   [strongSelf
                                       showTabWindow:selectedReplacement];
                                   dispatch_after(
                                       dispatch_time(
                                           DISPATCH_TIME_NOW,
                                           (int64_t)(0.15 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                                         s->Close();
                                         BlinkSaveOpenTabs();
                                       });
                                 }];
          BLINKER_DIAG("TAB_MANAGER: active close handed off to replacement");
          break;
        }
      }
      return NO;
    }
    [shells removeObjectAtIndex:i];
    s->Close();
    BLINKER_DIAG("TAB_MANAGER: close dispatched");
    BlinkSaveOpenTabs();
    return YES;
  };
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:nav animated:YES completion:nil];
}

// Закладки (лежать в NSUserDefaults).
- (NSMutableArray*)bookmarks {
  NSArray* saved =
      [[NSUserDefaults standardUserDefaults] arrayForKey:@"BlinkBookmarks"];
  if (!saved) {
    return [NSMutableArray array];
  }
  NSData* data = [NSPropertyListSerialization
      dataWithPropertyList:saved
                    format:NSPropertyListBinaryFormat_v1_0
                   options:0
                     error:nil];
  return data ? [NSPropertyListSerialization
                    propertyListWithData:data
                                 options:NSPropertyListMutableContainers
                                  format:nil
                                   error:nil]
              : [NSMutableArray array];
}

- (void)addBookmarkWithCompletion:(void (^)(NSDictionary*))completion {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Add Bookmark")
                       message:BlinkL(@"Enter a name and website address.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Name");
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"https://example.com";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:BlinkL(@"Add")
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction* action) {
                        NSString* title =
                            alert.textFields.firstObject.text ?: @"";
                        NSString* value =
                            alert.textFields.lastObject.text ?: @"";
                        value =
                            [value stringByTrimmingCharactersInSet:
                                       NSCharacterSet
                                           .whitespaceAndNewlineCharacterSet];
                        if (value.length && ![value containsString:@"://"]) {
                          value = [@"https://" stringByAppendingString:value];
                        }
                        NSURL* url = [NSURL URLWithString:value];
                        if (!url.host.length) {
                          UIAlertController* invalid = [UIAlertController
                              alertControllerWithTitle:BlinkL(
                                                           @"Invalid address")
                                               message:BlinkL(@"Enter a complete "
                                                       @"website address.")
                                        preferredStyle:
                                            UIAlertControllerStyleAlert];
                          [invalid
                              addAction:
                                  [UIAlertAction
                                      actionWithTitle:BlinkL(@"OK")
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
                          UIViewController* host =
                              weakSelf.presentedViewController ?: weakSelf;
                          [host presentViewController:invalid
                                             animated:YES
                                           completion:nil];
                          return;
                        }
                        NSDictionary* bookmark = @{
                          @"title" : title.length ? title : url.host,
                          @"url" : value
                        };
                        if (completion) {
                          completion(bookmark);
                        }
                      }]];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  UIViewController* presenter = self.presentedViewController ?: self;
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)showBookmarks {
  [self showBookmarksAtPath:@[] title:BlinkL(@"Bookmarks")];
}

- (NSMutableArray*)bookmarkItemsInRoot:(NSMutableArray*)root
                                  path:(NSArray<NSNumber*>*)path {
  NSMutableArray* items = root;
  for (NSNumber* component in path) {
    NSInteger index = component.integerValue;
    if (index < 0 || index >= (NSInteger)items.count) {
      return nil;
    }
    NSMutableDictionary* folder = items[index];
    if (![folder isKindOfClass:NSMutableDictionary.class]) {
      return nil;
    }
    NSMutableArray* children = folder[@"children"];
    if (![children isKindOfClass:NSMutableArray.class]) {
      children = [NSMutableArray array];
      folder[@"children"] = children;
    }
    items = children;
  }
  return items;
}

- (void)saveBookmarks:(NSArray*)bookmarks {
  [[NSUserDefaults standardUserDefaults] setObject:bookmarks
                                            forKey:@"BlinkBookmarks"];
}

- (void)showBookmarksAtPath:(NSArray<NSNumber*>*)path title:(NSString*)title {
  NSMutableArray* root = [self bookmarks];
  NSMutableArray* bms = [self bookmarkItemsInRoot:root path:path];
  if (!bms) {
    return;
  }
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.literalRows = YES;
  vc.title = title;
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSString*>* icons = [NSMutableArray array];
  for (NSDictionary* b in bms) {
    BOOL folder = [b[@"children"] isKindOfClass:NSArray.class];
    NSString* url = folder ? @"" : (b[@"url"] ?: @"");
    [vc.titles addObject:(b[@"title"] ?: url)];
    [vc.subtitles
        addObject:folder ? [NSString
                               stringWithFormat:BlinkL(@"%lu items"),
                                                (unsigned long)[b[@"children"]
                                                    count]]
                         : url];
    [icons addObject:folder ? @"folder.fill" : @"bookmark"];
  }
  vc.imageNames = icons;
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    if (i >= (NSInteger)bms.count) {
      return;
    }
    NSDictionary* item = bms[i];
    if ([item[@"children"] isKindOfClass:NSArray.class]) {
      [weakSelf showBookmarksAtPath:[path arrayByAddingObject:@(i)]
                              title:item[@"title"] ?: @"Folder"];
    } else {
      [weakSelf loadURLString:item[@"url"] ?: @""];
      [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }
  };
  vc.onDelete = ^(NSInteger i) {
    if (i < (NSInteger)bms.count) {
      [bms removeObjectAtIndex:i];
      [weakSelf saveBookmarks:root];
    }
  };
  __weak BlinkListVC* weakBookmarksVC = vc;
  vc.onAdd = ^{
    BlinkListVC* chooser = [[BlinkListVC alloc] init];
    chooser.title = BlinkL(@"Add");
    chooser.dismissOnSelect = NO;
    chooser.titles = [@[ @"Bookmark", @"Folder" ] mutableCopy];
    chooser.subtitles =
        [@[ @"Save a website address", @"Organize bookmarks" ] mutableCopy];
    chooser.imageNames = @[ @"bookmark", @"folder.fill" ];
    __weak BlinkListVC* weakChooser = chooser;
    chooser.onSelect = ^(NSInteger choice) {
      BlinkBookmarkEditorVC* editor = [[BlinkBookmarkEditorVC alloc] init];
      editor.folderMode = choice == 1;
      // Закладка за замовчуванням для сторінки, на якій людина зараз
      content::Shell* visible = KeyWindowShell();
      if (choice == 0 && visible && visible->web_contents()) {
        const GURL page = visible->web_contents()->GetVisibleURL();
        if (page.SchemeIsHTTPOrHTTPS()) {
          editor.initialURL = base::SysUTF8ToNSString(page.spec());
          editor.initialName = base::SysUTF16ToNSString(
              visible->web_contents()->GetTitle());
        }
      }
      editor.onSave = ^(NSString* name, NSString* url) {
        BOOL folder = choice == 1;
        NSMutableDictionary* item =
            folder ? [@{@"title" : name, @"children" : [NSMutableArray array]}
                         mutableCopy]
                   : [@{@"title" : name, @"url" : url} mutableCopy];
        [bms addObject:item];
        [weakSelf saveBookmarks:root];
        [weakBookmarksVC.titles addObject:name];
        [weakBookmarksVC.subtitles addObject:folder ? [NSString stringWithFormat:BlinkL(@"%lu items"), 0ul] : url];
        NSMutableArray* updated = [weakBookmarksVC.imageNames mutableCopy];
        [updated addObject:folder ? @"folder.fill" : @"bookmark"];
        weakBookmarksVC.imageNames = updated;
        [weakBookmarksVC.tableView reloadData];
      };
      [weakChooser.navigationController pushViewController:editor animated:YES];
    };
    [weakBookmarksVC.navigationController pushViewController:chooser
                                                    animated:YES];
  };
  [self presentList:vc];
}

// Завантаження лягають у <data>/MyFiles/Downloads.
- (void)showDownloads {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:NO forKey:@"BlinkDownloadAttention"];
  [defaults synchronize];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:kBlinkDownloadAttentionChanged
                    object:nil];
  base::FilePath p = _shell->web_contents()
                         ->GetBrowserContext()
                         ->GetPath()
                         .Append(FILE_PATH_LITERAL("MyFiles"))
                         .Append(FILE_PATH_LITERAL("Downloads"));
  NSString* dir = base::SysUTF8ToNSString(p.value());
  NSFileManager* fm = [NSFileManager defaultManager];
  NSArray* files = [fm contentsOfDirectoryAtPath:dir error:nil];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.literalRows = YES;
  vc.title = BlinkL(@"Downloads");
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  NSMutableArray* thumbnails = [NSMutableArray array];
  for (NSString* f in files) {
    NSString* full = [dir stringByAppendingPathComponent:f];
    NSDictionary* attrs = [fm attributesOfItemAtPath:full error:nil];
    [vc.titles addObject:f];
    [vc.subtitles
        addObject:[NSByteCountFormatter
                      stringFromByteCount:(long long)[attrs fileSize]
                               countStyle:NSByteCountFormatterCountStyleFile]];
    [paths addObject:full];
    UIImage* thumbnail = nil;
    NSString* ext = f.pathExtension.lowercaseString;
    NSSet* imageExtensions = [NSSet
        setWithArray:@[ @"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp" ]];
    NSSet* videoExtensions =
        [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v", @"webm" ]];
    if ([imageExtensions containsObject:ext]) {
      UIImage* image = [UIImage imageWithContentsOfFile:full];
      if (@available(iOS 15.0, *)) {
        thumbnail = [image imageByPreparingThumbnailOfSize:CGSizeMake(64, 40)];
      } else {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 40), YES, 0);
        [image drawInRect:CGRectMake(0, 0, 64, 40)];
        thumbnail = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
      }
    } else if ([videoExtensions containsObject:ext]) {
      AVAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:full]
                                           options:nil];
      AVAssetImageGenerator* generator =
          [[AVAssetImageGenerator alloc] initWithAsset:asset];
      generator.appliesPreferredTrackTransform = YES;
      generator.maximumSize = CGSizeMake(64, 40);
      CGImageRef frame =
          [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600)
                            actualTime:nullptr
                                 error:nil];
      if (frame) {
        thumbnail = [UIImage imageWithCGImage:frame];
        CGImageRelease(frame);
      }
    }
    [thumbnails addObject:thumbnail ?: (id)[NSNull null]];
  }
  vc.rowImages = thumbnails;
  if (vc.titles.count == 0) {
    [vc.titles addObject:BlinkL(@"No downloads yet")];
    [vc.subtitles addObject:@""];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    if (i >= (NSInteger)paths.count) {
      return;
    }
    NSString* ext = paths[i].pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mhtml"] || [ext isEqualToString:@"mht"]) {
      NSString* fileURL = [NSURL fileURLWithPath:paths[i]].absoluteString;
      [weakSelf dismissViewControllerAnimated:YES
                                   completion:^{
                                     [weakSelf openSavedPage:fileURL];
                                   }];
      return;
    }
    UIActivityViewController* share = [[UIActivityViewController alloc]
        initWithActivityItems:@[ [NSURL fileURLWithPath:paths[i]] ]
        applicationActivities:nil];
    [weakSelf presentViewController:share animated:YES completion:nil];
  };
  vc.onDelete = ^(NSInteger i) {
    if (i < (NSInteger)paths.count) {
      [[NSFileManager defaultManager] removeItemAtPath:paths[i] error:nil];
    }
  };
  [self presentList:vc];
}

- (void)openSavedPage:(NSString*)fileURL {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  content::Shell* shell = content::Shell::CreateNewWindow(
      _shell->web_contents()->GetBrowserContext(),
      GURL(base::SysNSStringToUTF8(fileURL)), nullptr, gfx::Size());
  if (shell) {
    [self showTabWindow:shell];
  }
}

- (void)closeCurrentTab {
  if (content::Shell::windows().size() <= 1) {
    return;
  }
  content::Shell* current = _shell;
  for (content::Shell* s : content::Shell::windows()) {
    if (s != current) {
      [self showTabWindow:s];
      break;
    }
  }
  current->Close();
  BlinkSaveOpenTabs();
}

// Позиція панелі зверху (за замовчуванням) чи знизу, в NSUserDefaults.
namespace {
std::string BlinkerPopupPath(const content::BlinkerWebExtension& extension);
NSString* BlinkerExtensionURL(const std::string& id,
                              const std::string& relative);
}  // namespace

// Скорочення з manifest.commands. Ctrl на маку в Chrome це Command.
static BOOL BlinkParseExtensionShortcut(const std::string& spec,
                                        NSString** input,
                                        UIKeyModifierFlags* flags) {
  *flags = 0;
  *input = nil;
  for (const std::string& raw : base::SplitString(
           spec, "+", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    const std::string part = base::ToLowerASCII(raw);
    if (part == "ctrl" || part == "command") {
      *flags |= UIKeyModifierCommand;
    } else if (part == "macctrl") {
      *flags |= UIKeyModifierControl;
    } else if (part == "alt" || part == "option") {
      *flags |= UIKeyModifierAlternate;
    } else if (part == "shift") {
      *flags |= UIKeyModifierShift;
    } else if (part.size() == 1 && base::IsAsciiAlphaNumeric(part[0])) {
      *input = base::SysUTF8ToNSString(part);
    } else if (part == "comma" || part == "period" || part == "space") {
      *input = part == "comma" ? @"," : (part == "period" ? @"." : @" ");
    } else if (part == "up" || part == "down" || part == "left" ||
               part == "right") {
      *input = part == "up"     ? UIKeyInputUpArrow
               : part == "down" ? UIKeyInputDownArrow
               : part == "left" ? UIKeyInputLeftArrow
                                : UIKeyInputRightArrow;
    } else if (part == "pageup" || part == "pagedown") {
      *input = part == "pageup" ? UIKeyInputPageUp : UIKeyInputPageDown;
    } else {
      return NO;
    }
  }
  const UIKeyModifierFlags required =
      UIKeyModifierCommand | UIKeyModifierControl | UIKeyModifierAlternate;
  return *input != nil && (*flags & required) != 0;
}

static NSMutableDictionary<NSString*, NSArray<NSString*>*>*
BlinkExtensionShortcutTargets() {
  static NSMutableDictionary* targets = [NSMutableDictionary dictionary];
  return targets;
}

- (NSArray<UIKeyCommand*>*)keyCommands {
  NSMutableArray<UIKeyCommand*>* commands =
      [NSMutableArray arrayWithArray:[super keyCommands] ?: @[]];
  NSMutableDictionary* targets = BlinkExtensionShortcutTargets();
  [targets removeAllObjects];
  for (const auto& extension :
       content::BlinkerWebExtensionRegistry::GetInstance().extensions()) {
    const base::DictValue* declared =
        extension->enabled ? extension->manifest.FindDict("commands")
                           : nullptr;
    if (!declared) {
      continue;
    }
    for (const auto [name, value] : *declared) {
      const base::DictValue* command = value.GetIfDict();
      const base::Value* suggested =
          command ? command->Find("suggested_key") : nullptr;
      const std::string* spec = suggested ? suggested->GetIfString() : nullptr;
      if (suggested && suggested->is_dict()) {
        const base::DictValue& keys = suggested->GetDict();
        spec = keys.FindString("ios");
        spec = spec ? spec : keys.FindString("mac");
        spec = spec ? spec : keys.FindString("default");
      }
      NSString* input = nil;
      UIKeyModifierFlags flags = 0;
      if (!spec || !BlinkParseExtensionShortcut(*spec, &input, &flags)) {
        continue;
      }
      NSString* key = [NSString stringWithFormat:@"%@|%ld", input, (long)flags];
      if (targets[key]) {
        continue;  // перше розширення лишає собі скорочення
      }
      targets[key] = @[
        base::SysUTF8ToNSString(extension->id), base::SysUTF8ToNSString(name)
      ];
      UIKeyCommand* keyCommand =
          [UIKeyCommand keyCommandWithInput:input
                              modifierFlags:flags
                                     action:@selector(runExtensionShortcut:)];
      if (const std::string* description =
              command->FindString("description")) {
        keyCommand.discoverabilityTitle =
            base::SysUTF8ToNSString(*description);
      }
      [commands addObject:keyCommand];
    }
  }
  return commands;
}

- (void)runExtensionShortcut:(UIKeyCommand*)keyCommand {
  NSArray<NSString*>* target = BlinkExtensionShortcutTargets()[[NSString
      stringWithFormat:@"%@|%ld", keyCommand.input,
                       (long)keyCommand.modifierFlags]];
  if (target.count != 2 || !_shell || !_shell->web_contents()) {
    return;
  }
  const std::string id = base::SysNSStringToUTF8(target[0]);
  const std::string name = base::SysNSStringToUTF8(target[1]);
  if (name == "_execute_action" || name == "_execute_browser_action" ||
      name == "_execute_page_action") {
    for (const auto& extension :
         content::BlinkerWebExtensionRegistry::GetInstance().extensions()) {
      if (extension->id != id) {
        continue;
      }
      NSString* popup = BlinkerExtensionURL(id, BlinkerPopupPath(*extension));
      if (popup) {
        [self openExtensionPage:popup];
      } else {
        content::BlinkerActivateExtensionAction(id, _shell->web_contents());
      }
      return;
    }
    return;
  }
  content::BlinkerFireExtensionCommand(id, name, _shell->web_contents());
}

- (void)applyKioskLayout {
  if (!_contentView) {
    return;
  }
  _toolbarBackgroundView.hidden = YES;
  _loadingProgressView.hidden = YES;
  [NSLayoutConstraint deactivateConstraints:_topPosConstraints];
  [NSLayoutConstraint deactivateConstraints:_bottomPosConstraints];
  _topPosConstraints = @[
    [_contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [_contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                              constant:-_keyboardViewportInset],
  ];
  _bottomPosConstraints = nil;
  [NSLayoutConstraint activateConstraints:_topPosConstraints];
  if (!self.kioskExitGesture) {
    self.kioskExitGesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleKioskExitGesture:)];
    self.kioskExitGesture.numberOfTouchesRequired = 3;
    self.kioskExitGesture.minimumPressDuration = 0.8;
    self.kioskExitGesture.cancelsTouchesInView = NO;
    self.kioskExitGesture.delaysTouchesBegan = NO;
    [self.view addGestureRecognizer:self.kioskExitGesture];
  }
  self.kioskExitGesture.enabled = YES;
  self.kioskLayoutApplied = YES;
}

- (void)handleKioskExitGesture:(UILongPressGestureRecognizer*)gesture {
  if (gesture.state != UIGestureRecognizerStateBegan || !g_blink_kiosk_mode ||
      self.presentedViewController) {
    return;
  }
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Exit Full Screen?")
                       message:nil
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Exit")
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction*) {
                                            BlinkSetKioskMode(NO);
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)prefersStatusBarHidden {
  return g_blink_kiosk_mode;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return g_blink_kiosk_mode;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
  return g_blink_kiosk_mode ? UIRectEdgeAll : UIRectEdgeNone;
}

- (CGFloat)effectiveKeyboardInset {
  const BOOL bottom =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkToolbarBottom"];
  return MAX(self.webKeyboardInset, bottom ? self.nativeKeyboardInset : 0);
}

- (void)applyToolbarPosition {
  _keyboardViewportInset = [self effectiveKeyboardInset];
  if (g_blink_kiosk_mode && _shell &&
      !_shell->IsFullscreenForTabOrPending(_shell->web_contents())) {
    [self applyKioskLayout];
    return;
  }
  if (self.kioskLayoutApplied) {
    self.kioskLayoutApplied = NO;
    self.kioskExitGesture.enabled = NO;
    _toolbarBackgroundView.hidden = NO;
    _loadingProgressView.hidden = NO;
  }
  const BOOL hideToolbar =
      content::Shell::ShouldHideToolbar() || !_toolbarBackgroundView;
  // Налаштування застосовується до всіх вкладок. Вкладка без готових view
  // кинула б NSException, тож пропускаємо її, вона застосує його сама.
  if (!_contentView || (!hideToolbar && !_loadingProgressView)) {
    return;
  }
  [NSLayoutConstraint deactivateConstraints:_topPosConstraints];
  [NSLayoutConstraint deactivateConstraints:_bottomPosConstraints];
  if (hideToolbar) {
    _topPosConstraints = @[
      [_contentView.topAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      // Вміст до самого низу під індикатором, як у Safari і Chrome, без білої
      // смуги.
      [_contentView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor
                         constant:-_keyboardViewportInset],
    ];
    _bottomPosConstraints = nil;
    [NSLayoutConstraint activateConstraints:_topPosConstraints];
    return;
  }
  BOOL bottom =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkToolbarBottom"];
  [NSLayoutConstraint deactivateConstraints:_loadingProgressConstraints];
  _loadingProgressConstraints = @[
    [_loadingProgressView.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [_loadingProgressView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    bottom ? [_loadingProgressView.bottomAnchor
                 constraintEqualToAnchor:_toolbarBackgroundView.topAnchor]
           : [_loadingProgressView.topAnchor
                 constraintEqualToAnchor:_toolbarBackgroundView.bottomAnchor],
    [_loadingProgressView.heightAnchor constraintEqualToConstant:2],
  ];
  [NSLayoutConstraint activateConstraints:_loadingProgressConstraints];
  _topPosConstraints = @[
    [_toolbarBackgroundView.topAnchor
        constraintEqualToAnchor:self.view.topAnchor],
    [_contentView.topAnchor
        constraintEqualToAnchor:_toolbarBackgroundView.bottomAnchor],
    [_contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                              constant:-_keyboardViewportInset],
  ];
  // Знизу панель стоїть над клавіатурою, а не під нею. Висота клавіатури з
  // сповіщення вже містить панель над клавішами, тож зсув рівний їй. Без
  // клавіатури зсув нуль.
  _bottomPosConstraints = @[
    [_toolbarBackgroundView.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor
                       constant:-_keyboardViewportInset],
    [_contentView.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_contentView.bottomAnchor
        constraintEqualToAnchor:_toolbarBackgroundView.topAnchor],
  ];
  [NSLayoutConstraint
      activateConstraints:bottom ? _bottomPosConstraints : _topPosConstraints];
}

- (void)setPageLoading:(BOOL)loading {
  if (!_loadingProgressView) {
    return;
  }
  [_loadingProgressView.layer removeAllAnimations];
  if (loading) {
    _loadingProgressView.hidden = NO;
    [_loadingProgressView setProgress:0.12 animated:NO];
    [UIView animateWithDuration:8.0
                     animations:^{
                       [self.loadingProgressView setProgress:0.86 animated:YES];
                     }];
  } else {
    [self updateSiteButtons];
    // Знімок для списку вкладок беремо, коли сторінка встигла намалюватись.
    // Без цього вкладка, яку жодного разу не відкривали зі списку, лишалась
    // без знімка.
    __weak ContentShellWindowDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     ContentShellWindowDelegate* strongSelf = weakSelf;
                     if (strongSelf && strongSelf->_shell &&
                         strongSelf.view.window.isKeyWindow) {
                       BlinkCaptureTabPreview(strongSelf->_shell);
                     }
                   });
    [_loadingProgressView setProgress:1 animated:YES];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          self.loadingProgressView.hidden = YES;
          [self.loadingProgressView setProgress:0 animated:NO];
        });
  }
}

- (void)setKeyboardViewportInset:(CGFloat)inset {
  self.webKeyboardInset = MAX((CGFloat)0, inset);
  [self refreshKeyboardInset];
}

- (void)nativeKeyboardFrameChanged:(NSNotification*)notification {
  UIWindow* window = self.view.window;
  if (!window) {
    return;
  }
  CGFloat height = 0;
  if (![notification.name isEqualToString:UIKeyboardWillHideNotification]) {
    NSValue* end = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    const CGRect overlap = CGRectIntersection(
        window.bounds, [window convertRect:end.CGRectValue fromWindow:nil]);
    height = CGRectIsNull(overlap) ? 0 : overlap.size.height;
  }
  // Низька смужка від фізичної клавіатури не рахується.
  if (height < 150) {
    height = 0;
  }
  if (height > 0 && !window.isKeyWindow) {
    return;
  }
  NSNumber* duration =
      notification.userInfo[UIKeyboardAnimationDurationUserInfoKey];
  NSNumber* curve = notification.userInfo[UIKeyboardAnimationCurveUserInfoKey];
  g_blink_keyboard_duration = duration.doubleValue > 0 ? duration.doubleValue
                                                       : 0.25;
  g_blink_keyboard_curve = curve ? curve.integerValue : 7;
  self.nativeKeyboardInset = height;
  [self refreshKeyboardInset];
}

- (void)refreshKeyboardInset {
  if (fabs(_keyboardViewportInset - [self effectiveKeyboardInset]) < 1) {
    return;
  }
  [self applyToolbarPosition];
  // Панель і вміст їдуть за тим же часом і кривою, що й клавіатура, тож між
  // ними нема щілини і мигання.
  const NSTimeInterval duration = g_blink_keyboard_duration;
  [UIView animateWithDuration:duration
                        delay:0
                      options:(UIViewAnimationOptions)(
                                  (g_blink_keyboard_curve << 16) |
                                  UIViewAnimationOptionBeginFromCurrentState)
                   animations:^{
                     [self.view layoutIfNeeded];
                   }
                   completion:nil];
}

- (void)toggleToolbarPosition {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setBool:![d boolForKey:@"BlinkToolbarBottom"]
      forKey:@"BlinkToolbarBottom"];
  for (content::Shell* s : content::Shell::windows()) {
    UIWindow* w = s->window().Get();
    if ([w.rootViewController
            isKindOfClass:[ContentShellWindowDelegate class]]) {
      ContentShellWindowDelegate* del =
          (ContentShellWindowDelegate*)w.rootViewController;
      [del applyToolbarPosition];
      [w layoutIfNeeded];
    }
  }
}

// У фоні сторінки не малюють. Metal відкидає роботу GPU застосунку у фоні, а
// втрачений через це пристрій Dawn у процесі браузера вже не відновити.
// Вкладка зі звуком лишається як була, щоб не зупинити відтворення.
extern "C" void BlinkSetPagesBackgrounded(bool backgrounded) {
  static base::NoDestructor<std::vector<base::WeakPtr<content::WebContents>>>
      hidden;
  if (!backgrounded) {
    for (base::WeakPtr<content::WebContents>& contents : *hidden) {
      if (contents) {
        contents->WasShown();
      }
    }
    hidden->clear();
    return;
  }
  for (content::Shell* shell : content::Shell::windows()) {
    content::WebContents* contents = shell->web_contents();
    if (!contents ||
        contents->GetVisibility() != content::Visibility::VISIBLE ||
        contents->IsCurrentlyAudible()) {
      continue;
    }
    contents->WasHidden();
    hidden->push_back(contents->GetWeakPtr());
  }
}

extern "C" void BlinkSetKeyboardAnimation(double duration, int curve) {
  g_blink_keyboard_duration = duration > 0 ? duration : 0.25;
  g_blink_keyboard_curve = curve >= 0 ? curve : 7;
}

extern "C" void BlinkSetKeyboardViewportInset(float inset) {
  dispatch_async(dispatch_get_main_queue(), ^{
    for (content::Shell* shell : content::Shell::windows()) {
      UIWindow* window = shell->window().Get();
      if (![window.rootViewController
              isKindOfClass:[ContentShellWindowDelegate class]]) {
        continue;
      }
      ContentShellWindowDelegate* delegate =
          (ContentShellWindowDelegate*)window.rootViewController;
      if (window.isKeyWindow || inset == 0) {
        [delegate setKeyboardViewportInset:inset];
      }
    }
  });
}

// Мова інтерфейсу Blinker Fluid окремо від клавіатури iOS. Чи брати
// Accept-Language, вирішує сам сайт. Переклади в ui_strings.json, ключ там
// англійський рядок, чого нема то показуєм англійською.
static NSString* BlinkL(NSString* english) {
  static NSDictionary* table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString* path = [NSBundle.mainBundle pathForResource:@"ui_strings"
                                                   ofType:@"json"];
    NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil]
                     : nil;
    table = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
  });
  if (![english isKindOfClass:NSString.class] || !english.length) {
    return english;
  }
  NSString* accept = [[NSUserDefaults standardUserDefaults]
                         stringForKey:@"BlinkLanguageAccept"]
                         ?: @"en-US,en";
  NSString* code = [[[accept componentsSeparatedByString:@","] firstObject]
                       componentsSeparatedByString:@"-"]
                       .firstObject.lowercaseString;
  NSDictionary* entry = table[english];
  id value = [entry isKindOfClass:NSDictionary.class] ? entry[code] : nil;
  return [value isKindOfClass:NSString.class] && [value length] ? value
                                                                : english;
}

// ui/shell_dialogs cannot see BlinkL, the file chooser asks for it here.
extern "C" NSString* BlinkLocalizedString(NSString* english) {
  return BlinkL(english);
}

- (UIImage*)googleProfileImage {
  const BOOL privateSession =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  if (privateSession) {
    return g_private_google_avatar;
  }
  return [UIImage imageWithContentsOfFile:BlinkGoogleAvatarPath()];
}

- (UIImage*)googleSecondaryProfileImage {
  const BOOL privateSession =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  if (privateSession) {
    return [BlinkGoogleAvatarIdentity(g_private_google_avatar_url)
               isEqualToString:BlinkGoogleAvatarIdentity(
                                   g_private_google_secondary_avatar_url)]
               ? nil
               : g_private_google_secondary_avatar;
  }
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* primary = [defaults stringForKey:@"BlinkGoogleAvatarURL"];
  NSString* secondary =
      [defaults stringForKey:@"BlinkGoogleSecondaryAvatarURL"];
  if ([BlinkGoogleAvatarIdentity(primary)
          isEqualToString:BlinkGoogleAvatarIdentity(secondary)]) {
    [defaults removeObjectForKey:@"BlinkGoogleSecondaryAvatarURL"];
    [[NSFileManager defaultManager]
        removeItemAtPath:BlinkGoogleSecondaryAvatarPath()
                   error:nil];
    return nil;
  }
  return [UIImage imageWithContentsOfFile:BlinkGoogleSecondaryAvatarPath()];
}

- (NSString*)googleProfileSubtitle {
  const BOOL privateSession =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  NSString* email = privateSession
                        ? g_private_google_email
                        : [[NSUserDefaults standardUserDefaults]
                              stringForKey:@"BlinkGoogleAccountEmail"];
  if (email.length) {
    return email;
  }
  return privateSession ? @"No normal accounts are shared with private mode"
                        : @"Add or manage your saved sign in";
}

typedef NS_ENUM(NSInteger, BlinkMenuRow) {
  BlinkMenuRowAccount,
  BlinkMenuRowReload,
  BlinkMenuRowNewTab,
  BlinkMenuRowTabs,
  BlinkMenuRowHome,
  BlinkMenuRowPrivate,
  BlinkMenuRowBookmarks,
  BlinkMenuRowDownloads,
  BlinkMenuRowExtensions,
  BlinkMenuRowSiteSettings,
  BlinkMenuRowSiteMode,
  BlinkMenuRowZoom,
  BlinkMenuRowTranslate,
  BlinkMenuRowFind,
  BlinkMenuRowSaveOffline,
  BlinkMenuRowShare,
  BlinkMenuRowFullScreen,
  BlinkMenuRowSettings,
  BlinkMenuRowUpdates,
  BlinkMenuRowSiteAdBlock,
};

- (void)showMainMenu {
  if (!_rebuildingMenu) {
    UIImpactFeedbackGenerator* feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  bool isDesktop = _shell && content::BlinkIsDesktopSite(_shell->web_contents());
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Menu");
  vc.compactRows = YES;
  vc.dismissOnSelect = NO;
  int zoomPercent = BlinkCurrentPageZoomPercent(_shell);
  BOOL privateOn =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  const GURL pageURL = _shell && _shell->web_contents()
                           ? _shell->web_contents()->GetLastCommittedURL()
                           : GURL();
  const BOOL webPage = pageURL.SchemeIsHTTPOrHTTPS();
  vc.titles = [@[
    @"Google Account", BlinkL(@"Reload"), BlinkL(@"New Tab"),
    [NSString stringWithFormat:@"%@ (%zu)", BlinkL(@"Tabs"),
                               content::Shell::windows().size()],
    BlinkL(@"Home"), BlinkL(@"Private Browsing"),
    BlinkL(@"Bookmarks"), BlinkL(@"Downloads"), BlinkL(@"Extensions"),
    BlinkL(@"Site Settings"),
    isDesktop ? BlinkL(@"Request Mobile Page")
              : BlinkL(@"Request Desktop Page"),
    [NSString stringWithFormat:@"%@ (%d%%)", BlinkL(@"Page Zoom"), zoomPercent],
    BlinkL(@"Translate Page"), BlinkL(@"Find in Page"),
    BlinkL(@"Save Page Offline"), BlinkL(@"Share Link"),
    BlinkL(@"Full Screen"), BlinkL(@"Settings"),
    BlinkL(@"Check for Updates"), @"Block ads on this site"
  ] mutableCopy];
  vc.subtitles = [@[
    @"Add or manage your saved sign in", @"", @"", @"",
    @"", privateOn ? BlinkL(@"On") : BlinkL(@"Off"), @"", @"",
    [self extensionsMenuSubtitle],
    webPage ? base::SysUTF8ToNSString(pageURL.host()) : @"", @"", @"", @"",
    @"", @"", @"", @"Hold with three fingers to exit", @"",
    BlinkL(@"Latest GitHub release"), @""
  ] mutableCopy];
  vc.imageNames = @[
    @"person.crop.circle.badge.plus", @"arrow.clockwise", @"plus",
    @"square.on.square", @"house", @"eye.slash",
    @"bookmark", @"arrow.down.circle", @"puzzlepiece.extension",
    @"slider.horizontal.3", @"desktopcomputer", @"textformat.size",
    @"character.bubble", @"magnifyingglass", @"arrow.down.doc",
    @"square.and.arrow.up", @"arrow.up.left.and.arrow.down.right",
    @"gearshape", @"arrow.triangle.2.circlepath", @"hand.raised.slash"
  ];
  UIImage* googleAvatar = BlinkCircularMenuIcon([self googleProfileImage]);
  NSMutableArray* rowImages = [NSMutableArray array];
  for (NSUInteger row = 0; row < vc.titles.count; ++row) {
    [rowImages addObject:row == BlinkMenuRowAccount && googleAvatar
                             ? static_cast<id>(googleAvatar)
                             : static_cast<id>([NSNull null])];
  }
  vc.rowImages = rowImages;
  vc.subtitles[BlinkMenuRowAccount] = [self googleProfileSubtitle];
  vc.sectionTitles = @[
    @"ACCOUNT", BlinkL(@"BROWSER"), BlinkL(@"LIBRARY"), BlinkL(@"PAGE"),
    BlinkL(@"APP")
  ];
  vc.sectionStarts = @[
    @(BlinkMenuRowAccount), @(BlinkMenuRowReload), @(BlinkMenuRowBookmarks),
    @(BlinkMenuRowSiteSettings), @(BlinkMenuRowSettings)
  ];
  if ([[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkDownloadAttention"]) {
    vc.badgedRows = [NSIndexSet indexSetWithIndex:BlinkMenuRowDownloads];
  }
  [self updateSiteAdBlockRow:vc];
  if (!webPage) {
    NSMutableIndexSet* disabled =
        [vc.disabledRows mutableCopy] ?: [NSMutableIndexSet indexSet];
    [disabled addIndex:BlinkMenuRowSiteSettings];
    [disabled addIndex:BlinkMenuRowTranslate];
    [disabled addIndex:BlinkMenuRowSaveOffline];
    vc.disabledRows = disabled;
  }
  __weak BlinkListVC* weakMenu = vc;
  vc.onSelect = ^(NSInteger row) {
    void (^dismissThen)(dispatch_block_t) = ^(dispatch_block_t action) {
      [weakMenu.navigationController dismissViewControllerAnimated:YES
                                                        completion:action];
    };
    switch (static_cast<BlinkMenuRow>(row)) {
      case BlinkMenuRowAccount:
        [weakSelf showGoogleAccountMenu];
        break;
      case BlinkMenuRowReload: {
        dismissThen(^{
          [weakSelf reloadOrStop];
        });
        break;
      }
      case BlinkMenuRowNewTab: {
        dismissThen(^{
          [weakSelf openNewTab];
        });
        break;
      }
      case BlinkMenuRowTabs: {
        dismissThen(^{
          [weakSelf showTabSwitcher];
        });
        break;
      }
      case BlinkMenuRowHome: {
        dismissThen(^{
          [weakSelf goHome];
        });
        break;
      }
      case BlinkMenuRowPrivate: {
        dismissThen(^{
          [weakSelf togglePrivateBrowsing];
        });
        break;
      }
      case BlinkMenuRowBookmarks:
        [weakSelf showBookmarks];
        break;
      case BlinkMenuRowDownloads:
        [weakSelf showDownloads];
        break;
      case BlinkMenuRowExtensions:
        [weakSelf showExtensionsMenu];
        break;
      case BlinkMenuRowSiteMode: {
        dismissThen(^{
          [weakSelf toggleDesktopSite];
        });
        break;
      }
      case BlinkMenuRowZoom: {
        [weakSelf showPageZoomMenuThen:^(int percent) {
          weakMenu.titles[BlinkMenuRowZoom] = [NSString
              stringWithFormat:@"%@ (%d%%)", BlinkL(@"Page Zoom"), percent];
          [weakMenu.tableView reloadData];
        }];
        break;
      }
      case BlinkMenuRowSiteSettings:
        [weakSelf showSiteSettings];
        break;
      case BlinkMenuRowTranslate: {
        dismissThen(^{
          [weakSelf translatePage];
        });
        break;
      }
      case BlinkMenuRowSaveOffline: {
        dismissThen(^{
          [weakSelf savePageOffline];
        });
        break;
      }
      case BlinkMenuRowFullScreen: {
        dismissThen(^{
          BlinkSetKioskMode(YES);
        });
        break;
      }
      case BlinkMenuRowFind: {
        dismissThen(^{
          [weakSelf showFindInPage];
        });
        break;
      }
      case BlinkMenuRowShare: {
        dismissThen(^{
          [weakSelf shareCurrentLink];
        });
        break;
      }
      case BlinkMenuRowSettings:
        [weakSelf showSettings];
        break;
      case BlinkMenuRowUpdates:
        [weakSelf checkForUpdates];
        break;
      case BlinkMenuRowSiteAdBlock:
        [weakSelf toggleSiteAdBlock];
        [weakSelf updateSiteAdBlockRow:weakMenu];
        break;
    }
  };
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationPopover;
  nav.preferredContentSize =
      CGSizeMake(MIN(340, self.view.bounds.size.width - 36),
                 MIN(500, self.view.bounds.size.height - 130));
  UIColor* menuChrome = [UIColor colorWithWhite:0.09 alpha:1.0];
  // Фон списку того ж сірого кольору, що й поповер, з відступом знизу, щоб
  // обрізаний рядок не залазив на стрілку.
  vc.tableView.backgroundColor = menuChrome;
  vc.tableView.contentInset = UIEdgeInsetsMake(0, 0, 14, 0);
  vc.tableView.tableFooterView =
      [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 14)];
  UIPopoverPresentationController* popover = nav.popoverPresentationController;
  popover.delegate = self;
  popover.sourceView = _menuButton;
  popover.sourceRect = _menuButton.bounds;
  popover.permittedArrowDirections =
      UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
  popover.backgroundColor = menuChrome;
  [self presentViewController:nav animated:!_rebuildingMenu completion:nil];
}

// Екран розширень.

namespace {

// Сторінка popup з manifest, версія manifest не важлива.
std::string BlinkerPopupPath(const content::BlinkerWebExtension& extension) {
  for (const char* key : {"action", "browser_action", "page_action"}) {
    if (const base::DictValue* section = extension.manifest.FindDict(key)) {
      if (const std::string* page = section->FindString("default_popup")) {
        return *page;
      }
    }
  }
  return std::string();
}

// `options_ui.page` або старий `options_page`.
std::string BlinkerOptionsPath(const content::BlinkerWebExtension& extension) {
  if (const base::DictValue* ui = extension.manifest.FindDict("options_ui")) {
    if (const std::string* page = ui->FindString("page")) {
      return *page;
    }
  }
  if (const std::string* page = extension.manifest.FindString("options_page")) {
    return *page;
  }
  return std::string();
}

NSString* BlinkerExtensionURL(const std::string& id,
                              const std::string& relative) {
  if (relative.empty()) {
    return nil;
  }
  std::string path = relative;
  while (!path.empty() && path.front() == '/') {
    path.erase(path.begin());
  }
  return base::SysUTF8ToNSString(
      base::StrCat({content::kBlinkerExtensionScheme, "://", id, "/", path}));
}

}  // namespace

- (NSString*)extensionsMenuSubtitle {
  auto& registry = content::BlinkerWebExtensionRegistry::GetInstance();
  if (!registry.loaded()) {
    registry.LoadAll();
  }
  const size_t total = registry.extensions().size();
  if (total == 0) {
    return BlinkL(@"None installed");
  }
  size_t enabled = 0;
  for (const auto& extension : registry.extensions()) {
    if (extension->enabled) {
      ++enabled;
    }
  }
  if (enabled == total) {
    return [NSString stringWithFormat:BlinkL(@"%zu installed"), total];
  }
  return [NSString stringWithFormat:BlinkL(@"%zu installed, %zu off"), total,
                                    total - enabled];
}

- (void)showExtensionsMenu {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.literalRows = YES;
  vc.title = BlinkL(@"Extensions");
  vc.dismissOnSelect = NO;
  vc.headerNote = @"Extensions are experimental. Not every extension works "
                  @"properly and some may break the app. Recommended "
                  @"Extensions lists the ones that were tested and found "
                  @"stable.";
  [self populateExtensionsList:vc];
  [self presentList:vc];
}

// Заповнення окремо від показу, щоб вимкнення чи видалення оновлювало список на
// екрані замість нового поповера.
- (void)populateExtensionsList:(BlinkListVC*)vc {
  auto& registry = content::BlinkerWebExtensionRegistry::GetInstance();
  if (!registry.loaded()) {
    registry.LoadAll();
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  // Перші два рядки ведуть до нових розширень, далі встановлені.
  constexpr NSInteger kDiscoverRows = 2;
  vc.titles = [@[
    BlinkL(@"Recommended Extensions"), BlinkL(@"Chrome Web Store")
  ] mutableCopy];
  vc.subtitles = [@[
    BlinkL(@"Tested with Blinker Fluid"),
    BlinkL(@"Open an extension page and tap Add")
  ] mutableCopy];
  vc.imageNames = @[ @"star", @"puzzlepiece.extension" ];
  vc.sectionTitles = @[ @"DISCOVER", @"INSTALLED" ];
  vc.sectionStarts = @[ @0, @(kDiscoverRows) ];
  NSMutableArray<NSString*>* ids = [NSMutableArray array];
  NSMutableIndexSet* enabledRows = [NSMutableIndexSet indexSet];
  for (const auto& extension : registry.extensions()) {
    NSString* name = base::SysUTF8ToNSString(
        extension->name.empty() ? extension->id : extension->name);
    NSMutableArray<NSString*>* notes = [NSMutableArray array];
    if (!extension->version.empty()) {
      [notes addObject:[NSString stringWithFormat:@"v%@",
                                 base::SysUTF8ToNSString(extension->version)]];
    }
    [notes addObject:extension->enabled ? BlinkL(@"On") : BlinkL(@"Off")];
    // Значок, який розширення ставить на кнопку дії, видно лише тут.
    const std::string badge =
        content::BlinkerExtensionBadgeText(extension->id);
    if (!badge.empty()) {
      [notes addObject:[NSString stringWithFormat:BlinkL(@"badge %@"),
                                 base::SysUTF8ToNSString(badge)]];
    }
    if (!extension->unsupported_features.empty()) {
      [notes addObject:[NSString
                           stringWithFormat:BlinkL(@"%zu unsupported"),
                                            extension->unsupported_features
                                                .size()]];
    }
    [vc.titles addObject:name];
    [vc.subtitles addObject:[notes componentsJoinedByString:@", "]];
    [ids addObject:base::SysUTF8ToNSString(extension->id)];
    if (extension->enabled) {
      [enabledRows addIndex:vc.titles.count - 1];
    }
  }
  if (ids.count == 0) {
    [vc.titles addObject:BlinkL(@"No extensions installed")];
    [vc.subtitles
        addObject:BlinkL(@"Open a link to a .crx, or put an unpacked folder in "
                         @"Documents/BlinkerExtensions")];
    vc.checkedRows = nil;
    vc.disabledRows = [NSIndexSet indexSetWithIndex:kDiscoverRows];
  } else {
    vc.checkedRows = enabledRows;
    vc.disabledRows = nil;
  }
  vc.onSelect = ^(NSInteger row) {
    if (row == 0) {
      [weakSelf showRecommendedExtensions];
      return;
    }
    if (row == 1) {
      [weakSelf dismissViewControllerAnimated:YES
                                   completion:^{
                                     [weakSelf
                                         loadURLString:
                                             @"https://"
                                             @"chromewebstore.google.com/"];
                                   }];
      return;
    }
    const NSInteger index = row - kDiscoverRows;
    if (index >= 0 && index < (NSInteger)ids.count) {
      [weakSelf showExtensionDetail:ids[(NSUInteger)index]];
    }
  };
  [vc.tableView reloadData];
}

// Назад до списку розширень, перебудованого після зміни з екрана деталей.
- (void)popToRefreshedExtensionsList:(BlinkListVC*)detail {
  UINavigationController* nav = detail.navigationController;
  if (!nav) {
    [self showExtensionsMenu];
    return;
  }
  [nav popViewControllerAnimated:YES];
  UIViewController* top = nav.topViewController;
  if ([top isKindOfClass:[BlinkListVC class]]) {
    [self populateExtensionsList:(BlinkListVC*)top];
  }
}

- (void)showExtensionDetail:(NSString*)extensionId {
  auto& registry = content::BlinkerWebExtensionRegistry::GetInstance();
  const std::string id = base::SysNSStringToUTF8(extensionId);
  const content::BlinkerWebExtension* found = nullptr;
  for (const auto& extension : registry.extensions()) {
    if (extension->id == id) {
      found = extension.get();
      break;
    }
  }
  if (!found) {
    return;
  }
  NSString* popup = BlinkerExtensionURL(id, BlinkerPopupPath(*found));
  NSString* options = BlinkerExtensionURL(id, BlinkerOptionsPath(*found));
  const BOOL enabled = found->enabled;
  NSString* name = base::SysUTF8ToNSString(
      found->name.empty() ? found->id : found->name);
  __weak ContentShellWindowDelegate* weakSelf = self;
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  __weak BlinkListVC* weakDetail = vc;
  vc.title = name;
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSString*>* targets = [NSMutableArray array];  // "" це дія

  if (popup) {
    [vc.titles addObject:BlinkL(@"Open")];
    [vc.subtitles addObject:@"The extension's own panel"];
    [targets addObject:popup];
  } else if (found->manifest.FindDict("action") ||
             found->manifest.FindDict("browser_action")) {
    // Без попапу розширення саме обробляє натискання. Підпис береться з
    // setTitle() або default_title.
    std::string title_text = content::BlinkerExtensionActionTitle(id);
    if (title_text.empty()) {
      for (const char* key : {"action", "browser_action"}) {
        const base::DictValue* section = found->manifest.FindDict(key);
        const std::string* declared =
            section ? section->FindString("default_title") : nullptr;
        if (declared) {
          title_text = *declared;
          break;
        }
      }
    }
    NSString* title = base::SysUTF8ToNSString(title_text);
    [vc.titles addObject:BlinkL(@"Run")];
    [vc.subtitles addObject:title.length
                               ? title
                               : @"This extension acts when you open it"];
    [targets addObject:@"@"];
  }
  if (options) {
    [vc.titles addObject:BlinkL(@"Settings")];
    [vc.subtitles addObject:@"The extension's options page"];
    [targets addObject:options];
  }
  [vc.titles addObject:enabled ? BlinkL(@"Turn Off") : BlinkL(@"Turn On")];
  [vc.subtitles addObject:enabled
                             ? @"Stops its scripts and rules on every page"
                             : @"Runs its scripts and rules again"];
  [targets addObject:@""];
  [vc.titles addObject:BlinkL(@"Remove")];
  [vc.subtitles addObject:@"Deletes the extension's files"];
  [targets addObject:@"!"];
  vc.onSelect = ^(NSInteger row) {
    if (row >= (NSInteger)targets.count) {
      return;
    }
    NSString* target = targets[(NSUInteger)row];
    if ([target isEqualToString:@"-"]) {
      return;
    }
    if ([target isEqualToString:@""]) {
      content::BlinkerWebExtensionRegistry::GetInstance().SetEnabled(
          base::SysNSStringToUTF8(extensionId), !enabled);
      [weakSelf popToRefreshedExtensionsList:weakDetail];
      return;
    }
    if ([target isEqualToString:@"!"]) {
      [weakSelf confirmRemoveExtension:extensionId
                                 named:name
                                detail:weakDetail];
      return;
    }
    if ([target isEqualToString:@"@"]) {
      [weakSelf dismissExtensionScreensThen:^{
        [weakSelf runExtensionAction:extensionId];
      }];
      return;
    }
    [weakSelf dismissExtensionScreensThen:^{
      [weakSelf openExtensionPage:target];
    }];
  };
  [self presentList:vc];
}

// Попап і сторінка налаштувань відкриваються окремою вкладкою, щоб сторінка під
// ними лишалася і розширення її бачило.
- (void)openExtensionPage:(NSString*)urlString {
  GURL url(base::SysNSStringToUTF8(urlString));
  if (!url.is_valid() || !_shell || !_shell->web_contents()) {
    return;
  }
  // Якщо меню відкрили з іншого попапу, під ним лишається та сама вкладка.
  content::WebContents* over = _shell->web_contents();
  if (content::WebContents* under = content::BlinkerExtensionPageOpener(over)) {
    over = under;
  }
  content::BlinkerNoteExtensionPageOpened(url, over);
  content::Shell* opened = content::Shell::CreateNewWindow(
      over->GetBrowserContext(), url, nullptr, gfx::Size());
  if (opened) {
    // Розширення питає активну вкладку і шукає її серед усіх, тож попап мусить
    // знати, над якою він стоїть. Вкладка, до якої розширення звертається, має
    // бути саме та, що була на екрані, а не перша в списку.
    content::BlinkerSetExtensionPageOpener(opened->web_contents(), over);
    BlinkPresentShellWindow(opened);
  }
}

- (void)runExtensionAction:(NSString*)extensionId {
  content::BlinkerActivateExtensionAction(
      base::SysNSStringToUTF8(extensionId),
      _shell ? _shell->web_contents() : nullptr);
}

- (void)dismissExtensionScreensThen:(dispatch_block_t)action {
  UIViewController* presented = self.presentedViewController;
  if (!presented) {
    if (action) {
      action();
    }
    return;
  }
  // Над self можуть стояти і головне меню, і екран розширень, dismiss з self
  // закриває весь стек.
  [self dismissViewControllerAnimated:YES completion:action];
}

- (void)confirmRemoveExtension:(NSString*)extensionId
                         named:(NSString*)name
                        detail:(BlinkListVC*)detail {
  __weak ContentShellWindowDelegate* weakSelf = self;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:BlinkL(@"Remove %@?"), name]
                       message:BlinkL(@"Its files, and anything it stored, are "
                               @"deleted. This cannot be undone.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Remove")
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction* unused) {
                                 content::BlinkerRemoveExtension(
                                     base::SysNSStringToUTF8(extensionId));
                                 [weakSelf
                                     popToRefreshedExtensionsList:detail];
                               }]];
  UIViewController* presenter = self.presentedViewController ?: self;
  // UIAlertController з поповера на iPad теж хоче якір.
  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.sourceView = _menuButton;
    alert.popoverPresentationController.sourceRect = _menuButton.bounds;
  }
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)showGoogleAccountMenu {
  const BOOL privateSession =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = privateSession ? @"Private Google Account" : @"Google Account";
  vc.dismissOnSelect = NO;
  vc.titles = [@[
    @"Add Google Account", @"Switch Accounts", @"Manage Google Account",
    @"Sign out of Google"
  ] mutableCopy];
  vc.subtitles = [@[
    privateSession
        ? @"Sign in only for this private session"
        : @"Save the account in Blinker Fluid's normal browser session",
    @"Choose another signed in account",
    @"Security, personal info, and connected services",
    privateSession ? @"Sign out of this private session"
                   : @"Sign out of the normal browser session"
  ] mutableCopy];
  vc.imageNames = @[
    @"person.badge.plus", @"arrow.triangle.2.circlepath", @"person.crop.circle",
    @"rectangle.portrait.and.arrow.right"
  ];
  UIImage* avatar = [self googleProfileImage];
  UIImage* secondaryAvatar = [self googleSecondaryProfileImage];
  vc.rowImages = @[
    [NSNull null],
    BlinkSwitchAccountIcon(avatar, secondaryAvatar, BlinkerAccentColor())
        ?: [NSNull null],
    BlinkCircularMenuIcon(avatar) ?: [NSNull null], [NSNull null]
  ];
  vc.sectionTitles = @[ @"GOOGLE WEB SESSION" ];
  vc.sectionStarts = @[ @0 ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakVC = vc;
  vc.onSelect = ^(NSInteger row) {
    NSArray<NSString*>* urls = @[
      @"https://accounts.google.com/AddSession?continue=https%3A%2F%2Fmyaccount.google.com%2F",
      @"https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fmyaccount.google.com%2F",
      @"https://myaccount.google.com/", @"https://accounts.google.com/Logout"
    ];
    if (row == 3) {
      if (privateSession) {
        g_private_google_avatar = nil;
        g_private_google_secondary_avatar = nil;
        g_private_google_avatar_url = nil;
        g_private_google_secondary_avatar_url = nil;
        g_private_google_email = nil;
      } else {
        [[NSFileManager defaultManager] removeItemAtPath:BlinkGoogleAvatarPath()
                                                   error:nil];
        [[NSFileManager defaultManager]
            removeItemAtPath:BlinkGoogleSecondaryAvatarPath()
                       error:nil];
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:@"BlinkGoogleAccountEmail"];
        [defaults removeObjectForKey:@"BlinkGoogleAccountSeen"];
        [defaults removeObjectForKey:@"BlinkGoogleAvatarURL"];
        [defaults removeObjectForKey:@"BlinkGoogleSecondaryAvatarURL"];
      }
    }
    [weakVC.navigationController
        dismissViewControllerAnimated:YES
                           completion:^{
                             [weakSelf loadURLString:urls[row]];
                           }];
  };
  [self presentList:vc];
}

- (void)showPageZoomMenuThen:(void (^)(int))changed {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Page Zoom");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSArray<NSNumber*>* percentages =
      @[ @50, @67, @80, @90, @100, @110, @125, @150, @175, @200 ];
  int current = BlinkCurrentPageZoomPercent(_shell);
  NSInteger selectedRow = [percentages indexOfObject:@(current)];
  for (NSNumber* value in percentages) {
    [vc.titles addObject:[NSString stringWithFormat:@"%@%%", value]];
    [vc.subtitles addObject:@""];
  }
  if (selectedRow != NSNotFound) {
    vc.checkedRows = [NSIndexSet indexSetWithIndex:selectedRow];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakZoom = vc;
  void (^onChange)(int) = [changed copy];
  vc.onSelect = ^(NSInteger row) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_shell ||
        !strongSelf->_shell->web_contents() || row < 0 ||
        row >= static_cast<NSInteger>(percentages.count)) {
      return;
    }
    int percent = percentages[row].intValue;
    content::WebContents* contents = strongSelf->_shell->web_contents();
    const int old_percent = BlinkCurrentPageZoomPercent(strongSelf->_shell);
    if (NSString* key = BlinkZoomKey(strongSelf->_shell)) {
      [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:key];
    }
    content::BlinkSetPageZoom(contents, percent);
    content::BlinkerNotifyZoomChanged(contents, old_percent, percent);
    weakZoom.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakZoom.tableView reloadData];
    if (onChange) {
      onChange(percent);
    }
  };
  [self presentList:vc];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:
    (UIPresentationController*)controller {
  return UIModalPresentationNone;
}

- (void)showFindInPage {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  if (self.findBar) {
    [(BlinkFindBar*)self.findBar focus];
    return;
  }
  BlinkFindBar* bar =
      [[BlinkFindBar alloc] initWithWebContents:_shell->web_contents()];
  __weak ContentShellWindowDelegate* weakSelf = self;
  bar.onDone = ^{
    [weakSelf.findBar removeFromSuperview];
    weakSelf.findBar = nil;
  };
  [self.view addSubview:bar];
  // Нижній край вмісту йде за панеллю знизу, за клавіатурою і за режимами без
  // панелі, тож пошук завжди над ними.
  [NSLayoutConstraint activateConstraints:@[
    [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
  ]];
  self.findBar = bar;
  [bar focus];
}

- (void)shareCurrentLink {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  GURL visibleURL = _shell->web_contents()->GetVisibleURL();
  if (!visibleURL.is_valid() || visibleURL.SchemeIs("data")) {
    return;
  }
  NSString* value = base::SysUTF8ToNSString(visibleURL.spec());
  NSURL* url = [NSURL URLWithString:value];
  UIActivityViewController* share =
      [[UIActivityViewController alloc] initWithActivityItems:@[ url ?: value ]
                                        applicationActivities:nil];
  share.popoverPresentationController.sourceView = self.menuButton;
  share.popoverPresentationController.sourceRect = self.menuButton.bounds;
  [self presentViewController:share animated:YES completion:nil];
}

// Колір теми чи вигляд стартової змінились, тож перефарбовуєм панель і
// збираєм стартову сторінку наново.
- (void)refreshAppearance {
  [self updateBackground];
  _loadingProgressView.progressTintColor = BlinkerAccentColor();
  _pullSpinner.color = BlinkerAccentColor();
  if (_startPage) {
    const BOOL visible = !_startPage.hidden;
    [_startPage removeFromSuperview];
    _startPage = nil;
    if (visible) {
      [self showStartPage:YES];
    }
  }
}

- (void)updateBackground {
  UIColor* color = [_tracingHandler isTracing]
                       ? [ContentShellWindowDelegate backgroundColorTracing]
                       : [ContentShellWindowDelegate backgroundColorDefault];
  _toolbarBackgroundView.backgroundColor = color;
  _toolbarBackgroundView.layer.backgroundColor = color.CGColor;
  _toolbarContentView.backgroundColor = color;
  _toolbarContentView.layer.backgroundColor = color.CGColor;
  _toolbarPaintView.backgroundColor = color;
}

- (void)stopTracing {
  [_tracingHandler stop];
}

- (void)startTracingWithCategories:(const char*)categories {
  __weak ContentShellWindowDelegate* weakSelf = self;
  [_tracingHandler
      startWithHandler:^{
        [weakSelf updateBackground];
      }
      stopHandler:^{
        [weakSelf updateBackground];
      }
      categories:categories];
}

- (void)setURL:(NSString*)url {
  // Порожня вкладка показує стартову сторінку і пустий рядок адреси, справжня
  // сторінка ховає її і показує свій URL.
  BOOL isStartPage = (url.length == 0) || [url isEqualToString:@"about:blank"];
  [self showStartPage:isStartPage];
  NSString* savedName = isStartPage ? nil : BlinkSavedPageName(url);
  _urlField.text = isStartPage ? @"" : savedName ?: url;
  [self updateSiteButtons];
  if (!isStartPage) {
    [self maybeOfferWebStoreInstall:GURL(base::SysNSStringToUTF8(url))];
  }
  // Private сесія нічого не пише, бо список лежить у NSUserDefaults відкрито з
  // повними URL, включно з входом і OAuth.
  const BOOL isPrivate =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  if (!isPrivate && !isStartPage &&
      ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"])) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString*>* history =
        [[defaults stringArrayForKey:@"BlinkHistory"] mutableCopy]
            ?: [NSMutableArray array];
    if (![history.firstObject isEqualToString:url]) {
      [history insertObject:url atIndex:0];
      if (history.count > 500) {
        [history removeObjectsInRange:NSMakeRange(500, history.count - 500)];
      }
      [defaults setObject:history forKey:@"BlinkHistory"];
    }
  }
}

- (void)ensureStartPage {
  if (_startPage || !_contentView) {
    return;
  }
  _startPage = [[BlinkerStartPageView alloc] initWithFrame:_contentView.bounds];
  _startPage.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  __weak ContentShellWindowDelegate* weakSelf = self;
  _startPage.onNavigate = ^(NSString* input) {
    [weakSelf openUserInput:input];
  };
  [_contentView addSubview:_startPage];
}

- (void)showStartPage:(BOOL)show {
  [self ensureStartPage];
  _startPage.hidden = !show;
  if (show) {
    [_contentView bringSubviewToFront:_startPage];
  }
  // Скрипти розширень (Shimeji) малюють у порожній сторінці під екраном. Якщо
  // під екраном саме такий документ (Shell завантажує його з базовою адресою
  // стартової), екран стає прозорим, а сторінка під ним його кольору. Інакше
  // екран суцільний, як було, бо під ним порожньо.
  content::NavigationEntry* visible =
      _shell && _shell->web_contents()
          ? _shell->web_contents()->GetController().GetVisibleEntry()
          : nullptr;
  const BOOL seeThrough =
      show && visible && !visible->GetBaseURLForDataURL().is_empty();
  [_startPage setSeeThrough:seeThrough];
  if (_shell && _shell->web_contents()) {
    _shell->web_contents()->SetPageBaseBackgroundColor(
        seeThrough ? std::optional<SkColor>(SkColorSetRGB(14, 14, 16))
                   : std::nullopt);
  }
}

// Перехід за введеним, домен стає URL, решта йде в обраний пошуковик. Спільне
// для рядка адреси і Paste & Go.
- (void)openUserInput:(NSString*)nsInput {
  std::string fieldValue = base::SysNSStringToUTF8(nsInput);
  base::TrimWhitespaceASCII(fieldValue, base::TRIM_ALL, &fieldValue);
  if (fieldValue.empty()) {
    return;
  }
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkHTTPSFirst"] &&
      base::StartsWith(fieldValue, "http://",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    fieldValue.replace(0, 7, "https://");
  }
  GURL url(fieldValue);
  if (!url.has_scheme()) {
    bool looksLikeURL = fieldValue.find(' ') == std::string::npos &&
                        fieldValue.find('.') != std::string::npos;
    const std::string search = content::BlinkerSearchURLForQuery(fieldValue);
    url = looksLikeURL || search.empty() ? GURL("https://" + fieldValue)
                                         : GURL(search);
  }
  if (url.is_valid() && _shell) {
    _shell->LoadURL(url);
  }
}

// Дотик до рядка адреси виділяє його вміст, щоб введене замінило адресу.
// Наступним кроком циклу, бо UIKit ставить курсор після цього виклику.
- (void)textFieldDidBeginEditing:(UITextField*)field {
  if (field != _urlField || !field.text.length) {
    return;
  }
  __weak UITextField* weakField = field;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (weakField.isEditing) {
      [weakField selectAll:nil];
    }
  });
}

- (BOOL)textFieldShouldReturn:(UITextField*)field {
  [_urlField resignFirstResponder];
  [self openUserInput:field.text];
  return YES;
}

// Вставляє URL чи текст з іншого застосунку і відкриває. Безпечний шлях, який
// не чіпає ввід тексту в web (на iOS 15 він падає).
- (void)pasteAndGo {
  NSString* clipboard = [UIPasteboard generalPasteboard].string;
  if (clipboard.length) {
    [self openUserInput:clipboard];
  }
}

// Довге натискання на рядок адреси вибирає пошуковик.
- (void)showSearchEngineMenu:(UILongPressGestureRecognizer*)gesture {
  if (gesture.state != UIGestureRecognizerStateBegan) {
    return;
  }
  [self presentSearchEngineMenu];
}

- (void)presentSearchEngineMenu {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Search Engine");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  for (size_t i = 0; i < std::size(kSearchEngines); ++i) {
    [vc.titles
        addObject:[NSString stringWithUTF8String:kSearchEngines[i].name]];
    [vc.subtitles addObject:@""];
  }
  // Підказки шлють введене пошуковику, тому перемикач поруч з вибором
  // пошуковика. В private вони вимкнені завжди.
  const NSInteger suggestionsRow =
      static_cast<NSInteger>(std::size(kSearchEngines));
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  const BOOL suggestionsOn =
      [defaults boolForKey:@"BlinkSearchSuggestions"];
  [vc.titles addObject:@"Search Suggestions"];
  [vc.subtitles addObject:suggestionsOn ? @"On for the start page" : @"Off"];
  vc.sectionTitles = @[ BlinkL(@"Search Engine"), @"START PAGE" ];
  vc.sectionStarts = @[ @0, @(suggestionsRow) ];
  vc.checkedRows = [NSIndexSet indexSetWithIndex:g_search_engine];
  __weak BlinkListVC* weakChooser = vc;
  vc.onSelect = ^(NSInteger row) {
    if (row == suggestionsRow) {
      NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
      const BOOL wasOn = [d boolForKey:@"BlinkSearchSuggestions"];
      [d setBool:!wasOn forKey:@"BlinkSearchSuggestions"];
      [d synchronize];
      weakChooser.subtitles[row] = !wasOn ? @"On for the start page" : @"Off";
      [weakChooser.tableView reloadData];
      return;
    }
    if (row < 0 || row >= static_cast<NSInteger>(std::size(kSearchEngines))) {
      return;
    }
    g_search_engine = static_cast<int>(row);
    [[NSUserDefaults standardUserDefaults] setInteger:row
                                               forKey:@"BlinkSearchEngine"];
    weakChooser.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakChooser.tableView reloadData];
  };
  [self presentList:vc];
}

- (void)checkForUpdates {
  // Той самий нюанс NSURLSession, запит іде повз проксі, тож з Tor він
  // повідомив би GitHub напряму. Тому просто кажем про це.
  if (BlinkNativeNetworkingBlocked()) {
    UIAlertController* blocked = [UIAlertController
        alertControllerWithTitle:BlinkL(@"Check for Updates")
                         message:BlinkL(@"Update checks are unavailable in private "
                                 @"browsing or while a proxy is configured.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [blocked addAction:[UIAlertAction actionWithTitle:BlinkL(@"OK")
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
    [(self.presentedViewController ?: self) presentViewController:blocked
                                                         animated:YES
                                                       completion:nil];
    return;
  }
  NSString* installedVersion =
      [NSBundle.mainBundle
          objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
          ?: @"0";
  // Саме список релізів, а не /releases/latest, бо той не бачить prerelease, а
  // кожен реліз Blinker Fluid це prerelease, тож там 404.
  NSURL* endpoint =
      [NSURL URLWithString:@"https://api.github.com/repos/Nodesclock/"
                           @"Blinker-Fluid/releases?per_page=20"];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:endpoint];
  [request setValue:@"application/vnd.github+json"
      forHTTPHeaderField:@"Accept"];
  [request setValue:[@"Blinker-Fluid/" stringByAppendingString:installedVersion]
      forHTTPHeaderField:@"User-Agent"];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [[BlinkNativeSession()
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          id payload = data.length
                           ? [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:nil]
                           : nil;
          // Найновіші спершу, тож перший не draft і є релізом для оновлення.
          NSDictionary* release = nil;
          if ([payload isKindOfClass:NSArray.class]) {
            for (NSDictionary* candidate in (NSArray*)payload) {
              if ([candidate isKindOfClass:NSDictionary.class] &&
                  ![candidate[@"draft"] boolValue]) {
                release = candidate;
                break;
              }
            }
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            ContentShellWindowDelegate* strongSelf = weakSelf;
            if (!strongSelf) {
              return;
            }
            NSString* tag = [release[@"tag_name"] isKindOfClass:NSString.class]
                                ? release[@"tag_name"]
                                : nil;
            if (error || !tag.length) {
              UIAlertController* failed = [UIAlertController
                  alertControllerWithTitle:BlinkL(@"Couldn't Check for Updates")
                                   message:
                                       BlinkL(error ? @"GitHub could not be reached. "
                                               @"Check "
                                               @"your connection and try again."
                                             : @"No published release was "
                                               @"found on "
                                               @"GitHub.")
                            preferredStyle:UIAlertControllerStyleAlert];
              [failed addAction:[UIAlertAction
                                    actionWithTitle:BlinkL(@"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
              UIViewController* host =
                  strongSelf.presentedViewController ?: strongSelf;
              [host presentViewController:failed animated:YES completion:nil];
              return;
            }
            // Теги мають вигляд v.0.3. Відкидаємо все до першої цифри, бо
            // крапка попереду ховала б кожне оновлення при NSNumericSearch.
            NSRange firstDigit =
                [tag rangeOfCharacterFromSet:NSCharacterSet
                                                 .decimalDigitCharacterSet];
            NSString* normalized =
                firstDigit.location == NSNotFound
                    ? tag
                    : [tag substringFromIndex:firstDigit.location];
            BOOL newer =
                [normalized compare:installedVersion
                            options:NSNumericSearch] == NSOrderedDescending;
            NSString* notes = [release[@"body"] isKindOfClass:NSString.class]
                                  ? release[@"body"]
                                  : BlinkL(@"No changelog was supplied.");
            if (notes.length > 8000) {
              notes = [notes substringToIndex:8000];
            }
            NSArray* assets = [release[@"assets"] isKindOfClass:NSArray.class]
                                  ? release[@"assets"]
                                  : nil;
            NSArray<NSString*>* bundleParts =
                [NSBundle.mainBundle.bundleIdentifier
                    componentsSeparatedByString:@"."];
            const bool wantsJIT = [bundleParts containsObject:@"jit"];
            content::BlinkerBuildVariant variant =
                content::BlinkerBuildVariant::kMain;
#if defined(BLINKER_LEGACY_LOW_MEMORY)
            variant = [bundleParts containsObject:@"ios12"] ||
                              [bundleParts containsObject:@"ios11"]
                          ? content::BlinkerBuildVariant::kLegacyIOS
                          : content::BlinkerBuildVariant::kSideload;
#endif
            std::vector<std::string> names;
            NSMutableArray<NSString*>* links = [NSMutableArray array];
            for (NSDictionary* asset in assets) {
              NSString* link = asset[@"browser_download_url"];
              if (![link isKindOfClass:NSString.class]) {
                continue;
              }
              NSString* name = [asset[@"name"] isKindOfClass:NSString.class]
                                   ? asset[@"name"]
                                   : link.lastPathComponent;
              names.push_back(base::SysNSStringToUTF8(name.lowercaseString));
              [links addObject:link];
            }
            const int picked =
                content::BlinkerPickUpdateAsset(names, wantsJIT, variant);
            NSString* ipaURL = picked < 0 ? nil : links[picked];
            NSString* title =
                newer ? [NSString stringWithFormat:BlinkL(@"Update %@"), tag]
                      : BlinkL(@"Blinker Fluid is Up to Date");
            // Схема встановлення є лише там, де є TrollStore, тож питаємо
            // систему.
            const BOOL trollStoreAvailable = [[UIApplication sharedApplication]
                canOpenURL:[NSURL URLWithString:@"apple-magnifier://"]];
            NSString* primaryTitle = nil;
            dispatch_block_t primary = nil;
            if (newer && ipaURL.length && !trollStoreAvailable) {
              primaryTitle = BlinkL(@"Download Update");
              primary = ^{
                // Через свої загрузки, щоб поставити вручну.
                BLINKER_DIAG("UPDATE: downloading in-app");
                [weakSelf loadURLString:ipaURL];
              };
            } else if (newer && ipaURL.length && trollStoreAvailable) {
              primaryTitle = BlinkL(@"Update with TrollStore");
              primary = ^{
                NSMutableCharacterSet* allowed =
                    [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
                [allowed removeCharactersInString:@"&=?#"];
                NSString* encoded = [ipaURL
                    stringByAddingPercentEncodingWithAllowedCharacters:allowed];
                NSURL* install = [NSURL
                    URLWithString:[@"apple-magnifier://install?url="
                                      stringByAppendingString:encoded]];
                [[UIApplication sharedApplication]
                              openURL:install
                              options:@{}
                    completionHandler:^(BOOL success) {
                      if (!success) {
                        // Встановлення не вдалося, тож завантажуємо файл у
                        // застосунку.
                        BLINKER_DIAG(
                            "UPDATE: TrollStore install refused, downloading");
                        [weakSelf loadURLString:ipaURL];
                      }
                    }];
              };
            }
            BlinkUpdateSheetVC* sheet = [[BlinkUpdateSheetVC alloc] init];
            sheet.headline = title;
            sheet.installedVersion = installedVersion;
            sheet.latestVersion = tag;
            sheet.notes = notes;
            sheet.primaryTitle = primaryTitle;
            sheet.primaryAction = primary;
            UINavigationController* nav = [[UINavigationController alloc]
                initWithRootViewController:sheet];
            UIViewController* host =
                strongSelf.presentedViewController ?: strongSelf;
            [host presentViewController:nav animated:YES completion:nil];
          });
        }] resume];
}

// Визначено нижче, біля меню рушія JavaScript.
static NSString* BlinkJITTierTitle(NSInteger tier);
static NSInteger BlinkCurrentJITTier(void);
static NSInteger BlinkEffectiveJITTier(void);

// Фільтр реклами і трекерів (blinker_content_filter.cc).
extern "C" bool BlinkAdBlockEnabled(void);
extern "C" void BlinkAdBlockSetEnabled(bool enabled);
extern "C" unsigned long long BlinkAdBlockBlockedCount(void);
extern "C" unsigned long BlinkAdBlockRuleCount(void);

static NSString* BlinkAdBlockSubtitle(void) {
  if (!BlinkAdBlockEnabled()) {
    return @"Off";
  }
  unsigned long long blocked = BlinkAdBlockBlockedCount();
  if (blocked == 0) {
    return @"On";
  }
  return [NSString stringWithFormat:BlinkL(@"On, %llu blocked"), blocked];
}

struct BlinkLanguageOption {
  __unsafe_unretained NSString* name;
  __unsafe_unretained NSString* accept;
};

static const BlinkLanguageOption kBlinkLanguages[] = {
    {@"English", @"en-US,en"},       {@"Spanish", @"es-ES,es,en"},
    {@"Chinese", @"zh-CN,zh,en"},    {@"Russian", @"ru-RU,ru,en"},
    {@"Ukrainian", @"uk-UA,uk,en"},  {@"Polish", @"pl-PL,pl,en"},
    {@"Czech", @"cs-CZ,cs,en"},      {@"German", @"de-DE,de,en"},
    {@"Japanese", @"ja-JP,ja,en"},   {@"Korean", @"ko-KR,ko,en"},
    {@"Vietnamese", @"vi-VN,vi,en"}, {@"Turkish", @"tr-TR,tr,en"},
    {@"French", @"fr-FR,fr,en"},     {@"Swedish", @"sv-SE,sv,en"},
    {@"Arabic", @"ar-SA,ar,en"},
};

static NSString* BlinkLanguageName(void) {
  NSString* selected = [[NSUserDefaults standardUserDefaults]
                           stringForKey:@"BlinkLanguageAccept"]
                           ?: @"en-US,en";
  NSString* localeID =
      [[selected componentsSeparatedByString:@","] firstObject];
  NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:localeID];
  for (const BlinkLanguageOption& option : kBlinkLanguages) {
    if ([selected isEqualToString:option.accept]) {
      NSString* languageCode =
          [[[option.accept componentsSeparatedByString:@","] firstObject]
              componentsSeparatedByString:@"-"]
              .firstObject;
      return ([locale localizedStringForLanguageCode:languageCode]
                  ?: option.name)
          .capitalizedString;
    }
  }
  return @"English";
}

// Глобальні налаштування браузера.
static int BlinkCurrentIdentity() {
  return content::BlinkUserAgentIdentity();
}

static NSString* BlinkIdentityTitle(int identity) {
  switch (identity) {
    case content::kBlinkIdentitySafariIOS:
      return @"Safari (iOS)";
    case content::kBlinkIdentityChromeIOS:
      return @"Chrome (iOS)";
    default:
      return @"Chrome (Android)";
  }
}

// Android мальований, бо серед системних символів його нема.
static UIImage* BlinkAndroidGlyph() {
  const CGSize size = CGSizeMake(28, 28);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [UIColor.blackColor set];
  UIBezierPath* head = [UIBezierPath bezierPath];
  [head moveToPoint:CGPointMake(4, 21)];
  [head addArcWithCenter:CGPointMake(14, 21)
                  radius:10
              startAngle:M_PI
                endAngle:0
               clockwise:YES];
  [head closePath];
  [head fill];
  UIBezierPath* antennae = [UIBezierPath bezierPath];
  antennae.lineWidth = 1.6;
  antennae.lineCapStyle = kCGLineCapRound;
  [antennae moveToPoint:CGPointMake(8.4, 13.2)];
  [antennae addLineToPoint:CGPointMake(6.2, 9.2)];
  [antennae moveToPoint:CGPointMake(19.6, 13.2)];
  [antennae addLineToPoint:CGPointMake(21.8, 9.2)];
  [antennae stroke];
  CGContextSetBlendMode(UIGraphicsGetCurrentContext(), kCGBlendModeClear);
  [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(8.6, 15.4, 2.4, 2.4)]
      fill];
  [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(17, 15.4, 2.4, 2.4)] fill];
  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Знак того, ким браузер представляється сайтам.
static UIImage* BlinkIdentityIcon(int identity) {
  switch (identity) {
    case content::kBlinkIdentitySafariIOS:
      return BlinkSystemImage(@"applelogo");
    case content::kBlinkIdentityChromeIOS: {
      // Знак Chromium зберігає свої кольори, а не береться шаблоном під колір
      // теми. Тонке світле коло, щоб він не зливався з темним списком.
      UIImage* logo = [UIImage imageNamed:@"chromium_logo"];
      if (!logo) {
        return BlinkSystemImage(@"globe");
      }
      const CGSize canvas = CGSizeMake(28, 28);
      UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
      const CGRect disc = CGRectMake(3, 3, 22, 22);
      [logo drawInRect:disc];
      UIBezierPath* ring =
          [UIBezierPath bezierPathWithOvalInRect:CGRectInset(disc, -0.75, -0.75)];
      ring.lineWidth = 1.5;
      [[UIColor colorWithWhite:0.85 alpha:1.0] setStroke];
      [ring stroke];
      UIImage* badge = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      return [badge imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    default:
      return BlinkAndroidGlyph();
  }
}

// Значок Secure DNS: глобус із замочком. Системний network має криві меридіани,
// а звичайний globe уже стоїть біля мов. Малюється шаблоном, тож бере колір теми.
static UIImage* BlinkSecureDnsIcon() {
  // Поле шире за малюнок, щоб текст рядка став на одну лінію з іншими значками.
  const CGSize canvas = CGSizeMake(25, 22);
  UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextTranslateCTM(ctx, 1.5, 0);
  const CGPoint center = CGPointMake(9.75, 9.75);
  const CGFloat radius = 8.25;
  CGContextSetLineCap(ctx, kCGLineCapRound);
  CGContextSetLineJoin(ctx, kCGLineJoinRound);
  CGContextSetRGBStrokeColor(ctx, 0, 0, 0, 1);
  CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
  CGContextSetLineWidth(ctx, 1.5);

  // Коло, один меридіан, екватор і дві паралелі, усе симетрично.
  CGContextStrokeEllipseInRect(
      ctx, CGRectMake(center.x - radius, center.y - radius, 2 * radius,
                      2 * radius));
  CGContextStrokeEllipseInRect(
      ctx, CGRectMake(center.x - 3.6, center.y - radius, 7.2, 2 * radius));
  CGContextMoveToPoint(ctx, center.x - radius, center.y);
  CGContextAddLineToPoint(ctx, center.x + radius, center.y);
  const CGFloat parallel = 4.6;
  const CGFloat half = std::sqrt(radius * radius - parallel * parallel);
  CGContextMoveToPoint(ctx, center.x - half, center.y - parallel);
  CGContextAddLineToPoint(ctx, center.x + half, center.y - parallel);
  CGContextMoveToPoint(ctx, center.x - half, center.y + parallel);
  CGContextAddLineToPoint(ctx, center.x + half, center.y + parallel);
  CGContextStrokePath(ctx);

  // Замочок у нижньому правому куті, навколо нього виїмка в глобусі.
  const CGRect body = CGRectMake(12.8, 14.8, 8.4, 6.6);
  CGContextSaveGState(ctx);
  CGContextSetBlendMode(ctx, kCGBlendModeClear);
  [[UIBezierPath
      bezierPathWithRoundedRect:CGRectMake(body.origin.x - 2.0,
                                           body.origin.y - 4.9,
                                           body.size.width + 4.0,
                                           body.size.height + 6.9)
                   cornerRadius:3.6] fill];
  CGContextRestoreGState(ctx);
  [[UIBezierPath bezierPathWithRoundedRect:body cornerRadius:1.6] fill];
  CGContextSetLineWidth(ctx, 1.4);
  CGContextAddArc(ctx, CGRectGetMidX(body), body.origin.y, 2.3, M_PI, 0, 0);
  CGContextStrokePath(ctx);

  UIImage* image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  if (@available(iOS 13.0, *)) {
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  }
  // На iOS 12 комірка ставить текст одразу за значком, а решту значків
  // BlinkSystemImage кладе в поле 28 на 28, тож і цей кладемо так само.
  UIGraphicsBeginImageContextWithOptions(CGSizeMake(28, 28), NO, 0);
  [image drawInRect:CGRectMake((28 - image.size.width) / 2,
                               (28 - image.size.height) / 2, image.size.width,
                               image.size.height)];
  UIImage* centered = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [centered imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

typedef NS_ENUM(NSInteger, BlinkSettingsRow) {
  BlinkSettingsRowSearchEngine,
  BlinkSettingsRowAppearance,
  BlinkSettingsRowToolbar,
  BlinkSettingsRowLanguages,
  BlinkSettingsRowIdentity,
  BlinkSettingsRowCustomize,
  BlinkSettingsRowPrivateBrowsing,
  BlinkSettingsRowAdBlock,
  BlinkSettingsRowProxy,
  BlinkSettingsRowSecureDNS,
  BlinkSettingsRowAppLock,
  BlinkSettingsRowHTTPSFirst,
  BlinkSettingsRowPopups,
  BlinkSettingsRowPrivacyOptions,
  BlinkSettingsRowPermissions,
  BlinkSettingsRowClearData,
  BlinkSettingsRowHistory,
  BlinkSettingsRowImportExport,
  BlinkSettingsRowJavaScript,
  BlinkSettingsRowMemorySaver,
  BlinkSettingsRowAbout,
  BlinkSettingsRowTextSelection,
};

- (void)showSettings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Settings");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  BOOL bottom = [d boolForKey:@"BlinkToolbarBottom"];
  UIUserInterfaceStyle st = UIUserInterfaceStyleUnspecified;
  if (@available(iOS 13.0, *)) {
    st = self.view.window.overrideUserInterfaceStyle;
  }
  NSString* theme = st == UIUserInterfaceStyleDark
                        ? BlinkL(@"Dark")
                        : (st == UIUserInterfaceStyleLight ? BlinkL(@"Light")
                                                           : BlinkL(@"System"));
  [vc.titles addObject:BlinkL(@"Search Engine")];
  [vc.subtitles
      addObject:[NSString
                    stringWithUTF8String:kSearchEngines[g_search_engine].name]];
  [vc.titles addObject:BlinkL(@"Appearance")];
  [vc.subtitles addObject:theme];
  [vc.titles addObject:BlinkL(@"Toolbar Position")];
  [vc.subtitles addObject:bottom ? BlinkL(@"Bottom") : BlinkL(@"Top")];
  [vc.titles addObject:BlinkL(@"Languages")];
  [vc.subtitles addObject:BlinkLanguageName()];
  [vc.titles addObject:BlinkL(@"Browser Identity")];
  [vc.subtitles addObject:BlinkIdentityTitle(BlinkCurrentIdentity())];
  [vc.titles addObject:BlinkL(@"Customize")];
  [vc.subtitles addObject:BlinkThemeColorName()];
  [vc.titles addObject:BlinkL(@"Private Browsing")];
  BOOL privateRequested = [d boolForKey:@"BlinkPrivateBrowsing"];
  BOOL privateActive =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  NSString* privateState = privateRequested ? BlinkL(@"On") : BlinkL(@"Off");
  if (privateRequested != privateActive) {
    privateState = [NSString
        stringWithFormat:@"%@, %@", privateState, BlinkL(@"Restart required")];
  }
  [vc.subtitles addObject:privateState];
  [vc.titles addObject:BlinkL(@"Ad & Tracker Blocking")];
  [vc.subtitles addObject:BlinkAdBlockSubtitle()];
  NSString* proxy = [d stringForKey:@"BlinkProxy"];
  [vc.titles addObject:BlinkL(@"Tor and Proxy")];
  [vc.subtitles addObject:proxy.length ? proxy : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"Secure DNS")];
  [vc.subtitles addObject:BlinkSecureDnsSubtitle()];
  [vc.titles addObject:BlinkL(@"Password and Face ID Lock")];
  [vc.subtitles addObject:[d boolForKey:@"BlinkAppLock"] ? BlinkL(@"On")
                                                         : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"HTTPS First Navigation")];
  [vc.subtitles addObject:[d boolForKey:@"BlinkHTTPSFirst"] ? BlinkL(@"On")
                                                            : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"Block Popups")];
  [vc.subtitles addObject:BlinkPopupSettingsSubtitle()];
  [vc.titles addObject:BlinkL(@"Privacy Options")];
  [vc.subtitles addObject:BlinkPrivacyOptionsSubtitle()];
  [vc.titles addObject:BlinkL(@"Website Permissions")];
  [vc.subtitles addObject:@"Location, camera and microphone"];
  [vc.titles addObject:BlinkL(@"Clear Browsing Data")];
  [vc.subtitles addObject:@"History and website data"];
  [vc.titles addObject:BlinkL(@"History")];
  [vc.subtitles addObject:@"Recently visited pages"];
  [vc.titles addObject:BlinkL(@"Import and Export")];
  [vc.subtitles addObject:@"Bookmarks, history and extensions"];
  [vc.titles addObject:BlinkL(@"JavaScript Engine")];
  [vc.subtitles addObject:BlinkJITTierTitle(BlinkEffectiveJITTier())];
  [vc.titles addObject:BlinkL(@"Memory Saver")];
  [vc.subtitles addObject:BlinkMemorySaverTitle(BlinkMemorySaverLevel())];
  [vc.titles addObject:BlinkL(@"About Blinker Fluid")];
  [vc.subtitles addObject:@"Version, source and developer"];
  [vc.titles addObject:@"Selection Color"];
  [vc.subtitles addObject:BlinkSelectionColorName()];
  vc.imageNames = @[
    @"magnifyingglass", @"circle.lefthalf.filled",
    @"rectangle.bottomthird.inset.filled", @"globe", @"person.text.rectangle",
    @"paintbrush", @"eye.slash", @"hand.raised.slash", @"lock.shield",
    @"network", @"lock.fill", @"checkmark.shield", @"macwindow.badge.plus",
    @"shield.lefthalf.fill", @"hand.raised", @"trash",
    @"clock.arrow.circlepath", @"square.and.arrow.down", @"bolt.fill",
    @"memorychip", @"info.circle", @"text.cursor"
  ];
  NSMutableArray* titleColors = [NSMutableArray array];
  NSMutableArray* rowImages = [NSMutableArray array];
  for (NSUInteger row = 0; row < vc.titles.count; ++row) {
    id color = [NSNull null];
    if (row == BlinkSettingsRowProxy) {
      color = BlinkerTorColor();
    } else if (row == BlinkSettingsRowCustomize && privateActive) {
      color = [UIColor colorWithWhite:0.45 alpha:1.0];
    }
    [titleColors addObject:color];
    id image = [NSNull null];
    if (row == BlinkSettingsRowIdentity) {
      image = BlinkIdentityIcon(BlinkCurrentIdentity());
    } else if (row == BlinkSettingsRowSecureDNS) {
      image = BlinkSecureDnsIcon();
    }
    [rowImages addObject:image ?: [NSNull null]];
  }
  vc.titleColors = titleColors;
  vc.rowImages = rowImages;
  // У private тема завжди графітова, тож вибір кольорів там нічого б не міняв.
  if (privateActive) {
    vc.disabledRows = [NSIndexSet indexSetWithIndex:BlinkSettingsRowCustomize];
    vc.subtitles[BlinkSettingsRowCustomize] =
        @"Not available in Private Browsing";
  }
  vc.sectionTitles = @[
    BlinkL(@"GENERAL"), BlinkL(@"PRIVACY"), BlinkL(@"PERFORMANCE"),
    BlinkL(@"ABOUT"), @"TEXT"
  ];
  vc.sectionStarts = @[
    @(BlinkSettingsRowSearchEngine), @(BlinkSettingsRowPrivateBrowsing),
    @(BlinkSettingsRowJavaScript), @(BlinkSettingsRowAbout),
    @(BlinkSettingsRowTextSelection)
  ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakSettings = vc;
  vc.onSelect = ^(NSInteger i) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    switch (static_cast<BlinkSettingsRow>(i)) {
      case BlinkSettingsRowSearchEngine:
        [weakSelf presentSearchEngineMenu];
        break;
      case BlinkSettingsRowAppearance:
        [weakSelf showAppearanceMenu];
        break;
      case BlinkSettingsRowToolbar: {
        [weakSelf toggleToolbarPosition];
        BOOL nowBottom = [defaults boolForKey:@"BlinkToolbarBottom"];
        weakSettings.subtitles[BlinkSettingsRowToolbar] =
            nowBottom ? BlinkL(@"Bottom") : BlinkL(@"Top");
        [weakSettings.tableView reloadData];
        break;
      }
      case BlinkSettingsRowLanguages:
        [weakSelf showLanguageMenu];
        break;
      case BlinkSettingsRowIdentity:
        [weakSelf showIdentityMenu:weakSettings];
        break;
      case BlinkSettingsRowCustomize:
        if (!BlinkPrivateSession()) {
          [weakSelf showCustomize:weakSettings];
        }
        break;
      case BlinkSettingsRowPrivateBrowsing: {
        BOOL enabled = ![defaults boolForKey:@"BlinkPrivateBrowsing"];
        [defaults setBool:enabled forKey:@"BlinkPrivateBrowsing"];
        [defaults synchronize];
        weakSettings.subtitles[BlinkSettingsRowPrivateBrowsing] = [NSString
            stringWithFormat:@"%@, %@",
                             enabled ? BlinkL(@"On") : BlinkL(@"Off"),
                             BlinkL(@"Restart required")];
        [weakSettings.tableView reloadData];
        break;
      }
      case BlinkSettingsRowAdBlock:
        [weakSelf showAdBlockSettings];
        break;
      case BlinkSettingsRowProxy:
        [weakSelf showProxySettings];
        break;
      case BlinkSettingsRowSecureDNS:
        [weakSelf showSecureDNS:weakSettings];
        break;
      case BlinkSettingsRowImportExport:
        [weakSelf showImportExport];
        break;
      case BlinkSettingsRowAppLock:
        [weakSelf toggleAppLockFromSettings:weakSettings];
        break;
      case BlinkSettingsRowHTTPSFirst: {
        BOOL enabled = ![defaults boolForKey:@"BlinkHTTPSFirst"];
        [defaults setBool:enabled forKey:@"BlinkHTTPSFirst"];
        weakSettings.subtitles[BlinkSettingsRowHTTPSFirst] =
            enabled ? BlinkL(@"On") : BlinkL(@"Off");
        [weakSettings.tableView reloadData];
        break;
      }
      case BlinkSettingsRowPopups:
        [weakSelf showPopupSettings:weakSettings];
        break;
      case BlinkSettingsRowPrivacyOptions:
        [weakSelf showPrivacyOptions:weakSettings];
        break;
      case BlinkSettingsRowPermissions:
        [weakSelf showWebsitePermissions];
        break;
      case BlinkSettingsRowClearData:
        [weakSelf showClearBrowsingData];
        break;
      case BlinkSettingsRowHistory:
        [weakSelf showHistory];
        break;
      case BlinkSettingsRowJavaScript:
        [weakSelf showJavaScriptEngineMenu:weakSettings];
        break;
      case BlinkSettingsRowMemorySaver:
        [weakSelf showMemorySaver:weakSettings];
        break;
      case BlinkSettingsRowAbout:
        [weakSelf showAbout];
        break;
      case BlinkSettingsRowTextSelection:
        [weakSelf showSelectionColor:weakSettings];
        break;
    }
  };
  [self presentList:vc];
}

// Замок і звук зліва в рядку адреси.
- (void)updateSiteButtons {
  if (!_urlField || !_siteButtonsView) {
    return;
  }
  content::WebContents* contents = _shell ? _shell->web_contents() : nullptr;
  const GURL url = contents ? contents->GetLastCommittedURL() : GURL();
  const BOOL saved = content::BlinkerIsSavedPageURL(url);
  const BOOL web = url.SchemeIsHTTPOrHTTPS() || saved;
  const BOOL muted = contents && contents->IsAudioMuted();
  const BOOL audio = contents && (muted || contents->IsCurrentlyAudible());
  if (!web && !audio) {
    _urlField.leftViewMode = UITextFieldViewModeNever;
    return;
  }
  NSString* lock = saved ? @"arrow.down.doc" : @"lock.fill";
  _siteButton.accessibilityLabel =
      saved ? BlinkL(@"Saved Page") : BlinkL(@"Site Settings");
  if (web && !saved) {
    content::NavigationEntry* entry =
        contents->GetController().GetLastCommittedEntry();
    const bool cert_error =
        entry && net::IsCertStatusError(entry->GetSSL().cert_status);
    if (entry && entry->GetPageType() == content::PAGE_TYPE_ERROR) {
      lock = @"info.circle";
    } else if (!url.SchemeIs("https") || cert_error) {
      lock = @"exclamationmark.triangle.fill";
    }
  }
  [_siteButton setImage:BlinkSystemImage(lock) forState:UIControlStateNormal];
  [_audioButton
      setImage:BlinkSystemImage(muted ? @"speaker.slash.fill"
                                      : @"speaker.wave.2.fill")
      forState:UIControlStateNormal];
  _audioButton.accessibilityLabel =
      muted ? BlinkL(@"Unmute Tab") : BlinkL(@"Mute Tab");
  CGFloat x = 4;
  _siteButton.hidden = !web;
  _audioButton.hidden = !audio;
  if (web) {
    _siteButton.frame = CGRectMake(x, 0, 28, 30);
    x += 28;
  }
  if (audio) {
    _audioButton.frame = CGRectMake(x, 0, 28, 30);
    x += 28;
  }
  _siteButtonsView.frame = CGRectMake(0, 0, x + 2, 30);
  _urlField.leftView = _siteButtonsView;
  _urlField.leftViewMode = UITextFieldViewModeUnlessEditing;
}

- (void)toggleTabMute {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  content::WebContents* contents = _shell->web_contents();
  contents->SetAudioMuted(!contents->IsAudioMuted());
  [self updateSiteButtons];
}

// Налаштування поточного сайту з рядка адреси чи меню.
- (void)fillSiteSettings:(BlinkListVC*)vc url:(const GURL&)url {
  if (!vc || !_shell || !_shell->web_contents()) {
    return;
  }
  content::WebContents* contents = _shell->web_contents();
  NSString* host = base::SysUTF8ToNSString(url.host());
  content::NavigationEntry* entry =
      contents->GetController().GetLastCommittedEntry();
  const bool cert_error =
      entry && net::IsCertStatusError(entry->GetSSL().cert_status);
  NSString* connection = @"Connection is secure";
  NSString* connectionDetail = @"What you send to this site stays private";
  NSString* connectionIcon = @"lock.fill";
  if (entry && entry->GetPageType() == content::PAGE_TYPE_ERROR) {
    connection = @"This page couldn't load";
    connectionDetail = @"Something went wrong while loading it.";
    connectionIcon = @"info.circle";
  } else if (cert_error) {
    connection = @"Certificate problem";
    connectionDetail = @"This site's certificate isn't trusted";
    connectionIcon = @"exclamationmark.triangle.fill";
  } else if (!url.SchemeIs("https")) {
    connection = @"Connection is not secure";
    connectionDetail = @"Don't enter passwords or payment details here";
    connectionIcon = @"exclamationmark.triangle.fill";
  }
  auto& filter = content::BlinkerContentFilter::GetInstance();
  NSString* adState = BlinkL(@"Off");
  if (filter.enabled()) {
    adState = filter.IsHostAllowlisted(url.host())
                  ? BlinkL(@"Off for this site")
                  : [NSString stringWithFormat:BlinkL(@"On, %llu blocked"),
                                               (unsigned long long)
                                                   filter.blocked_count_for_host(
                                                       url.host())];
  }
  const BOOL popupsAllowed = !BlinkShouldBlockPopupFromHost(std::string(url.host()).c_str());
  NSString* sound = contents->IsAudioMuted()
                        ? BlinkL(@"Muted")
                        : (contents->IsCurrentlyAudible()
                               ? BlinkL(@"Playing audio")
                               : BlinkL(@"On"));
  vc.titles = [@[
    connection, @"Desktop Site", @"Ad & Tracker Blocking", @"Popups",
    @"Page Zoom", @"Keep Tab Awake", @"Sound", @"Clear Cookies and Site Data"
  ] mutableCopy];
  vc.subtitles = [@[
    connectionDetail,
    content::BlinkIsDesktopSite(contents) ? BlinkL(@"On") : BlinkL(@"Off"),
    adState,
    popupsAllowed ? BlinkL(@"Allowed") : BlinkL(@"Blocked"),
    [NSString stringWithFormat:@"%d%%", BlinkCurrentPageZoomPercent(_shell)],
    BlinkHostStaysActive(host) ? BlinkL(@"On, never sleeps")
                               : BlinkL(@"Off"),
    sound, @"Signs you out of this site"
  ] mutableCopy];
  vc.imageNames = @[
    connectionIcon, @"desktopcomputer", @"hand.raised.slash",
    @"macwindow.badge.plus", @"textformat.size", @"memorychip",
    contents->IsAudioMuted() ? @"speaker.slash.fill" : @"speaker.wave.2.fill",
    @"trash"
  ];
  NSMutableIndexSet* disabled =
      [NSMutableIndexSet indexSetWithIndex:BlinkSiteRowConnection];
  if (!BlinkBlockPopupsEnabled()) {
    [disabled addIndex:BlinkSiteRowPopups];
  }
  vc.disabledRows = disabled;
  NSMutableArray* colors = [NSMutableArray array];
  for (NSUInteger i = 0; i < vc.titles.count; ++i) {
    [colors addObject:i == BlinkSiteRowClearData
                          ? static_cast<id>(UIColor.systemRedColor)
                          : static_cast<id>([NSNull null])];
  }
  vc.titleColors = colors;
  vc.sectionTitles = @[ @"CONNECTION", @"THIS SITE", @"DATA" ];
  vc.sectionStarts = @[
    @(BlinkSiteRowConnection), @(BlinkSiteRowDesktop), @(BlinkSiteRowClearData)
  ];
  // До показу таблицю не чіпаєм, інакше вид вантажиться без навігації і
  // кнопки Done на iOS 12 нема.
  if (vc.isViewLoaded) {
    [vc.tableView reloadData];
  }
}

// Збережена копія. Справжню адресу Blink пише в заголовок MHTML.
- (void)showSavedPageInfo:(const GURL&)url {
  GURL original;
  base::FilePath path;
  if (net::FileURLToFilePath(url, &path)) {
    NSFileHandle* file = [NSFileHandle
        fileHandleForReadingAtPath:base::SysUTF8ToNSString(path.value())];
    NSData* head = [file readDataOfLength:16384];
    [file closeFile];
    NSString* text =
        head ? [[NSString alloc] initWithData:head
                                     encoding:NSISOLatin1StringEncoding]
             : nil;
    for (NSString* raw in [text componentsSeparatedByString:@"\n"]) {
      NSString* line = [raw
          stringByTrimmingCharactersInSet:NSCharacterSet
                                              .whitespaceAndNewlineCharacterSet];
      if (!line.length) {
        break;
      }
      if ([line hasPrefix:@"Snapshot-Content-Location:"]) {
        original = GURL(base::SysNSStringToUTF8([[line
            substringFromIndex:26]
            stringByTrimmingCharactersInSet:NSCharacterSet
                                                .whitespaceCharacterSet]));
        break;
      }
    }
  }
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Saved Page")
                       message:BlinkL(@"This copy is saved on this device and "
                                      @"opens without a connection.")
                preferredStyle:UIAlertControllerStyleAlert];
  if (original.SchemeIsHTTPOrHTTPS()) {
    __weak ContentShellWindowDelegate* weakSelf = self;
    NSString* spec = base::SysUTF8ToNSString(original.spec());
    [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Open Original")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              [weakSelf loadURLString:spec];
                                            }]];
  }
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"OK")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self tintMenu:alert color:BlinkLabelColor()];
  [BlinkTopViewController(self) presentViewController:alert
                                             animated:YES
                                           completion:nil];
}

- (void)showSiteSettings {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  const GURL url = _shell->web_contents()->GetLastCommittedURL();
  if (content::BlinkerIsSavedPageURL(url)) {
    [self showSavedPageInfo:url];
    return;
  }
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = base::SysUTF8ToNSString(url.host());
  vc.dismissOnSelect = NO;
  [self fillSiteSettings:vc url:url];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakList = vc;
  NSString* host = base::SysUTF8ToNSString(url.host());
  vc.onSelect = ^(NSInteger row) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_shell ||
        !strongSelf->_shell->web_contents()) {
      return;
    }
    content::WebContents* contents = strongSelf->_shell->web_contents();
    if (contents->GetLastCommittedURL().host() != url.host()) {
      return;
    }
    switch (static_cast<BlinkSiteRow>(row)) {
      case BlinkSiteRowConnection:
        return;
      case BlinkSiteRowDesktop:
        [strongSelf toggleDesktopSite];
        break;
      case BlinkSiteRowAdBlock:
        [strongSelf toggleSiteAdBlock];
        break;
      case BlinkSiteRowPopups:
        if (BlinkShouldBlockPopupFromHost(std::string(url.host()).c_str())) {
          BlinkAllowPopupsForHost(host);
        } else {
          BlinkDisallowPopupsForHost(host);
        }
        break;
      case BlinkSiteRowZoom: {
        [strongSelf showPageZoomMenuThen:^(int percent) {
          [weakSelf fillSiteSettings:weakList url:url];
        }];
        return;
      }
      case BlinkSiteRowKeepAwake:
        BlinkSetHostStaysActive(host, !BlinkHostStaysActive(host));
        break;
      case BlinkSiteRowSound:
        [strongSelf toggleTabMute];
        break;
      case BlinkSiteRowClearData:
        [strongSelf confirmClearSiteData:url list:weakList];
        return;
    }
    [strongSelf fillSiteSettings:weakList url:url];
  };
  vc.compactRows = YES;
  [self presentCompactList:vc from:_siteButton];
}

// Малий поповер від кнопки, як головне меню. Коли якийсь список уже показаний,
// наприклад пункт меню, сторінка просто додається в його стек.
- (void)presentCompactList:(BlinkListVC*)vc from:(UIView*)source {
  if ([self.presentedViewController isKindOfClass:[UINavigationController class]] ||
      !source.window) {
    [self presentList:vc];
    return;
  }
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationPopover;
  nav.preferredContentSize =
      CGSizeMake(MIN(340, self.view.bounds.size.width - 36),
                 MIN(480, self.view.bounds.size.height - 130));
  UIColor* chrome = [UIColor colorWithWhite:0.09 alpha:1.0];
  vc.tableView.backgroundColor = chrome;
  UIPopoverPresentationController* popover = nav.popoverPresentationController;
  popover.delegate = self;
  popover.sourceView = source;
  popover.sourceRect = source.bounds;
  popover.permittedArrowDirections =
      UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
  popover.backgroundColor = chrome;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)confirmClearSiteData:(const GURL&)url list:(BlinkListVC*)list {
  const GURL target = url;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:[NSString
                                   stringWithFormat:BlinkL(@"Clear Data for %@"),
                                                    base::SysUTF8ToNSString(
                                                        url.host())]
                       message:BlinkL(@"You will be signed out of this site "
                                      @"and its saved data will be deleted.")
                preferredStyle:UIAlertControllerStyleAlert];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakList = list;
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Clear")
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction* action) {
                                 ContentShellWindowDelegate* strongSelf =
                                     weakSelf;
                                 if (!strongSelf || !strongSelf->_shell ||
                                     !strongSelf->_shell->web_contents()) {
                                   return;
                                 }
                                 content::WebContents* contents =
                                     strongSelf->_shell->web_contents();
                                 content::BlinkClearSiteData(contents, target);
                                 contents->GetController().Reload(
                                     content::ReloadType::BYPASSING_CACHE,
                                     true);
                                 [strongSelf fillSiteSettings:weakList
                                                          url:target];
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [BlinkTopViewController(self) presentViewController:alert
                                             animated:YES
                                           completion:nil];
}

// Переклад через проксі Google, бо вбудованого перекладача в content нема.
- (void)translatePage {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  content::WebContents* contents = _shell->web_contents();
  const GURL url = contents->GetLastCommittedURL();
  if (base::EndsWith(url.host(), ".translate.goog") &&
      contents->GetController().CanGoBack()) {
    contents->GetController().GoBack();
    return;
  }
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  std::string target = content::BlinkerInterfaceLanguage();
  if (target == "zh") {
    target = "zh-CN";
  }
  const GURL translate(
      "https://translate.google.com/translate?sl=auto&tl=" + target +
      "&hl=" + target + "&u=" + base::EscapeQueryParamValue(url.spec(), true));
  _shell->LoadURL(translate);
}

// Сторінка одним файлом MHTML у Завантаженнях, відкривається без мережі.
- (void)savePageOffline {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  content::WebContents* contents = _shell->web_contents();
  const GURL url = contents->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  NSString* title = base::SysUTF16ToNSString(contents->GetTitle());
  NSCharacterSet* bad =
      [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r\t"];
  title = [[title componentsSeparatedByCharactersInSet:bad]
      componentsJoinedByString:@" "];
  title = [title stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!title.length) {
    title = base::SysUTF8ToNSString(url.host());
  }
  if (title.length > 80) {
    title = [title substringToIndex:80];
  }
  base::FilePath dir = contents->GetBrowserContext()
                           ->GetPath()
                           .Append(FILE_PATH_LITERAL("MyFiles"))
                           .Append(FILE_PATH_LITERAL("Downloads"));
  NSString* dirPath = base::SysUTF8ToNSString(dir.value());
  [NSFileManager.defaultManager createDirectoryAtPath:dirPath
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString* path = nil;
  for (int i = 1; i < 100; ++i) {
    NSString* name = i == 1 ? [title stringByAppendingString:@".mhtml"]
                            : [NSString stringWithFormat:@"%@ %d.mhtml",
                                                         title, i];
    NSString* candidate = [dirPath stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
      path = candidate;
      break;
    }
  }
  if (!path) {
    return;
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  NSString* savedName = path.lastPathComponent;
  contents->GenerateMHTML(
      content::MHTMLGenerationParams(
          base::FilePath(base::SysNSStringToUTF8(path))),
      base::BindOnce(^(int64_t size) {
        ContentShellWindowDelegate* strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        BLINKER_DIAGF("OFFLINE_PAGE: saved size=%lld",
                      static_cast<long long>(size));
        if (size <= 0) {
          [strongSelf showNotice:BlinkL(@"Couldn't save this page")
                         message:nil];
          return;
        }
        BlinkShowActionBar(
            strongSelf.view.window, @"arrow.down.doc",
            [NSString stringWithFormat:BlinkL(@"Saved to Downloads as %@"),
                                       savedName],
            BlinkL(@"Show"), ^{
              [weakSelf showDownloads];
            });
      }));
}

- (void)showNotice:(NSString*)title message:(NSString*)message {
  UIAlertController* alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"OK")
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [BlinkTopViewController(self) presentViewController:alert
                                             animated:YES
                                           completion:nil];
}

- (void)shareFileAtPath:(NSString*)path {
  UIActivityViewController* share = [[UIActivityViewController alloc]
      initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
      applicationActivities:nil];
  UIViewController* host = BlinkTopViewController(self);
  share.popoverPresentationController.sourceView = host.view;
  share.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(host.view.bounds),
                 CGRectGetMidY(host.view.bounds), 1, 1);
  [host presentViewController:share animated:YES completion:nil];
}

- (void)showImportExport {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Import and Export");
  vc.dismissOnSelect = NO;
  vc.titles = [@[
    @"Import Bookmarks", @"Export Bookmarks", @"Import History",
    @"Export History", @"Back Up Extensions", @"Restore Extensions"
  ] mutableCopy];
  vc.subtitles = [@[
    @"From an HTML file from Chrome, Safari, Firefox or Reynard",
    @"As an HTML file other browsers can import",
    @"From Chrome Takeout or a Safari export",
    @"As a JSON file in Safari's format",
    @"Extensions with their settings, as a ZIP file",
    @"From a Blinker Fluid backup"
  ] mutableCopy];
  vc.imageNames = @[
    @"square.and.arrow.down", @"square.and.arrow.up", @"square.and.arrow.down",
    @"square.and.arrow.up", @"square.and.arrow.up", @"square.and.arrow.down"
  ];
  vc.sectionTitles = @[ @"BOOKMARKS", @"HISTORY", @"EXTENSIONS" ];
  vc.sectionStarts = @[ @0, @2, @4 ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    switch (row) {
      case 0:
        [weakSelf pickImportFile:BlinkImportBookmarks];
        break;
      case 1:
        [weakSelf exportBookmarks];
        break;
      case 2:
        [weakSelf pickImportFile:BlinkImportHistory];
        break;
      case 3:
        [weakSelf exportHistory];
        break;
      case 4:
        [weakSelf backUpExtensions];
        break;
      case 5:
        [weakSelf pickImportFile:BlinkImportExtensions];
        break;
    }
  };
  [self presentList:vc];
}

- (void)pickImportFile:(NSInteger)kind {
  self.pendingImportKind = kind;
  UIDocumentPickerViewController* picker = nil;
  if (@available(iOS 14.0, *)) {
    NSArray<UTType*>* types =
        kind == BlinkImportBookmarks
            ? @[ UTTypeHTML ]
            : (kind == BlinkImportHistory ? @[ UTTypeJSON, UTTypeZIP ]
                                          : @[ UTTypeZIP ]);
    picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types
                           asCopy:YES];
  } else {
    NSArray<NSString*>* types =
        kind == BlinkImportBookmarks
            ? @[ @"public.html" ]
            : (kind == BlinkImportHistory
                   ? @[ @"public.json", @"com.pkware.zip-archive" ]
                   : @[ @"com.pkware.zip-archive" ]);
    picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:types
                       inMode:UIDocumentPickerModeImport];
  }
  picker.delegate = self;
  [BlinkTopViewController(self) presentViewController:picker
                                             animated:YES
                                           completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  self.pendingImportKind = BlinkImportNone;
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  const NSInteger kind = self.pendingImportKind;
  self.pendingImportKind = BlinkImportNone;
  NSURL* picked = urls.firstObject;
  if (!picked) {
    return;
  }
  // Копія у tmp, щоб далі не тримати доступ до чужого файлу.
  NSString* copy = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"blinker-import-%@.%@",
                                     NSUUID.UUID.UUIDString,
                                     picked.pathExtension.lowercaseString
                                         ?: @"dat"]];
  const BOOL scoped = [picked startAccessingSecurityScopedResource];
  NSError* error = nil;
  [NSFileManager.defaultManager copyItemAtURL:picked
                                        toURL:[NSURL fileURLWithPath:copy]
                                        error:&error];
  if (scoped) {
    [picked stopAccessingSecurityScopedResource];
  }
  if (error) {
    [self showNotice:BlinkL(@"Couldn't open this file") message:nil];
    return;
  }
  switch (kind) {
    case BlinkImportBookmarks:
      [self importBookmarksFromPath:copy];
      break;
    case BlinkImportHistory:
      [self importHistoryFromPath:copy];
      break;
    case BlinkImportExtensions:
      [self restoreExtensionsFromPath:copy];
      break;
    default:
      [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
      break;
  }
}

- (void)importBookmarksFromPath:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  std::vector<content::BlinkerBookmarkNode> nodes;
  if (data.length) {
    nodes = content::BlinkerParseBookmarksHtml(std::string_view(
        static_cast<const char*>(data.bytes), data.length));
  }
  NSUInteger links = 0;
  NSMutableArray* items = BlinkBookmarkItemsFromNodes(nodes, &links);
  if (!links) {
    [self showNotice:BlinkL(@"No bookmarks found")
             message:BlinkL(@"Choose a bookmarks HTML file exported from "
                            @"another browser.")];
    return;
  }
  NSMutableArray* root = [self bookmarks];
  [root addObject:[@{
          @"title" : BlinkL(@"Imported Bookmarks"),
          @"children" : items,
          @"dateAdded" :
              @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0))
        } mutableCopy]];
  [self saveBookmarks:root];
  [self showNotice:[NSString stringWithFormat:BlinkL(@"Imported %lu bookmarks"),
                                              static_cast<unsigned long>(links)]
           message:BlinkL(@"They are in the Imported Bookmarks folder.")];
}

- (void)exportBookmarks {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  std::vector<content::BlinkerBookmarkNode> nodes;
  BlinkCollectBookmarkNodes([defaults arrayForKey:@"BlinkBookmarks"], &nodes);
  std::vector<content::BlinkerBookmarkNode> other;
  BlinkCollectBookmarkNodes([defaults arrayForKey:@"BlinkOtherBookmarks"],
                            &other);
  if (!other.empty()) {
    content::BlinkerBookmarkNode folder;
    folder.title = "Other Bookmarks";
    folder.children = std::move(other);
    nodes.push_back(std::move(folder));
  }
  if (nodes.empty()) {
    [self showNotice:BlinkL(@"No bookmarks yet") message:nil];
    return;
  }
  const std::string html = content::BlinkerWriteBookmarksHtml(nodes);
  NSString* path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"Blinker Fluid bookmarks.html"];
  [[NSData dataWithBytes:html.data() length:html.size()] writeToFile:path
                                                          atomically:YES];
  [self shareFileAtPath:path];
}

- (void)importHistoryFromPath:(NSString*)path {
  __weak ContentShellWindowDelegate* weakSelf = self;
  NSString* source = path;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData* data = nil;
    if ([source.pathExtension isEqualToString:@"zip"]) {
      // У zip від Safari лежить History.json, у Takeout BrowserHistory.json.
      NSString* unpacked = [source stringByAppendingString:@"-unpacked"];
      if (zip::Unzip(base::FilePath(base::SysNSStringToUTF8(source)),
                     base::FilePath(base::SysNSStringToUTF8(unpacked)))) {
        NSDirectoryEnumerator* files =
            [NSFileManager.defaultManager enumeratorAtPath:unpacked];
        for (NSString* file in files) {
          NSString* name = file.lastPathComponent;
          if ([name isEqualToString:@"History.json"] ||
              [name isEqualToString:@"BrowserHistory.json"]) {
            data = [NSData
                dataWithContentsOfFile:[unpacked
                                           stringByAppendingPathComponent:file]];
            break;
          }
        }
      }
      [NSFileManager.defaultManager removeItemAtPath:unpacked error:nil];
    } else {
      data = [NSData dataWithContentsOfFile:source];
    }
    [NSFileManager.defaultManager removeItemAtPath:source error:nil];
    NSArray<NSString*>* urls = BlinkHistoryURLsFromJSON(data);
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf finishHistoryImport:urls];
    });
  });
}

- (void)finishHistoryImport:(NSArray<NSString*>*)urls {
  if (!urls.count) {
    [self showNotice:BlinkL(@"No history found")
             message:BlinkL(@"Choose BrowserHistory.json from Chrome Takeout "
                            @"or the History.json or ZIP that Safari "
                            @"exports.")];
    return;
  }
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  NSMutableArray<NSString*>* history =
      [[defaults stringArrayForKey:@"BlinkHistory"] mutableCopy]
          ?: [NSMutableArray array];
  NSMutableSet<NSString*>* seen = [NSMutableSet setWithArray:history];
  NSUInteger added = 0;
  for (NSString* url in urls) {
    if (history.count >= 500) {
      break;
    }
    if ([seen containsObject:url]) {
      continue;
    }
    [seen addObject:url];
    [history addObject:url];
    ++added;
  }
  [defaults setObject:history forKey:@"BlinkHistory"];
  [self showNotice:[NSString stringWithFormat:BlinkL(@"Imported %lu pages"),
                                              static_cast<unsigned long>(added)]
           message:nil];
}

- (void)exportHistory {
  NSArray<NSString*>* history =
      [NSUserDefaults.standardUserDefaults stringArrayForKey:@"BlinkHistory"];
  if (!history.count) {
    [self showNotice:BlinkL(@"No history yet") message:nil];
    return;
  }
  // Часу відвідин Blink не пише, тож лишаєм порядок, по секунді на запис.
  const long long now =
      (long long)(NSDate.date.timeIntervalSince1970 * 1000000.0);
  NSMutableArray* items = [NSMutableArray array];
  [history enumerateObjectsUsingBlock:^(NSString* url, NSUInteger i, BOOL*) {
    NSString* host = [NSURL URLWithString:url].host ?: url;
    [items addObject:@{
      @"url" : url,
      @"title" : host,
      @"time_usec" : @(now - (long long)i * 1000000),
      @"visit_count" : @1
    }];
  }];
  NSDictionary* root = @{
    @"metadata" : @{
      @"browser_name" : @"Blinker Fluid",
      @"browser_version" : @"0.3.2",
      @"data_type" : @"history",
      @"export_time_usec" : @(now),
      @"schema_version" : @1
    },
    @"history" : items
  };
  NSData* data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:0
                                                   error:nil];
  NSString* path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"Blinker Fluid history.json"];
  [data writeToFile:path atomically:YES];
  [self shareFileAtPath:path];
}

- (void)backUpExtensions {
  __weak ContentShellWindowDelegate* weakSelf = self;
  content::BlinkerBackUpExtensions(base::BindOnce(^(base::FilePath archive) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    if (archive.empty()) {
      [strongSelf showNotice:BlinkL(@"Nothing to back up")
                     message:BlinkL(@"No extensions are installed, or the "
                                    @"backup couldn't be written.")];
      return;
    }
    [strongSelf shareFileAtPath:base::SysUTF8ToNSString(archive.value())];
  }));
}

- (void)restoreExtensionsFromPath:(NSString*)path {
  __weak ContentShellWindowDelegate* weakSelf = self;
  NSString* source = path;
  content::BlinkerStageExtensionRestore(
      base::FilePath(base::SysNSStringToUTF8(path)),
      base::BindOnce(^(int count) {
        [NSFileManager.defaultManager removeItemAtPath:source error:nil];
        ContentShellWindowDelegate* strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        if (count < 0) {
          [strongSelf
              showNotice:BlinkL(@"This isn't an extensions backup")
                 message:BlinkL(@"Choose a ZIP made with Back Up Extensions.")];
          return;
        }
        UIAlertController* alert = [UIAlertController
            alertControllerWithTitle:
                [NSString stringWithFormat:BlinkL(@"%d extensions ready"),
                                           count]
                             message:BlinkL(@"They will be restored the next "
                                            @"time Blinker Fluid opens.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
                             actionWithTitle:BlinkL(@"Restart Blinker Fluid")
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction* action) {
                                       [weakSelf restartApplication];
                                     }]];
        [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Later")
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [BlinkTopViewController(strongSelf) presentViewController:alert
                                                         animated:YES
                                                       completion:nil];
      }));
}

- (void)showSecureDNS:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Secure DNS");
  vc.dismissOnSelect = NO;
  __weak BlinkListVC* weakSettings = settings;
  __weak BlinkListVC* weakList = vc;
  __weak ContentShellWindowDelegate* weakSelf = self;
  void (^refill)(void) = ^{
    BlinkListVC* list = weakList;
    if (!list) {
      return;
    }
    NSString* current =
        [NSUserDefaults.standardUserDefaults stringForKey:@"BlinkSecureDNS"]
            ?: @"";
    list.titles = [NSMutableArray arrayWithObject:@"Off"];
    list.subtitles = [NSMutableArray arrayWithObject:@"Use the network's DNS"];
    NSInteger checked = current.length ? -1 : 0;
    for (const BlinkSecureDnsProvider& provider : kBlinkSecureDnsProviders) {
      [list.titles addObject:@(provider.name)];
      [list.subtitles addObject:@(provider.detail)];
      if ([current isEqualToString:@(provider.doh_template)]) {
        checked = list.titles.count - 1;
      }
    }
    [list.titles addObject:@"Custom"];
    [list.subtitles addObject:checked < 0 ? current
                                          : @"Any DNS over HTTPS address"];
    if (checked < 0) {
      checked = list.titles.count - 1;
    }
    list.checkedRows = [NSIndexSet indexSetWithIndex:checked];
    list.sectionTitles = @[ @"PROVIDER" ];
    list.sectionStarts = @[ @0 ];
    if (list.isViewLoaded) {
      [list.tableView reloadData];
    }
    weakSettings.subtitles[BlinkSettingsRowSecureDNS] = BlinkSecureDnsSubtitle();
    [weakSettings.tableView reloadData];
  };
  refill();
  vc.onSelect = ^(NSInteger row) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    const NSInteger providers =
        static_cast<NSInteger>(std::size(kBlinkSecureDnsProviders));
    if (row == 0) {
      [defaults removeObjectForKey:@"BlinkSecureDNS"];
    } else if (row <= providers) {
      [defaults setObject:@(kBlinkSecureDnsProviders[row - 1].doh_template)
                   forKey:@"BlinkSecureDNS"];
    } else {
      [weakSelf askCustomSecureDNS:refill];
      return;
    }
    content::BlinkerApplySecureDnsSetting();
    refill();
  };
  [self presentList:vc];
}

- (void)askCustomSecureDNS:(void (^)(void))done {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Custom Secure DNS")
                       message:BlinkL(@"Enter the DNS over HTTPS address of "
                                      @"your provider.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"https://dns.example/dns-query";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak UIAlertController* weakAlert = alert;
  void (^finished)(void) = [done copy];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Save")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction* action) {
                                 NSString* value = [weakAlert.textFields
                                                        .firstObject.text
                                     stringByTrimmingCharactersInSet:
                                         NSCharacterSet
                                             .whitespaceAndNewlineCharacterSet];
                                 if (!content::BlinkerIsValidSecureDnsTemplate(
                                         base::SysNSStringToUTF8(value ?: @""))) {
                                   [weakSelf
                                       showNotice:BlinkL(@"Invalid address")
                                          message:BlinkL(
                                                      @"Use an https address "
                                                      @"of a DNS over HTTPS "
                                                      @"server.")];
                                   return;
                                 }
                                 [NSUserDefaults.standardUserDefaults
                                     setObject:value
                                        forKey:@"BlinkSecureDNS"];
                                 content::BlinkerApplySecureDnsSetting();
                                 if (finished) {
                                   finished();
                                 }
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [BlinkTopViewController(self) presentViewController:alert
                                             animated:YES
                                           completion:nil];
}

- (void)showRecommendedExtensions {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.literalRows = YES;
  vc.title = BlinkL(@"Recommended Extensions");
  vc.dismissOnSelect = NO;
  vc.headerNote = @"These extensions were tested with Blinker Fluid and found "
                  @"stable. Tap one to open its official page in the Chrome "
                  @"Web Store. Other extensions may not work properly.";
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableIndexSet* installed = [NSMutableIndexSet indexSet];
  NSMutableArray<NSString*>* ids = [NSMutableArray array];
  NSMutableArray* images = [NSMutableArray array];
  for (const BlinkRecommendedExtension& extension :
       kBlinkRecommendedExtensions) {
    NSString* extensionId = @(extension.id);
    const BOOL have = BlinkExtensionInstalled(extensionId, extension.match);
    [vc.titles addObject:@(extension.name)];
    [vc.subtitles
        addObject:have ? [NSString stringWithFormat:@"%@, %@",
                                                    BlinkL(@"Installed"),
                                                    BlinkL(@(extension.about))]
                       : BlinkL(@(extension.about))];
    if (have) {
      [installed addIndex:ids.count];
    }
    [ids addObject:extensionId];
    [images addObject:@"puzzlepiece.extension"];
  }
  vc.imageNames = images;
  vc.checkedRows = installed;
  vc.disabledRows = installed;
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(ids.count)) {
      return;
    }
    // Розширення не ставиться само, відкривається його офіційна сторінка в
    // Chrome Web Store, а кнопку Add показує maybeOfferWebStoreInstall.
    NSString* spec =
        [@"https://chromewebstore.google.com/detail/"
            stringByAppendingString:ids[row]];
    [weakSelf dismissViewControllerAnimated:YES
                                 completion:^{
                                   BlinkOpenURLInNewTab(spec.UTF8String, false);
                                 }];
  };
  [self presentList:vc];
}

- (void)installWebStoreExtension:(NSString*)extensionId {
  BLINKER_DIAG("EXT: installing from Chrome Web Store");
  [self loadURLString:BlinkWebStoreInstallURL(extensionId)];
}

- (void)maybeOfferWebStoreInstall:(const GURL&)url {
  NSString* extensionId = BlinkWebStoreExtensionId(url);
  if (!extensionId || [self.lastWebStorePrompt isEqualToString:extensionId] ||
      !self.view.window.isKeyWindow) {
    return;
  }
  self.lastWebStorePrompt = extensionId;
  const char* knownMatch = nullptr;
  for (const BlinkRecommendedExtension& extension :
       kBlinkRecommendedExtensions) {
    if ([extensionId isEqualToString:@(extension.id)]) {
      knownMatch = extension.match;
    }
  }
  const BOOL have = BlinkExtensionInstalled(extensionId, knownMatch);
  __weak ContentShellWindowDelegate* weakSelf = self;
  BlinkShowActionBar(
      self.view.window, @"puzzlepiece.extension",
      have ? BlinkL(@"This extension is installed")
           : BlinkL(@"Add this extension to Blinker Fluid"),
      have ? nil : BlinkL(@"Add"), ^{
        [weakSelf installWebStoreExtension:extensionId];
      });
}

- (void)showIdentityMenu:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Browser Identity");
  vc.dismissOnSelect = NO;
  vc.titles = [@[
    BlinkIdentityTitle(content::kBlinkIdentityChromeAndroid),
    BlinkIdentityTitle(content::kBlinkIdentitySafariIOS),
    BlinkIdentityTitle(content::kBlinkIdentityChromeIOS)
  ] mutableCopy];
  vc.subtitles = [@[
    @"Default. Works best with sign in pages and bot checks",
    @"For sites that offer more on iPhone and iPad",
    @"Same as Chrome on iPhone or iPad"
  ] mutableCopy];
  vc.rowImages = @[
    BlinkIdentityIcon(content::kBlinkIdentityChromeAndroid),
    BlinkIdentityIcon(content::kBlinkIdentitySafariIOS),
    BlinkIdentityIcon(content::kBlinkIdentityChromeIOS)
  ];
  vc.checkedRows = [NSIndexSet indexSetWithIndex:BlinkCurrentIdentity()];
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  vc.onSelect = ^(NSInteger row) {
    if (row == BlinkCurrentIdentity()) {
      return;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:row
                                               forKey:@"BlinkUserAgentIdentity"];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    for (content::Shell* shell : content::Shell::windows()) {
      content::WebContents* contents = shell->web_contents();
      if (!contents || content::BlinkIsDesktopSite(contents)) {
        continue;
      }
      content::BlinkApplyIdentity(contents);
      const GURL url = contents->GetLastCommittedURL();
      if (url.SchemeIsHTTPOrHTTPS()) {
        shell->LoadURL(url);
      }
    }
    weakList.checkedRows = [NSIndexSet indexSetWithIndex:row];
    weakSettings.subtitles[BlinkSettingsRowIdentity] =
        BlinkIdentityTitle(static_cast<int>(row));
    NSMutableArray* settingsImages = [weakSettings.rowImages mutableCopy];
    if (BlinkSettingsRowIdentity < (NSInteger)settingsImages.count) {
      settingsImages[BlinkSettingsRowIdentity] =
          BlinkIdentityIcon(static_cast<int>(row));
      weakSettings.rowImages = settingsImages;
    }
    [weakList.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  [self presentList:vc];
}

- (void)showPopupSettings:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Block Popups");
  vc.dismissOnSelect = NO;
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  void (^populate)(void) = ^{
    BlinkListVC* list = weakList;
    NSArray<NSString*>* hosts = BlinkPopupAllowedHosts();
    list.titles = [@[ BlinkL(@"Block Popups") ] mutableCopy];
    list.subtitles =
        [@[ BlinkBlockPopupsEnabled()
                ? @"Windows a page opens without your tap are stopped"
                : BlinkL(@"Off") ] mutableCopy];
    for (NSString* host in hosts) {
      [list.titles addObject:host];
      [list.subtitles addObject:@"Allowed, swipe to remove"];
    }
    list.checkedRows = BlinkBlockPopupsEnabled()
                           ? [NSIndexSet indexSetWithIndex:0]
                           : [NSIndexSet indexSet];
    list.protectedRows = [NSIndexSet indexSetWithIndex:0];
    list.sectionTitles = hosts.count ? @[ @"", @"ALLOWED SITES" ] : @[ @"" ];
    list.sectionStarts = hosts.count ? @[ @0, @1 ] : @[ @0 ];
    weakSettings.subtitles[BlinkSettingsRowPopups] = BlinkPopupSettingsSubtitle();
    [list.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  vc.onSelect = ^(NSInteger row) {
    if (row != 0) {
      return;
    }
    [[NSUserDefaults standardUserDefaults] setBool:!BlinkBlockPopupsEnabled()
                                            forKey:kBlinkBlockPopupsKey];
    populate();
  };
  vc.onDelete = ^(NSInteger row) {
    NSMutableArray<NSString*>* hosts = [BlinkPopupAllowedHosts() mutableCopy];
    if (row >= 1 && row - 1 < static_cast<NSInteger>(hosts.count)) {
      [hosts removeObjectAtIndex:row - 1];
      [[NSUserDefaults standardUserDefaults]
          setObject:hosts
             forKey:kBlinkPopupAllowedHostsKey];
    }
    populate();
  };
  vc.reloadAfterDelete = YES;
  populate();
  [self presentList:vc];
}

- (void)refreshAllWindows {
  for (content::Shell* shell : content::Shell::windows()) {
    UIWindow* window = shell->window().Get();
    if ([window.rootViewController
            isKindOfClass:[ContentShellWindowDelegate class]]) {
      [(ContentShellWindowDelegate*)window.rootViewController
          refreshAppearance];
    }
  }
}

- (void)showCustomize:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Customize";
  vc.dismissOnSelect = NO;
  vc.imageNames = @[
    @"paintpalette", @"square.grid.2x2", @"textformat.size", @"textformat",
    @"link"
  ];
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  __weak ContentShellWindowDelegate* weakSelf = self;
  void (^populate)(void) = ^{
    BlinkListVC* list = weakList;
    const BOOL hidden =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkHideShortcuts"];
    list.titles = [@[
      @"Theme Color", @"Start Page Shortcuts", @"Default Page Zoom",
      @"Text Color", @"Link Color"
    ] mutableCopy];
    list.subtitles = [@[
      BlinkThemeColorName(), hidden ? BlinkL(@"Off") : BlinkL(@"On"),
      [NSString stringWithFormat:@"%d%%", content::BlinkDefaultZoomPercent()],
      BlinkWebColorName(content::kBlinkerWebTextColorKey),
      BlinkWebColorName(content::kBlinkerWebLinkColorKey)
    ] mutableCopy];
    weakSettings.subtitles[BlinkSettingsRowCustomize] = BlinkThemeColorName();
    [list applyNavigationBarAppearance];
    [list.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  vc.onSelect = ^(NSInteger row) {
    if (row == 0) {
      [weakSelf showThemeColors:populate];
    } else if (row == 1) {
      NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
      [d setBool:![d boolForKey:@"BlinkHideShortcuts"]
          forKey:@"BlinkHideShortcuts"];
      [weakSelf refreshAllWindows];
      populate();
    } else if (row == 2) {
      [weakSelf showDefaultZoom:populate];
    } else if (row == 3) {
      [weakSelf showWebColors:content::kBlinkerWebTextColorKey
                        title:@"Text Color"
                      changed:populate];
    } else if (row == 4) {
      [weakSelf showWebColors:content::kBlinkerWebLinkColorKey
                        title:@"Link Color"
                      changed:populate];
    }
  };
  populate();
  [self presentList:vc];
}

// Колір тексту або посилань на сайтах. Типово кольори самого сайту.
- (void)showWebColors:(const char*)key
                title:(NSString*)title
              changed:(void (^)(void))changed {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = title;
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray* dots = [NSMutableArray array];
  for (const content::BlinkerWebColorOption& option :
       content::kBlinkerWebColors) {
    [vc.titles addObject:@(option.name)];
    [vc.subtitles addObject:vc.subtitles.count ? @"" : @"Default"];
    UIColor* color = BlinkColorFromHex(option.hex);
    UIImage* dot = color ? BlinkColorDot(color)
                         : BlinkSystemImage(@"circle.lefthalf.filled");
    [dots addObject:dot ?: BlinkColorDot(UIColor.clearColor)];
  }
  vc.rowImages = dots;
  vc.sectionTitles = @[ @"DARK READER AND STYLUS CAN CHANGE COLORS TOO" ];
  vc.sectionStarts = @[ @0 ];
  vc.checkedRows = [NSIndexSet indexSetWithIndex:BlinkWebColorIndex(key)];
  __weak BlinkListVC* weakList = vc;
  NSString* defaultsKey = @(key);
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 ||
        row >= static_cast<NSInteger>(std::size(content::kBlinkerWebColors))) {
      return;
    }
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    if (row == 0) {
      [d removeObjectForKey:defaultsKey];
    } else {
      [d setObject:@(content::kBlinkerWebColors[row].hex) forKey:defaultsKey];
    }
    BlinkApplyWebColorsToOpenTabs();
    weakList.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakList.tableView reloadData];
    changed();
  };
  [self presentList:vc];
}

- (void)showThemeColors:(void (^)(void))changed {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Theme Color";
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray* dots = [NSMutableArray array];
  for (const BlinkThemeColorOption& option : kBlinkThemeColors) {
    [vc.titles addObject:@(option.name)];
    [vc.subtitles addObject:vc.subtitles.count ? @"" : @"Default"];
    [dots addObject:BlinkColorDot([UIColor colorWithRed:option.red / 255.0
                                                  green:option.green / 255.0
                                                   blue:option.blue / 255.0
                                                  alpha:1.0])];
  }
  vc.rowImages = dots;
  vc.checkedRows = [NSIndexSet indexSetWithIndex:BlinkThemeColorIndex()];
  __weak BlinkListVC* weakList = vc;
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    [[NSUserDefaults standardUserDefaults] setInteger:row
                                               forKey:@"BlinkThemeColor"];
    weakList.checkedRows = [NSIndexSet indexSetWithIndex:BlinkThemeColorIndex()];
    BlinkApplyAppIconForTheme();
    [weakSelf refreshAllWindows];
    [weakList applyNavigationBarAppearance];
    [weakList.tableView reloadData];
    changed();
  };
  [self presentList:vc];
}

- (void)showDefaultZoom:(void (^)(void))changed {
  NSArray<NSNumber*>* percentages = @[ @75, @90, @100, @110, @125, @150 ];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Default Page Zoom";
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  for (NSNumber* percent in percentages) {
    [vc.titles addObject:[NSString stringWithFormat:@"%d%%", percent.intValue]];
    [vc.subtitles addObject:percent.intValue == 100 ? @"Default" : @""];
  }
  const NSUInteger current = [percentages
      indexOfObject:@(content::BlinkDefaultZoomPercent())];
  vc.checkedRows = current == NSNotFound
                       ? [NSIndexSet indexSet]
                       : [NSIndexSet indexSetWithIndex:current];
  __weak BlinkListVC* weakList = vc;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(percentages.count)) {
      return;
    }
    [[NSUserDefaults standardUserDefaults]
        setInteger:percentages[row].integerValue
            forKey:@"BlinkDefaultZoom"];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    // Сайти зі своїм масштабом його і лишають, решта бере новий.
    for (content::Shell* shell : content::Shell::windows()) {
      if (content::WebContents* contents = shell->web_contents()) {
        content::BlinkApplyPageZoom(contents,
                                    contents->GetLastCommittedURL());
      }
    }
    weakList.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakList.tableView reloadData];
    changed();
  };
  [self presentList:vc];
}

- (void)applyPrivacyOption:(NSInteger)row enabled:(BOOL)enabled {
  switch (row) {
    case 0:
      for (content::Shell* shell : content::Shell::windows()) {
        if (content::WebContents* contents = shell->web_contents()) {
          BlinkApplyPrivacyRendererPrefs(contents->GetMutableRendererPrefs());
          contents->SyncRendererPrefs();
        }
      }
      break;
    case 1:
      // Приватний профіль блокує їх завжди, тож міняєм лише звичайний.
      content::ShellContentBrowserClient::Get()
          ->browser_context()
          ->GetDefaultStoragePartition()
          ->GetCookieManagerForBrowserProcess()
          ->BlockThirdPartyCookies(enabled);
      break;
    case 2:
      content::BlinkerSetTrackingParamStripping(enabled);
      break;
    default:
      break;
  }
}

- (void)showPrivacyOptions:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Privacy Options";
  vc.dismissOnSelect = NO;
  vc.titles = [@[
    @"Ask Sites Not to Track", @"Block Third Party Cookies",
    @"Remove Tracking From Links", @"Hide Content in App Switcher",
    @"Fresh Start"
  ] mutableCopy];
  vc.subtitles = [@[
    @"Sends Global Privacy Control and Do Not Track",
    @"Some sign in buttons need them",
    @"Strips utm and click IDs from addresses",
    @"Covers the page when you leave the app",
    @"Every launch starts with no history, tabs, cookies or site data"
  ] mutableCopy];
  vc.imageNames = @[
    @"hand.raised", @"circle.slash", @"link", @"rectangle.on.rectangle.slash",
    @"sparkles"
  ];
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  __weak ContentShellWindowDelegate* weakSelf = self;
  void (^populate)(void) = ^{
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    NSMutableIndexSet* on = [NSMutableIndexSet indexSet];
    NSArray<NSString*>* keys = BlinkPrivacyOptionKeys();
    for (NSUInteger row = 0; row < keys.count; ++row) {
      if ([d boolForKey:keys[row]]) {
        [on addIndex:row];
      }
    }
    weakList.checkedRows = on;
    weakSettings.subtitles[BlinkSettingsRowPrivacyOptions] =
        BlinkPrivacyOptionsSubtitle();
    [weakList.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  void (^toggle)(NSInteger) = ^(NSInteger row) {
    NSString* key = BlinkPrivacyOptionKeys()[row];
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    const BOOL enabled = ![d boolForKey:key];
    [d setBool:enabled forKey:key];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    [weakSelf applyPrivacyOption:row enabled:enabled];
    populate();
  };
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 ||
        row >= static_cast<NSInteger>(BlinkPrivacyOptionKeys().count)) {
      return;
    }
    // Fresh Start виходить з усіх сайтів, тож перед увімкненням питаєм.
    if (row == 4 &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkFreshStart"]) {
      UIAlertController* alert = [UIAlertController
          alertControllerWithTitle:BlinkL(@"Fresh Start")
                           message:BlinkL(@"From the next launch, history, open "
                                          @"tabs, cookies and site data are "
                                          @"cleared every time Blinker Fluid "
                                          @"starts. You will be signed out of "
                                          @"websites.")
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
      [alert addAction:[UIAlertAction
                           actionWithTitle:BlinkL(@"Turn On")
                                     style:UIAlertActionStyleDestructive
                                   handler:^(UIAlertAction* action) {
                                     toggle(row);
                                   }]];
      [weakList presentViewController:alert animated:YES completion:nil];
      return;
    }
    toggle(row);
  };
  populate();
  [self presentList:vc];
}

- (void)showMemorySaver:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Memory Saver";
  vc.dismissOnSelect = NO;
  GURL current = _shell && _shell->web_contents()
                     ? _shell->web_contents()->GetLastCommittedURL()
                     : GURL();
  NSString* currentHost = current.SchemeIsHTTPOrHTTPS() && !current.host().empty()
                              ? base::SysUTF8ToNSString(current.host())
                              : nil;
  const BOOL privateSession =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  __block NSArray<NSString*>* shownHosts = @[];
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  void (^populate)(void) = ^{
    BlinkListVC* list = weakList;
    NSMutableArray<NSString*>* hosts = [BlinkMemorySaverSites() mutableCopy];
    for (NSString* host in BlinkSessionMemorySaverSites()) {
      if (![hosts containsObject:host]) {
        [hosts addObject:host];
      }
    }
    shownHosts = hosts;
    list.titles =
        [@[ @"Off", @"Moderate", @"Balanced", @"Maximum", @"Keep This Site Active" ]
            mutableCopy];
    list.subtitles = [@[
      BlinkL(@"Tabs stay active until memory runs low"),
      [NSString stringWithFormat:BlinkL(@"Tabs sleep after %d min in the background"),
                                 MemorySaverIdleMinutes(1)],
      [NSString stringWithFormat:BlinkL(@"Tabs sleep after %d min in the background"),
                                 MemorySaverIdleMinutes(2)],
      [NSString stringWithFormat:BlinkL(@"Tabs sleep after %d min, at most %zu stay active"),
                                 MemorySaverIdleMinutes(3),
                                 MemorySaverResidentTabLimit(3)],
      currentHost ?: BlinkL(@"Open a website first")
    ] mutableCopy];
    for (NSString* host in hosts) {
      [list.titles addObject:host];
      [list.subtitles addObject:@"Stays active, swipe to remove"];
    }
    list.checkedRows = [NSIndexSet indexSetWithIndex:BlinkMemorySaverLevel()];
    list.protectedRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 5)];
    list.disabledRows = currentHost ? [NSIndexSet indexSet]
                                    : [NSIndexSet indexSetWithIndex:4];
    list.sectionTitles =
        @[ @"INACTIVE TABS SLEEP TO FREE MEMORY", @"SITES THAT STAY ACTIVE" ];
    list.sectionStarts = @[ @0, @4 ];
    weakSettings.subtitles[BlinkSettingsRowMemorySaver] =
        BlinkMemorySaverTitle(BlinkMemorySaverLevel());
    [list.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  vc.onSelect = ^(NSInteger row) {
    if (row >= 0 && row <= 3) {
      [[NSUserDefaults standardUserDefaults] setInteger:row
                                                 forKey:kBlinkMemorySaverKey];
    } else if (row == 4 && currentHost) {
      if (privateSession) {
        [BlinkSessionMemorySaverSites() addObject:currentHost];
      } else if (![BlinkMemorySaverSites() containsObject:currentHost]) {
        [[NSUserDefaults standardUserDefaults]
            setObject:[BlinkMemorySaverSites()
                          arrayByAddingObject:currentHost]
               forKey:kBlinkMemorySaverSitesKey];
      }
    }
    populate();
  };
  vc.onDelete = ^(NSInteger row) {
    const NSInteger index = row - 5;
    if (index >= 0 && index < static_cast<NSInteger>(shownHosts.count)) {
      NSString* host = shownHosts[index];
      [BlinkSessionMemorySaverSites() removeObject:host];
      NSMutableArray<NSString*>* saved = [BlinkMemorySaverSites() mutableCopy];
      [saved removeObject:host];
      [[NSUserDefaults standardUserDefaults] setObject:saved
                                                forKey:kBlinkMemorySaverSitesKey];
    }
    populate();
  };
  vc.reloadAfterDelete = YES;
  populate();
  [self presentList:vc];
}

// Колір каретки, виділення і його маркерів. Перший рядок це колір за
// замовчуванням, останній веселка.
- (void)showSelectionColor:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Selection Color";
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray* dots = [NSMutableArray array];
  NSMutableArray<NSString*>* values = [NSMutableArray array];
  for (const content::BlinkerWebColorOption& option :
       content::kBlinkerWebColors) {
    // Тут нема кольору сайту, замість нього помаранчевий Blinker Fluid.
    if (!option.hex[0]) {
      [vc.titles addObject:@(kBlinkThemeColors[0].name)];
      [vc.subtitles addObject:@"Default"];
      [values addObject:@""];
      [dots addObject:BlinkColorDot(BlinkerOrangeColor())];
      continue;
    }
    // Помаранчевий у списку вже є, тож дубль не показуємо.
    if (strcmp(option.name, "Orange") == 0) {
      continue;
    }
    [vc.titles addObject:@(option.name)];
    [vc.subtitles addObject:@""];
    [values addObject:@(option.hex)];
    [dots addObject:BlinkColorDot(BlinkColorFromHex(option.hex))];
  }
  [vc.titles addObject:@"RGB"];
  [vc.subtitles addObject:@"Rainbow"];
  [values addObject:@(content::kBlinkerSelectionRainbow)];
  [dots addObject:BlinkRainbowDot()];
  vc.rowImages = dots;
  NSString* current = [[NSUserDefaults standardUserDefaults]
      stringForKey:@(content::kBlinkerSelectionColorKey)] ?: @"";
  NSInteger selected = [values indexOfObject:current];
  vc.checkedRows =
      [NSIndexSet indexSetWithIndex:selected == NSNotFound ? 0 : selected];
  __weak BlinkListVC* weakList = vc;
  __weak BlinkListVC* weakSettings = settings;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(values.count)) {
      return;
    }
    NSString* value = values[row];
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    if (value.length) {
      [d setObject:value forKey:@(content::kBlinkerSelectionColorKey)];
    } else {
      [d removeObjectForKey:@(content::kBlinkerSelectionColorKey)];
    }
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    BlinkApplySelectionColorToOpenTabs(value);
    weakList.checkedRows = [NSIndexSet indexSetWithIndex:row];
    weakSettings.subtitles[BlinkSettingsRowTextSelection] =
        weakList.titles[row];
    [weakList.tableView reloadData];
    [weakSettings.tableView reloadData];
  };
  [self presentList:vc];
}

- (void)updateSiteAdBlockRow:(BlinkListVC*)list {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  const GURL url = _shell->web_contents()->GetLastCommittedURL();
  auto& filter = content::BlinkerContentFilter::GetInstance();
  bool allowed = filter.IsHostAllowlisted(url.host());
  list.titles[BlinkMenuRowSiteAdBlock] =
      allowed ? @"Block ads on this site" : @"Don't block on this site";
  list.subtitles[BlinkMenuRowSiteAdBlock] =
      url.SchemeIsHTTPOrHTTPS()
          ? [NSString
                stringWithFormat:BlinkL(@"%llu blocked on this page%@"),
                                 (unsigned long long)
                                     filter.blocked_count_for_host(url.host()),
                                 !filter.enabled()
                                     ? @", blocking off"
                                     : (allowed ? @", site allowed" : @"")]
          : @"Open a website first";
  if (!url.SchemeIsHTTPOrHTTPS()) {
    NSMutableIndexSet* disabled =
        [list.disabledRows mutableCopy] ?: [NSMutableIndexSet indexSet];
    [disabled addIndex:BlinkMenuRowSiteAdBlock];
    list.disabledRows = disabled;
  }
  [list.tableView reloadData];
}

- (void)toggleSiteAdBlock {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  auto* contents = _shell->web_contents();
  const GURL url = contents->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  auto& filter = content::BlinkerContentFilter::GetInstance();
  bool allow = !filter.IsHostAllowlisted(url.host());
  filter.SetHostAllowlisted(url.host(), allow);
  if (!contents->GetBrowserContext()->IsOffTheRecord()) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray* hosts =
        [[defaults arrayForKey:@"BlinkAdBlockAllowedHosts"] mutableCopy]
            ?: [NSMutableArray array];
    NSString* host = base::SysUTF8ToNSString(url.host());
    [hosts removeObject:host];
    if (allow) {
      [hosts addObject:host];
    }
    [defaults setObject:hosts forKey:@"BlinkAdBlockAllowedHosts"];
  }
  contents->GetController().Reload(content::ReloadType::NORMAL, true);
}

- (void)showAdBlockSettings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Ad & Tracker Blocking");
  vc.protectedRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)];
  vc.reloadAfterDelete = YES;
  vc.dismissOnSelect = NO;
  vc.dismissOnAdd = NO;
  __weak BlinkListVC* weakList = vc;
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onRefresh = ^{
    BlinkListVC* list = weakList;
    if (!list) {
      return;
    }
    auto& subscriptions = content::BlinkerFilterSubscriptions::GetInstance();
    auto& filter = content::BlinkerContentFilter::GetInstance();
    auto stats = filter.rule_stats();
    list.titles =
        [@[ @"Blocking", @"Update lists now", @"Active rules" ] mutableCopy];
    list.subtitles = [@[
      filter.enabled() ? @"On" : @"Off",
      subscriptions.can_update() ? @"Automatic refresh every day"
                                 : @"Updates paused in private browsing",
      [NSString stringWithFormat:BlinkL(@"%zu network, %zu cosmetic, %zu exceptions"),
                                 stats.network_rules, stats.cosmetic_rules,
                                 stats.exception_rules]
    ] mutableCopy];
    NSMutableIndexSet* checked = [NSMutableIndexSet indexSet];
    for (const auto& item : subscriptions.lists()) {
      if (item.enabled) {
        [checked addIndex:list.titles.count];
      }
      [list.titles addObject:base::SysUTF8ToNSString(item.name)];
      NSString* status = base::SysUTF8ToNSString(item.status);
      [list.subtitles addObject:item.enabled ? status : @"Disabled"];
    }
    list.checkedRows = checked;
    NSMutableIndexSet* disabled = [NSMutableIndexSet indexSetWithIndex:2];
    if (!subscriptions.ready() || !subscriptions.can_update()) {
      [disabled addIndex:1];
    }
    list.disabledRows = disabled;
    list.sectionTitles =
        @[ @"BLOCKING", @"FILTER LISTS, TAP TO TURN ON OR OFF" ];
    list.sectionStarts = @[ @0, @3 ];
    [list.tableView reloadData];
  };
  vc.onSelect = ^(NSInteger row) {
    auto& subscriptions = content::BlinkerFilterSubscriptions::GetInstance();
    if (row == 0) {
      BOOL enabled = !BlinkAdBlockEnabled();
      BlinkAdBlockSetEnabled(enabled);
      [[NSUserDefaults standardUserDefaults] setBool:enabled
                                              forKey:@"BlinkAdBlock"];
    } else if (row == 1) {
      subscriptions.Refresh(true);
    } else if (row >= 3 && (size_t)(row - 3) < subscriptions.lists().size()) {
      const auto item = subscriptions.lists()[row - 3];
      subscriptions.SetEnabled(item.id, !item.enabled);
    }
    if (weakList.onRefresh) {
      weakList.onRefresh();
    }
  };
  vc.onDelete = ^(NSInteger row) {
    auto& subscriptions = content::BlinkerFilterSubscriptions::GetInstance();
    if (row >= 3 && (size_t)(row - 3) < subscriptions.lists().size()) {
      std::string id = subscriptions.lists()[row - 3].id;
      subscriptions.Remove(id);
      if (weakList.onRefresh) {
        weakList.onRefresh();
      }
    }
  };
  vc.onAdd = ^{
    [weakSelf addFilterSubscription:weakList];
  };
  vc.onRefresh();
  [self presentList:vc];
}

- (void)addFilterSubscription:(BlinkListVC*)list {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Add filter list")
                       message:BlinkL(@"Enter an HTTPS EasyList or uBlock format list "
                               @"URL. Network and cosmetic rules are "
                               @"supported. Advanced scriptlets are not.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"https://example.org/filters.txt";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Name (optional)");
  }];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  __weak BlinkListVC* weakList = list;
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:BlinkL(@"Add")
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction* action) {
                        NSString* value = [alert.textFields[0].text
                            stringByTrimmingCharactersInSet:
                                NSCharacterSet
                                    .whitespaceAndNewlineCharacterSet];
                        std::string error =
                            content::BlinkerFilterSubscriptions::GetInstance()
                                .Add(
                                    GURL(base::SysNSStringToUTF8(value ?: @"")),
                                    base::SysNSStringToUTF8(
                                        alert.textFields[1].text ?: @""));
                        if (!error.empty()) {
                          UIAlertController* failure = [UIAlertController
                              alertControllerWithTitle:BlinkL(@"Cannot add list")
                                               message:BlinkL(base::SysUTF8ToNSString(
                                                           error))
                                        preferredStyle:
                                            UIAlertControllerStyleAlert];
                          [failure
                              addAction:
                                  [UIAlertAction
                                      actionWithTitle:BlinkL(@"OK")
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
                          [weakList presentViewController:failure
                                                 animated:YES
                                               completion:nil];
                        }
                        if (weakList.onRefresh) {
                          weakList.onRefresh();
                        }
                      }]];
  [list presentViewController:alert animated:YES completion:nil];
}

// Відкриті сторінки зібрані старою мовою. Будуєм той самий стек наново і
// показуєм без анімації, так що людина лишається на сторінці мов.
- (void)reopenLanguagesInNewLanguage {
  UINavigationController* nav =
      [self.presentedViewController isKindOfClass:UINavigationController.class]
          ? (UINavigationController*)self.presentedViewController
          : nil;
  const BOOL fromMenu =
      [nav.viewControllers.firstObject isKindOfClass:BlinkListVC.class] &&
      ((BlinkListVC*)nav.viewControllers.firstObject).compactRows;
  __weak ContentShellWindowDelegate* weakSelf = self;
  [self dismissViewControllerAnimated:NO
                           completion:^{
                             ContentShellWindowDelegate* strongSelf = weakSelf;
                             if (!strongSelf) {
                               return;
                             }
                             strongSelf->_rebuildingMenu = YES;
                             if (fromMenu) {
                               [strongSelf showMainMenu];
                             }
                             [strongSelf showSettings];
                             [strongSelf showLanguageMenu];
                             strongSelf->_rebuildingMenu = NO;
                           }];
}

- (void)showLanguageMenu {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Languages");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  vc.imageNames = @[];
  NSMutableArray<NSString*>* accepts = [NSMutableArray array];

  NSString* selected = [[NSUserDefaults standardUserDefaults]
                           stringForKey:@"BlinkLanguageAccept"]
                           ?: @"en-US,en";
  NSString* selectedLocaleID =
      [[selected componentsSeparatedByString:@","] firstObject];
  NSLocale* displayLocale =
      [[NSLocale alloc] initWithLocaleIdentifier:selectedLocaleID];
  NSInteger selectedRow = 0;
  NSInteger languageIndex = 0;
  for (const BlinkLanguageOption& option : kBlinkLanguages) {
    NSString* localeID = [[[option.accept componentsSeparatedByString:@","]
                              firstObject] componentsSeparatedByString:@"-"]
                             .firstObject;
    NSString* localizedName =
        [displayLocale localizedStringForLanguageCode:localeID] ?: option.name;
    [accepts addObject:option.accept];
    [vc.titles addObject:localizedName.capitalizedString];
    [vc.subtitles addObject:@""];
    if ([selected isEqualToString:option.accept]) {
      selectedRow = languageIndex;
    }
    ++languageIndex;
  }
  vc.checkedRows = [NSIndexSet indexSetWithIndex:selectedRow];

  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(accepts.count)) {
      return;
    }
    NSString* accept = accepts[row];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([accept isEqualToString:[defaults stringForKey:@"BlinkLanguageAccept"]]) {
      return;
    }
    [defaults setObject:accept forKey:@"BlinkLanguageAccept"];
    [defaults synchronize];
    BlinkSetSearchPlaceholder(weakSelf.urlField,
                              [UIColor colorWithWhite:0.7 alpha:1.0]);
    [weakSelf.startPage applyInterfaceLanguage];
    [weakSelf reopenLanguagesInNewLanguage];
  };
  [self presentList:vc];
}

- (void)toggleAppLockFromSettings:(BlinkListVC*)settings {
  LAContext* context = [[LAContext alloc] init];
  NSError* error = nil;
  if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                            error:&error]) {
    return;
  }
  BOOL currentlyEnabled =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkAppLock"];
  NSString* reason = currentlyEnabled
                         ? BlinkL(@"Authenticate to turn off Blinker Fluid App Lock")
                         : BlinkL(@"Authenticate to protect Blinker Fluid");
  __weak ContentShellWindowDelegate* weakSelf = self;
  [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
          localizedReason:reason
                    reply:^(BOOL success, NSError* authError) {
                      if (!success) {
                        return;
                      }
                      dispatch_async(dispatch_get_main_queue(), ^{
                        BOOL enabled = !currentlyEnabled;
                        [[NSUserDefaults standardUserDefaults]
                            setBool:enabled
                             forKey:@"BlinkAppLock"];
                        g_blink_app_unlocked = enabled;
                        settings.subtitles[BlinkSettingsRowAppLock] =
                            enabled ? BlinkL(@"On") : BlinkL(@"Off");
                        [settings.tableView reloadData];
                        [weakSelf updatePrivacyLock];
                      });
                    }];
}

- (void)showWebsitePermissions {
  NSString* (^state)(int) = ^NSString*(int permission) {
    if (BlinkIOSSystemPermissionStatus(permission)) {
      return @"Allowed in iOS Settings";
    }
    if (permission == 0) {
      CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
      return status == kCLAuthorizationStatusNotDetermined
                 ? @"Tap to request access"
                 : @"Off, change in iOS Settings";
    }
    AVMediaType type = permission == 1 ? AVMediaTypeAudio : AVMediaTypeVideo;
    return [AVCaptureDevice authorizationStatusForMediaType:type] ==
                   AVAuthorizationStatusNotDetermined
               ? @"Tap to request access"
               : @"Off, change in iOS Settings";
  };
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Website Permissions");
  vc.dismissOnSelect = NO;
  vc.titles = [@[ @"Location", @"Camera", @"Microphone", @"Open iOS Settings" ]
      mutableCopy];
  vc.subtitles =
      [@[ state(0), state(2), state(1), @"Change system level access" ]
          mutableCopy];
  vc.imageNames = @[ @"location", @"camera", @"mic", @"gear" ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakPermissions = vc;
  vc.onSelect = ^(NSInteger row) {
    if (row == 0) {
      CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
      if (status == kCLAuthorizationStatusNotDetermined) {
        weakSelf.permissionLocationManager = [[CLLocationManager alloc] init];
        [weakSelf.permissionLocationManager requestWhenInUseAuthorization];
      } else {
        NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:nil];
      }
    } else if (row == 1 || row == 2) {
      int permission = row == 1 ? 2 : 1;
      AVMediaType type = permission == 1 ? AVMediaTypeAudio : AVMediaTypeVideo;
      AVAuthorizationStatus status =
          [AVCaptureDevice authorizationStatusForMediaType:type];
      if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:type
                                 completionHandler:^(BOOL granted) {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     weakPermissions.subtitles[row] =
                                         granted
                                             ? @"Allowed in iOS Settings"
                                             : @"Off, change in iOS Settings";
                                     [weakPermissions.tableView reloadData];
                                   });
                                 }];
      } else {
        NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:nil];
      }
    } else if (row == 3) {
      NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
      [[UIApplication sharedApplication] openURL:url
                                         options:@{}
                               completionHandler:nil];
    }
  };
  [self presentList:vc];
}

- (void)showHistory {
  NSMutableArray<NSString*>* history =
      [[[NSUserDefaults standardUserDefaults] stringArrayForKey:@"BlinkHistory"]
          mutableCopy]
          ?: [NSMutableArray array];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.literalRows = YES;
  vc.title = BlinkL(@"History");
  vc.dismissOnSelect = YES;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [history mutableCopy];
  for (NSString* value in history) {
    NSURL* url = [NSURL URLWithString:value];
    [vc.titles addObject:url.host.length ? url.host : value];
  }
  vc.imageNames = @[];
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    if (row < (NSInteger)history.count) {
      [weakSelf openUserInput:history[row]];
    }
  };
  vc.onDelete = ^(NSInteger row) {
    if (row < (NSInteger)history.count) {
      [history removeObjectAtIndex:row];
      [[NSUserDefaults standardUserDefaults] setObject:history
                                                forKey:@"BlinkHistory"];
    }
  };
  [self presentList:vc];
}

- (void)showClearBrowsingData {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Clear Browsing Data")
                       message:BlinkL(@"Clear browsing history and "
                               @"reload all open tabs? Website "
                               @"cookies remain available so "
                               @"you are not signed out.")
                preferredStyle:UIAlertControllerStyleAlert];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:BlinkL(@"Clear")
                              style:UIAlertActionStyleDestructive
                            handler:^(UIAlertAction* action) {
                              [[NSUserDefaults standardUserDefaults]
                                  removeObjectForKey:@"BlinkHistory"];
                              for (content::Shell* shell :
                                   content::Shell::windows()) {
                                if (shell->web_contents()) {
                                  content::NavigationController& controller =
                                      shell->web_contents()->GetController();
                                  if (controller
                                          .CanPruneAllButLastCommitted()) {
                                    controller.PruneAllButLastCommitted();
                                  }
                                  controller.Reload(
                                      content::ReloadType::NORMAL, true);
                                }
                              }
                              BlinkSaveOpenTabs();
                              [weakSelf.navigationController
                                  popViewControllerAnimated:YES];
                            }]];
  // Очищення одного сайту виходить з облікового запису лише на ньому.
  GURL current = _shell && _shell->web_contents()
                     ? _shell->web_contents()->GetLastCommittedURL()
                     : GURL();
  if (current.SchemeIsHTTPOrHTTPS() && !current.host().empty()) {
    NSString* title =
        [NSString stringWithFormat:BlinkL(@"Clear Data for %@"),
                                   base::SysUTF8ToNSString(current.host())];
    [alert addAction:[UIAlertAction
                         actionWithTitle:title
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction* action) {
                                   ContentShellWindowDelegate* strongSelf =
                                       weakSelf;
                                   if (!strongSelf || !strongSelf->_shell) {
                                     return;
                                   }
                                   content::BlinkClearSiteData(
                                       strongSelf->_shell->web_contents(),
                                       current);
                                   strongSelf->_shell->web_contents()
                                       ->GetController()
                                       .Reload(
                                           content::ReloadType::BYPASSING_CACHE,
                                           true);
                                 }]];
  }
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  UIViewController* host = self.presentedViewController ?: self;
  [host presentViewController:alert animated:YES completion:nil];
}

- (void)showAbout {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"ABOUT");
  NSString* appVersion =
      [NSBundle.mainBundle
          objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
          ?: BlinkL(@"Unknown");
  NSString* chromiumVersion = [NSString
      stringWithUTF8String:std::string(version_info::GetVersionNumber())
                               .c_str()];
  vc.titles = [@[
    @"Blinker Fluid", @"Chromium Engine", @"GitHub Repository",
    @"Nodesclock on GitHub", @"Monero (XMR)", @"Litecoin (LTC)"
  ] mutableCopy];
  vc.subtitles = [@[
    [NSString stringWithFormat:BlinkL(@"Version %@"), appVersion],
    [@"Chromium " stringByAppendingString:chromiumVersion],
    @"github.com/Nodesclock/Blinker-fluid", @"github.com/Nodesclock",
    @"8Ab52zsnVgzRRKp1HnhT6UWZY6GmUK67HXKZtQ8wHPMF4LXbDLiwSeJR2uHaRox71eQWxLk7BczDD1N7v9QbHWt5CK6Qtfw",
    @"ltc1q4zhq6sszzwvez79g9drzs29q9f5czdv9kcqtcc"
  ] mutableCopy];
  vc.imageNames = @[
    @"safari", @"globe", @"chevron.left.forwardslash.chevron.right",
    @"person.crop.circle", @"heart.circle", @"heart.circle"
  ];
  vc.sectionTitles = @[ @"ABOUT", @"DONATIONS, TAP TO COPY" ];
  vc.sectionStarts = @[ @0, @4 ];
  vc.disabledRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)];
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    if (row == 2) {
      [weakSelf openUserInput:@"https://github.com/Nodesclock/Blinker-fluid"];
    } else if (row == 3) {
      [weakSelf openUserInput:@"https://github.com/Nodesclock"];
    } else if (row == 4) {
      UIPasteboard.generalPasteboard.string =
          @"8Ab52zsnVgzRRKp1HnhT6UWZY6GmUK67HXKZtQ8wHPMF4LXbDLiwSeJR2uHaRox71eQ"
          @"WxLk7BczDD1N7v9QbHWt5CK6Qtfw";
      [[[UINotificationFeedbackGenerator alloc] init]
          notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (row == 5) {
      UIPasteboard.generalPasteboard.string =
          @"ltc1q4zhq6sszzwvez79g9drzs29q9f5czdv9kcqtcc";
      [[[UINotificationFeedbackGenerator alloc] init]
          notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
  };
  [self presentList:vc];
}

// Tor чи інший проксі SOCKS5 або HTTP. Застосовується перемикачем proxy-server
// на наступному запуску. SOCKS5 розв'язує імена віддалено, тож .onion працює.
- (void)showProxySettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Tor and Proxy")
                       message:
                           BlinkL(@"Enter an existing SOCKS5 or HTTP proxy supplied "
                           @"by a Tor app or server. Blinker does not bundle "
                           @"a Tor daemon. A 127.0.0.1 address works only "
                           @"while another Tor service is listening on that "
                           @"port. Use SOCKS5 for onion sites. Restart to apply. Leave blank to "
                           @"turn off.")
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField* tf) {
    tf.placeholder = @"socks5://host:port";
    tf.text = [d stringForKey:@"BlinkProxy"];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.keyboardType = UIKeyboardTypeURL;
  }];
  __weak UIAlertController* weakAlert = a;
  __weak ContentShellWindowDelegate* weakSelf = self;
  [a addAction:
          [UIAlertAction
              actionWithTitle:BlinkL(@"Save")
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction* act) {
                        NSString* v =
                            weakAlert.textFields.firstObject.text ?: @"";
                        v = [v stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
                        BOOL valid = !v.length || content::blinker_proxy::IsValid(
                            base::SysNSStringToUTF8(v));
                        if (!valid) {
                          UIAlertController* bad = [UIAlertController
                              alertControllerWithTitle:BlinkL(@"Invalid proxy")
                                               message:BlinkL(
                                                   @"Use a complete address "
                                                   @"such as "
                                                   @"socks5://127.0.0.1:9050.")
                                        preferredStyle:
                                            UIAlertControllerStyleAlert];
                          [bad addAction:
                                   [UIAlertAction
                                       actionWithTitle:BlinkL(@"OK")
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
                          UIViewController* host =
                              weakSelf.presentedViewController ?: weakSelf;
                          [host presentViewController:bad
                                             animated:YES
                                           completion:nil];
                          return;
                        }
                        if (v.length) {
                          [d setObject:v forKey:@"BlinkProxy"];
                        } else {
                          [d removeObjectForKey:@"BlinkProxy"];
                        }
                        [d synchronize];
                        UIAlertController* r = [UIAlertController
                            alertControllerWithTitle:BlinkL(@"Restart required")
                                             message:BlinkL(
                                                         @"Quit and reopen to "
                                                         @"apply.")
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [r addAction:
                                [UIAlertAction
                                    actionWithTitle:BlinkL(@"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
                        UIViewController* host =
                            weakSelf.presentedViewController ?: weakSelf;
                        [host presentViewController:r
                                           animated:YES
                                         completion:nil];
                      }]];
  [a addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [self tintMenu:a color:BlinkerTorColor()];
  UIViewController* presenter = self.presentedViewController ?: self;
  [presenter presentViewController:a animated:YES completion:nil];
}

// Домашня сторінка, свій URL (порожній значить вбудована). Читає GetStartupURL
// при старті і openNewTab для нових вкладок.
- (void)showHomepageSettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Homepage")
                       message:BlinkL(@"Custom start page URL. Leave blank for the "
                               @"built in start page. Applies to new tabs now "
                               @"and to the start page on next launch.")
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField* tf) {
    tf.placeholder = @"https://example.com";
    tf.text = [d stringForKey:@"BlinkHomepage"];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.keyboardType = UIKeyboardTypeURL;
  }];
  __weak UIAlertController* weakAlert = a;
  __weak ContentShellWindowDelegate* weakSelf = self;
  [a addAction:[UIAlertAction
                   actionWithTitle:BlinkL(@"Save")
                             style:UIAlertActionStyleDefault
                           handler:^(UIAlertAction* act) {
                             NSString* v =
                                 weakAlert.textFields.firstObject.text ?: @"";
                             v = [v
                                 stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
                             if (v.length &&
                                 [v rangeOfString:@"://"].location ==
                                     NSNotFound) {
                               v = [@"https://" stringByAppendingString:v];
                             }
                             if (v.length) {
                               [d setObject:v forKey:@"BlinkHomepage"];
                             } else {
                               [d removeObjectForKey:@"BlinkHomepage"];
                             }
                             [weakSelf showSettings];
                           }]];
  [a addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [self tintMenu:a color:BlinkLabelColor()];
  [self presentViewController:a animated:YES completion:nil];
}

// Значення як у IOSJitTier з shell_main_delegate.cc.
static const NSInteger kBlinkJITTierMin = 1;
static const NSInteger kBlinkJITTierMax = 5;
static const NSInteger kBlinkJITTierDefault = 4;

static NSString* BlinkJITTierTitle(NSInteger tier) {
  switch (tier) {
    case 0:
    case 1:
      return @"Interpreter";
    case 2:
      return @"Baseline JIT";
    case 3:
      return @"Balanced JIT";
    case 4:
      return @"Full JIT";
    case 5:
      return @"Full JIT + WebAssembly";
    default:
      return @"Interpreter";
  }
}

static NSString* BlinkJITTierDetail(NSInteger tier) {
  switch (tier) {
    case 0:
    case 1:
      return @"No compiled code. Slowest, and the most thoroughly tested.";
    case 2:
      return @"Sparkplug compiles each function once, without speculation.";
    case 3:
      return @"Adds the Maglev optimizer and the regular expression compiler.";
    case 4:
      return @"Adds TurboFan, V8's top optimizing compiler.";
    case 5:
      return @"Also compiles WebAssembly instead of interpreting it.";
    default:
      return @"";
  }
}

static BOOL BlinkIsJITBundle() {
  NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
  return bundleID.length &&
         [[bundleID componentsSeparatedByString:@"."] containsObject:@"jit"];
}

static NSInteger BlinkCurrentJITTier(void) {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  if (![d objectForKey:@"BlinkJITTier"]) {
    return kBlinkJITTierDefault;
  }
  NSInteger tier = [d integerForKey:@"BlinkJITTier"];
  return MIN(MAX(tier, (NSInteger)0), kBlinkJITTierMax);
}

// Рівень, що працює насправді. JIT дозволений лиш bundle id blinkerfluid.jit,
// тож стабільний пакет завжди без JIT, хай що в налаштуванні.
static NSInteger BlinkEffectiveJITTier(void) {
  return BlinkIsJITBundle() ? BlinkCurrentJITTier() : kBlinkJITTierMin;
}

- (void)showJavaScriptEngineMenu:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"JavaScript Engine");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSNumber*>* tiers = [NSMutableArray array];
  const BOOL jitBundle = BlinkIsJITBundle();
  // Рівень 0 сторож збою ставить сам. Це той самий інтерпретатор.
  NSInteger current = MAX(BlinkEffectiveJITTier(), kBlinkJITTierMin);
  for (NSInteger tier = kBlinkJITTierMin; tier <= kBlinkJITTierMax; ++tier) {
    [tiers addObject:@(tier)];
    [vc.titles addObject:BlinkJITTierTitle(tier)];
    // Пояснюєм чому рівень недоступний, а не просто сірим.
    [vc.subtitles addObject:(!jitBundle && tier > kBlinkJITTierMin)
                                ? BlinkL(@"Requires the JIT build")
                                : BlinkJITTierDetail(tier)];
  }
  NSInteger selectedRow = [tiers indexOfObject:@(current)];
  if (selectedRow != NSNotFound) {
    vc.checkedRows = [NSIndexSet indexSetWithIndex:selectedRow];
  }
  if (!jitBundle) {
    vc.disabledRows =
        [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, tiers.count - 1)];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakEngine = vc;
  __weak BlinkListVC* weakSettings = settings;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(tiers.count)) {
      return;
    }
    NSInteger tier = tiers[row].integerValue;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:tier forKey:@"BlinkJITTier"];
    [defaults setInteger:-1 forKey:@"BlinkJITTierProbe"];
    [defaults removeObjectForKey:@"BlinkJITTierGuardBuild"];
    [defaults removeObjectForKey:@"BlinkJITTierBeforeGuard"];
    [defaults synchronize];
    weakSettings.subtitles[BlinkSettingsRowJavaScript] =
        BlinkJITTierTitle(tier);
    weakEngine.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakSettings.tableView reloadData];
    [weakEngine.tableView reloadData];
    // На стабільному пакеті можна вибрати лиш поточний рівень, тож питання
    // про перезапуск обіцяло б зміну, якої не буде.
    if (jitBundle) {
      [weakSelf showJITTierChangedAlert:tier];
    }
  };
  [self presentList:vc];
}

- (void)showJITTierChangedAlert:(NSInteger)tier {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkJITTierTitle(tier)
                       message:[NSString
                                   stringWithFormat:@"%@\n\n%@",
                                                    BlinkJITTierDetail(tier),
                                                    BlinkL(@"Quit and reopen "
                                                           @"to apply.")]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"OK")
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self tintMenu:alert color:BlinkLabelColor()];
  UIViewController* presenter = self.presentedViewController ?: self;
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)showAppearanceMenu {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Appearance");
  vc.dismissOnSelect = NO;
  vc.titles =
      [@[ BlinkL(@"System"), BlinkL(@"Light"), BlinkL(@"Dark") ] mutableCopy];
  vc.subtitles = [@[ @"", @"", @"" ] mutableCopy];
  NSArray<NSNumber*>* styles = @[
    @(UIUserInterfaceStyleUnspecified), @(UIUserInterfaceStyleLight),
    @(UIUserInterfaceStyleDark)
  ];
  NSInteger current =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"BlinkAppearance"];
  NSInteger selectedRow = [styles indexOfObject:@(current)];
  if (selectedRow != NSNotFound) {
    vc.checkedRows = [NSIndexSet indexSetWithIndex:selectedRow];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakAppearance = vc;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(styles.count)) {
      return;
    }
    UIUserInterfaceStyle style =
        static_cast<UIUserInterfaceStyle>(styles[row].integerValue);
    for (content::Shell* shell : content::Shell::windows()) {
      UIWindow* window = shell->window().Get();
      if (window) {
        if (@available(iOS 13.0, *)) {
          window.overrideUserInterfaceStyle = style;
        }
      }
    }
    [weakSelf applyWebColorScheme:style];
    [[NSUserDefaults standardUserDefaults] setInteger:style
                                               forKey:@"BlinkAppearance"];
    weakAppearance.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakAppearance.tableView reloadData];
  };
  [self presentList:vc];
}

// Примусовий prefers-color-scheme для сторінок через NativeTheme, щоб сайти
// малювали свою темну чи світлу тему.
- (void)applyWebColorScheme:(UIUserInterfaceStyle)style {
  BlinkSetWebColorScheme(BlinkResolvedWebStyle(style));
  // Перезавантажуєм справжні сторінки, щоб media query спрацював одразу.
  for (content::Shell* shell : content::Shell::windows()) {
    if (!shell->web_contents()) {
      continue;
    }
    GURL url = shell->web_contents()->GetLastCommittedURL();
    if (url.SchemeIsHTTPOrHTTPS()) {
      shell->web_contents()->GetController().Reload(content::ReloadType::NORMAL,
                                                    true);
    }
  }
}

- (void)toggleDesktopSite {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  if (content::BlinkShellTabIsInAuthFlow(_shell->web_contents())) {
    // Не міняємо UA під час переходів входу, це ламає вхід Google.
    BLINKER_DIAG("AUTH_FLOW: site mode locked during auth");
    BLINKER_DIAG("AUTH_FLOW: user agent stable during auth");
    return;
  }
  BLINKER_DIAG("SITE_MODE: button toggled");
  const bool setDesktop = !content::BlinkIsDesktopSite(_shell->web_contents());
  GURL current = _shell->web_contents()->GetLastCommittedURL();
  if (!current.is_valid()) {
    current = _shell->web_contents()->GetVisibleURL();
  }
  // Спершу Stop, щоб Chromium не перезавантажив сторінку зі старим флагом UA
  // override.
  _shell->web_contents()->Stop();
  content::BlinkSetSiteMode(_shell->web_contents(), current, setDesktop);
  if (current.is_valid() && current.SchemeIsHTTPOrHTTPS()) {
    _shell->LoadURL(content::BlinkURLForSiteMode(current, setDesktop));
  }
}

// iOS крутить лиш у ті орієнтації, які дозволяє view controller, тож блок
// орієнтації сторінки треба віддати тут.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return BlinkSupportedOrientations();
}

- (UIActivityIndicatorView*)pullToRefreshSpinner {
  if (_pullSpinner) {
    return _pullSpinner;
  }
  if (!_contentView) {
    // Constraints з nil anchor кидають виняток, а до ієрархії view чіплятись
    // нема до чого.
    return nil;
  }
  UIActivityIndicatorViewStyle spinnerStyle = UIActivityIndicatorViewStyleGray;
  if (@available(iOS 13.0, *)) {
    spinnerStyle = UIActivityIndicatorViewStyleMedium;
  }
  _pullSpinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:spinnerStyle];
  _pullSpinner.color = BlinkerAccentColor();
  _pullSpinner.hidesWhenStopped = NO;
  _pullSpinner.alpha = 0;
  _pullSpinner.translatesAutoresizingMaskIntoConstraints = NO;
  [_contentView addSubview:_pullSpinner];
  [NSLayoutConstraint activateConstraints:@[
    [_pullSpinner.centerXAnchor
        constraintEqualToAnchor:_contentView.centerXAnchor],
    [_pullSpinner.topAnchor constraintEqualToAnchor:_contentView.topAnchor
                                           constant:18],
  ]];
  return _pullSpinner;
}

- (void)updatePullToRefreshProgress:(CGFloat)progress {
  UIActivityIndicatorView* spinner = [self pullToRefreshSpinner];
  if (!spinner) {
    return;
  }
  [_contentView bringSubviewToFront:spinner];
  progress = MAX(0, progress);
  spinner.alpha = MIN(progress * 2, 1.0);
  // Видимий опір, індикатор їде втричі повільніше за палець і стає на 60pt,
  // коли готовий до refresh.
  spinner.transform = CGAffineTransformRotate(
      CGAffineTransformMakeTranslation(0, MIN(progress, 1.0) * 60),
      MIN(progress, 1.0) * (CGFloat)M_PI * 1.5);
}

- (void)finishPullToRefresh:(BOOL)triggered {
  UIActivityIndicatorView* spinner = [self pullToRefreshSpinner];
  if (!spinner) {
    return;
  }
  if (triggered) {
    spinner.transform = CGAffineTransformIdentity;
    [spinner startAnimating];
    BLINKER_DIAG("PULL_REFRESH: threshold reached, reloading");
    // Не reloadOrStop, бо ця кнопка перемикач і pull під час довгого
    // завантаження скасував би його.
    if (_shell && _shell->web_contents()) {
      _shell->web_contents()->GetController().Reload(
          content::ReloadType::NORMAL, /*check_for_repost=*/true);
    }
  }
  [UIView animateWithDuration:0.25
      animations:^{
        spinner.alpha = 0;
      }
      completion:^(BOOL finished) {
        [spinner stopAnimating];
        spinner.transform = CGAffineTransformIdentity;
      }];
}

- (void)setContents:(UIView*)content {
  // Слідкуємо за контейнером. Інакше зміна розміру, якої не почав Chromium,
  // лишала б старий кадр і темний фон довкола.
  content.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  content.frame = _contentView.bounds;
  [_contentView addSubview:content];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:
           (id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [coordinator
      animateAlongsideTransition:nil
                      completion:^(
                          id<UIViewControllerTransitionCoordinatorContext>
                              context) {
                        ContentShellWindowDelegate* strongSelf = weakSelf;
                        if (!strongSelf || !strongSelf->_shell ||
                            !strongSelf->_shell->web_contents()) {
                          return;
                        }
                        UIView* webView = strongSelf->_shell->web_contents()
                                              ->GetNativeView()
                                              .Get();
                        webView.frame = strongSelf.contentView.bounds;
                        [strongSelf.view setNeedsLayout];
                        [strongSelf.view layoutIfNeeded];
                        content::RenderFrameHost* main_frame =
                            strongSelf->_shell->web_contents()
                                ->GetPrimaryMainFrame();
                        if (!main_frame || !main_frame->GetRenderViewHost()) {
                          return;
                        }
                        content::RenderWidgetHost* widget =
                            main_frame->GetRenderViewHost()->GetWidget();
                        if (!widget) {
                          return;
                        }
                        if (widget->GetView()) {
                          widget->GetView()->SetBounds(
                              gfx::Rect(0, 0, lround(webView.bounds.size.width),
                                        lround(webView.bounds.size.height)));
                        }
                        static_cast<content::RenderWidgetHostImpl*>(widget)
                            ->SynchronizeVisualPropertiesIgnoringPendingAck();
                        // Сцена закінчує поворот після першого UIDevice
                        // сповіщення, тож орієнтацію шлем ще раз.
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:
                                UIDeviceOrientationDidChangeNotification
                                          object:UIDevice.currentDevice];
                        base::WeakPtr<content::WebContents> rotated_contents =
                            strongSelf->_shell->web_contents()->GetWeakPtr();
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          50 * NSEC_PER_MSEC),
                            dispatch_get_main_queue(), ^{
                              if (!rotated_contents) {
                                return;
                              }
                              content::RenderFrameHost* final_frame =
                                  rotated_contents->GetPrimaryMainFrame();
                              if (!final_frame ||
                                  !final_frame->GetRenderViewHost()) {
                                return;
                              }
                              content::RenderWidgetHost* final_widget =
                                  final_frame->GetRenderViewHost()->GetWidget();
                              if (final_widget && final_widget->GetView()) {
                                static_cast<content::RenderWidgetHostViewIOS*>(
                                    final_widget->GetView())
                                    ->UpdateScreenInfo();
                                static_cast<content::RenderWidgetHostImpl*>(
                                    final_widget)
                                    ->SynchronizeVisualPropertiesIgnoringPendingAck();
                                BLINKER_DIAG("FULLSCREEN_LAYOUT: final "
                                             "ScreenInfo refreshed");
                              }
                            });
                        if (strongSelf->_shell->IsFullscreenForTabOrPending(
                                strongSelf->_shell->web_contents())) {
                          if (@available(iOS 16.0, *)) {
                            strongSelf->_shell->web_contents()->WasHidden();
                            strongSelf->_shell->web_contents()->WasShown();
                          } else {
                            // На iOS 15 перемикання видимості заморожує відео,
                            // тож після повороту просимо нову поверхню.
                            static_cast<content::RenderWidgetHostImpl*>(widget)
                                ->RequestRepaintOnNewSurface();
                            BLINKER_DIAG("FULLSCREEN_LAYOUT: iOS 15 final "
                                         "rotation surface refreshed");
                          }
                        }
                        BLINKER_DIAGF("FULLSCREEN_LAYOUT: rotation completed "
                                      "target=%.0fx%.0f "
                                      "content=%.0fx%.0f web=%.0fx%.0f",
                                      size.width, size.height,
                                      strongSelf.contentView.bounds.size.width,
                                      strongSelf.contentView.bounds.size.height,
                                      webView.bounds.size.width,
                                      webView.bounds.size.height);
                      }];
}

// Надійно фарбує текст опцій alert/action sheet (сам tintColor не завжди
// тримається). Destructive лишаються червоними.
- (void)tintMenu:(UIAlertController*)menu color:(UIColor*)color {
  menu.view.tintColor = color;
  for (UIAlertAction* action in menu.actions) {
    if (action.style != UIAlertActionStyleDestructive) {
      [action setValue:color forKey:@"titleTextColor"];
    }
  }
}

- (void)voiceOverStatusDidChange {
  content::BrowserAccessibilityState* accessibility_state =
      content::BrowserAccessibilityState::GetInstance();
  if (UIAccessibilityIsVoiceOverRunning()) {
    _scopedAccessibilityMode = accessibility_state->CreateScopedModeForProcess(
        kVoiceOverEnabledAXMode);
  } else {
    _scopedAccessibilityMode.reset();
  }
}
@end

extern "C" void BlinkActivateShell(content::Shell* shell) {
  UIWindow* window = shell ? shell->window().Get() : nil;
  if ([window.rootViewController
          isKindOfClass:[ContentShellWindowDelegate class]]) {
    [(ContentShellWindowDelegate*)window.rootViewController
        showTabWindow:shell];
  }
}

@implementation TracingHandler

- (void)startWithHandler:(void (^)())startHandler
             stopHandler:(void (^)())stopHandler
              categories:(const char*)categories {
  int i = 0;
  NSString* filename;
  NSFileManager* fileManager = [NSFileManager defaultManager];
  NSString* path = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES)[0];

  do {
    filename =
        [path stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"trace_%d.pftrace.gz", i++]];
  } while ([fileManager fileExistsAtPath:filename]);

  if (![fileManager createFileAtPath:filename contents:nil attributes:nil]) {
    NSLog(@"Failed to create tracefile: %@", filename);
    return;
  }

  _traceFileHandle = [NSFileHandle fileHandleForWritingAtPath:filename];
  if (_traceFileHandle == nil) {
    NSLog(@"Failed to open tracefile: %@", filename);
    return;
  }

  NSLog(@"Will trace to file: %@", filename);

  perfetto::TraceConfig perfettoConfig = tracing::GetDefaultPerfettoConfig(
      base::trace_event::TraceConfig(categories, ""),
      /*privacy_filtering_enabled=*/false,
      /*convert_to_legacy_json=*/true);

  perfettoConfig.set_write_into_file(true);
  _tracingSession =
      perfetto::Tracing::NewTrace(perfetto::BackendType::kCustomBackend);

  _tracingSession->Setup(perfettoConfig, [_traceFileHandle fileDescriptor]);

  __weak TracingHandler* weakSelf = self;
  auto runner = base::SequencedTaskRunner::GetCurrentDefault();

  _tracingSession->SetOnStartCallback([runner, startHandler]() {
    runner->PostTask(FROM_HERE, base::BindOnce(^{
                       startHandler();
                     }));
  });

  _tracingSession->SetOnStopCallback([runner, weakSelf, stopHandler]() {
    runner->PostTask(FROM_HERE, base::BindOnce(^{
                       [weakSelf onStopped];
                       stopHandler();
                     }));
  });

  _tracingSession->Start();
}

- (void)stop {
  _tracingSession->Stop();
}

- (void)onStopped {
  [_traceFileHandle closeFile];
  _traceFileHandle = nil;
  _tracingSession.reset();
}

- (id)init {
  _traceFileHandle = nil;
  return self;
}

- (BOOL)isTracing {
  return !!_tracingSession.get();
}

@end

namespace content {

struct ShellPlatformDelegate::ShellData {
  UIWindow* window;
  bool fullscreen = false;
};

struct ShellPlatformDelegate::PlatformData {};

ShellPlatformDelegate::ShellPlatformDelegate() = default;
ShellPlatformDelegate::~ShellPlatformDelegate() = default;

}  // namespace content

namespace content {

namespace {

// alert, confirm, prompt і "Покинути сторінку?". Сам content shell на iOS їх
// мовчки глушить, тож confirm завжди вертав false.
class BlinkerJavaScriptDialogManager : public JavaScriptDialogManager {
 public:
  explicit BlinkerJavaScriptDialogManager(Shell* shell) : shell_(shell) {}
  ~BlinkerJavaScriptDialogManager() override { Dismiss(); }

  void RunJavaScriptDialog(WebContents* web_contents,
                           RenderFrameHost* render_frame_host,
                           JavaScriptDialogType dialog_type,
                           const std::u16string& message_text,
                           const std::u16string& default_prompt_text,
                           DialogClosedCallback callback,
                           bool* did_suppress_message) override {
    if (callback_ || suppressed_ || !CanShow()) {
      *did_suppress_message = true;
      return;
    }
    *did_suppress_message = false;
    ++dialogs_on_page_;
    const GURL origin =
        render_frame_host ? render_frame_host->GetLastCommittedOrigin().GetURL()
                          : web_contents->GetLastCommittedURL();
    NSString* host = base::SysUTF8ToNSString(origin.host());
    NSString* title =
        host.length ? [NSString stringWithFormat:BlinkL(@"%@ says"), host]
                    : nil;
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:title
                         message:base::SysUTF16ToNSString(message_text)
                  preferredStyle:UIAlertControllerStyleAlert];
    const int token = ++token_;
    callback_ = std::move(callback);
    base::WeakPtr<BlinkerJavaScriptDialogManager> weak =
        weak_factory_.GetWeakPtr();
    __weak UIAlertController* weakAlert = alert;
    if (dialog_type == JAVASCRIPT_DIALOG_TYPE_PROMPT) {
      NSString* initial = base::SysUTF16ToNSString(default_prompt_text);
      [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = initial;
      }];
    }
    if (dialog_type != JAVASCRIPT_DIALOG_TYPE_ALERT) {
      [alert addAction:[UIAlertAction
                           actionWithTitle:BlinkL(@"Cancel")
                                     style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction*) {
                                     if (weak) {
                                       weak->Finish(token, false, u"");
                                     }
                                   }]];
    }
    const bool prompt = dialog_type == JAVASCRIPT_DIALOG_TYPE_PROMPT;
    [alert addAction:[UIAlertAction
                         actionWithTitle:BlinkL(@"OK")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction*) {
                                   std::u16string input;
                                   if (prompt) {
                                     input = base::SysNSStringToUTF16(
                                         weakAlert.textFields.firstObject.text
                                             ?: @"");
                                   }
                                   if (weak) {
                                     weak->Finish(token, true, input);
                                   }
                                 }]];
    // Сторінка, що сипле діалог за діалогом, інакше не дала б нічого робити.
    if (dialogs_on_page_ > 2) {
      [alert addAction:[UIAlertAction
                           actionWithTitle:BlinkL(@"Block More Dialogs")
                                     style:UIAlertActionStyleDestructive
                                   handler:^(UIAlertAction*) {
                                     if (weak) {
                                       weak->suppressed_ = true;
                                       weak->Finish(token, false, u"");
                                     }
                                   }]];
    }
    alert_ = alert;
    Show(alert, token, 0);
  }

  void RunBeforeUnloadDialog(WebContents* web_contents,
                             RenderFrameHost* render_frame_host,
                             bool is_reload,
                             DialogClosedCallback callback) override {
    if (callback_ || !CanShow()) {
      std::move(callback).Run(true, std::u16string());
      return;
    }
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:is_reload ? BlinkL(@"Reload this site?")
                                           : BlinkL(@"Leave this site?")
                         message:BlinkL(@"Changes you made may not be saved.")
                  preferredStyle:UIAlertControllerStyleAlert];
    const int token = ++token_;
    callback_ = std::move(callback);
    base::WeakPtr<BlinkerJavaScriptDialogManager> weak =
        weak_factory_.GetWeakPtr();
    [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction*) {
                                              if (weak) {
                                                weak->Finish(token, false, u"");
                                              }
                                            }]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:is_reload ? BlinkL(@"Reload")
                                                   : BlinkL(@"Leave")
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction*) {
                                   if (weak) {
                                     weak->Finish(token, true, u"");
                                   }
                                 }]];
    alert_ = alert;
    Show(alert, token, 0);
  }

  bool HandleJavaScriptDialog(WebContents* web_contents,
                              bool accept,
                              const std::u16string* prompt_override) override {
    if (!callback_) {
      return false;
    }
    std::u16string input;
    if (prompt_override) {
      input = *prompt_override;
    } else if (alert_.textFields.firstObject) {
      input = base::SysNSStringToUTF16(alert_.textFields.firstObject.text ?: @"");
    }
    Finish(token_, accept, input);
    return true;
  }

  void CancelDialogs(WebContents* web_contents, bool reset_state) override {
    if (callback_) {
      Finish(token_, false, u"");
    }
    if (reset_state) {
      suppressed_ = false;
      dialogs_on_page_ = 0;
    }
  }

 private:
  // Фонова вкладка діалогу не показує, як і Chrome не показує його поверх
  // іншої вкладки.
  bool CanShow() {
    UIWindow* window = shell_ ? shell_->window().Get() : nil;
    return window && !window.hidden && window.rootViewController;
  }

  // Поки попередній алерт ще ховається, UIKit новий мовчки не покаже і
  // сторінка висіла б, тож чекаєм кінця анімації.
  void Show(UIAlertController* alert, int token, int attempt) {
    if (token != token_ || !callback_) {
      return;
    }
    UIWindow* window = shell_ ? shell_->window().Get() : nil;
    UIViewController* top = window.rootViewController;
    while (top.presentedViewController) {
      top = top.presentedViewController;
    }
    const bool busy = top.isBeingDismissed || top.isBeingPresented;
    if (!top || (!busy && [top isKindOfClass:UIAlertController.class])) {
      BLINKER_LOG("JS_DIALOG: another alert is showing, answered as cancel");
      Finish(token, false, u"");
      return;
    }
    base::WeakPtr<BlinkerJavaScriptDialogManager> weak =
        weak_factory_.GetWeakPtr();
    if (busy) {
      if (attempt > 30) {
        BLINKER_LOG("JS_DIALOG: presentation never settled, answered as cancel");
        Finish(token, false, u"");
        return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
                       if (weak) {
                         weak->Show(alert, token, attempt + 1);
                       }
                     });
      return;
    }
    [top presentViewController:alert
                      animated:YES
                    completion:^{
                      // Відповідь могла прийти ще під час появи.
                      if (!weak || weak->token_ != token || !weak->callback_) {
                        [alert dismissViewControllerAnimated:NO
                                                  completion:nil];
                      }
                    }];
  }

  void Finish(int token, bool ok, const std::u16string& input) {
    if (token != token_ || !callback_) {
      return;
    }
    UIAlertController* alert = alert_;
    alert_ = nil;
    if (alert.presentingViewController && !alert.isBeingDismissed) {
      [alert dismissViewControllerAnimated:NO completion:nil];
    }
    std::move(callback_).Run(ok, input);
  }

  void Dismiss() {
    UIAlertController* alert = alert_;
    alert_ = nil;
    if (alert.presentingViewController) {
      [alert dismissViewControllerAnimated:NO completion:nil];
    }
    if (callback_) {
      std::move(callback_).Run(false, std::u16string());
    }
  }

  raw_ptr<Shell> shell_;
  DialogClosedCallback callback_;
  UIAlertController* __strong alert_ = nil;
  int token_ = 0;
  int dialogs_on_page_ = 0;
  bool suppressed_ = false;
  base::WeakPtrFactory<BlinkerJavaScriptDialogManager> weak_factory_{this};
};

}  // namespace

std::unique_ptr<JavaScriptDialogManager>
ShellPlatformDelegate::CreateJavaScriptDialogManager(Shell* shell) {
  return std::make_unique<BlinkerJavaScriptDialogManager>(shell);
}

std::string BlinkerLocalizedUTF8(std::string_view english) {
  @autoreleasepool {
    return base::SysNSStringToUTF8(BlinkL(base::SysUTF8ToNSString(english)));
  }
}

std::string BlinkerInterfaceLanguage() {
  @autoreleasepool {
    NSString* accept = [[NSUserDefaults standardUserDefaults]
                           stringForKey:@"BlinkLanguageAccept"]
                           ?: @"en-US,en";
    NSString* code = [[[accept componentsSeparatedByString:@","] firstObject]
                         componentsSeparatedByString:@"-"]
                         .firstObject.lowercaseString;
    return code.length ? base::SysNSStringToUTF8(code) : std::string("en");
  }
}

}  // namespace content

extern "C" void BlinkTabAudioStateChanged(content::Shell* shell) {
  UIWindow* window = shell ? shell->window().Get() : nil;
  if ([window.rootViewController
          isKindOfClass:[ContentShellWindowDelegate class]]) {
    [(ContentShellWindowDelegate*)window.rootViewController updateSiteButtons];
  }
}

namespace content {

void ShellPlatformDelegate::Initialize(const gfx::Size& default_window_size) {
  screen_ = std::make_unique<display::ScopedNativeScreen>();
  // Старі збірки брали аватаркою довільну картинку користувача Google.
  // Збережену так один раз прибираєм, справжня підтягнеться знову.
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if (![defaults boolForKey:@"BlinkGoogleAvatarFromAccountFrames"]) {
    [defaults removeObjectForKey:@"BlinkGoogleAvatarURL"];
    [defaults removeObjectForKey:@"BlinkGoogleSecondaryAvatarURL"];
    [NSFileManager.defaultManager removeItemAtPath:BlinkGoogleAvatarPath()
                                             error:nil];
    [NSFileManager.defaultManager
        removeItemAtPath:BlinkGoogleSecondaryAvatarPath()
                   error:nil];
    [defaults setBool:YES forKey:@"BlinkGoogleAvatarFromAccountFrames"];
  }
}

void ShellPlatformDelegate::CreatePlatformWindow(
    Shell* shell,
    const gfx::Size& initial_size) {
  BLINKER_DIAG("C1: ShellPlatformDelegate::CreatePlatformWindow");
  size_t active_frames = 0;
  for (content::Shell* window : content::Shell::windows()) {
    content::WebContents* contents = window->web_contents();
    if (contents && contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
      ++active_frames;
    }
  }
  const GURL last_url = shell && shell->web_contents()
                            ? shell->web_contents()->GetVisibleURL()
                            : GURL();
  BLINKER_DIAGF("C1a: CreatePlatformWindow web_contents=%zu active_frames=%zu "
                "last_url=%s",
                content::Shell::windows().size(), active_frames,
                content::blinker_logging::LoggableURLSpec(last_url).c_str());
  DCHECK(!shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  UIWindow* window =
      [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  // Темний, а не білий, щоб між вкладками не блимало білим.
  window.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
  // tintColor системний, курсор і виділення на сайтах видно і на білому, і на
  // темному. Помаранчевий лишається лиш на головній.

  static dispatch_once_t kiosk_once;
  dispatch_once(&kiosk_once, ^{
    g_blink_kiosk_mode =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkKioskMode"];
    UIApplication.sharedApplication.idleTimerDisabled = g_blink_kiosk_mode;
  });
  ContentShellWindowDelegate* controller =
      [[ContentShellWindowDelegate alloc] initWithShell:shell];
  // Gives a restoration identifier so that state restoration works.
  controller.restorationIdentifier = @"rootViewController";
  window.rootViewController = controller;

  shell_data.window = window;
}

gfx::NativeWindow ShellPlatformDelegate::GetNativeWindow(Shell* shell) {
  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  return gfx::NativeWindow(shell_data.window);
}

void ShellPlatformDelegate::CleanUp(Shell* shell) {
  g_crash_restore_urls.erase(shell);
  g_crash_restore_inflight.erase(shell);
  DCHECK(shell_data_map_.contains(shell));
  shell_data_map_.erase(shell);
}

void ShellPlatformDelegate::SetContents(Shell* shell) {
  DCHECK(shell_data_map_.contains(shell));
  BlinkFinishFreshStart();
  //  ShellData& shell_data = shell_data_map_[shell];

  //  UIView* web_contents_view = shell->web_contents()->GetNativeView();
  //  [((ContentShellWindowDelegate *)shell_data.window.rootViewController)
  //  setContents:web_contents_view];
}

void ShellPlatformDelegate::ResizeWebContent(Shell* shell,
                                             const gfx::Size& content_size) {
  DCHECK(shell_data_map_.contains(shell));
}

void ShellPlatformDelegate::EnableUIControl(Shell* shell,
                                            UIControl control,
                                            bool is_enabled) {
  if (content::Shell::ShouldHideToolbar()) {
    return;
  }

  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];
  UIButton* button = nil;
  switch (control) {
    case BACK_BUTTON:
      button = [((ContentShellWindowDelegate*)
                     shell_data.window.rootViewController) backButton];
      break;
    case FORWARD_BUTTON:
      button = [((ContentShellWindowDelegate*)
                     shell_data.window.rootViewController) forwardButton];
      break;
    case STOP_BUTTON: {
      NSString* imageName = is_enabled ? @"ic_stop" : @"ic_reload";
      [[((ContentShellWindowDelegate*)shell_data.window.rootViewController)
          reloadOrStopButton] setImage:[UIImage imageNamed:imageName]
                              forState:UIControlStateNormal];
      break;
    }
    default:
      NOTREACHED() << "Unknown UI control";
  }
  [button setEnabled:is_enabled];
}

void ShellPlatformDelegate::SetAddressBarURL(Shell* shell, const GURL& url) {
  if (shell->web_contents()->GetLastCommittedURL() == url) {
    g_crash_restore_inflight.erase(shell);
  }
  if (Shell::ShouldHideToolbar()) {
    return;
  }
  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  NSString* url_string = base::SysUTF8ToNSString(url.spec());
  [((ContentShellWindowDelegate*)shell_data.window.rootViewController)
      setURL:url_string];

  // Адреса змінюється і при навігаціях усередині сторінки, тож запис
  // відкладається, поки вони не вщухнуть.
  static base::NoDestructor<base::OneShotTimer> save_timer;
  save_timer->Start(FROM_HERE, base::Seconds(1),
                    base::BindOnce([] { BlinkSaveOpenTabs(); }));
}

void ShellPlatformDelegate::SetIsLoading(Shell* shell, bool loading) {
  if (!shell) {
    return;
  }
  UIWindow* window = shell->window().Get();
  if ([window.rootViewController
          isKindOfClass:[ContentShellWindowDelegate class]]) {
    ContentShellWindowDelegate* delegate =
        (ContentShellWindowDelegate*)window.rootViewController;
    [delegate setPageLoading:loading];
  }
}

void ShellPlatformDelegate::SetTitle(Shell* shell,
                                     const std::u16string& title) {
  DCHECK(shell_data_map_.contains(shell));
}

void ShellPlatformDelegate::MainFrameCreated(Shell* shell,
                                             RenderFrameHost* main_frame) {}

bool ShellPlatformDelegate::DestroyShell(Shell* shell) {
  ForgetPendingRestoreURL(shell);
  [BlinkTabPreviewCache() removeObjectForKey:[NSValue valueWithPointer:shell]];
  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  [shell_data.window resignKeyWindow];
  return false;  // We have not destroyed the shell here.
}

std::unique_ptr<ColorChooser> ShellPlatformDelegate::OpenColorChooser(
    WebContents* web_contents,
    SkColor color,
    const std::vector<blink::mojom::ColorSuggestionPtr>& suggestions) {
  return ShellColorChooserIOS::OpenColorChooser(web_contents, color,
                                                suggestions);
}

void ShellPlatformDelegate::RunFileChooser(
    RenderFrameHost* render_frame_host,
    scoped_refptr<FileSelectListener> listener,
    const blink::mojom::FileChooserParams& params) {
  ShellFileSelectHelper::RunFileChooser(render_frame_host, std::move(listener),
                                        params);
}

}  // namespace content

namespace content {

std::string BlinkCaptureVisibleTab(Shell* shell, bool png, int quality) {
  UIWindow* window = shell ? shell->window().Get() : nil;
  UIImage* image = nil;
  if (window && !window.hidden && !CGRectIsEmpty(window.bounds)) {
    ContentShellWindowDelegate* delegate =
        static_cast<ContentShellWindowDelegate*>(window.rootViewController);
    UIView* view =
        [delegate isKindOfClass:[ContentShellWindowDelegate class]] &&
                delegate.contentView
            ? delegate.contentView
            : window;
    UIGraphicsImageRenderer* renderer =
        [[UIGraphicsImageRenderer alloc] initWithBounds:view.bounds];
    image = [renderer imageWithActions:^(UIGraphicsImageRendererContext*) {
      [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
    }];
  } else if (shell) {
    // Сторінка під попапом схована, тож береться останнє прев'ю вкладки.
    image = [BlinkTabPreviewCache()
        objectForKey:[NSValue valueWithPointer:shell]];
  }
  NSData* data = !image ? nil
                 : png  ? UIImagePNGRepresentation(image)
                        : UIImageJPEGRepresentation(image, quality / 100.0);
  if (!data.length) {
    return std::string();
  }
  return std::string(png ? "data:image/png;base64," : "data:image/jpeg;base64,") +
         base::SysNSStringToUTF8([data base64EncodedStringWithOptions:0]);
}

}  // namespace content

namespace {

// Закладки браузера як дерево chrome.bookmarks. id з'являються ліниво і
// зберігаються у самих записах, тож UI закладок працює як раніше.
NSString* const kBlinkBookmarksKey = @"BlinkBookmarks";
NSString* const kBlinkOtherBookmarksKey = @"BlinkOtherBookmarks";
NSString* const kBlinkBookmarkNextIdKey = @"BlinkBookmarkNextId";

NSMutableArray* BxLoad(NSString* key) {
  NSArray* saved = [[NSUserDefaults standardUserDefaults] arrayForKey:key];
  NSData* data =
      saved ? [NSPropertyListSerialization
                  dataWithPropertyList:saved
                                format:NSPropertyListBinaryFormat_v1_0
                               options:0
                                 error:nil]
            : nil;
  NSMutableArray* items =
      data ? [NSPropertyListSerialization
                 propertyListWithData:data
                              options:NSPropertyListMutableContainers
                               format:nil
                                error:nil]
           : nil;
  return [items isKindOfClass:NSMutableArray.class] ? items
                                                     : [NSMutableArray array];
}

NSString* BxNextId() {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  const NSInteger next = MAX(100, [d integerForKey:kBlinkBookmarkNextIdKey]);
  [d setInteger:next + 1 forKey:kBlinkBookmarkNextIdKey];
  return [NSString stringWithFormat:@"%ld", static_cast<long>(next)];
}

BOOL BxEnsureIds(NSMutableArray* items) {
  BOOL changed = NO;
  for (id item in items) {
    if (![item isKindOfClass:NSMutableDictionary.class]) {
      continue;
    }
    NSMutableDictionary* node = item;
    if (![node[@"id"] isKindOfClass:NSString.class]) {
      node[@"id"] = BxNextId();
      changed = YES;
    }
    if (!node[@"dateAdded"]) {
      node[@"dateAdded"] = @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0));
      changed = YES;
    }
    if ([node[@"children"] isKindOfClass:NSMutableArray.class]) {
      changed |= BxEnsureIds(node[@"children"]);
    }
  }
  return changed;
}

struct BxTree {
  NSMutableArray* bar;
  NSMutableArray* other;
};

BxTree BxLoadTree() {
  BxTree tree{BxLoad(kBlinkBookmarksKey), BxLoad(kBlinkOtherBookmarksKey)};
  const BOOL barChanged = BxEnsureIds(tree.bar);
  const BOOL otherChanged = BxEnsureIds(tree.other);
  if (barChanged || otherChanged) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setObject:tree.bar forKey:kBlinkBookmarksKey];
    [d setObject:tree.other forKey:kBlinkOtherBookmarksKey];
  }
  return tree;
}

void BxSave(const BxTree& tree) {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setObject:tree.bar forKey:kBlinkBookmarksKey];
  [d setObject:tree.other forKey:kBlinkOtherBookmarksKey];
}

BOOL BxIsFolder(NSDictionary* node) {
  return node[@"url"] == nil;
}

NSMutableArray* BxRootChildren(const BxTree& tree, NSString* folder_id) {
  if ([folder_id isEqualToString:@"1"]) {
    return tree.bar;
  }
  if ([folder_id isEqualToString:@"2"]) {
    return tree.other;
  }
  return nil;
}

// Батьківський список, індекс і id батька для вузла.
BOOL BxFind(NSMutableArray* items,
            NSString* parent_id,
            NSString* node_id,
            NSMutableArray** out_items,
            NSUInteger* out_index,
            NSString** out_parent) {
  for (NSUInteger i = 0; i < items.count; ++i) {
    NSMutableDictionary* node = items[i];
    if (![node isKindOfClass:NSMutableDictionary.class]) {
      continue;
    }
    if ([node[@"id"] isEqualToString:node_id]) {
      *out_items = items;
      *out_index = i;
      *out_parent = parent_id;
      return YES;
    }
    if ([node[@"children"] isKindOfClass:NSMutableArray.class] &&
        BxFind(node[@"children"], node[@"id"], node_id, out_items, out_index,
               out_parent)) {
      return YES;
    }
  }
  return NO;
}

BOOL BxLocate(const BxTree& tree,
              NSString* node_id,
              NSMutableArray** items,
              NSUInteger* index,
              NSString** parent) {
  return BxFind(tree.bar, @"1", node_id, items, index, parent) ||
         BxFind(tree.other, @"2", node_id, items, index, parent);
}

NSMutableArray* BxChildrenOf(const BxTree& tree, NSString* folder_id) {
  if (NSMutableArray* root = BxRootChildren(tree, folder_id)) {
    return root;
  }
  NSMutableArray* items = nil;
  NSUInteger index = 0;
  NSString* parent = nil;
  if (!BxLocate(tree, folder_id, &items, &index, &parent)) {
    return nil;
  }
  NSMutableDictionary* node = items[index];
  if (!BxIsFolder(node)) {
    return nil;
  }
  if (![node[@"children"] isKindOfClass:NSMutableArray.class]) {
    node[@"children"] = [NSMutableArray array];
  }
  return node[@"children"];
}

NSDictionary* BxNode(NSDictionary* node,
                     NSString* parent_id,
                     NSUInteger index,
                     BOOL recursive) {
  NSMutableDictionary* out = [@{
    @"id" : node[@"id"] ?: @"",
    @"parentId" : parent_id,
    @"index" : @(index),
    @"title" : [node[@"title"] isKindOfClass:NSString.class] ? node[@"title"]
                                                              : @"",
    @"dateAdded" : [node[@"dateAdded"] isKindOfClass:NSNumber.class]
        ? @([node[@"dateAdded"] longLongValue])
        : @0,
    @"syncing" : @NO,
  } mutableCopy];
  if (!BxIsFolder(node)) {
    out[@"url"] = node[@"url"];
  } else if (recursive) {
    NSMutableArray* children = [NSMutableArray array];
    NSArray* items = node[@"children"];
    for (NSUInteger i = 0; i < items.count; ++i) {
      [children addObject:BxNode(items[i], out[@"id"], i, YES)];
    }
    out[@"children"] = children;
  }
  return out;
}

NSDictionary* BxRootNode(const BxTree& tree, NSString* folder_id,
                         BOOL recursive) {
  const BOOL bar = [folder_id isEqualToString:@"1"];
  NSMutableDictionary* folder = [@{
    @"id" : folder_id,
    @"parentId" : @"0",
    @"index" : bar ? @0 : @1,
    @"title" : bar ? @"Bookmarks Bar" : @"Other Bookmarks",
    @"folderType" : bar ? @"bookmarks-bar" : @"other",
    @"dateAdded" : @0,
    @"syncing" : @NO,
  } mutableCopy];
  if (recursive) {
    NSMutableArray* children = [NSMutableArray array];
    NSArray* items = bar ? tree.bar : tree.other;
    for (NSUInteger i = 0; i < items.count; ++i) {
      [children addObject:BxNode(items[i], folder_id, i, YES)];
    }
    folder[@"children"] = children;
  }
  return folder;
}

NSDictionary* BxAnyNode(const BxTree& tree, NSString* node_id, BOOL recursive) {
  if ([node_id isEqualToString:@"0"]) {
    NSMutableDictionary* root = [@{
      @"id" : @"0",
      @"title" : @"",
      @"dateAdded" : @0,
      @"syncing" : @NO
    } mutableCopy];
    if (recursive) {
      root[@"children"] =
          @[ BxRootNode(tree, @"1", YES), BxRootNode(tree, @"2", YES) ];
    }
    return root;
  }
  if (BxRootChildren(tree, node_id)) {
    return BxRootNode(tree, node_id, recursive);
  }
  NSMutableArray* items = nil;
  NSUInteger index = 0;
  NSString* parent = nil;
  if (!BxLocate(tree, node_id, &items, &index, &parent)) {
    return nil;
  }
  return BxNode(items[index], parent, index, recursive);
}

void BxCollect(NSArray* items,
               NSString* parent_id,
               NSMutableArray* out) {
  for (NSUInteger i = 0; i < items.count; ++i) {
    NSDictionary* node = items[i];
    if (![node isKindOfClass:NSDictionary.class]) {
      continue;
    }
    [out addObject:BxNode(node, parent_id, i, NO)];
    if ([node[@"children"] isKindOfClass:NSArray.class]) {
      BxCollect(node[@"children"], node[@"id"], out);
    }
  }
}

NSDictionary* BxError(NSString* message) {
  return @{@"ok" : @NO, @"error" : message};
}

NSDictionary* BxBookmarksOp(NSDictionary* req) {
  NSString* op = req[@"op"];
  BxTree tree = BxLoadTree();
  NSMutableArray* events = [NSMutableArray array];
  NSMutableDictionary* reply = [@{@"ok" : @YES} mutableCopy];
  NSString* node_id =
      [req[@"id"] isKindOfClass:NSString.class] ? req[@"id"] : nil;

  if ([op isEqualToString:@"getTree"]) {
    reply[@"result"] = @[ BxAnyNode(tree, @"0", YES) ];
  } else if ([op isEqualToString:@"getSubTree"] || [op isEqualToString:@"get"] ||
             [op isEqualToString:@"getChildren"]) {
    NSArray* ids = [req[@"ids"] isKindOfClass:NSArray.class]
                       ? req[@"ids"]
                       : (node_id ? @[ node_id ] : @[]);
    if ([op isEqualToString:@"getChildren"]) {
      NSDictionary* folder = node_id ? BxAnyNode(tree, node_id, YES) : nil;
      if (!folder) {
        return BxError(@"Can't find bookmark for id.");
      }
      NSMutableArray* kids = [NSMutableArray array];
      for (NSDictionary* child in folder[@"children"]) {
        NSMutableDictionary* flat = [child mutableCopy];
        [flat removeObjectForKey:@"children"];
        [kids addObject:flat];
      }
      reply[@"result"] = kids;
    } else {
      NSMutableArray* out = [NSMutableArray array];
      for (id one in ids) {
        NSDictionary* node =
            [one isKindOfClass:NSString.class]
                ? BxAnyNode(tree, one, [op isEqualToString:@"getSubTree"])
                : nil;
        if (!node) {
          return BxError(@"Can't find bookmark for id.");
        }
        [out addObject:node];
      }
      reply[@"result"] = out;
    }
  } else if ([op isEqualToString:@"getRecent"] ||
             [op isEqualToString:@"search"]) {
    NSMutableArray* all = [NSMutableArray array];
    BxCollect(tree.bar, @"1", all);
    BxCollect(tree.other, @"2", all);
    NSMutableArray* out = [NSMutableArray array];
    if ([op isEqualToString:@"getRecent"]) {
      for (NSDictionary* n in all) {
        if (n[@"url"]) {
          [out addObject:n];
        }
      }
      [out sortUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                   NSDictionary* b) {
        return [b[@"dateAdded"] compare:a[@"dateAdded"]];
      }];
      const NSUInteger limit = MAX(1, [req[@"count"] unsignedIntegerValue]);
      if (out.count > limit) {
        [out removeObjectsInRange:NSMakeRange(limit, out.count - limit)];
      }
    } else {
      id query = req[@"query"];
      NSString* text = [query isKindOfClass:NSString.class] ? query : nil;
      NSDictionary* fields =
          [query isKindOfClass:NSDictionary.class] ? query : nil;
      if (fields && [fields[@"query"] isKindOfClass:NSString.class]) {
        text = fields[@"query"];
      }
      NSArray* words =
          [[text lowercaseString] componentsSeparatedByCharactersInSet:
              NSCharacterSet.whitespaceCharacterSet];
      for (NSDictionary* n in all) {
        if (fields[@"url"] && ![n[@"url"] isEqual:fields[@"url"]]) {
          continue;
        }
        if (fields[@"title"] && ![n[@"title"] isEqual:fields[@"title"]]) {
          continue;
        }
        NSString* hay = [[NSString stringWithFormat:@"%@ %@", n[@"title"],
                                                     n[@"url"] ?: @""]
            lowercaseString];
        BOOL match = YES;
        for (NSString* w in words) {
          if (w.length && ![hay containsString:w]) {
            match = NO;
            break;
          }
        }
        if (match) {
          [out addObject:n];
        }
      }
    }
    reply[@"result"] = out;
  } else if ([op isEqualToString:@"create"]) {
    NSDictionary* details = req[@"details"];
    NSString* parent = [details[@"parentId"] isKindOfClass:NSString.class]
                           ? details[@"parentId"]
                           : @"1";
    NSMutableArray* siblings = BxChildrenOf(tree, parent);
    if (!siblings) {
      return BxError(@"Can't find parent bookmark for id.");
    }
    NSMutableDictionary* node = [@{
      @"id" : BxNextId(),
      @"title" : [details[@"title"] isKindOfClass:NSString.class]
          ? details[@"title"]
          : @"",
      @"dateAdded" : @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
    } mutableCopy];
    if ([details[@"url"] isKindOfClass:NSString.class]) {
      if (![NSURL URLWithString:details[@"url"]].scheme) {
        return BxError(@"Invalid URL.");
      }
      node[@"url"] = details[@"url"];
    } else {
      node[@"children"] = [NSMutableArray array];
    }
    NSUInteger index = siblings.count;
    if ([details[@"index"] isKindOfClass:NSNumber.class]) {
      index = MIN([details[@"index"] unsignedIntegerValue], siblings.count);
    }
    [siblings insertObject:node atIndex:index];
    BxSave(tree);
    NSDictionary* created = BxNode(node, parent, index, NO);
    reply[@"result"] = created;
    [events addObject:@{
      @"name" : @"bookmarks.onCreated",
      @"args" : @[ node[@"id"], created ]
    }];
  } else if ([op isEqualToString:@"update"] || [op isEqualToString:@"move"] ||
             [op isEqualToString:@"remove"] ||
             [op isEqualToString:@"removeTree"]) {
    if (!node_id || [@[ @"0", @"1", @"2" ] containsObject:node_id]) {
      return BxError(node_id ? @"Can't modify the root bookmark folders."
                             : @"Can't find bookmark for id.");
    }
    NSMutableArray* items = nil;
    NSUInteger index = 0;
    NSString* parent = nil;
    if (!BxLocate(tree, node_id, &items, &index, &parent)) {
      return BxError(@"Can't find bookmark for id.");
    }
    NSMutableDictionary* node = items[index];
    if ([op isEqualToString:@"update"]) {
      NSDictionary* changes = req[@"changes"];
      NSMutableDictionary* info = [NSMutableDictionary dictionary];
      if ([changes[@"title"] isKindOfClass:NSString.class]) {
        node[@"title"] = changes[@"title"];
        info[@"title"] = changes[@"title"];
      }
      if ([changes[@"url"] isKindOfClass:NSString.class]) {
        if (BxIsFolder(node)) {
          return BxError(@"Can't set URL of a bookmark folder.");
        }
        node[@"url"] = changes[@"url"];
        info[@"url"] = changes[@"url"];
      }
      BxSave(tree);
      if (!info[@"title"]) {
        info[@"title"] = node[@"title"] ?: @"";
      }
      reply[@"result"] = BxNode(node, parent, index, NO);
      [events addObject:@{
        @"name" : @"bookmarks.onChanged",
        @"args" : @[ node_id, info ]
      }];
    } else if ([op isEqualToString:@"move"]) {
      NSDictionary* dest = req[@"destination"];
      NSString* new_parent = [dest[@"parentId"] isKindOfClass:NSString.class]
                                 ? dest[@"parentId"]
                                 : parent;
      NSMutableArray* target = BxChildrenOf(tree, new_parent);
      if (!target) {
        return BxError(@"Can't find parent bookmark for id.");
      }
      [items removeObjectAtIndex:index];
      NSUInteger to = target.count;
      if ([dest[@"index"] isKindOfClass:NSNumber.class]) {
        to = MIN([dest[@"index"] unsignedIntegerValue], target.count);
      }
      [target insertObject:node atIndex:to];
      BxSave(tree);
      reply[@"result"] = BxNode(node, new_parent, to, NO);
      [events addObject:@{
        @"name" : @"bookmarks.onMoved",
        @"args" : @[
          node_id, @{
            @"parentId" : new_parent,
            @"index" : @(to),
            @"oldParentId" : parent,
            @"oldIndex" : @(index)
          }
        ]
      }];
    } else {
      if ([op isEqualToString:@"remove"] && BxIsFolder(node) &&
          [node[@"children"] count]) {
        return BxError(@"Can't remove non-empty folder (use recursive to "
                       @"force).");
      }
      NSDictionary* removed = BxNode(node, parent, index, YES);
      [items removeObjectAtIndex:index];
      BxSave(tree);
      [events addObject:@{
        @"name" : @"bookmarks.onRemoved",
        @"args" : @[
          node_id,
          @{@"parentId" : parent, @"index" : @(index), @"node" : removed}
        ]
      }];
    }
  } else {
    return BxError([NSString
        stringWithFormat:@"chrome.bookmarks.%@ is not implemented", op]);
  }
  reply[@"events"] = events;
  return reply;
}

}  // namespace

namespace content {

std::string BlinkBookmarksOp(const std::string& request_json) {
  NSData* data = [NSData dataWithBytes:request_json.data()
                                length:request_json.size()];
  NSDictionary* req = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:nil];
  NSDictionary* reply = [req isKindOfClass:NSDictionary.class]
                            ? BxBookmarksOp(req)
                            : BxError(@"Bad request");
  NSData* out = [NSJSONSerialization dataWithJSONObject:reply
                                                options:0
                                                  error:nil];
  return out ? std::string(static_cast<const char*>(out.bytes), out.length)
             : std::string("{\"ok\":false,\"error\":\"Bad reply\"}");
}

}  // namespace content

namespace {

using BlinkLoginCallback =
    base::OnceCallback<void(std::optional<net::AuthCredentials>)>;

UIAlertController* g_login_prompt = nil;
int g_login_prompt_token = 0;

std::map<int, BlinkLoginCallback>& PendingLoginCallbacks() {
  static base::NoDestructor<std::map<int, BlinkLoginCallback>> pending;
  return *pending;
}

void FinishLoginPrompt(int token,
                       std::optional<net::AuthCredentials> credentials) {
  if (token == g_login_prompt_token) {
    g_login_prompt = nil;
  }
  auto it = PendingLoginCallbacks().find(token);
  if (it == PendingLoginCallbacks().end()) {
    return;
  }
  BlinkLoginCallback callback = std::move(it->second);
  PendingLoginCallbacks().erase(it);
  std::move(callback).Run(std::move(credentials));
}

}  // namespace

namespace content {

int BlinkShowLoginPrompt(WebContents* contents,
                         const std::string& host,
                         const std::string& realm,
                         bool proxy,
                         bool retry,
                         BlinkLoginCallback done) {
  Shell* shell = contents ? Shell::FromWebContents(contents) : nullptr;
  UIViewController* presenter =
      shell ? shell->window().Get().rootViewController : nil;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  if (!presenter || g_login_prompt) {
    return 0;
  }
  NSString* where = base::SysUTF8ToNSString(host);
  NSString* message =
      realm.empty()
          ? where
          : [NSString stringWithFormat:@"%@: %@", where,
                                       base::SysUTF8ToNSString(realm)];
  if (retry) {
    message = [message
        stringByAppendingFormat:@"\n%@",
                                BlinkL(@"The username or password was incorrect.")];
  }
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:BlinkL(proxy ? @"Proxy sign in" : @"Sign in")
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Username");
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.textContentType = UITextContentTypeUsername;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = BlinkL(@"Password");
    field.secureTextEntry = YES;
    field.textContentType = UITextContentTypePassword;
  }];
  const int token = ++g_login_prompt_token;
  PendingLoginCallbacks()[token] = std::move(done);
  __weak UIAlertController* weakAlert = alert;
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction*) {
                                            FinishLoginPrompt(token,
                                                              std::nullopt);
                                          }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Sign In")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction*) {
                                 NSArray<UITextField*>* fields =
                                     weakAlert.textFields;
                                 FinishLoginPrompt(
                                     token,
                                     net::AuthCredentials(
                                         base::SysNSStringToUTF16(
                                             fields.firstObject.text ?: @""),
                                         base::SysNSStringToUTF16(
                                             fields.lastObject.text ?: @"")));
                               }]];
  g_login_prompt = alert;
  [presenter presentViewController:alert animated:YES completion:nil];
  return token;
}

void BlinkCancelLoginPrompt(int token) {
  // Запит скасували раніше за відповідь, тож колбек просто викидаєм.
  PendingLoginCallbacks().erase(token);
  if (token == g_login_prompt_token && g_login_prompt) {
    UIAlertController* alert = g_login_prompt;
    g_login_prompt = nil;
    [alert dismissViewControllerAnimated:YES completion:nil];
  }
}

}  // namespace content

namespace content {

void BlinkConfirmExtensionUninstall(const std::string& extension_id) {
  const BlinkerWebExtension* found = nullptr;
  for (const auto& extension : BlinkerWebExtensionRegistry::GetInstance()
                                   .extensions()) {
    if (extension->id == extension_id) {
      found = extension.get();
      break;
    }
  }
  Shell* shell = KeyWindowShell();
  UIViewController* presenter =
      shell ? shell->window().Get().rootViewController : nil;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  if (!found || !presenter) {
    return;
  }
  NSString* name = base::SysUTF8ToNSString(found->name.empty() ? found->id
                                                               : found->name);
  NSString* identifier = base::SysUTF8ToNSString(extension_id);
  NSString* title =
      [NSString stringWithFormat:BlinkL(@"%@ wants to remove itself"), name];
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:title
                       message:BlinkL(@"Its files, and anything it stored, are "
                               @"deleted. This cannot be undone.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:BlinkL(@"Keep")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:BlinkL(@"Remove")
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction*) {
                                 BlinkerRemoveExtension(
                                     base::SysNSStringToUTF8(identifier));
                               }]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

}  // namespace content

static void BlinkSyncShellBounds(content::Shell* shell) {
  UIWindow* window = shell->window().Get();
  ContentShellWindowDelegate* delegate =
      static_cast<ContentShellWindowDelegate*>(window.rootViewController);
  if (![delegate isKindOfClass:[ContentShellWindowDelegate class]]) {
    return;
  }
  [delegate applyToolbarPosition];
  [delegate setNeedsStatusBarAppearanceUpdate];
  [delegate setNeedsUpdateOfHomeIndicatorAutoHidden];
  [delegate setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
  [delegate.view setNeedsLayout];
  [delegate.view layoutIfNeeded];
  content::WebContents* contents = shell->web_contents();
  if (!contents) {
    return;
  }
  UIView* web_view = contents->GetNativeView().Get();
  web_view.frame = delegate.contentView.bounds;
  content::RenderWidgetHostView* view =
      contents->GetPrimaryMainFrame()
          ? contents->GetPrimaryMainFrame()->GetView()
          : nullptr;
  if (view) {
    view->SetBounds(gfx::Rect(0, 0, lround(web_view.bounds.size.width),
                              lround(web_view.bounds.size.height)));
  }
}

static void BlinkSetKioskMode(BOOL on) {
  if (g_blink_kiosk_mode == on) {
    return;
  }
  g_blink_kiosk_mode = on;
  [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"BlinkKioskMode"];
  UIApplication.sharedApplication.idleTimerDisabled = on;
  for (content::Shell* shell : content::Shell::windows()) {
    BlinkSyncShellBounds(shell);
  }
}

namespace content {

void ShellPlatformDelegate::ToggleFullscreenModeForTab(
    Shell* shell,
    WebContents* web_contents,
    bool enter_fullscreen) {
  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  if (shell_data.fullscreen == enter_fullscreen) {
    return;
  }
  shell_data.fullscreen = enter_fullscreen;
  ContentShellWindowDelegate* delegate =
      (ContentShellWindowDelegate*)shell_data.window.rootViewController;

  // Поле з фокусом тримало б клавіатуру, і її відступ сперечався б із розміткою
  // під час переходу.
  [delegate.view endEditing:YES];
  BlinkSetKeyboardViewportInset(0);
  // Прибираємо всю панель разом з її геометрією, інакше після повороту
  // лишається чорна смуга біля відео.
  [delegate toolbarBackgroundView].hidden = enter_fullscreen;
  [NSLayoutConstraint deactivateConstraints:delegate.fullscreenConstraints];
  if (enter_fullscreen) {
    [NSLayoutConstraint deactivateConstraints:delegate.topPosConstraints];
    [NSLayoutConstraint deactivateConstraints:delegate.bottomPosConstraints];
    [NSLayoutConstraint
        deactivateConstraints:delegate.contentHorizontalConstraints];
    UIView* rootView = delegate.view;
    UIView* contentView = delegate.contentView;
    delegate.fullscreenConstraints = @[
      [contentView.leadingAnchor
          constraintEqualToAnchor:rootView.leadingAnchor],
      [contentView.trailingAnchor
          constraintEqualToAnchor:rootView.trailingAnchor],
      [contentView.topAnchor constraintEqualToAnchor:rootView.topAnchor],
      [contentView.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:delegate.fullscreenConstraints];
  } else {
    delegate.fullscreenConstraints = nil;
    [NSLayoutConstraint
        activateConstraints:delegate.contentHorizontalConstraints];
    [delegate applyToolbarPosition];
  }
  UIApplication.sharedApplication.idleTimerDisabled =
      enter_fullscreen || g_blink_kiosk_mode;
  BlinkSetNativeVideoPiP(enter_fullscreen);
  // Панель усталюється до SynchronizeVisualProperties, щоб рендерер отримав
  // кінцевий розмір.
  [delegate.view setNeedsLayout];
  [delegate.view layoutIfNeeded];

  // Поворот асинхронний, тож після того, як UIKit затвердив нові межі, ще раз
  // синхронізуємо розмір, інакше лишається портретна поверхня.
  base::WeakPtr<WebContents> weak_contents = web_contents->GetWeakPtr();
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        if (!weak_contents) {
          return;
        }
        UIView* delayed_content = [delegate contentView];
        UIView* web_view = weak_contents->GetNativeView().Get();
        web_view.frame = delayed_content.bounds;
        [delegate.view setNeedsLayout];
        [delegate.view layoutIfNeeded];
        // Після повороту кадр fullscreen порожній, тож змінюємо видимість, щоб
        // отримати новий LocalSurfaceId і повний кадр.
        if (enter_fullscreen) {
          // На iOS 15 це заморожує відео, а iOS 16 без цього лишає чорну
          // поверхню.
          if (@available(iOS 16.0, *)) {
            weak_contents->WasHidden();
            weak_contents->WasShown();
            BLINKER_DIAG(
                "FULLSCREEN_LAYOUT: forced post-rotation surface refresh");
          }
        }
        content::RenderFrameHost* main_frame =
            weak_contents->GetPrimaryMainFrame();
        if (!main_frame || !main_frame->GetRenderViewHost()) {
          return;
        }
        content::RenderWidgetHost* widget =
            main_frame->GetRenderViewHost()->GetWidget();
        if (!widget) {
          return;
        }
        if (widget->GetView()) {
          widget->GetView()->SetBounds(
              gfx::Rect(0, 0, lround(web_view.bounds.size.width),
                        lround(web_view.bounds.size.height)));
        }
        if (enter_fullscreen) {
          if (@available(iOS 16.0, *)) {
            // Оновлення робить перемикання видимості вище.
          } else {
            // Сам розмір на iOS 15 лишає стару поверхню відео, тож генеруємо
            // новий LocalSurfaceId без приховування сторінки.
            static_cast<content::RenderWidgetHostImpl*>(widget)
                ->RequestRepaintOnNewSurface();
            BLINKER_DIAG(
                "FULLSCREEN_LAYOUT: iOS 15 requested new video surface");
          }
        }
        // За один поворот приходить кілька змін, і кінцеву не можна відкидати
        // лише тому, що підтвердження портретної ще в дорозі.
        static_cast<content::RenderWidgetHostImpl*>(widget)
            ->SynchronizeVisualPropertiesIgnoringPendingAck();
        BLINKER_DIAG("FULLSCREEN_LAYOUT: post-transition sync");
      });

  UIView* content_view = [delegate contentView];
  BLINKER_DIAGF("FULLSCREEN_LAYOUT: enter=%d content=%.0fx%.0f web=%.0fx%.0f "
                "subviews=%lu\n",
                enter_fullscreen ? 1 : 0, content_view.bounds.size.width,
                content_view.bounds.size.height,
                content_view.subviews.firstObject.frame.size.width,
                content_view.subviews.firstObject.frame.size.height,
                (unsigned long)content_view.subviews.count);
}

bool ShellPlatformDelegate::IsFullscreenForTabOrPending(
    Shell* shell,
    const WebContents* web_contents) const {
  DCHECK(shell_data_map_.contains(shell));
  auto iter = shell_data_map_.find(shell);
  return iter->second.fullscreen;
}

}  // namespace content
