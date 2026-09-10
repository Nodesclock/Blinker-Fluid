// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_platform_delegate.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreLocation/CoreLocation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <map>

#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/blinker_private_logging.h"

extern "C" void BlinkPrepareForRestart();
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

#include "base/files/file.h"
#include "base/hash/hash.h"
#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/trace_event/trace_config.h"
#include "base/version_info/version_info.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_ios.h"
#include "content/browser/screen_orientation/screen_orientation_provider.h"
#include "content/public/browser/browser_accessibility_state.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/scoped_accessibility_mode.h"
#include "content/public/browser/screen_orientation_delegate.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/stop_find_action.h"
#include "content/shell/app/resource.h"
#include "content/shell/browser/blinker_extensions.h"
#include "content/shell/browser/color_chooser/shell_color_chooser_ios.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_browser_main_parts.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/browser/shell_file_select_helper.h"
#include "services/device/public/mojom/screen_orientation.mojom-shared.h"
#include "services/tracing/public/cpp/perfetto/perfetto_config.h"
#include "services/tracing/public/mojom/constants.mojom.h"
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
// Defined in shell_content_browser_client.cc; read by OverrideWebPreferences to
// drive the web content's prefers-color-scheme. Set by the Appearance UI here.
extern int g_blink_preferred_color_scheme;
// Defined in shell_content_browser_client.cc; 1 = force desktop layout prefs
// (read by OverrideWebPreferences). Toggled by Request Desktop/Mobile Site.
extern int g_force_desktop_site;
// Defined in shell_content_browser_client.cc; site-mode UA client-hints
// (Sec-CH-UA-Mobile / platform) matching the desktop/mobile UA string.
blink::UserAgentMetadata GetShellUserAgentMetadataForSiteMode(bool desktop);
// Defined in shell.cc; true while a ChatGPT/Google auth redirect chain is in
// Flight so we don't change UA/site-mode mid-auth.
bool BlinkShellIsInAuthFlow();
}  // namespace content

static NSString* BlinkL(NSString* english);
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

// Google serves the same account image at URLs that differ only in the final
// requested crop size (for example =s200-c versus =s400-c). Treat that suffix
// as presentation metadata, not as a second account identity.
static NSString* BlinkGoogleAvatarIdentity(NSString* value) {
  NSRange sizeSuffix = [value rangeOfString:@"=" options:NSBackwardsSearch];
  return sizeSuffix.location == NSNotFound
             ? value
             : [value substringToIndex:sizeSuffix.location];
}

namespace content {
void BlinkObserveGoogleAvatarURL(Shell* shell, const char* value) {
  if (!shell || !shell->web_contents() || !value || !value[0]) {
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
  [[[NSURLSession sharedSession]
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
}  // namespace content

static UIImage* BlinkSystemImage(NSString* name) {
  if (@available(iOS 13.0, *)) {
    return [UIImage systemImageNamed:name];
  }
  return nil;
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

static UIImage* BlinkSwitchAccountIcon(UIImage* primary, UIImage* secondary) {
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
    [[UIColor colorWithRed:224 / 255.0
                     green:71 / 255.0
                      blue:40 / 255.0
                     alpha:1.0] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:badgeRect] fill];
    [[UIColor blackColor] setStroke];
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
  // Chromium remains the media-clock owner. The native transport controls are
  // deliberately acknowledged without creating a competing AVPlayer clock.
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
  // iOS 15's sample-buffer PiP controller retains IOSurface mappings when its
  // source layer is also being presented inline by Chromium. A fullscreen
  // video can consequently accumulate thousands of media/GPU VM regions until
  // pmap_enter fails and RunningBoard kills the browser. The ownership model is
  // reliable on iOS 16 and newer; keep ordinary Chromium fullscreen on iOS 15.
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

// Selectable search engines (long-press the URL bar). An empty
// query string means "None" — input is always treated as a URL.
struct SearchEngine {
  const char* name;
  const char* query;  // search prefix; the (escaped) term is appended.
  // Endpoint returning OpenSearch suggestions as ["query", ["a", "b", ...]].
  // Empty means this engine offers none, so the start page shows no list.
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
    SearchEngine{"Blinker Fluid (Google)", "https://www.google.com/search?q=",
                 "https://suggestqueries.google.com/complete/"
                 "search?client=firefox&q="},
};
int g_search_engine = 0;  // Default: Google.
bool g_blink_app_unlocked = false;

// Whether this launch is a private (off-the-record) session. Cached from the
// BlinkPrivateBrowsing preference on first use: the browser context is chosen
// once at startup and can't change without a restart, so the value — and the
// theme derived from it — is stable for the whole session.
bool BlinkPrivateSession() {
  static bool active = [[NSUserDefaults standardUserDefaults]
      boolForKey:@"BlinkPrivateBrowsing"];
  return active;
}

// The app's single theme color, used for both the toolbar/nav-bar background
// and the menu/start-page accent. Warm red-orange (matching the
// ungoogled-chromium icon) in a normal session; a dark purple in a private
// session so the whole UI signals off-the-record at a glance.
UIColor* BlinkerThemeColor() {
  if (BlinkPrivateSession()) {
    return [UIColor colorWithRed:130 / 255.0
                           green:62 / 255.0
                            blue:190 / 255.0
                           alpha:1.0];
  }
  return [UIColor colorWithRed:224 / 255.0
                         green:71 / 255.0
                          blue:40 / 255.0
                         alpha:1.0];
}

// Accent color for menu/start-page text and icons. Follows the theme color, so
// a private session tints these dark purple instead of orange.
UIColor* BlinkerAccentColor() {
  return BlinkerThemeColor();
}
UIColor* BlinkerTorColor() {
  return [UIColor colorWithRed:159 / 255.0
                         green:102 / 255.0
                          blue:224 / 255.0
                         alpha:1.0];
}

constexpr ui::AXMode kVoiceOverEnabledAXMode =
    ui::kAXModeComplete | ui::AXMode::kFromPlatform | ui::AXMode::kScreenReader;

// Persist the URLs of every open tab so they survive app
// close/reopen. Called on each navigation (SetAddressBarURL) and on tab
// open/close. The list is restored — crash-guarded — at launch by
// ShellBrowserMainParts::InitializeMessageLoopContext. UIKit state restoration
// stays disabled (it caused crash-loops); this is our own lightweight model.
NSString* BlinkZoomKey(content::Shell* shell) {
  if (!shell || !shell->web_contents()) {
    return nil;
  }
  // No key in a private session: the key embeds the hostname, so storing it
  // would leave a per-site record of where the user went. Zoom still applies
  // to the live page, it just isn't remembered.
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
  return stored > 0 ? static_cast<int>(stored) : 100;
}

UIImage* BlinkCaptureTabPreview(content::Shell* shell);

NSString* BlinkTabURL(content::Shell* shell) {
  if (!shell || !shell->web_contents()) {
    return nil;
  }
  GURL url = content::PeekPendingRestoreURL(shell);
  if (!url.is_valid()) {
    url = shell->web_contents()->GetLastCommittedURL();
  }
  if (!url.is_valid()) {
    url = shell->web_contents()->GetVisibleURL();
  }
  if (!url.is_valid() || url.IsAboutBlank()) {
    return @"about:blank";
  }
  return url.SchemeIsHTTPOrHTTPS() ? base::SysUTF8ToNSString(url.spec()) : nil;
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
  // Guarded here rather than at the call sites: a preview is a JPEG of the
  // rendered page, so a private session must not leave one on disk no matter
  // which path asks for the capture.
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
  NSString* path = BlinkTabPreviewPath(BlinkTabURL(shell));
  return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

void BlinkSaveOpenTabs(bool persistPreviews = false) {
  for (content::Shell* shell : content::Shell::windows()) {
    if (shell->web_contents() &&
        shell->web_contents()->GetBrowserContext()->IsOffTheRecord()) {
      return;
    }
  }
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
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
  [d synchronize];
}

NSCache<NSValue*, UIImage*>* BlinkTabPreviewCache() {
  static NSCache<NSValue*, UIImage*>* cache = [] {
    NSCache<NSValue*, UIImage*>* value = [[NSCache alloc] init];
    value.countLimit = 24;
    return value;
  }();
  return cache;
}

UIImage* BlinkCaptureTabPreview(content::Shell* shell) {
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
  if (image) {
    [BlinkTabPreviewCache() setObject:image forKey:key];
    BlinkSaveTabPreview(shell, image);
  }
  return image;
}

}  // namespace

extern "C" void BlinkPersistOpenTabs() {
  BlinkSaveOpenTabs(true);
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

// Window bridges for shell.cc (C++, can't touch UIKit). Used by the Google
// sign-in popup flow: AddNewContents keeps the GSI popup as a real Shell and
// presents its window; window.close() hands the screen back to the opener.

// Make |shell|'s UIWindow key+visible in the active scene (same mechanics as
// tab switching / showTabWindow).
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
    const bool selected = candidate == shell;
    if (!selected && candidateWindow && !candidateWindow.hidden) {
      BlinkCaptureTabPreview(candidate);
    }
    if (candidateWindow) {
      candidateWindow.hidden = !selected;
    }
    if (candidate->web_contents()) {
      if (selected) {
        candidate->web_contents()->WasShown();
      } else {
        candidate->web_contents()->WasHidden();
      }
    }
  }
  win.hidden = NO;
  [win makeKeyAndVisible];
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

static void BlinkDiscardBackgroundTabsExcept(content::Shell* keep) {
  for (content::Shell* candidate : content::Shell::windows()) {
    if (candidate == keep || !candidate->web_contents()) {
      continue;
    }
    content::WebContents* contents = candidate->web_contents();
    contents->WasHidden();
    contents->SetPageFrozen(true);
    if (!contents->WasDiscarded() &&
        !contents->HasUncommittedNavigationInPrimaryMainFrame()) {
      contents->Discard(base::DoNothing());
      BLINKER_DIAG("TAB_LIFECYCLE: discarded inactive renderer");
    }
  }
}

namespace {

// A background tab untouched for this long is discarded even when memory is
// not tight. A resident renderer keeps its frame tree and compositor layers
// alive, which is most of what walks the process toward the jetsam limit, and
// a discarded tab restores from its navigation entry on reselect.
constexpr double kInactiveTabDiscardSeconds = 10 * 60;
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

// The orientation mask the page has asked for, or "all" when unlocked. The
// window delegate reports this from -supportedInterfaceOrientations, since iOS
// only rotates to orientations the view controller admits to supporting.
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
    // Pre-16 has no public rotation request; this is the long-standing way and
    // is what every browser shipping fullscreen video on those releases uses.
    UIInterfaceOrientation target = (mask & UIInterfaceOrientationMaskLandscape)
                                        ? UIInterfaceOrientationLandscapeRight
                                        : UIInterfaceOrientationPortrait;
    if (mask != UIInterfaceOrientationMaskAll) {
      [[UIDevice currentDevice] setValue:@(target) forKey:@"orientation"];
    }
    [UIViewController attemptRotationToDeviceOrientation];
  }
}

// Without this, screen.orientation.lock() rejects with NotSupportedError --
// only Android ships a delegate upstream. YouTube's player locks to landscape
// as part of going fullscreen, and the rejection leaves its container black and
// static, which is what "fullscreen goes black" actually was.
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

// Fullscreen video is a landscape experience on a phone, and pages do not
// reliably ask for it -- YouTube never calls screen.orientation.lock() here, so
// waiting for the page leaves the video boxed into a portrait viewport. Rotate
// on the way in and put the orientation back on the way out.
extern "C" void BlinkApplyFullscreenOrientation(bool entering,
                                                UIWindow* window) {
  static UIInterfaceOrientationMask pre_fullscreen_mask =
      UIInterfaceOrientationMaskAll;

  if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) {
    // iPads are usable fullscreen in either orientation; forcing one is worse.
    return;
  }

  UIInterfaceOrientationMask target;
  if (entering) {
    pre_fullscreen_mask = g_orientation_mask;
    UIInterfaceOrientation current = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
      current = window.windowScene ? window.windowScene.interfaceOrientation
                                   : UIInterfaceOrientationUnknown;
    } else {
      current = UIApplication.sharedApplication.statusBarOrientation;
    }
    // Respect the way the device is already being held.
    target = UIInterfaceOrientationIsLandscape(current)
                 ? (current == UIInterfaceOrientationLandscapeLeft
                        ? UIInterfaceOrientationMaskLandscapeLeft
                        : UIInterfaceOrientationMaskLandscapeRight)
                 : UIInterfaceOrientationMaskLandscapeRight;
    BLINKER_DIAG("FULLSCREEN: rotating to landscape");
  } else {
    target = pre_fullscreen_mask;
    pre_fullscreen_mask = UIInterfaceOrientationMaskAll;
    BLINKER_DIAG("FULLSCREEN: orientation restored");
  }
  ApplyOrientationMask(target);
}

extern "C" void BlinkInstallOrientationDelegate(void) {
  static base::NoDestructor<BlinkerScreenOrientationDelegate> delegate;
  content::ScreenOrientationProvider::SetDelegate(delegate.get());
  BLINKER_DIAG("ORIENTATION: delegate installed");
}

extern "C" void BlinkNoteTabActivated(content::Shell* shell) {
  if (shell) {
    TabLastActiveTime()[shell] = CFAbsoluteTimeGetCurrent();
  }
}

// Sweeps tabs the user has left alone. Separate from the pressure and tab-count
// triggers: those react to a process already in trouble, this keeps it from
// getting there.
extern "C" void BlinkDiscardIdleBackgroundTabs(void) {
  std::map<content::Shell*, double>& times = TabLastActiveTime();
  const double now = CFAbsoluteTimeGetCurrent();
  content::Shell* keep = KeyWindowShell();
  if (!keep && !content::Shell::windows().empty()) {
    keep = content::Shell::windows().front();
  }

  // Drop entries for closed tabs so the map never dereferences a freed Shell.
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
        contents->HasUncommittedNavigationInPrimaryMainFrame()) {
      continue;
    }
    if (now - times[candidate] < kInactiveTabDiscardSeconds) {
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
  // Routine trigger (opening a tab): only worth shedding once enough tabs are
  // resident to matter.
  if (content::Shell::windows().size() < 6) {
    return;
  }
  BlinkDiscardBackgroundTabsExcept(keep);
}

// Memory-pressure trigger. Deliberately ignores the tab-count floor above: at
// the critical threshold the alternative is a jetsam SIGKILL that loses every
// tab, so shedding even one background renderer is the better trade. Purging
// caches alone does not release a resident renderer's frame or compositor
// layers, which is where the footprint actually is. Keeps whichever tab owns
// the key window so the visible page is never discarded out from under the
// user.
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
  BlinkDiscardBackgroundTabsExcept(keep);
}

// Called right before a script-initiated close (window.close()). If the
// closing shell owns the KEY window, activate another shell's window first —
// preferring |preferred_opener|'s shell — or the app is left on a dead
// UIWindow. Closing a background tab must not touch the visible window.
extern "C" void BlinkShellWillCloseReactivate(
    content::Shell* closing,
    content::WebContents* preferred_opener) {
  UIWindow* closingWin = closing ? closing->window().Get() : nil;
  if (!closingWin || !closingWin.isKeyWindow) {
    return;
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
    for (content::Shell* s : content::Shell::windows()) {
      if (s != closing) {
        replacement = s;
        break;
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

// Native UIKit Find in Page surface. Chromium performs the search and draws
// match highlights; UIKit supplies the search field, keyboard, navigation
// controls, accessibility, and sheet presentation.
@interface BlinkFindInPageController : UIViewController <UISearchBarDelegate> {
 @private
  base::WeakPtr<content::WebContents> _webContents;
  UISearchBar* _searchBar;
  int _requestID;
}
- (instancetype)initWithWebContents:(content::WebContents*)webContents;
@end

@implementation BlinkFindInPageController

- (instancetype)initWithWebContents:(content::WebContents*)webContents {
  if ((self = [super init])) {
    _webContents = webContents->GetWeakPtr();
    static int nextRequestID = 1;
    _requestID = nextRequestID++;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  if (@available(iOS 13.0, *)) {
    self.view.backgroundColor = UIColor.systemBackgroundColor;
  } else {
    self.view.backgroundColor = UIColor.whiteColor;
  }
  self.title = BlinkL(@"Find in Page");
  _searchBar = [[UISearchBar alloc] init];
  _searchBar.delegate = self;
  _searchBar.placeholder = BlinkL(@"Find in Page");
  _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
  self.navigationItem.titleView = _searchBar;
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(done:)];

  UIBarButtonItem* previous;
  if (@available(iOS 13.0, *)) {
    previous = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.up"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(previous:)];
  } else {
    previous = [[UIBarButtonItem alloc] initWithTitle:@"Previous"
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(previous:)];
  }
  previous.accessibilityLabel = @"Previous Match";
  UIBarButtonItem* next;
  if (@available(iOS 13.0, *)) {
    next = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(next:)];
  } else {
    next = [[UIBarButtonItem alloc] initWithTitle:@"Next"
                                            style:UIBarButtonItemStylePlain
                                           target:self
                                           action:@selector(next:)];
  }
  next.accessibilityLabel = @"Next Match";
  UIBarButtonItem* flexible = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];
  self.toolbarItems = @[ flexible, previous, flexible, next, flexible ];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self.navigationController setToolbarHidden:NO animated:YES];
  [_searchBar becomeFirstResponder];
}

- (void)runFindForward:(BOOL)forward newSession:(BOOL)newSession {
  if (!_webContents || _searchBar.text.length == 0) {
    return;
  }
  auto options = blink::mojom::FindOptions::New();
  options->forward = forward;
  options->new_session = newSession;
  _webContents->Find(_requestID, base::SysNSStringToUTF16(_searchBar.text),
                     std::move(options), /*skip_delay=*/true);
}

- (void)searchBar:(UISearchBar*)searchBar textDidChange:(NSString*)searchText {
  if (searchText.length == 0) {
    if (_webContents) {
      _webContents->StopFinding(content::STOP_FIND_ACTION_CLEAR_SELECTION);
    }
    return;
  }
  [self runFindForward:YES newSession:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar*)searchBar {
  [self runFindForward:YES newSession:NO];
}

- (void)previous:(id)sender {
  [self runFindForward:NO newSession:NO];
}

- (void)next:(id)sender {
  [self runFindForward:YES newSession:NO];
}

- (void)done:(id)sender {
  if (_webContents) {
    _webContents->StopFinding(content::STOP_FIND_ACTION_KEEP_SELECTION);
  }
  [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

@end

@class BlinkerStartPageView;

@interface ContentShellWindowDelegate
    : UIViewController <UITextFieldDelegate,
                        UIPopoverPresentationControllerDelegate> {
 @private
  raw_ptr<content::Shell> _shell;
}
// Toolbar containing navigation buttons and |urlField|.
@property(nonatomic, strong) UIStackView* toolbarBackgroundView;
// A real UIView behind the stack's arranged content. UIStackView itself did
// not paint backgrounds reliably before iOS 13.
@property(nonatomic, strong) UIView* toolbarPaintView;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* topPosConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* bottomPosConstraints;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* contentHorizontalConstraints;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* fullscreenConstraints;
@property(nonatomic, assign) CGFloat keyboardViewportInset;
// The native Blinker Fluid start page, shown over a blank tab.
@property(nonatomic, strong) BlinkerStartPageView* startPage;
// Toolbar containing navigation buttons and |urlField|.
@property(nonatomic, strong) UIStackView* toolbarContentView;
// Button to navigate backwards.
@property(nonatomic, strong) UIButton* backButton;
// Button to navigate forwards.
@property(nonatomic, strong) UIButton* forwardButton;
// Button that either refresh the page or stops the page load.
@property(nonatomic, strong) UIButton* reloadOrStopButton;
// Button that shows the menu
@property(nonatomic, strong) UIButton* menuButton;
// Text field used for navigating to URLs.
@property(nonatomic, strong) UITextField* urlField;
// Container for |webView|.
@property(nonatomic, strong) UIView* contentView;
@property(nonatomic, strong) UIProgressView* loadingProgressView;
@property(nonatomic, strong) UIActivityIndicatorView* pullSpinner;
@property(nonatomic, strong)
    NSArray<NSLayoutConstraint*>* loadingProgressConstraints;
@property(nonatomic, strong) UIView* privacyLockView;
@property(nonatomic, strong) CLLocationManager* permissionLocationManager;
// Manages tracing and tracing state.
@property(nonatomic, strong) TracingHandler* tracingHandler;

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
- (void)handleURLBarSwipe:(UISwipeGestureRecognizer*)gesture;
- (void)switchToTab:(content::Shell*)shell direction:(NSInteger)direction;
- (void)updateDownloadAttentionBadge;
- (void)setURL:(NSString*)url;
- (void)setContents:(UIView*)content;
- (void)stopTracing;
- (void)startTracingWithCategories:(const char*)categories;
- (void)voiceOverStatusDidChange;
- (void)updatePullToRefreshProgress:(CGFloat)progress;
- (void)finishPullToRefresh:(BOOL)triggered;
@end

namespace {

// Pull past this many points and release to reload. Deliberately long: a short
// throw at the top of a page reads as an accidental refresh, and there is no
// rubber-band travel here to make a shorter pull feel intentional.
constexpr CGFloat kPullToRefreshThreshold = 150;
// Ignore pulls below this so the indicator does not flicker on ordinary
// scrolling that happens to run past the top.
constexpr CGFloat kPullToRefreshMinimum = 30;
// Blink reports overscroll while the gesture runs but sends nothing on
// release, so a gap this long stands in for "finger lifted".
constexpr int64_t kPullReleaseGraceMs = 140;

CGFloat g_pull_peak = 0;
int64_t g_pull_generation = 0;

ContentShellWindowDelegate* KeyWindowDelegate() {
  content::Shell* shell = KeyWindowShell();
  UIWindow* window = shell ? shell->window().Get() : nil;
  if (![window.rootViewController
          isKindOfClass:[ContentShellWindowDelegate class]]) {
    return nil;
  }
  return (ContentShellWindowDelegate*)window.rootViewController;
}

}  // namespace

// Called from RenderWidgetHostViewIOS::DidOverscroll for overscroll the page
// did not consume. `allowed` is false when the root element sets
// overscroll-behavior-y, which is how a site declares it handles pull itself.
extern "C" void BlinkOverscrollPull(float pull_points, bool allowed) {
  if (!allowed || pull_points < kPullToRefreshMinimum) {
    return;
  }
  ContentShellWindowDelegate* delegate = KeyWindowDelegate();
  if (!delegate) {
    return;
  }
  g_pull_peak = std::max(g_pull_peak, static_cast<CGFloat>(pull_points));
  // Show progress across the travel past the minimum, not from zero, so the
  // indicator reaches full only at an intentional pull.
  [delegate updatePullToRefreshProgress:(g_pull_peak - kPullToRefreshMinimum) /
                                        (kPullToRefreshThreshold -
                                         kPullToRefreshMinimum)];

  const int64_t generation = ++g_pull_generation;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kPullReleaseGraceMs * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        if (generation != g_pull_generation) {
          return;
        }
        const BOOL triggered = g_pull_peak >= kPullToRefreshThreshold;
        g_pull_peak = 0;
        [delegate finishPullToRefresh:triggered];
      });
}

// A reusable modal list view used for Tabs, Bookmarks and
// Downloads — gives a "decent" UI (tap to open, swipe to delete, + to add).
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
// Optional per-row title colors (parallel to titles; use NSNull for default).
@property(nonatomic, strong) NSArray* titleColors;
@property(nonatomic, assign) NSInteger protectedIndex;  // -1 = none
@property(nonatomic, assign) BOOL isTabList;  // YES = emit TAB_MANAGER_UI logs
@property(nonatomic, assign) BOOL compactRows;
@property(nonatomic, assign) BOOL dismissOnSelect;
@property(nonatomic, assign) BOOL dismissOnAdd;
@property(nonatomic, copy) void (^onSelect)(NSInteger);
@property(nonatomic, copy) void (^onDelete)(NSInteger);  // nil = no delete
@property(nonatomic, copy) void (^onAdd)(void);          // nil = no + button
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
  // Dark theme with the red accent of the app.
  UIColor* bg = [UIColor colorWithWhite:0.09 alpha:1.0];
  self.tableView.backgroundColor = bg;
  self.tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
  self.tableView.rowHeight = self.isTabList ? 76 : (self.compactRows ? 48 : 58);
  self.tableView.tableFooterView = [[UIView alloc] init];
  [self applyNavigationBarAppearance];
}

// The navigation bar is shared by every screen pushed into this navigation
// controller, so styling it in -viewDidLoad (which runs once) leaves whichever
// screen appeared last in control of it. That is why the menu's bar showed up
// grey and then turned accent-coloured for good after a visit to the Tabs
// screen, which styles the same bar its own way. Re-applying on every
// appearance makes each screen own its own look.
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self applyNavigationBarAppearance];
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
    // Compact rows change only the table density. They must not silently
    // switch the navigation bar to the dark table background.
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
             ? self.sectionTitles[section]
             : nil;
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
  c.textLabel.text = self.titles[row];
  c.textLabel.numberOfLines = 1;
  UIColor* titleColor = BlinkerAccentColor();
  if (row < (NSInteger)self.titleColors.count &&
      [self.titleColors[row] isKindOfClass:[UIColor class]]) {
    titleColor = self.titleColors[row];
  }
  c.textLabel.textColor = titleColor;
  c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
  c.detailTextLabel.text =
      (row < (NSInteger)self.subtitles.count) ? self.subtitles[row] : @"";
  c.detailTextLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
  c.detailTextLabel.numberOfLines = 1;
  if (row < (NSInteger)self.rowImages.count &&
      [self.rowImages[row] isKindOfClass:[UIImage class]]) {
    c.imageView.image = self.rowImages[row];
    c.imageView.contentMode = UIViewContentModeScaleAspectFill;
    c.imageView.clipsToBounds = NO;
    c.imageView.layer.cornerRadius = 0;
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
         [self globalRowForIndexPath:ip] != self.protectedIndex;
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
@property(nonatomic, copy) void (^onSave)(NSString*, NSString*);
@end

@implementation BlinkBookmarkEditorVC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.folderMode ? @"New Folder" : @"New Bookmark";
  self.view.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                           target:self
                           action:@selector(save)];
  _nameField =
      [self fieldWithPlaceholder:self.folderMode ? @"Folder name" : @"Name"];
  NSMutableArray* fields = [NSMutableArray arrayWithObject:_nameField];
  if (!self.folderMode) {
    _urlField = [self fieldWithPlaceholder:@"https://example.com"];
    _urlField.keyboardType = UIKeyboardTypeURL;
    [fields addObject:_urlField];
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
  [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface BlinkTabCardCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView* preview;
@property(nonatomic, strong) UILabel* titleLabel;
@property(nonatomic, strong) UILabel* urlLabel;
@property(nonatomic, strong) UIButton* closeButton;
@end

@implementation BlinkTabCardCell
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.contentView.backgroundColor = UIColor.clearColor;
    self.contentView.clipsToBounds = NO;
    _preview = [[UIImageView alloc] init];
    _preview.contentMode = UIViewContentModeScaleAspectFill;
    _preview.clipsToBounds = YES;
    _preview.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    _preview.layer.cornerRadius = 18;
    if (@available(iOS 13.0, *)) {
      _preview.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _preview.layer.borderWidth = 1;
    _preview.layer.borderColor = [UIColor colorWithWhite:0.24 alpha:1].CGColor;
    _preview.layer.shadowOpacity = 0.16;
    _preview.layer.shadowRadius = 8;
    _preview.layer.shadowOffset = CGSizeMake(0, 3);
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.whiteColor;
    _urlLabel = [[UILabel alloc] init];
    _urlLabel.font = [UIFont systemFontOfSize:10];
    _urlLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1];
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setImage:BlinkSystemImage(@"xmark.circle.fill")
                  forState:UIControlStateNormal];
    _closeButton.tintColor = UIColor.whiteColor;
    _closeButton.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:0.55];
    _closeButton.layer.cornerRadius = 14;
    for (UIView* view in @[ _preview, _titleLabel, _urlLabel, _closeButton ]) {
      view.translatesAutoresizingMaskIntoConstraints = NO;
      [self.contentView addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
      [_preview.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                         constant:3],
      [_preview.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:3],
      [_preview.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-3],
      [_preview.heightAnchor
          constraintEqualToAnchor:self.contentView.heightAnchor
                       multiplier:0.80],
      [_titleLabel.topAnchor constraintEqualToAnchor:_preview.bottomAnchor
                                            constant:6],
      [_titleLabel.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:6],
      [_titleLabel.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-6],
      [_urlLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                          constant:3],
      [_urlLabel.leadingAnchor
          constraintEqualToAnchor:_titleLabel.leadingAnchor],
      [_urlLabel.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-10],
      [_closeButton.topAnchor constraintEqualToAnchor:_preview.topAnchor
                                             constant:8],
      [_closeButton.trailingAnchor
          constraintEqualToAnchor:_preview.trailingAnchor
                         constant:-8],
      [_closeButton.widthAnchor constraintEqualToConstant:28],
      [_closeButton.heightAnchor constraintEqualToConstant:28],
    ]];
  }
  return self;
}
@end

@interface BlinkTabsVC : UICollectionViewController
@property(nonatomic, strong) NSMutableArray<NSString*>* titles;
@property(nonatomic, strong) NSMutableArray<NSString*>* urls;
@property(nonatomic, strong) NSMutableArray<UIImage*>* previews;
@property(nonatomic, copy) void (^onSelect)(NSInteger);
@property(nonatomic, copy) BOOL (^onClose)(NSInteger);
@property(nonatomic, copy) void (^onAdd)(void);
@property(nonatomic, copy) void (^onReorder)(NSInteger, NSInteger);
@end

@implementation BlinkTabsVC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = BlinkL(@"Tabs");
  self.collectionView.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1];
  [self.collectionView registerClass:[BlinkTabCardCell class]
          forCellWithReuseIdentifier:@"tab"];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(done)];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                           target:self
                           action:@selector(add)];
  [self applyNavigationBarAppearance];
}

// See BlinkListVC: the navigation bar is shared, so each screen has to restore
// its own styling every time it appears rather than once at load.
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self applyNavigationBarAppearance];
}

- (void)applyNavigationBarAppearance {
  UINavigationBar* bar = self.navigationController.navigationBar;
  if (!bar) {
    return;
  }
  if (@available(iOS 13.0, *)) {
    UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    ap.titleTextAttributes =
        @{NSForegroundColorAttributeName : BlinkerAccentColor()};
    bar.standardAppearance = ap;
    bar.scrollEdgeAppearance = ap;
    bar.compactAppearance = ap;
  } else {
    bar.translucent = NO;
    bar.barTintColor = [UIColor colorWithWhite:0.08 alpha:1];
    bar.titleTextAttributes =
        @{NSForegroundColorAttributeName : BlinkerAccentColor()};
  }
  bar.tintColor = BlinkerAccentColor();
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
  cell.titleLabel.text = self.titles[path.item];
  cell.urlLabel.text = self.urls[path.item];
  cell.preview.image = self.previews[path.item];
  cell.closeButton.tag = path.item;
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
// UICollectionViewController installs a long-press gesture for interactive
// movement by default, so implementing these two turns it on.
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
  NSString* title = self.titles[fromIndex];
  NSString* url = self.urls[fromIndex];
  UIImage* preview = self.previews[fromIndex];
  [self.titles removeObjectAtIndex:fromIndex];
  [self.urls removeObjectAtIndex:fromIndex];
  [self.previews removeObjectAtIndex:fromIndex];
  [self.titles insertObject:title atIndex:toIndex];
  [self.urls insertObject:url atIndex:toIndex];
  [self.previews insertObject:preview atIndex:toIndex];
  if (self.onReorder) {
    self.onReorder(fromIndex, toIndex);
  }
}

- (void)closeTapped:(UIButton*)button {
  // Resolve the row from the cell rather than a tag baked in at configure
  // time: reordering moves cells without reconfiguring them, and a stale tag
  // would close whichever tab happened to be at that position originally.
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
  [self.collectionView reloadData];
}
@end

// The native Blinker Fluid start page. A real UIKit view (logo +
// "Blinker Fluid" + a search box + quick links) shown over a blank tab — so the
// start page is embedded in the app and never appears as a URL in the bar.
@interface BlinkerStartPageView
    : UIView <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy) void (^onNavigate)(NSString*);
@end

@implementation BlinkerStartPageView {
  UITextField* _search;
  UIStackView* _shortcutGrid;
  UITableView* _suggestions;
  NSArray<NSString*>* _suggestionTitles;
  NSURLSessionDataTask* _suggestionTask;
  int64_t _suggestionGeneration;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor colorWithRed:0.055
                                           green:0.055
                                            blue:0.063
                                           alpha:1.0];

    UIImageView* logo = [[UIImageView alloc]
        initWithImage:[UIImage imageNamed:@"blinker_logo"]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo.widthAnchor constraintEqualToConstant:120].active = YES;
    [logo.heightAnchor constraintEqualToConstant:120].active = YES;

    _search = [[UITextField alloc] init];
    _search.placeholder = @"Search or type URL";
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
    _search.delegate = self;
    [_search addTarget:self
                  action:@selector(searchTextChanged)
        forControlEvents:UIControlEventEditingChanged];
    _search.returnKeyType = UIReturnKeyGo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
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

- (UIStackView*)rowWithLinks:(NSArray*)links startIndex:(NSInteger)startIndex {
  NSMutableArray* buttons = [NSMutableArray array];
  NSInteger index = startIndex;
  for (NSDictionary* link in links) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString* title = link[@"title"] ?: @"Site";
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
    caption.textColor = UIColor.whiteColor;
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
  if (!components.host.length) {
    return;
  }
  NSURLComponents* iconComponents = [components copy];
  iconComponents.path = @"/apple-touch-icon.png";
  iconComponents.query = nil;
  iconComponents.fragment = nil;
  NSURL* touchIconURL = iconComponents.URL;
  if (!touchIconURL) {
    return;
  }
  [[[NSURLSession sharedSession]
        dataTaskWithURL:touchIconURL
      completionHandler:^(NSData* data, NSURLResponse* response,
                          NSError* error) {
        UIImage* image = data.length ? [UIImage imageWithData:data] : nil;
        if (!image) {
          NSString* encoded =
              [value stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet];
          NSURL* highResolutionURL = [NSURL
              URLWithString:
                  [NSString stringWithFormat:@"https://www.google.com/s2/"
                                             @"favicons?domain_url=%@&sz=256",
                                             encoded]];
          [[[NSURLSession sharedSession]
                dataTaskWithURL:highResolutionURL
              completionHandler:^(NSData* fallbackData,
                                  NSURLResponse* fallbackResponse,
                                  NSError* fallbackError) {
                UIImage* fallbackImage =
                    fallbackData.length ? [UIImage imageWithData:fallbackData]
                                        : nil;
                if (fallbackImage) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    imageView.image = fallbackImage;
                    fallback.hidden = YES;
                  });
                }
              }] resume];
          return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          UIButton* button = (UIButton*)imageView.superview.superview;
          if (button.tag != buttonIndex) {
            return;
          }
          imageView.image = image;
          fallback.hidden = YES;
        });
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

- (void)linkTapped:(UIButton*)button {
  UIImpactFeedbackGenerator* feedback = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  if (self.onNavigate && button.accessibilityIdentifier.length) {
    self.onNavigate(button.accessibilityIdentifier);
  }
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

// Suggestions live on the start page only. The URL bar deliberately has none:
// it holds the address of the page you are on, and completing against it would
// send the beginning of every URL you edit to the search provider.
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
  // A private session must never hand what is being typed to a search
  // provider, and the preference (absent means on) can switch it off entirely.
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  const BOOL enabled =
      [defaults objectForKey:@"BlinkSearchSuggestions"] == nil ||
      [defaults boolForKey:@"BlinkSearchSuggestions"];
  // This request goes out through NSURLSession, which knows nothing about the
  // proxy configured for the browser's own network stack. Sending it anyway
  // would put the user's typing on the direct connection they configured Tor
  // precisely to avoid, so with a proxy set there are no suggestions.
  const BOOL proxied = [defaults stringForKey:@"BlinkProxy"].length > 0;
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
  _suggestionTask = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response,
                          NSError* error) {
        if (error || !data) {
          return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:nil];
        // OpenSearch suggestions: ["typed", ["first", "second", ...], ...].
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
    cell.textLabel.textColor = UIColor.whiteColor;
  }
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
std::unique_ptr<content::ScopedAccessibilityMode> _scopedAccessibilityMode;

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (UIColor*)backgroundColorDefault {
  // The toolbar background follows the theme color: warm red-orange normally,
  // dark purple in a private session.
  return BlinkerThemeColor();
}

+ (UIColor*)backgroundColorTracing {
  return [UIColor colorWithRed:234.0 / 255.0
                         green:67.0 / 255.0
                          blue:53.0 / 255.0
                         alpha:1.0];
}

#if BUILDFLAG(IS_IOS_TVOS)
// The following methods handle tvOS's focus engine by implementing the
// following behavior:
// 1. The content view is focused and receives user input by default.
// 2. Pressing the Menu button in the remote control switches focus to
//    `_toolbarContentView` so that users can use the toolbar and the location
//    bar.
// 3. Pressing the Menu button again after that will switch to the home screen,
//    and swiping down to focus the content view will reset the behavior
//    described in 1).
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
  // `userInteractionEnabled` is false when we create `_toolbarContentView` so
  // that we focus on `_contentView` by default instead of the Back button in
  // the toolbar.
  // We set it to true when explicitly pressing the Back button on the remote
  // control in order to focus the toolbar.
  return _toolbarContentView.userInteractionEnabled ? @[ _toolbarContentView ]
                                                    : @[ _contentView ];
}
#endif

- (void)viewDidLoad {
  [super viewDidLoad];

  // Dark root background so the home-indicator / safe-area edge never flashes
  // white behind the web content during launch, rotation, or keyboard shifts.
  self.view.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];

  // Create a web content view.
  self.contentView = [[UIView alloc] init];
  [self.view addSubview:_contentView];

  // Create a toolbar.
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
    self.urlField = [self makeURLBar];
    // The toolbar already tints dark purple in a private session via
    // backgroundColorDefault; just label the empty URL field to match.
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

    // Constraint the toolbar background view. (Vertical position — top vs
    // bottom — is set by -applyToolbarPosition so it can be toggled in
    // Settings.)
    _toolbarBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_toolbarBackgroundView.leadingAnchor
          constraintEqualToAnchor:self.view.leadingAnchor],
      [_toolbarBackgroundView.trailingAnchor
          constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // Constraint the toolbar content view.
    _toolbarContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      // This height constraint is somewhat arbitrary: the idea is that it gives
      // us enough space to centralize the buttons inside |_toolbarContentView|
      // while having enough top and bottom margins.
      // Twice the size of a button also accounts for platforms such as tvOS,
      // where focused buttons are larger and have a drop shadow.
      [_toolbarContentView.heightAnchor
          constraintEqualToAnchor:_backButton.heightAnchor
                       multiplier:2.0],
    ]];
  }  // if (!content::Shell::ShouldHideToolbar())

  // Constraint the web content view. (Horizontal here; vertical top/bottom is
  // managed by -applyToolbarPosition together with the toolbar.)
  _contentView.translatesAutoresizingMaskIntoConstraints = NO;
  self.contentHorizontalConstraints = @[
    [_contentView.leadingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_contentView.trailingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
  ];
  [NSLayoutConstraint activateConstraints:_contentHorizontalConstraints];
  [self applyToolbarPosition];

  // Enable Accessibility if VoiceOver is already running.
  if (UIAccessibilityIsVoiceOverRunning()) {
    _scopedAccessibilityMode =
        content::BrowserAccessibilityState::GetInstance()
            ->CreateScopedModeForProcess(kVoiceOverEnabledAXMode);
  }

  // Register for VoiceOver notifications.
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

  // Restore the persisted appearance (web prefers-color-scheme + iOS chrome).
  NSInteger appearance =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"BlinkAppearance"];
  if (appearance == UIUserInterfaceStyleLight ||
      appearance == UIUserInterfaceStyleDark) {
    [self applyWebColorScheme:(UIUserInterfaceStyle)appearance];
    if (@available(iOS 13.0, *)) {
      self.view.window.overrideUserInterfaceStyle =
          (UIUserInterfaceStyle)appearance;
    }
  }

  // Show the native start page if this tab opened blank.
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
  title.text = @"Blinker Fluid Locked";
  title.textColor = UIColor.whiteColor;
  title.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
  title.translatesAutoresizingMaskIntoConstraints = NO;
  UIButton* unlock = [UIButton buttonWithType:UIButtonTypeSystem];
  [unlock setTitle:@"Open with Face ID/Password" forState:UIControlStateNormal];
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
  context.localizedCancelTitle = @"Cancel";
  NSError* error = nil;
  if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                            error:&error]) {
    return;
  }
  [context
       evaluatePolicy:LAPolicyDeviceOwnerAuthentication
      localizedReason:@"Unlock your Blinker Fluid browsing session"
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
                      }
                    }
                  });
                }];
}

- (void)darkModeDidChange {
  BOOL darkModeEnabled =
      (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
  _urlField.backgroundColor =
      darkModeEnabled ? [UIColor darkGrayColor] : [UIColor whiteColor];
}

- (id)initWithShell:(content::Shell*)shell {
  if ((self = [super init])) {
    _shell = shell;
    // Restore the persisted search engine selection.
    NSInteger se = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"BlinkSearchEngine"];
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
    // Asset catalogs from newer Xcode releases can fail to expose named images
    // on legacy iOS.  Keep the control visible and usable in that case instead
    // of silently installing a nil (invisible) image.
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
  // A touchscreen tap can emit both TouchUpInside and
  // PrimaryActionTriggered. Registering both invokes navigation actions twice
  // (notably Back), so iOS buttons use one event.
  [button addTarget:self
                action:action
      forControlEvents:UIControlEventTouchUpInside];
#endif
  return button;
}

- (UITextField*)makeURLBar {
  UITextField* field = [[UITextField alloc] init];
  field.placeholder = @"Search or type URL";
  field.tintColor = _toolbarBackgroundView.backgroundColor;
  [field setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                           forAxis:UILayoutConstraintAxisHorizontal];
  field.delegate = self;
  field.borderStyle = UITextBorderStyleRoundedRect;
  field.keyboardType = UIKeyboardTypeWebSearch;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
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

  // |toolbarBackgroundView| is a 1-item UIStackView. We use a UIStackView so
  // that we can:
  // 1. Easily hide |toolbarContentView| when entering fullscreen mode in a
  // way that removes it from the layout.
  // 2. Let UIStackView figure out most constraints for |toolbarContentView|
  // so that we do not have to do it manually.
  toolbarBackgroundView.backgroundColor =
      [ContentShellWindowDelegate backgroundColorDefault];
  // UIStackView did not render its backgroundColor on iOS 12. Paint its
  // backing layer as well so the normal orange/private purple toolbar is
  // visible on every supported OS version.
  toolbarBackgroundView.layer.backgroundColor =
      [ContentShellWindowDelegate backgroundColorDefault].CGColor;
  toolbarBackgroundView.opaque = YES;

  // On iOS 11/12, setting either UIStackView.backgroundColor or its CALayer's
  // background can still produce a transparent/black toolbar after layout.
  // Pin an ordinary UIView behind the arranged content so UIKit has a concrete
  // orange surface to composite.
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

  // Use the root view's layout margins (which account for safe areas and the
  // system's minimum margins).
  toolbarBackgroundView.layoutMarginsRelativeArrangement = YES;
  toolbarBackgroundView.preservesSuperviewLayoutMargins = YES;

  return toolbarBackgroundView;
}

- (UIStackView*)createToolbarContentView {
  UIStackView* toolbarContentView = [[UIStackView alloc] init];

  // Older UIStackView implementations do not reliably paint backgroundColor.
  UIColor* toolbarColor = [ContentShellWindowDelegate backgroundColorDefault];
  toolbarContentView.backgroundColor = toolbarColor;
  toolbarContentView.layer.backgroundColor = toolbarColor.CGColor;
  toolbarContentView.opaque = YES;

#if BUILDFLAG(IS_IOS_TVOS)
  // On tvOS, make it impossible to focus `_toolbarContentView` by simply
  // swiping up on the remote control since this behavior is not intuitive.
  toolbarContentView.userInteractionEnabled = NO;
#endif

  toolbarContentView.alignment = UIStackViewAlignmentCenter;
  toolbarContentView.axis = UILayoutConstraintAxisHorizontal;
  toolbarContentView.spacing = 16.0;

  return toolbarContentView;
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
  // Reload through the normal navigation path.
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

  // The off-the-record browser context is chosen when the process starts, so a
  // toggle only takes effect on the next launch. Offer to restart now; the
  // title and "Restart required" message are already localized.
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
                         exit(0);
                       });
        return;
      }
      BLINKER_DIAGF("APP_RESTART: helper failed error=%d", result);
    }
    dlclose(jailbreak);
  }

  // No usable relaunch helper: on Dopamine exec_cmd_nowait returns 1 from
  // inside the app sandbox. Quit anyway, because the settings that ask for a
  // restart only take effect on the next launch. The previous fallback opened
  // TrollStore's enable-jit URL, which switches to TrollStore and returns to a
  // still-running process — it looked like something happened while applying
  // nothing.
  BLINKER_DIAG("APP_RESTART: no relaunch helper; quitting for manual reopen");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   exit(0);
                 });
}

// Tab management. Each tab is a content::Shell (which already owns
// a UIWindow with a working toolbar); we switch tabs by making the chosen
// shell's window key+visible in the current scene. Incognito = a tab whose
// WebContents uses the off-the-record BrowserContext.
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
  if (shell->web_contents() && shell->web_contents()->WasDiscarded()) {
    GURL reload = shell->web_contents()->GetLastCommittedURL();
    shell->web_contents()->SetPageFrozen(false);
    if (reload.is_valid() && reload.SchemeIsHTTPOrHTTPS()) {
      BLINKER_DIAG("TAB_LIFECYCLE: reloading discarded tab");
      shell->LoadURL(reload);
    }
  }
  GURL pending = content::TakePendingRestoreURL(shell);
  if (pending.is_valid() && pending.SchemeIsHTTPOrHTTPS() &&
      shell->web_contents()) {
    BLINKER_DIAG("SESSION_RESTORE: loading deferred tab");
    shell->LoadURL(pending);
  }
  [self logTab:"switched to tab" shell:shell];
  // Each tab owns a UIWindow. Hide every inactive window and notify its
  // WebContents so background tabs stop compositing, running animation frames,
  // and retaining foreground graphics resources.
  for (content::Shell* candidate : content::Shell::windows()) {
    UIWindow* candidateWindow = candidate->window().Get();
    const bool selected = candidate == shell;
    if (!selected && candidateWindow && !candidateWindow.hidden) {
      BlinkCaptureTabPreview(candidate);
    }
    if (candidateWindow) {
      candidateWindow.hidden = !selected;
    }
    if (candidate->web_contents()) {
      if (selected) {
        candidate->web_contents()->SetPageFrozen(false);
        candidate->web_contents()->WasShown();
      } else {
        candidate->web_contents()->WasHidden();
        candidate->web_contents()->SetPageFrozen(true);
      }
    }
  }
  UIWindow* win = shell->window().Get();
  if (win) {
    if (@available(iOS 13.0, *)) {
      win.windowScene = self.view.window.windowScene;
    }
    win.hidden = NO;
    [win makeKeyAndVisible];
  }
  BlinkDiscardBackgroundTabs(shell);
  // Switching must NOT change the tab count or create a WebContents.
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
  // New tabs open the custom homepage if set, otherwise a blank tab showing the
  // native start page.
  NSString* homepage =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"BlinkHomepage"];
  GURL url = homepage.length ? GURL(base::SysNSStringToUTF8(homepage))
                             : GURL("about:blank");
  if (!url.is_valid()) {
    url = GURL("about:blank");
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
    if ([existing.topViewController isKindOfClass:[BlinkListVC class]] &&
        ((BlinkListVC*)existing.viewControllers.firstObject).compactRows) {
      vc.dismissOnAdd = NO;
      [existing pushViewController:vc animated:YES];
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
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)loadURLString:(NSString*)urlStr {
  GURL u(base::SysNSStringToUTF8(urlStr));
  if (u.is_valid() && _shell) {
    _shell->LoadURL(u);
  }
}

// Navigate the current tab to the built-in Blinker Fluid start page.
- (void)goHome {
  // Load a blank tab; -setURL: then shows the native start page over it.
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
  CGFloat width = MIN(self.view.bounds.size.width, 600);
  CGFloat cardWidth = floor((width - 44) / 2);
  layout.itemSize = CGSizeMake(cardWidth, cardWidth * 1.34);
  layout.sectionInset = UIEdgeInsetsMake(16, 14, 24, 14);
  layout.minimumInteritemSpacing = 12;
  layout.minimumLineSpacing = 16;
  BlinkTabsVC* vc = [[BlinkTabsVC alloc] initWithCollectionViewLayout:layout];
  vc.titles = [NSMutableArray array];
  vc.urls = [NSMutableArray array];
  vc.previews = [NSMutableArray array];
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
    [vc.urls addObject:url];
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
    // Shell::windows() backs every other consumer of tab order -- the switcher,
    // session save/restore, next/previous tab -- so move the entry there and
    // keep the local shell pointers in step.
    std::vector<content::Shell*>& windows = content::Shell::windows();
    if (from < 0 || to < 0 || from >= (NSInteger)windows.size() ||
        to >= (NSInteger)windows.size() || from >= (NSInteger)shells.count ||
        to >= (NSInteger)shells.count) {
      return;
    }
    content::Shell* moved = windows[from];
    windows.erase(windows.begin() + from);
    windows.insert(windows.begin() + to, moved);
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
      BLINKER_DIAG("TAB_MANAGER: kept final tab open");
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

// Bookmarks (stored in NSUserDefaults).
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
                       message:@"Enter a name and website address."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"Name";
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
                                               message:@"Enter a complete "
                                                       @"website address."
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
                               stringWithFormat:@"%lu items",
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
    chooser.title = @"Add";
    chooser.dismissOnSelect = NO;
    chooser.titles = [@[ @"Bookmark", @"Folder" ] mutableCopy];
    chooser.subtitles =
        [@[ @"Save a website address", @"Organize bookmarks" ] mutableCopy];
    chooser.imageNames = @[ @"bookmark", @"folder.fill" ];
    __weak BlinkListVC* weakChooser = chooser;
    chooser.onSelect = ^(NSInteger choice) {
      BlinkBookmarkEditorVC* editor = [[BlinkBookmarkEditorVC alloc] init];
      editor.folderMode = choice == 1;
      editor.onSave = ^(NSString* name, NSString* url) {
        BOOL folder = choice == 1;
        NSMutableDictionary* item =
            folder ? [@{@"title" : name, @"children" : [NSMutableArray array]}
                         mutableCopy]
                   : [@{@"title" : name, @"url" : url} mutableCopy];
        [bms addObject:item];
        [weakSelf saveBookmarks:root];
        [weakBookmarksVC.titles addObject:name];
        [weakBookmarksVC.subtitles addObject:folder ? @"0 items" : url];
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

// Downloads — content_shell saves to <data>/MyFiles/Downloads.
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
    [vc.titles addObject:@"No downloads yet"];
    [vc.subtitles addObject:@""];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    if (i >= (NSInteger)paths.count) {
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

// Toolbar position: top (default) or bottom, persisted in NSUserDefaults.
- (void)applyToolbarPosition {
  const BOOL hideToolbar =
      content::Shell::ShouldHideToolbar() || !_toolbarBackgroundView;
  // Toggling the setting in Settings applies this to EVERY open tab. A tab
  // whose views are not fully built (e.g. mid-restore) would build constraints
  // from a nil view/anchor and throw an NSException, taking down the whole app.
  // Skip it — it applies the current setting itself once its views exist (the
  // setup path calls this method after creating them).
  if (!_contentView || (!hideToolbar && !_loadingProgressView)) {
    return;
  }
  [NSLayoutConstraint deactivateConstraints:_topPosConstraints];
  [NSLayoutConstraint deactivateConstraints:_bottomPosConstraints];
  if (hideToolbar) {
    _topPosConstraints = @[
      [_contentView.topAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      // Extend web content to the true bottom edge (under the home indicator),
      // as Safari/Chrome do, instead of stopping at the safe-area line — that
      // gap left the root view showing as an empty white bar at the bottom.
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
    // Extend web content to the true bottom edge (under the home indicator)
    // rather than the safe-area line, which otherwise leaves an empty white
    // bar.
    [_contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                              constant:-_keyboardViewportInset],
  ];
  if (_keyboardViewportInset > 0) {
    // The bottom toolbar remains behind the keyboard. End web content exactly
    // at the keyboard edge; subtracting both toolbar height and keyboard inset
    // created the oversized gray gap.
    _bottomPosConstraints = @[
      [_toolbarBackgroundView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor],
      [_contentView.topAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [_contentView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor
                         constant:-_keyboardViewportInset],
    ];
  } else {
    _bottomPosConstraints = @[
      [_toolbarBackgroundView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor],
      [_contentView.topAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [_contentView.bottomAnchor
          constraintEqualToAnchor:_toolbarBackgroundView.topAnchor],
    ];
  }
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
  CGFloat clamped = MAX((CGFloat)0, inset);
  if (fabs(_keyboardViewportInset - clamped) < 1) {
    return;
  }
  _keyboardViewportInset = clamped;
  [self applyToolbarPosition];
  [UIView animateWithDuration:0.20
                   animations:^{
                     [self.view layoutIfNeeded];
                   }];
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

// Localizes Blinker Fluid's browser chrome independently of the iOS keyboard.
// Website content still decides whether to honor the matching Accept-Language.
static NSString* BlinkL(NSString* english) {
  static NSArray<NSString*>* keys;
  static NSDictionary<NSString*, NSArray<NSString*>*>* tables;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keys = [@"Menu|Reload|New Tab|Tabs|Home|Bookmarks|Downloads|Request Mobile "
            @"Page|Request Desktop Page|Page Zoom|Share Link|Settings|Check "
            @"for Updates|Latest GitHub release|BROWSER|LIBRARY|APP|Search "
            @"Engine|Appearance|Toolbar Position|Languages|Ad & Tracker "
            @"Blocking|Tor / Proxy|Password / Face ID Lock|HTTPS-First "
            @"Navigation|Website Permissions|Clear Browsing "
            @"Data|History|JavaScript Engine|About Blinker "
            @"Fluid|GENERAL|PRIVACY|PERFORMANCE|ABOUT|System|Light|Dark|Bottom|"
            @"Top|On|Off" componentsSeparatedByString:@"|"];
    NSDictionary<NSString*, NSString*>* joined = @{
      @"es" : @"Menú|Recargar|Nueva "
              @"pestaña|Pestañas|Inicio|Marcadores|Descargas|Solicitar sitio "
              @"móvil|Solicitar sitio de escritorio|Zoom de página|Compartir "
              @"enlace|Ajustes|Buscar actualizaciones|Última versión de "
              @"GitHub|NAVEGADOR|BIBLIOTECA|APP|Motor de "
              @"búsqueda|Apariencia|Posición de la barra|Idiomas|Bloqueo de "
              @"anuncios y rastreadores|Tor / Proxy|Bloqueo con contraseña / "
              @"Face ID|Navegación HTTPS primero|Permisos de sitios web|Borrar "
              @"datos de navegación|Historial|Motor JavaScript|Acerca de "
              @"Blinker Fluid|GENERAL|PRIVACIDAD|RENDIMIENTO|ACERCA "
              @"DE|Sistema|Claro|Oscuro|Abajo|Arriba|Activado|Desactivado",
      @"zh" : @"菜单|重新加载|新建标签页|标签页|主页|书签|下载|请求移动版网页|"
              @"请求桌面版网页|页面缩放|分享链接|设置|检查更新|最新 GitHub "
              @"版本|浏览器|资料库|应用|搜索引擎|外观|工具栏位置|语言|"
              @"广告与跟踪器拦截|Tor / 代理|密码 / Face ID 锁定|HTTPS "
              @"优先导航|网站权限|清除浏览数据|历史记录|JavaScript 引擎|关于 "
              @"Blinker "
              @"Fluid|通用|隐私|性能|关于|系统|浅色|深色|底部|顶部|开启|关闭",
      @"ru" : @"Меню|Обновить|Новая "
              @"вкладка|Вкладки|Главная|Закладки|Загрузки|Запросить мобильную "
              @"версию|Запросить версию для ПК|Масштаб страницы|Поделиться "
              @"ссылкой|Настройки|Проверить обновления|Последний выпуск "
              @"GitHub|БРАУЗЕР|БИБЛИОТЕКА|ПРИЛОЖЕНИЕ|Поисковая "
              @"система|Оформление|Положение панели|Языки|Блокировка рекламы и "
              @"трекеров|Tor / Прокси|Блокировка паролем / Face ID|Сначала "
              @"HTTPS|Разрешения сайтов|Очистить данные "
              @"браузера|История|Движок JavaScript|О Blinker "
              @"Fluid|ОБЩИЕ|КОНФИДЕНЦИАЛЬНОСТЬ|ПРОИЗВОДИТЕЛЬНОСТЬ|О "
              @"ПРИЛОЖЕНИИ|Системная|Светлая|Тёмная|Снизу|Сверху|Вкл.|Выкл.",
      @"uk" :
          @"Меню|Оновити|Нова "
          @"вкладка|Вкладки|Головна|Закладки|Завантаження|Запросити мобільну "
          @"версію|Запросити версію для комп’ютера|Масштаб сторінки|Поділитися "
          @"посиланням|Налаштування|Перевірити оновлення|Останній випуск "
          @"GitHub|БРАУЗЕР|БІБЛІОТЕКА|ПРОГРАМА|Пошукова "
          @"система|Вигляд|Положення панелі|Мови|Блокування реклами й "
          @"трекерів|Tor / Проксі|Блокування паролем / Face ID|Спочатку "
          @"HTTPS|Дозволи сайтів|Очистити дані перегляду|Історія|Рушій "
          @"JavaScript|Про Blinker "
          @"Fluid|ЗАГАЛЬНІ|КОНФІДЕНЦІЙНІСТЬ|ПРОДУКТИВНІСТЬ|ПРО "
          @"ПРОГРАМУ|Системна|Світла|Темна|Знизу|Зверху|Увімк.|Вимк.",
      @"pl" : @"Menu|Odśwież|Nowa karta|Karty|Strona "
              @"główna|Zakładki|Pobrane|Wersja mobilna|Wersja na "
              @"komputer|Powiększenie strony|Udostępnij "
              @"link|Ustawienia|Sprawdź aktualizacje|Najnowsze wydanie "
              @"GitHub|PRZEGLĄDARKA|BIBLIOTEKA|APLIKACJA|Wyszukiwarka|Wygląd|"
              @"Położenie paska|Języki|Blokowanie reklam i elementów "
              @"śledzących|Tor / Proxy|Blokada hasłem / Face ID|Najpierw "
              @"HTTPS|Uprawnienia witryn|Wyczyść dane "
              @"przeglądania|Historia|Silnik JavaScript|O Blinker "
              @"Fluid|OGÓLNE|PRYWATNOŚĆ|WYDAJNOŚĆ|INFORMACJE|Systemowy|Jasny|"
              @"Ciemny|Dół|Góra|Wł.|Wył.",
      @"cs" :
          @"Nabídka|Načíst znovu|Nový panel|Panely|Domů|Záložky|Stažené "
          @"soubory|Mobilní verze|Verze pro počítač|Přiblížení stránky|Sdílet "
          @"odkaz|Nastavení|Zkontrolovat aktualizace|Nejnovější vydání "
          @"GitHub|PROHLÍŽEČ|KNIHOVNA|APLIKACE|Vyhledávač|Vzhled|Poloha "
          @"panelu|Jazyky|Blokování reklam a sledování|Tor / Proxy|Zámek "
          @"heslem / Face ID|Nejprve HTTPS|Oprávnění webů|Vymazat údaje o "
          @"prohlížení|Historie|JavaScriptový engine|O aplikaci Blinker "
          @"Fluid|OBECNÉ|SOUKROMÍ|VÝKON|O "
          @"APLIKACI|Systém|Světlý|Tmavý|Dole|Nahoře|Zapnuto|Vypnuto",
      @"de" : @"Menü|Neu laden|Neuer "
              @"Tab|Tabs|Startseite|Lesezeichen|Downloads|Mobile Website "
              @"anfordern|Desktop-Website anfordern|Seitenzoom|Link "
              @"teilen|Einstellungen|Nach Updates suchen|Neueste "
              @"GitHub-Version|BROWSER|BIBLIOTHEK|APP|Suchmaschine|Darstellung|"
              @"Position der Symbolleiste|Sprachen|Werbe- und "
              @"Trackerblocker|Tor / Proxy|Passwort- / Face-ID-Sperre|HTTPS "
              @"zuerst|Website-Berechtigungen|Browserdaten "
              @"löschen|Verlauf|JavaScript-Engine|Über Blinker "
              @"Fluid|ALLGEMEIN|DATENSCHUTZ|LEISTUNG|ÜBER|System|Hell|Dunkel|"
              @"Unten|Oben|Ein|Aus",
      @"ja" :
          @"メニュー|再読み込み|新しいタブ|タブ|ホーム|ブックマーク|"
          @"ダウンロード|モバイル版を表示|デスクトップ版を表示|ページのズーム|"
          @"リンクを共有|設定|アップデートを確認|最新の GitHub "
          @"リリース|ブラウザ|ライブラリ|アプリ|検索エンジン|外観|"
          @"ツールバーの位置|言語|広告・トラッカーブロック|Tor / "
          @"プロキシ|パスワード / Face ID ロック|HTTPS "
          @"優先ナビゲーション|ウェブサイトの権限|閲覧データを消去|履歴|"
          @"JavaScript エンジン|Blinker Fluid "
          @"について|一般|プライバシー|パフォーマンス|情報|システム|ライト|"
          @"ダーク|下|上|オン|オフ",
      @"ko" :
          @"메뉴|새로고침|새 탭|탭|홈|북마크|다운로드|모바일 페이지 "
          @"요청|데스크톱 페이지 요청|페이지 확대/축소|링크 공유|설정|업데이트 "
          @"확인|최신 GitHub 릴리스|브라우저|라이브러리|앱|검색 엔진|모양|도구 "
          @"모음 위치|언어|광고 및 추적기 차단|Tor / 프록시|암호 / Face ID "
          @"잠금|HTTPS 우선 탐색|웹사이트 권한|인터넷 사용 기록 "
          @"삭제|기록|JavaScript 엔진|Blinker Fluid 정보|일반|개인정보 "
          @"보호|성능|정보|시스템|라이트|다크|아래|위|켜짐|꺼짐",
      @"vi" : @"Trình đơn|Tải lại|Thẻ mới|Các thẻ|Trang chủ|Dấu trang|Tải "
              @"xuống|Yêu cầu trang di động|Yêu cầu trang máy tính|Thu phóng "
              @"trang|Chia sẻ liên kết|Cài đặt|Kiểm tra cập nhật|Bản phát hành "
              @"GitHub mới nhất|TRÌNH DUYỆT|THƯ VIỆN|ỨNG DỤNG|Công cụ tìm "
              @"kiếm|Giao diện|Vị trí thanh công cụ|Ngôn ngữ|Chặn quảng cáo và "
              @"trình theo dõi|Tor / Proxy|Khóa bằng mật khẩu / Face ID|Ưu "
              @"tiên HTTPS|Quyền trang web|Xóa dữ liệu duyệt web|Lịch sử|Công "
              @"cụ JavaScript|Giới thiệu Blinker Fluid|CHUNG|QUYỀN RIÊNG "
              @"TƯ|HIỆU NĂNG|GIỚI THIỆU|Hệ thống|Sáng|Tối|Dưới|Trên|Bật|Tắt",
      @"tr" : @"Menü|Yeniden Yükle|Yeni Sekme|Sekmeler|Ana Sayfa|Yer "
              @"İmleri|İndirilenler|Mobil Sayfa İste|Masaüstü Sayfa İste|Sayfa "
              @"Yakınlaştırma|Bağlantıyı Paylaş|Ayarlar|Güncellemeleri "
              @"Denetle|En Son GitHub Sürümü|TARAYICI|KİTAPLIK|UYGULAMA|Arama "
              @"Motoru|Görünüm|Araç Çubuğu Konumu|Diller|Reklam ve İzleyici "
              @"Engelleme|Tor / Proxy|Parola / Face ID Kilidi|Önce HTTPS|Web "
              @"Sitesi İzinleri|Tarama Verilerini Temizle|Geçmiş|JavaScript "
              @"Motoru|Blinker Fluid "
              @"Hakkında|GENEL|GİZLİLİK|PERFORMANS|HAKKINDA|Sistem|Açık|Koyu|"
              @"Alt|Üst|Açık|Kapalı",
      @"fr" :
          @"Menu|Actualiser|Nouvel "
          @"onglet|Onglets|Accueil|Favoris|Téléchargements|Demander la version "
          @"mobile|Demander la version pour ordinateur|Zoom de la "
          @"page|Partager le lien|Réglages|Rechercher les mises à "
          @"jour|Dernière version GitHub|NAVIGATEUR|BIBLIOTHÈQUE|APP|Moteur de "
          @"recherche|Apparence|Position de la barre d’outils|Langues|Blocage "
          @"des publicités et traqueurs|Tor / Proxy|Verrouillage par mot de "
          @"passe / Face ID|Navigation HTTPS prioritaire|Autorisations des "
          @"sites|Effacer les données de navigation|Historique|Moteur "
          @"JavaScript|À propos de Blinker "
          @"Fluid|GÉNÉRAL|CONFIDENTIALITÉ|PERFORMANCES|À "
          @"PROPOS|Système|Clair|Sombre|En bas|En haut|Activé|Désactivé",
      @"sv" : @"Meny|Läs in igen|Ny flik|Flikar|Hem|Bokmärken|Hämtningar|Begär "
              @"mobilwebbplats|Begär datorwebbplats|Sidzoom|Dela "
              @"länk|Inställningar|Sök efter uppdateringar|Senaste "
              @"GitHub-versionen|WEBBLÄSARE|BIBLIOTEK|APP|Sökmotor|Utseende|"
              @"Verktygsfältets placering|Språk|Blockering av annonser och "
              @"spårare|Tor / Proxy|Lås med lösenord / Face ID|HTTPS "
              @"först|Webbplatsbehörigheter|Rensa "
              @"webbinformation|Historik|JavaScript-motor|Om Blinker "
              @"Fluid|ALLMÄNT|INTEGRITET|PRESTANDA|OM|System|Ljust|Mörkt|"
              @"Nederkant|Överkant|På|Av",
      @"ar" :
          @"القائمة|إعادة التحميل|علامة تبويب جديدة|علامات "
          @"التبويب|الرئيسية|الإشارات المرجعية|التنزيلات|طلب صفحة الهاتف|طلب "
          @"صفحة سطح المكتب|تكبير الصفحة|مشاركة الرابط|الإعدادات|التحقق من "
          @"التحديثات|أحدث إصدار على GitHub|المتصفح|المكتبة|التطبيق|محرك "
          @"البحث|المظهر|موضع شريط الأدوات|اللغات|حظر الإعلانات وأدوات "
          @"التتبع|Tor / الوكيل|قفل بكلمة مرور / Face ID|HTTPS أولاً|أذونات "
          @"المواقع|مسح بيانات التصفح|السجل|محرك JavaScript|حول Blinker "
          @"Fluid|عام|الخصوصية|الأداء|حول|النظام|فاتح|داكن|أسفل|أعلى|تشغيل|"
          @"إيقاف",
    };
    NSMutableDictionary* built = [NSMutableDictionary dictionary];
    [joined enumerateKeysAndObjectsUsingBlock:^(NSString* code, NSString* value,
                                                BOOL* stop) {
      NSArray* strings = [value componentsSeparatedByString:@"|"];
      if (strings.count == keys.count) {
        built[code] = strings;
      }
    }];
    tables = [built copy];
  });

  NSString* accept = [[NSUserDefaults standardUserDefaults]
                         stringForKey:@"BlinkLanguageAccept"]
                         ?: @"en-US,en";
  NSString* code = [[[accept componentsSeparatedByString:@","] firstObject]
                       componentsSeparatedByString:@"-"]
                       .firstObject.lowercaseString;
  if ([english isEqualToString:@"Restart Blinker Fluid"]) {
    return @{
      @"es" : @"Reiniciar Blinker Fluid",
      @"zh" : @"重新启动 Blinker Fluid",
      @"ru" : @"Перезапустить Blinker Fluid",
      @"uk" : @"Перезапустити Blinker Fluid",
      @"pl" : @"Uruchom ponownie Blinker Fluid",
      @"cs" : @"Restartovat Blinker Fluid",
      @"de" : @"Blinker Fluid neu starten",
      @"ja" : @"Blinker Fluid を再起動",
      @"ko" : @"Blinker Fluid 재시작",
      @"vi" : @"Khởi động lại Blinker Fluid",
      @"tr" : @"Blinker Fluid’ı Yeniden Başlat",
      @"fr" : @"Redémarrer Blinker Fluid",
      @"sv" : @"Starta om Blinker Fluid",
      @"ar" : @"إعادة تشغيل Blinker Fluid",
    }[code]
               ?: english;
  }
  if ([english isEqualToString:@"Blinker Fluid will close. Open it again to "
                               @"apply."]) {
    return @{
      @"es" : @"Blinker Fluid se cerrará. Ábrelo de nuevo para aplicar.",
      @"zh" : @"Blinker Fluid 将关闭。请重新打开以应用。",
      @"ru" : @"Blinker Fluid закроется. Откройте его снова, чтобы применить.",
      @"uk" :
          @"Blinker Fluid закриється. Відкрийте його знову, щоб застосувати.",
      @"pl" : @"Blinker Fluid zostanie zamknięty. Otwórz go ponownie, aby "
              @"zastosować.",
      @"cs" : @"Blinker Fluid se zavře. Znovu jej otevřete pro použití.",
      @"de" : @"Blinker Fluid wird beendet. Zum Übernehmen erneut öffnen.",
      @"ja" : @"Blinker Fluid を終了します。もう一度開くと適用されます。",
      @"ko" : @"Blinker Fluid가 종료됩니다. 다시 열면 적용됩니다.",
      @"vi" : @"Blinker Fluid sẽ đóng. Mở lại để áp dụng.",
      @"tr" : @"Blinker Fluid kapanacak. Uygulamak için tekrar açın.",
      @"fr" : @"Blinker Fluid va se fermer. Rouvrez-le pour appliquer.",
      @"sv" : @"Blinker Fluid stängs. Öppna det igen för att tillämpa.",
      @"ar" : @"سيتم إغلاق Blinker Fluid. افتحه مرة أخرى للتطبيق.",
    }[code]
               ?: english;
  }
  if ([english isEqualToString:@"Requires the JIT build"]) {
    return @{
      @"es" : @"Requiere la versión JIT",
      @"zh" : @"需要 JIT 版本",
      @"ru" : @"Требуется сборка JIT",
      @"uk" : @"Потрібна збірка JIT",
      @"pl" : @"Wymaga wersji JIT",
      @"cs" : @"Vyžaduje sestavení JIT",
      @"de" : @"Erfordert die JIT-Version",
      @"ja" : @"JIT ビルドが必要です",
      @"ko" : @"JIT 빌드가 필요함",
      @"vi" : @"Cần bản dựng JIT",
      @"tr" : @"JIT sürümü gerekir",
      @"fr" : @"Nécessite la version JIT",
      @"sv" : @"Kräver JIT-versionen",
      @"ar" : @"يتطلب إصدار JIT",
    }[code]
               ?: english;
  }
  if ([english isEqualToString:@"Later"]) {
    return @{
      @"es" : @"Más tarde",
      @"zh" : @"稍后",
      @"ru" : @"Позже",
      @"uk" : @"Пізніше",
      @"pl" : @"Później",
      @"cs" : @"Později",
      @"de" : @"Später",
      @"ja" : @"後で",
      @"ko" : @"나중에",
      @"vi" : @"Để sau",
      @"tr" : @"Daha sonra",
      @"fr" : @"Plus tard",
      @"sv" : @"Senare",
      @"ar" : @"لاحقًا",
    }[code]
               ?: english;
  }
  if ([english isEqualToString:@"Private Browsing"] ||
      [english isEqualToString:@"Restart required"]) {
    NSDictionary<NSString*, NSArray<NSString*>*>* translations = @{
      @"es" : @[ @"Navegación privada", @"Reinicio necesario" ],
      @"zh" : @[ @"无痕浏览", @"需要重新启动" ],
      @"ru" : @[ @"Приватный просмотр", @"Требуется перезапуск" ],
      @"uk" : @[ @"Приватний перегляд", @"Потрібен перезапуск" ],
      @"pl" : @[ @"Przeglądanie prywatne", @"Wymagane ponowne uruchomienie" ],
      @"cs" : @[ @"Anonymní prohlížení", @"Je vyžadován restart" ],
      @"de" : @[ @"Privates Surfen", @"Neustart erforderlich" ],
      @"ja" : @[ @"プライベートブラウズ", @"再起動が必要です" ],
      @"ko" : @[ @"비공개 브라우징", @"다시 시작해야 함" ],
      @"vi" : @[ @"Duyệt web riêng tư", @"Cần khởi động lại" ],
      @"tr" : @[ @"Gizli Tarama", @"Yeniden başlatma gerekli" ],
      @"fr" : @[ @"Navigation privée", @"Redémarrage requis" ],
      @"sv" : @[ @"Privat surfning", @"Omstart krävs" ],
      @"ar" : @[ @"التصفح الخاص", @"إعادة التشغيل مطلوبة" ],
    };
    NSArray<NSString*>* values = translations[code];
    if (values) {
      return values[[english isEqualToString:@"Private Browsing"] ? 0 : 1];
    }
  }
  // Dialog strings. Kept in their own keyed table rather than appended to the
  // pipe-delimited one above, because that format drops a whole language the
  // moment one field count drifts, and these are edited far more often.
  // Anything missing here falls through to English rather than breaking.
  static NSDictionary<NSString*, NSDictionary<NSString*, NSString*>*>* dialogs;
  static dispatch_once_t dialogsOnce;
  dispatch_once(&dialogsOnce, ^{
    dialogs = @{
      @"Save" : @{
        @"es" : @"Guardar",
        @"zh" : @"保存",
        @"ru" : @"Сохранить",
        @"uk" : @"Зберегти",
        @"pl" : @"Zapisz",
        @"cs" : @"Uložit",
        @"de" : @"Sichern",
        @"ja" : @"保存",
        @"ko" : @"저장",
        @"vi" : @"Lưu",
        @"tr" : @"Kaydet",
        @"fr" : @"Enregistrer",
        @"sv" : @"Spara",
        @"ar" : @"حفظ"
      },
      @"Cancel" : @{
        @"es" : @"Cancelar",
        @"zh" : @"取消",
        @"ru" : @"Отмена",
        @"uk" : @"Скасувати",
        @"pl" : @"Anuluj",
        @"cs" : @"Zrušit",
        @"de" : @"Abbrechen",
        @"ja" : @"キャンセル",
        @"ko" : @"취소",
        @"vi" : @"Hủy",
        @"tr" : @"İptal",
        @"fr" : @"Annuler",
        @"sv" : @"Avbryt",
        @"ar" : @"إلغاء"
      },
      @"OK" : @{
        @"zh" : @"好",
        @"ru" : @"ОК",
        @"uk" : @"ОК",
        @"ko" : @"확인",
        @"ar" : @"موافق"
      },
      @"Add" : @{
        @"es" : @"Añadir",
        @"zh" : @"添加",
        @"ru" : @"Добавить",
        @"uk" : @"Додати",
        @"pl" : @"Dodaj",
        @"cs" : @"Přidat",
        @"de" : @"Hinzufügen",
        @"ja" : @"追加",
        @"ko" : @"추가",
        @"vi" : @"Thêm",
        @"tr" : @"Ekle",
        @"fr" : @"Ajouter",
        @"sv" : @"Lägg till",
        @"ar" : @"إضافة"
      },
      @"Clear" : @{
        @"es" : @"Borrar",
        @"zh" : @"清除",
        @"ru" : @"Очистить",
        @"uk" : @"Очистити",
        @"pl" : @"Wyczyść",
        @"cs" : @"Vymazat",
        @"de" : @"Löschen",
        @"ja" : @"消去",
        @"ko" : @"지우기",
        @"vi" : @"Xóa",
        @"tr" : @"Temizle",
        @"fr" : @"Effacer",
        @"sv" : @"Rensa",
        @"ar" : @"مسح"
      },
      @"Not Now" : @{
        @"es" : @"Ahora no",
        @"zh" : @"暂不",
        @"ru" : @"Не сейчас",
        @"uk" : @"Не зараз",
        @"pl" : @"Nie teraz",
        @"cs" : @"Teď ne",
        @"de" : @"Jetzt nicht",
        @"ja" : @"後で",
        @"ko" : @"나중에",
        @"vi" : @"Để sau",
        @"tr" : @"Şimdi değil",
        @"fr" : @"Plus tard",
        @"sv" : @"Inte nu",
        @"ar" : @"ليس الآن"
      },
      @"Edit Shortcut" : @{
        @"es" : @"Editar acceso directo",
        @"zh" : @"编辑快捷方式",
        @"ru" : @"Изменить ярлык",
        @"uk" : @"Змінити ярлик",
        @"pl" : @"Edytuj skrót",
        @"cs" : @"Upravit zkratku",
        @"de" : @"Kurzbefehl bearbeiten",
        @"ja" : @"ショートカットを編集",
        @"ko" : @"단축어 편집",
        @"vi" : @"Sửa lối tắt",
        @"tr" : @"Kısayolu Düzenle",
        @"fr" : @"Modifier le raccourci",
        @"sv" : @"Redigera genväg",
        @"ar" : @"تعديل الاختصار"
      },
      @"Add Bookmark" : @{
        @"es" : @"Añadir marcador",
        @"zh" : @"添加书签",
        @"ru" : @"Добавить закладку",
        @"uk" : @"Додати закладку",
        @"pl" : @"Dodaj zakładkę",
        @"cs" : @"Přidat záložku",
        @"de" : @"Lesezeichen hinzufügen",
        @"ja" : @"ブックマークを追加",
        @"ko" : @"북마크 추가",
        @"vi" : @"Thêm dấu trang",
        @"tr" : @"Yer İmi Ekle",
        @"fr" : @"Ajouter un favori",
        @"sv" : @"Lägg till bokmärke",
        @"ar" : @"إضافة إشارة مرجعية"
      },
      @"Invalid address" : @{
        @"es" : @"Dirección no válida",
        @"zh" : @"地址无效",
        @"ru" : @"Неверный адрес",
        @"uk" : @"Неправильна адреса",
        @"pl" : @"Nieprawidłowy adres",
        @"cs" : @"Neplatná adresa",
        @"de" : @"Ungültige Adresse",
        @"ja" : @"無効なアドレス",
        @"ko" : @"잘못된 주소",
        @"vi" : @"Địa chỉ không hợp lệ",
        @"tr" : @"Geçersiz adres",
        @"fr" : @"Adresse non valide",
        @"sv" : @"Ogiltig adress",
        @"ar" : @"عنوان غير صالح"
      },
      @"Invalid proxy" : @{
        @"es" : @"Proxy no válido",
        @"zh" : @"代理无效",
        @"ru" : @"Неверный прокси",
        @"uk" : @"Неправильний проксі",
        @"pl" : @"Nieprawidłowy serwer proxy",
        @"cs" : @"Neplatný proxy server",
        @"de" : @"Ungültiger Proxy",
        @"ja" : @"無効なプロキシ",
        @"ko" : @"잘못된 프록시",
        @"vi" : @"Proxy không hợp lệ",
        @"tr" : @"Geçersiz proxy",
        @"fr" : @"Proxy non valide",
        @"sv" : @"Ogiltig proxy",
        @"ar" : @"وكيل غير صالح"
      },
      @"Homepage" : @{
        @"es" : @"Página de inicio",
        @"zh" : @"主页",
        @"ru" : @"Домашняя страница",
        @"uk" : @"Домашня сторінка",
        @"pl" : @"Strona główna",
        @"cs" : @"Domovská stránka",
        @"de" : @"Startseite",
        @"ja" : @"ホームページ",
        @"ko" : @"홈페이지",
        @"vi" : @"Trang chủ",
        @"tr" : @"Ana Sayfa",
        @"fr" : @"Page d’accueil",
        @"sv" : @"Startsida",
        @"ar" : @"الصفحة الرئيسية"
      },
      @"Couldn’t Check for Updates" : @{
        @"es" : @"No se pudo buscar actualizaciones",
        @"zh" : @"无法检查更新",
        @"ru" : @"Не удалось проверить обновления",
        @"uk" : @"Не вдалося перевірити оновлення",
        @"pl" : @"Nie można sprawdzić aktualizacji",
        @"cs" : @"Nepodařilo se zkontrolovat aktualizace",
        @"de" : @"Suche nach Updates fehlgeschlagen",
        @"ja" : @"アップデートを確認できません",
        @"ko" : @"업데이트를 확인할 수 없음",
        @"vi" : @"Không thể kiểm tra cập nhật",
        @"tr" : @"Güncellemeler denetlenemedi",
        @"fr" : @"Impossible de rechercher les mises à jour",
        @"sv" : @"Kunde inte söka efter uppdateringar",
        @"ar" : @"تعذر التحقق من التحديثات"
      },
      @"Quit and reopen to apply." : @{
        @"es" : @"Cierra y vuelve a abrir para aplicar.",
        @"zh" : @"退出并重新打开以应用。",
        @"ru" : @"Закройте и снова откройте, чтобы применить.",
        @"uk" : @"Закрийте та відкрийте знову, щоб застосувати.",
        @"pl" : @"Zamknij i otwórz ponownie, aby zastosować.",
        @"cs" : @"Ukončete a znovu otevřete pro použití.",
        @"de" : @"Beenden und erneut öffnen, um zu übernehmen.",
        @"ja" : @"終了して再度開くと適用されます。",
        @"ko" : @"종료했다가 다시 열면 적용됩니다.",
        @"vi" : @"Thoát và mở lại để áp dụng.",
        @"tr" : @"Uygulamak için kapatıp yeniden açın.",
        @"fr" : @"Quittez et rouvrez pour appliquer.",
        @"sv" : @"Avsluta och öppna igen för att tillämpa.",
        @"ar" : @"أغلق التطبيق وافتحه مرة أخرى للتطبيق."
      },
      @"Update with TrollStore" : @{
        @"es" : @"Actualizar con TrollStore",
        @"zh" : @"使用 TrollStore 更新",
        @"ru" : @"Обновить через TrollStore",
        @"uk" : @"Оновити через TrollStore",
        @"pl" : @"Aktualizuj przez TrollStore",
        @"cs" : @"Aktualizovat přes TrollStore",
        @"de" : @"Mit TrollStore aktualisieren",
        @"ja" : @"TrollStore で更新",
        @"ko" : @"TrollStore로 업데이트",
        @"vi" : @"Cập nhật bằng TrollStore",
        @"tr" : @"TrollStore ile güncelle",
        @"fr" : @"Mettre à jour avec TrollStore",
        @"sv" : @"Uppdatera med TrollStore",
        @"ar" : @"التحديث عبر TrollStore"
      },
    };
  });
  NSString* dialog = dialogs[english][code];
  if (dialog) {
    return dialog;
  }

  NSArray<NSString*>* localized = tables[code];
  NSUInteger index = [keys indexOfObject:english];
  return localized && index != NSNotFound ? localized[index] : english;
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
                        : @"Add or manage your saved sign-in";
}

- (void)showMainMenu {
  UIImpactFeedbackGenerator* feedback = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  __weak ContentShellWindowDelegate* weakSelf = self;
  bool isDesktop = _shell && _shell->web_contents() &&
                   !_shell->web_contents()
                        ->GetUserAgentOverride()
                        .ua_string_override.empty();
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Menu");
  vc.compactRows = YES;
  vc.dismissOnSelect = NO;
  int zoomPercent = BlinkCurrentPageZoomPercent(_shell);
  vc.titles = [@[
    @"Google Account", BlinkL(@"Reload"), BlinkL(@"New Tab"),
    [NSString stringWithFormat:@"%@ (%zu)", BlinkL(@"Tabs"),
                               content::Shell::windows().size()],
    BlinkL(@"Home"), BlinkL(@"Private Browsing"), BlinkL(@"Bookmarks"),
    BlinkL(@"Downloads"),
    isDesktop ? BlinkL(@"Request Mobile Page")
              : BlinkL(@"Request Desktop Page"),
    [NSString stringWithFormat:@"%@ (%d%%)", BlinkL(@"Page Zoom"), zoomPercent],
    BlinkL(@"Find in Page"), BlinkL(@"Share Link"), BlinkL(@"Settings"),
    BlinkL(@"Check for Updates")
  ] mutableCopy];
  BOOL privateOn =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  vc.subtitles = [@[
    @"Add or manage your saved sign-in", @"", @"", @"", @"",
    privateOn ? BlinkL(@"On") : BlinkL(@"Off"), @"", @"", @"", @"", @"", @"",
    @"", BlinkL(@"Latest GitHub release")
  ] mutableCopy];
  vc.imageNames = @[
    @"person.crop.circle.badge.plus", @"arrow.clockwise", @"plus",
    @"square.on.square", @"house", @"eye.slash", @"bookmark",
    @"arrow.down.circle", @"desktopcomputer", @"textformat.size",
    @"magnifyingglass", @"square.and.arrow.up", @"gearshape",
    @"arrow.triangle.2.circlepath"
  ];
  UIImage* googleAvatar = BlinkCircularMenuIcon([self googleProfileImage]);
  vc.rowImages = @[
    googleAvatar ?: [NSNull null], [NSNull null], [NSNull null], [NSNull null],
    [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null],
    [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null]
  ];
  vc.subtitles[0] = [self googleProfileSubtitle];
  vc.sectionTitles =
      @[ @"ACCOUNT", BlinkL(@"BROWSER"), BlinkL(@"LIBRARY"), BlinkL(@"APP") ];
  vc.sectionStarts = @[ @0, @1, @6, @12 ];
  if ([[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkDownloadAttention"]) {
    vc.badgedRows = [NSIndexSet indexSetWithIndex:7];
  }
  __weak BlinkListVC* weakMenu = vc;
  vc.onSelect = ^(NSInteger row) {
    void (^dismissThen)(dispatch_block_t) = ^(dispatch_block_t action) {
      [weakMenu.navigationController dismissViewControllerAnimated:YES
                                                        completion:action];
    };
    if (row == 0) {
      [weakSelf showGoogleAccountMenu];
    } else if (row == 1) {
      dismissThen(^{
        [weakSelf reloadOrStop];
      });
    } else if (row == 2) {
      dismissThen(^{
        [weakSelf openNewTab];
      });
    } else if (row == 3) {
      dismissThen(^{
        [weakSelf showTabSwitcher];
      });
    } else if (row == 4) {
      dismissThen(^{
        [weakSelf goHome];
      });
    } else if (row == 5) {
      dismissThen(^{
        [weakSelf togglePrivateBrowsing];
      });
    } else if (row == 6) {
      [weakSelf showBookmarks];
    } else if (row == 7) {
      [weakSelf showDownloads];
    } else if (row == 8) {
      dismissThen(^{
        [weakSelf toggleDesktopSite];
      });
    } else if (row == 9) {
      [weakSelf showPageZoomMenu:weakMenu];
    } else if (row == 10) {
      dismissThen(^{
        [weakSelf showFindInPage];
      });
    } else if (row == 11) {
      dismissThen(^{
        [weakSelf shareCurrentLink];
      });
    } else if (row == 12) {
      [weakSelf showSettings];
    } else if (row == 13) {
      [weakSelf checkForUpdates];
    }
  };
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationPopover;
  nav.preferredContentSize =
      CGSizeMake(MIN(340, self.view.bounds.size.width - 36),
                 MIN(500, self.view.bounds.size.height - 130));
  UIColor* menuChrome = [UIColor colorWithWhite:0.09 alpha:1.0];
  // Paint the list background the same grey as the popover chrome, and pad the
  // bottom so a half-clipped row doesn't bleed into the popover's downward
  // arrow
  // ("beak"). No top padding: the orange nav bar sits flush against the first
  // section header (an upward beak is covered by the opaque nav bar anyway).
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
  [self presentViewController:nav animated:YES completion:nil];
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
    @"Choose another signed-in account",
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
    BlinkSwitchAccountIcon(avatar, secondaryAvatar) ?: [NSNull null],
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

- (void)showPageZoomMenu:(BlinkListVC*)menu {
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
  __weak BlinkListVC* weakMenu = menu;
  __weak BlinkListVC* weakZoom = vc;
  vc.onSelect = ^(NSInteger row) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_shell ||
        !strongSelf->_shell->web_contents() || row < 0 ||
        row >= static_cast<NSInteger>(percentages.count)) {
      return;
    }
    int percent = percentages[row].intValue;
    content::WebContents* contents = strongSelf->_shell->web_contents();
    if (NSString* key = BlinkZoomKey(strongSelf->_shell)) {
      [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:key];
    }
    content::BlinkSetPageZoom(contents, percent);
    weakMenu.titles[8] =
        [NSString stringWithFormat:@"Page Zoom (%d%%)", percent];
    weakZoom.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakMenu.tableView reloadData];
    [weakZoom.tableView reloadData];
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
  BlinkFindInPageController* find = [[BlinkFindInPageController alloc]
      initWithWebContents:_shell->web_contents()];
  UINavigationController* navigation =
      [[UINavigationController alloc] initWithRootViewController:find];
  navigation.modalPresentationStyle = UIModalPresentationPageSheet;
  navigation.preferredContentSize =
      CGSizeMake(MIN(520, self.view.bounds.size.width - 24), 180);
  [self presentViewController:navigation animated:YES completion:nil];
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
  // A blank tab shows the native start page (and an empty URL bar); a real page
  // hides it and shows its URL.
  BOOL isStartPage = (url.length == 0) || [url isEqualToString:@"about:blank"];
  [self showStartPage:isStartPage];
  _urlField.text = isStartPage ? @"" : url;
  // A private session records nothing: this list is written to NSUserDefaults
  // in the clear and holds full URLs, including sign-in and OAuth callbacks.
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
      if (history.count > 250) {
        [history removeObjectsInRange:NSMakeRange(250, history.count - 250)];
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
}

// Navigates to user-entered text: a bare domain becomes a URL, anything else is
// run through the selected search engine. Shared by the URL bar and Paste & Go.
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
    const SearchEngine& eng = kSearchEngines[g_search_engine];
    if (looksLikeURL || eng.query[0] == '\0') {
      url = GURL("https://" + fieldValue);
    } else {
      url = GURL(eng.query + base::EscapeQueryParamValue(fieldValue, true));
    }
  }
  if (url.is_valid() && _shell) {
    _shell->LoadURL(url);
  }
}

- (BOOL)textFieldShouldReturn:(UITextField*)field {
  [_urlField resignFirstResponder];
  [self openUserInput:field.text];
  return YES;
}

// Paste a URL or search text copied from another app and open it. A safe paste
// path that doesn't touch the (crash-prone on iOS 15) web text-input pipeline.
- (void)pasteAndGo {
  NSString* clipboard = [UIPasteboard generalPasteboard].string;
  if (clipboard.length) {
    [self openUserInput:clipboard];
  }
}

// Long-press the URL bar to choose the search engine.
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
  // Suggestions send what is being typed to the search provider, so the switch
  // lives beside the provider choice rather than buried in Settings. Off in a
  // private session regardless of this preference.
  const NSInteger suggestionsRow =
      static_cast<NSInteger>(std::size(kSearchEngines));
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  const BOOL suggestionsOn =
      [defaults objectForKey:@"BlinkSearchSuggestions"] == nil ||
      [defaults boolForKey:@"BlinkSearchSuggestions"];
  [vc.titles addObject:@"Search Suggestions"];
  [vc.subtitles addObject:suggestionsOn ? @"On · start page only" : @"Off"];
  vc.sectionTitles = @[ BlinkL(@"Search Engine"), @"START PAGE" ];
  vc.sectionStarts = @[ @0, @(suggestionsRow) ];
  vc.checkedRows = [NSIndexSet indexSetWithIndex:g_search_engine];
  __weak BlinkListVC* weakChooser = vc;
  vc.onSelect = ^(NSInteger row) {
    if (row == suggestionsRow) {
      NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
      const BOOL wasOn = [d objectForKey:@"BlinkSearchSuggestions"] == nil ||
                         [d boolForKey:@"BlinkSearchSuggestions"];
      [d setBool:!wasOn forKey:@"BlinkSearchSuggestions"];
      [d synchronize];
      weakChooser.subtitles[row] = !wasOn ? @"On · start page only" : @"Off";
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
  // Same NSURLSession caveat as the search suggestions: this request does not
  // pass through the browser's proxy, so with Tor configured it would announce
  // the install to GitHub over the direct connection. Say so instead.
  if ([[NSUserDefaults standardUserDefaults] stringForKey:@"BlinkProxy"]
          .length > 0) {
    UIAlertController* blocked = [UIAlertController
        alertControllerWithTitle:BlinkL(@"Check for Updates")
                         message:@"Update checks are disabled while a proxy is "
                                 @"configured, because the check would not go "
                                 @"through it."
                  preferredStyle:UIAlertControllerStyleAlert];
    [blocked addAction:[UIAlertAction actionWithTitle:@"OK"
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
  // The releases *list*, not /releases/latest: that endpoint excludes
  // pre-releases and drafts, and every Blinker Fluid release is published as a
  // pre-release, so it answers 404. The list is ordered newest-first.
  NSURL* endpoint =
      [NSURL URLWithString:@"https://api.github.com/repos/Nodesclock/"
                           @"Blinker-Fluid/releases?per_page=20"];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:endpoint];
  [request setValue:@"application/vnd.github+json"
      forHTTPHeaderField:@"Accept"];
  [request setValue:[@"Blinker-Fluid/" stringByAppendingString:installedVersion]
      forHTTPHeaderField:@"User-Agent"];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          id payload = data.length
                           ? [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:nil]
                           : nil;
          // Newest first, so the first non-draft entry is the release to offer.
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
                  alertControllerWithTitle:BlinkL(@"Couldn’t Check for Updates")
                                   message:
                                       error ? @"GitHub could not be reached. "
                                               @"Check "
                                               @"your connection and try again."
                                             : @"No published release was "
                                               @"found on "
                                               @"GitHub."
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
            // Tags are written "v.0.3", so trim everything before the first
            // digit. Stripping only the "v" would leave ".0.3", and under
            // NSNumericSearch a leading "." sorts below "0" — which would hide
            // every real update.
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
                                  : @"No changelog was supplied.";
            if (notes.length > 1800) {
              notes = [[notes substringToIndex:1800]
                  stringByAppendingString:@"\n\n…"];
            }
            NSArray* assets = [release[@"assets"] isKindOfClass:NSArray.class]
                                  ? release[@"assets"]
                                  : nil;
            __block NSString* ipaURL = nil;
            BOOL wantsJIT = [[NSBundle.mainBundle.bundleIdentifier
                componentsSeparatedByString:@"."] containsObject:@"jit"];
            for (NSDictionary* asset in assets) {
              NSString* candidate = asset[@"browser_download_url"];
              NSString* name =
                  [asset[@"name"] isKindOfClass:NSString.class]
                      ? [asset[@"name"] lowercaseString]
                      : candidate.lastPathComponent.lowercaseString;
              BOOL isJIT = [name containsString:@"jit"];
              NSString* extension = candidate.pathExtension.lowercaseString;
              if (([extension isEqualToString:@"ipa"] ||
                   [extension isEqualToString:@"tipa"]) &&
                  isJIT == wantsJIT) {
                ipaURL = candidate;
                break;
              }
            }
            // Some releases contain only one IPA. It is better to offer it with
            // a clear label than silently claim there is no downloadable
            // update.
            if (!ipaURL.length) {
              for (NSDictionary* asset in assets) {
                NSString* candidate = asset[@"browser_download_url"];
                NSString* extension = candidate.pathExtension.lowercaseString;
                if ([extension isEqualToString:@"ipa"] ||
                    [extension isEqualToString:@"tipa"]) {
                  ipaURL = candidate;
                  break;
                }
              }
            }
            NSString* title =
                newer ? [NSString stringWithFormat:@"Update %@", tag]
                      : @"Blinker Fluid is Up to Date";
            NSString* message =
                [NSString stringWithFormat:@"Installed: %@\nLatest: %@\n\n%@",
                                           installedVersion, tag, notes];
            UIAlertController* result = [UIAlertController
                alertControllerWithTitle:title
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            // The install scheme only exists where TrollStore does. Ask the
            // system rather than assuming from the build: a compat package on a
            // TrollStore device can still use it, and a normal package
            // sideloaded cannot.
            const BOOL trollStoreAvailable = [[UIApplication sharedApplication]
                canOpenURL:[NSURL URLWithString:@"apple-magnifier://"]];
            if (newer && ipaURL.length && !trollStoreAvailable) {
              [result addAction:[UIAlertAction
                                    actionWithTitle:@"Download Update"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              // Loading it here routes the file
                                              // through the app's own download
                                              // manager, so it lands in
                                              // Downloads ready to install by
                                              // hand.
                                              BLINKER_DIAG(
                                                  "UPDATE: downloading in-app");
                                              [weakSelf loadURLString:ipaURL];
                                            }]];
            }
            if (newer && ipaURL.length && trollStoreAvailable) {
              [result
                  addAction:
                      [UIAlertAction
                          actionWithTitle:BlinkL(@"Update with TrollStore")
                                    style:UIAlertActionStyleDefault
                                  handler:^(UIAlertAction* action) {
                                    NSString* encoded = [ipaURL
                                        stringByAddingPercentEncodingWithAllowedCharacters:
                                            (^{
                                              NSMutableCharacterSet* allowed =
                                                  [NSCharacterSet
                                                          .URLQueryAllowedCharacterSet
                                                              mutableCopy];
                                              [allowed removeCharactersInString:
                                                           @"&=?#"];
                                              return allowed;
                                            })()];
                                    NSURL* install = [NSURL
                                        URLWithString:
                                            [@"apple-magnifier://install?url="
                                                stringByAppendingString:
                                                    encoded]];
                                    [[UIApplication sharedApplication]
                                        openURL:install
                                        options:@{}
                                        completionHandler:^(BOOL success) {
                                          if (!success) {
                                            // The scheme answered canOpenURL
                                            // but the install did not take.
                                            // Fall back to downloading in-app
                                            // rather than leaving the button
                                            // looking like a no-op.
                                            BLINKER_DIAG(
                                                "UPDATE: TrollStore install "
                                                "refused, downloading");
                                            [weakSelf loadURLString:ipaURL];
                                          }
                                        }];
                                  }]];
            }
            [result addAction:[UIAlertAction
                                  actionWithTitle:BlinkL(@"Not Now")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
            UIViewController* host =
                strongSelf.presentedViewController ?: strongSelf;
            [host presentViewController:result animated:YES completion:nil];
          });
        }] resume];
}

// Defined below, alongside the JavaScript-engine menu they belong to.
static NSString* BlinkJITTierTitle(NSInteger tier);
static NSInteger BlinkCurrentJITTier(void);
static NSInteger BlinkEffectiveJITTier(void);

// Ad/tracker content filter (implemented in blinker_content_filter.cc).
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
  return [NSString stringWithFormat:@"On · %llu blocked", blocked];
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

// Settings that are global browser preferences.
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
  [vc.titles addObject:BlinkL(@"Private Browsing")];
  BOOL privateRequested = [d boolForKey:@"BlinkPrivateBrowsing"];
  BOOL privateActive =
      _shell && _shell->web_contents() &&
      _shell->web_contents()->GetBrowserContext()->IsOffTheRecord();
  NSString* privateState = privateRequested ? BlinkL(@"On") : BlinkL(@"Off");
  if (privateRequested != privateActive) {
    privateState = [NSString
        stringWithFormat:@"%@ · %@", privateState, BlinkL(@"Restart required")];
  }
  [vc.subtitles addObject:privateState];
  [vc.titles addObject:BlinkL(@"Ad & Tracker Blocking")];
  [vc.subtitles addObject:BlinkAdBlockSubtitle()];
  NSString* proxy = [d stringForKey:@"BlinkProxy"];
  [vc.titles addObject:BlinkL(@"Tor / Proxy")];
  [vc.subtitles addObject:proxy.length ? proxy : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"Password / Face ID Lock")];
  [vc.subtitles addObject:[d boolForKey:@"BlinkAppLock"] ? BlinkL(@"On")
                                                         : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"HTTPS-First Navigation")];
  [vc.subtitles addObject:[d boolForKey:@"BlinkHTTPSFirst"] ? BlinkL(@"On")
                                                            : BlinkL(@"Off")];
  [vc.titles addObject:BlinkL(@"Website Permissions")];
  [vc.subtitles addObject:@"Location, camera and microphone"];
  [vc.titles addObject:BlinkL(@"Clear Browsing Data")];
  [vc.subtitles addObject:@"History and website data"];
  [vc.titles addObject:BlinkL(@"History")];
  [vc.subtitles addObject:@"Recently visited pages"];
  [vc.titles addObject:BlinkL(@"JavaScript Engine")];
  [vc.subtitles addObject:BlinkJITTierTitle(BlinkEffectiveJITTier())];
  [vc.titles addObject:BlinkL(@"About Blinker Fluid")];
  [vc.subtitles addObject:@"Version, source and developer"];
  vc.imageNames = @[
    @"magnifyingglass", @"circle.lefthalf.filled",
    @"rectangle.bottomthird.inset.filled", @"globe", @"eye.slash",
    @"hand.raised.slash", @"lock.shield", @"lock.fill", @"checkmark.shield",
    @"hand.raised", @"trash", @"clock.arrow.circlepath", @"bolt.fill",
    @"info.circle"
  ];
  vc.titleColors = @[
    [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null],
    BlinkerTorColor(), [NSNull null], [NSNull null], [NSNull null],
    [NSNull null], [NSNull null], [NSNull null], [NSNull null], [NSNull null]
  ];
  vc.sectionTitles = @[
    BlinkL(@"GENERAL"), BlinkL(@"PRIVACY"), BlinkL(@"PERFORMANCE"),
    BlinkL(@"ABOUT")
  ];
  vc.sectionStarts = @[ @0, @4, @12, @13 ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakSettings = vc;
  vc.onSelect = ^(NSInteger i) {
    if (i == 0) {
      [weakSelf presentSearchEngineMenu];
    } else if (i == 1) {
      [weakSelf showAppearanceMenu];
    } else if (i == 2) {
      [weakSelf toggleToolbarPosition];
      BOOL nowBottom = [[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkToolbarBottom"];
      weakSettings.subtitles[2] =
          nowBottom ? BlinkL(@"Bottom") : BlinkL(@"Top");
      [weakSettings.tableView reloadData];
    } else if (i == 3) {
      [weakSelf showLanguageMenu:weakSettings];
    } else if (i == 4) {
      BOOL enabled = ![[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkPrivateBrowsing"];
      [[NSUserDefaults standardUserDefaults] setBool:enabled
                                              forKey:@"BlinkPrivateBrowsing"];
      [[NSUserDefaults standardUserDefaults] synchronize];
      weakSettings.subtitles[4] = [NSString
          stringWithFormat:@"%@ · %@", enabled ? BlinkL(@"On") : BlinkL(@"Off"),
                           BlinkL(@"Restart required")];
      [weakSettings.tableView reloadData];
    } else if (i == 5) {
      BOOL nowEnabled = !BlinkAdBlockEnabled();
      BlinkAdBlockSetEnabled(nowEnabled);
      [[NSUserDefaults standardUserDefaults] setBool:nowEnabled
                                              forKey:@"BlinkAdBlock"];
      weakSettings.subtitles[5] = BlinkAdBlockSubtitle();
      [weakSettings.tableView reloadData];
    } else if (i == 6) {
      [weakSelf showProxySettings];
    } else if (i == 7) {
      [weakSelf toggleAppLockFromSettings:weakSettings];
    } else if (i == 8) {
      BOOL enabled = ![[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkHTTPSFirst"];
      [[NSUserDefaults standardUserDefaults] setBool:enabled
                                              forKey:@"BlinkHTTPSFirst"];
      weakSettings.subtitles[8] = enabled ? BlinkL(@"On") : BlinkL(@"Off");
      [weakSettings.tableView reloadData];
    } else if (i == 9) {
      [weakSelf showWebsitePermissions];
    } else if (i == 10) {
      [weakSelf showClearBrowsingData];
    } else if (i == 11) {
      [weakSelf showHistory];
    } else if (i == 12) {
      [weakSelf showJavaScriptEngineMenu:weakSettings];
    } else if (i == 13) {
      [weakSelf showAbout];
    }
  };
  [self presentList:vc];
}

- (void)showLanguageMenu:(BlinkListVC*)settings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Languages");
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  vc.imageNames = @[];
  NSMutableArray<NSString*>* names = [NSMutableArray array];
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
    [names addObject:localizedName.capitalizedString];
    [accepts addObject:option.accept];
    [vc.titles addObject:localizedName.capitalizedString];
    [vc.subtitles addObject:@""];
    if ([selected isEqualToString:option.accept]) {
      selectedRow = languageIndex;
    }
    ++languageIndex;
  }
  vc.checkedRows = [NSIndexSet indexSetWithIndex:selectedRow];

  __weak BlinkListVC* weakLanguages = vc;
  __weak BlinkListVC* weakSettings = settings;
  vc.onSelect = ^(NSInteger row) {
    if (row < 0 || row >= static_cast<NSInteger>(accepts.count)) {
      return;
    }
    NSString* name = names[row];
    NSString* accept = accepts[row];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:accept forKey:@"BlinkLanguageAccept"];
    [defaults synchronize];

    weakLanguages.checkedRows = [NSIndexSet indexSetWithIndex:row];
    weakSettings.subtitles[3] = name;
    [weakLanguages.tableView reloadData];
    [weakSettings.tableView reloadData];
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
                         ? @"Authenticate to turn off Blinker Fluid App Lock"
                         : @"Authenticate to protect Blinker Fluid";
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
                        settings.subtitles[7] =
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
                 : @"Off — change in iOS Settings";
    }
    AVMediaType type = permission == 1 ? AVMediaTypeAudio : AVMediaTypeVideo;
    return [AVCaptureDevice authorizationStatusForMediaType:type] ==
                   AVAuthorizationStatusNotDetermined
               ? @"Tap to request access"
               : @"Off — change in iOS Settings";
  };
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = BlinkL(@"Website Permissions");
  vc.dismissOnSelect = NO;
  vc.titles = [@[ @"Location", @"Camera", @"Microphone", @"Open iOS Settings" ]
      mutableCopy];
  vc.subtitles =
      [@[ state(0), state(2), state(1), @"Change system-level access" ]
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
                                             : @"Off — change in iOS Settings";
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
                       message:@"Clear browsing history and "
                               @"reload all open tabs? Website "
                               @"cookies remain available so "
                               @"you are not signed out."
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
                                  shell->web_contents()->GetController().Reload(
                                      content::ReloadType::NORMAL, true);
                                }
                              }
                              [weakSelf.navigationController
                                  popViewControllerAnimated:YES];
                            }]];
  // Clearing one site's cookies and storage is the option people actually want
  // when a single site misbehaves, and unlike the blanket clear above it does
  // sign you out -- of that site only.
  GURL current = _shell && _shell->web_contents()
                     ? _shell->web_contents()->GetLastCommittedURL()
                     : GURL();
  if (current.SchemeIsHTTPOrHTTPS() && !current.host().empty()) {
    NSString* title =
        [NSString stringWithFormat:@"Clear Data for %@",
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
          ?: @"Unknown";
  NSString* chromiumVersion = [NSString
      stringWithUTF8String:std::string(version_info::GetVersionNumber())
                               .c_str()];
  vc.titles = [@[
    @"Blinker Fluid", @"Chromium Engine", @"GitHub Repository",
    @"Nodesclock on GitHub", @"Monero (XMR)", @"Litecoin (LTC)"
  ] mutableCopy];
  vc.subtitles = [@[
    [@"Version " stringByAppendingString:appVersion],
    [@"Chromium " stringByAppendingString:chromiumVersion],
    @"github.com/Nodesclock/Blinker-fluid", @"github.com/Nodesclock",
    @"8Ab52zsnVgzRRKp1HnhT6UWZY6GmUK67HXKZtQ8wHPMF4LXbDLiwSeJR2uHaRox71eQWxLk7BczDD1N7v9QbHWt5CK6Qtfw",
    @"ltc1q4zhq6sszzwvez79g9drzs29q9f5czdv9kcqtcc"
  ] mutableCopy];
  vc.imageNames = @[
    @"safari", @"globe", @"chevron.left.forwardslash.chevron.right",
    @"person.crop.circle", @"heart.circle", @"heart.circle"
  ];
  vc.sectionTitles = @[ @"ABOUT", @"DONATIONS — TAP TO COPY" ];
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

// Tor / proxy: enter a SOCKS5 (or HTTP) proxy; saved to NSUserDefaults and
// applied as --proxy-server on next launch (see BasicStartupComplete). SOCKS5
// resolves hostnames remotely, so .onion works through a Tor daemon.
- (void)showProxySettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Tor / Proxy")
                       message:
                           @"Enter an existing SOCKS5/HTTP proxy supplied "
                           @"by a Tor app or server. Blinker does not bundle "
                           @"a Tor daemon. A 127.0.0.1 address works only "
                           @"while another Tor service is listening on that "
                           @"port. Restart the app to apply; leave blank to "
                           @"turn off."
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
                        NSURLComponents* parsed =
                            [NSURLComponents componentsWithString:v];
                        BOOL valid = !v.length ||
                                     (([parsed.scheme.lowercaseString
                                           isEqualToString:@"socks5"] ||
                                       [parsed.scheme.lowercaseString
                                           isEqualToString:@"socks4"] ||
                                       [parsed.scheme.lowercaseString
                                           isEqualToString:@"http"] ||
                                       [parsed.scheme.lowercaseString
                                           isEqualToString:@"https"]) &&
                                      parsed.host.length && parsed.port != nil);
                        if (!valid) {
                          UIAlertController* bad = [UIAlertController
                              alertControllerWithTitle:BlinkL(@"Invalid proxy")
                                               message:
                                                   @"Use a complete address "
                                                   @"such as "
                                                   @"socks5://127.0.0.1:9050."
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

// Homepage: a custom start-page URL (blank = the built-in start page). Read by
// GetStartupURL on launch and by openNewTab for new tabs.
- (void)showHomepageSettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:BlinkL(@"Homepage")
                       message:@"Custom start-page URL. Leave blank for the "
                               @"built-in start page. Applies to new tabs now "
                               @"and to the start page on next launch."
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
  [self tintMenu:a color:BlinkerAccentColor()];
  [self presentViewController:a animated:YES completion:nil];
}

// Values match IOSJitTier in shell_main_delegate.cc.
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
      return @"Adds the Maglev optimizer and the regular-expression compiler.";
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

// The tier that actually runs. Both bundles ship the same binary and differ
// only by identifier, and IsIOSRuntimeJITAuthorized() refuses every identifier
// except ...blinkerfluid.jit — so on the stable bundle the stored preference is
// never consulted and the engine is always the jitless interpreter. Reporting
// the stored value there would claim TurboFan on a build that cannot run it.
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
  NSInteger current = BlinkEffectiveJITTier();
  for (NSInteger tier = kBlinkJITTierMin; tier <= kBlinkJITTierMax; ++tier) {
    [tiers addObject:@(tier)];
    [vc.titles addObject:BlinkJITTierTitle(tier)];
    // Say why a tier is unavailable rather than greying it out with no reason.
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
    [defaults synchronize];
    weakSettings.subtitles[12] = BlinkJITTierTitle(tier);
    weakEngine.checkedRows = [NSIndexSet indexSetWithIndex:row];
    [weakSettings.tableView reloadData];
    [weakEngine.tableView reloadData];
    // On the stable bundle the only selectable row is the tier already running,
    // so a "quit and reopen to apply" prompt would promise a change that isn't.
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
  [self tintMenu:alert color:BlinkerAccentColor()];
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

// Force the web content's prefers-color-scheme (so sites render their own
// native dark/light theme), by overriding the NativeTheme used for web prefs.
- (void)applyWebColorScheme:(UIUserInterfaceStyle)style {
  // The real lever: OverrideWebPreferences reads this global to set the web
  // content's prefers-color-scheme (UIUserInterfaceStyle: 1=Light, 2=Dark,
  // 0=System->light). content_shell otherwise hardcodes it to light.
  content::g_blink_preferred_color_scheme = (int)style;
  // Also nudge NativeTheme (affects UA-rendered controls/scrollbars).
  using CS = ui::NativeTheme::PreferredColorScheme;
  CS scheme = (style == UIUserInterfaceStyleDark)    ? CS::kDark
              : (style == UIUserInterfaceStyleLight) ? CS::kLight
                                                     : CS::kNoPreference;
  if (ui::NativeTheme* web = ui::NativeTheme::GetInstanceForWeb()) {
    web->set_preferred_color_scheme(scheme);
    web->NotifyOnNativeThemeUpdated();
  }
  // Recompute web prefs for every tab so prefers-color-scheme applies now.
  for (content::Shell* s : content::Shell::windows()) {
    if (s->web_contents()) {
      s->web_contents()->NotifyPreferencesChanged();
    }
  }
  // Reload every real page so the new media query is evaluated immediately.
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
  if (content::BlinkShellIsInAuthFlow()) {
    // Don't flip UA/device-metrics during an auth redirect chain — that breaks
    // ChatGPT/Google login.
    BLINKER_DIAG("AUTH_FLOW: site mode locked during auth");
    BLINKER_DIAG("AUTH_FLOW: user agent stable during auth");
    return;
  }
  BLINKER_DIAG("SITE_MODE: button toggled");
  const GURL page_url = _shell->web_contents()->GetLastCommittedURL();
  NSString* modeKey =
      [NSString stringWithFormat:@"BlinkDesktopMode_%@",
                                 base::SysUTF8ToNSString(page_url.host())];
  // Read the state from the live UA override, which is what the menu label is
  // derived from. Using the per-host preference here instead made the button
  // disagree with its own label: on a host that serves mobile content even
  // under a desktop UA (m.youtube.com), the first tap set the override, the
  // label flipped to "Request Mobile Page", and a second tap read the stored
  // preference and silently switched back to mobile — so desktop mode never
  // appeared to take. See GitHub issue #8.
  const bool isDesktop = !_shell->web_contents()
                              ->GetUserAgentOverride()
                              .ua_string_override.empty();
  const bool setDesktop = !isDesktop;
  std::string ua = setDesktop ? content::kBlinkDesktopUserAgent : std::string();
  BLINKER_DIAG(setDesktop ? "SITE_MODE: set desktop" : "SITE_MODE: set mobile");
  BLINKER_DIAGF("SITE_MODE: applying user agent=%s",
                setDesktop ? ua.c_str() : "default mobile");
  blink::UserAgentOverride uaOverride;
  uaOverride.ua_string_override = ua;
  if (setDesktop) {
    // Sec-CH-UA-Mobile=?0 + macOS platform to match the desktop UA string.
    uaOverride.ua_metadata_override =
        content::GetShellUserAgentMetadataForSiteMode(/*desktop=*/true);
  }
  _shell->web_contents()->SetUserAgentOverride(uaOverride, true);
  BLINKER_DIAG(setDesktop ? "SITE_MODE: UA metadata mobile=false"
                          : "SITE_MODE: UA metadata mobile=true");

  // Native desktop mode via Chromium renderer prefs / device metrics (NO JS,
  // NO <meta viewport> injection). OverrideWebPreferences reads this flag to
  // set a wide (~980 CSS-px) desktop layout viewport; mobile restores
  // device-width. Cookies / localStorage / IndexedDB are left intact.
  content::g_force_desktop_site = setDesktop ? 1 : 0;
  [[NSUserDefaults standardUserDefaults] setBool:setDesktop forKey:modeKey];
  _shell->web_contents()->NotifyPreferencesChanged();
  BLINKER_DIAG("SITE_MODE: renderer prefs updated");
  BLINKER_DIAG(setDesktop ? "SITE_MODE: desktop device metrics width=980"
                          : "SITE_MODE: mobile device metrics restored");
  GURL current = _shell->web_contents()->GetLastCommittedURL();
  if (!current.is_valid()) {
    current = _shell->web_contents()->GetVisibleURL();
  }
  if (current.is_valid() && current.SchemeIsHTTPOrHTTPS()) {
    BLINKER_DIAG("SITE_MODE: reload after UA change");
    BLINKER_DIAG("SITE_MODE: reload after device metrics change");
    _shell->LoadURL(current);
  }
}

// iOS only rotates to orientations the view controller admits to supporting, so
// a page's orientation lock has to be reflected here.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return BlinkSupportedOrientations();
}

- (UIActivityIndicatorView*)pullToRefreshSpinner {
  if (_pullSpinner) {
    return _pullSpinner;
  }
  if (!_contentView) {
    // Constraints built against a nil anchor throw, and there is nothing to
    // attach to before the view hierarchy exists.
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
  spinner.alpha = MIN(progress, 1.0);
  spinner.transform =
      CGAffineTransformMakeRotation(progress * (CGFloat)M_PI * 1.5);
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
    // Not -reloadOrStop: that button toggles, so a pull during a slow load
    // would cancel it instead of refreshing.
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
  // Track the container. The web view is added as a bare subview and its frame
  // is otherwise only set when Chromium pushes new visual properties, so any
  // container resize the browser does not initiate -- collapsing the toolbar
  // for fullscreen, the rotation YouTube forces with it -- left the web view at
  // its previous frame with the near-black container background showing
  // through.
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
                        // UIWindowScene finishes rotating after UIDevice's
                        // first notification. Re-publish it now so
                        // display::Screen samples the final interface
                        // orientation, then refresh this view's cached
                        // ScreenInfos on the next task. This keeps Web
                        // screen.width/height in lockstep with the viewport.
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
                            // This is the final iOS 15 rotation callback. A
                            // visibility bounce here detaches the live video
                            // surface after the earlier fullscreen refresh,
                            // leaving audio playing over a frozen frame.
                            // Generate the replacement surface only after UIKit
                            // and ScreenInfo have reached their final size.
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

// Reliably colors an alert/action-sheet's option text (the tintColor alone
// doesn't always stick). Destructive actions keep their red.
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

void ShellPlatformDelegate::Initialize(const gfx::Size& default_window_size) {
  screen_ = std::make_unique<display::ScopedNativeScreen>();
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
  window.backgroundColor = [UIColor whiteColor];
#if !BUILDFLAG(IS_IOS_TVOS)
  // Leaves `tintColor` by default on tvOS. Refer to crbug.com/454180134.
  //
  // Upstream content_shell tints the whole window dark grey. Every UIKit
  // control that does not set its own tint inherits it, which is why toolbar
  // affordances came up grey and only turned accent-coloured once something
  // re-tinted them (switching tabs rebuilds the toolbar). The window tint is
  // the correct place to state the app's accent once, so both the top and the
  // bottom toolbar are right from the first frame.
  window.tintColor = BlinkerAccentColor();
#endif

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
  DCHECK(shell_data_map_.contains(shell));
  shell_data_map_.erase(shell);
}

void ShellPlatformDelegate::SetContents(Shell* shell) {
  DCHECK(shell_data_map_.contains(shell));
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
  if (Shell::ShouldHideToolbar()) {
    return;
  }
  DCHECK(shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  NSString* url_string = base::SysUTF8ToNSString(url.spec());
  [((ContentShellWindowDelegate*)shell_data.window.rootViewController)
      setURL:url_string];

  // Persist the updated tab set whenever an address changes (navigation /
  // commit) so reopening the app restores the tabs the user had open.
  BlinkSaveOpenTabs();
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

  // A focused field left over from the page keeps the keyboard and its
  // accessory bar on screen through the transition, and the keyboard's viewport
  // inset then fights the layout on the way in and survives on the way out.
  // Reynard's fullscreen path calls endEditing for the same reason.
  [delegate.view endEditing:YES];
  BlinkSetKeyboardViewportInset(0);
  // Remove the complete toolbar and its normal safe-area geometry. Hiding only
  // the arranged toolbar content leaves the outer stack and its portrait-era
  // constraints participating in layout after rotation, exposing a large black
  // strip beside/below video.
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
  // Keep the screen awake while a video is fullscreen.
  UIApplication.sharedApplication.idleTimerDisabled = enter_fullscreen;
  BlinkApplyFullscreenOrientation(enter_fullscreen, shell_data.window);
  BlinkSetNativeVideoPiP(enter_fullscreen);
  // Settle the collapsed/restored toolbar before
  // Shell::ToggleFullscreenModeForTab calls SynchronizeVisualProperties, so the
  // renderer is told the size the content view actually ends up with rather
  // than the pre-transition one.
  [delegate.view setNeedsLayout];
  [delegate.view layoutIfNeeded];

  // Rotation is asynchronous on pre-scene UIKit. Reynard explicitly follows
  // its fullscreen transition with another viewport resize; do the Chromium
  // equivalent after UIKit has committed the new bounds so Blink and Viz do
  // not keep presenting a portrait-sized (often black) surface in landscape.
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
        // A size sync alone leaves Viz's post-rotation fullscreen
        // frame as an empty CALayer tree (the video clock advances,
        // but there are no drawable contents). Bounce visibility
        // after UIKit has its final landscape bounds to invalidate
        // the stale LocalSurfaceId and demand a complete frame.
        if (enter_fullscreen) {
          // On iOS 15 a visibility bounce detaches the live video
          // surface after rotation: audio continues but the last
          // decoded frame remains frozen. iOS 16+ needs the bounce
          // to invalidate its otherwise-black stale LocalSurfaceId.
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
            // The visibility bounce above performs the refresh.
          } else {
            // Resizing alone leaves iOS 15 presenting the old video
            // surface (audio advances while its last frame freezes).
            // Generate and embed a fresh LocalSurfaceId without
            // hiding the page or attaching a second media consumer.
            static_cast<content::RenderWidgetHostImpl*>(widget)
                ->RequestRepaintOnNewSurface();
            BLINKER_DIAG(
                "FULLSCREEN_LAYOUT: iOS 15 requested new video surface");
          }
        }
        // Rotation can produce several visual-property changes in
        // one animation. The final landscape viewport must not be
        // discarded merely because the portrait resize ACK is
        // still in flight.
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
