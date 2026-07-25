// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_platform_delegate.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>

#include <array>
#include <stdio.h>

extern "C" void BlinkBootLog(const char* stage);

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
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/trace_event/trace_config.h"
#include "content/public/browser/browser_accessibility_state.h"
#include "content/public/browser/browser_context.h"
#include "ui/gfx/geometry/size.h"
#include "content/public/browser/scoped_accessibility_mode.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "ui/native_theme/native_theme.h"
#include "content/shell/app/resource.h"
#include "content/shell/browser/color_chooser/shell_color_chooser_ios.h"
#include "content/shell/browser/shell.h"
#include "content/shell/browser/shell_browser_main_parts.h"
#include "content/shell/browser/shell_browser_context.h"
#include "content/shell/browser/shell_content_browser_client.h"
#include "content/shell/browser/shell_file_select_helper.h"
#include "services/tracing/public/cpp/perfetto/perfetto_config.h"
#include "services/tracing/public/mojom/constants.mojom.h"
#include "third_party/perfetto/include/perfetto/tracing/core/trace_config.h"
#include "third_party/perfetto/include/perfetto/tracing/tracing.h"
#include "ui/accessibility/ax_mode.h"
#include "ui/display/screen.h"
#include "ui/gfx/native_ui_types.h"

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

namespace {

// Selectable search engines (long-press the URL bar). An empty
// query string means "None" — input is always treated as a URL.
struct SearchEngine {
  const char* name;
  const char* query;  // search prefix; the (escaped) term is appended.
};
constexpr std::array kSearchEngines = {
    SearchEngine{"Google", "https://www.google.com/search?q="},
    SearchEngine{"DuckDuckGo", "https://duckduckgo.com/?q="},
    SearchEngine{"Bing", "https://www.bing.com/search?q="},
    SearchEngine{"Yahoo", "https://search.yahoo.com/search?p="},
    SearchEngine{"Blinker Fluid (Google)",
                 "https://www.google.com/search?q="},
};
int g_search_engine = 0;  // Default: Google.
bool g_blink_app_unlocked = false;

// Accent color for menu/start-page text — matches the orange toolbar. The Tor
// proxy setting uses a distinct purple.
UIColor* BlinkerAccentColor() {
  return [UIColor colorWithRed:224 / 255.0
                         green:71 / 255.0
                          blue:40 / 255.0
                         alpha:1.0];
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
void BlinkSaveOpenTabs() {
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (content::Shell* s : content::Shell::windows()) {
    if (!s->web_contents()) {
      continue;
    }
    GURL u = content::PeekPendingRestoreURL(s);
    if (!u.is_valid()) {
      u = s->web_contents()->GetLastCommittedURL();
    }
    if (!u.is_valid()) {
      u = s->web_contents()->GetVisibleURL();
    }
    std::string spec;
    if (!u.is_valid() || u.IsAboutBlank() || u.spec().empty()) {
      // Keep blank/start-page tabs so the tab count is preserved.
      spec = "about:blank";
    } else if (u.SchemeIsHTTPOrHTTPS()) {
      spec = u.spec();
    } else {
      // Skip non-restorable schemes (devtools:, blob:, data:, file:, …).
      continue;
    }
    [urls addObject:base::SysUTF8ToNSString(spec)];
  }
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setObject:urls forKey:@"BlinkOpenTabs"];
  [d synchronize];
  BlinkBootLog("SESSION_RESTORE: saved last URL");
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
  }
  return image;
}

}  // namespace

extern "C" void BlinkPersistOpenTabs() {
  BlinkSaveOpenTabs();
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
  BlinkBootLog("AUTH_POPUP_GUARD: shell window presented");
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

extern "C" void BlinkDiscardBackgroundTabs(content::Shell* keep) {
  if (content::Shell::windows().size() < 6) {
    return;
  }
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
      BlinkBootLog("TAB_LIFECYCLE: discarded inactive renderer");
    }
  }
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
  if (closingWin.windowScene) {
    win.windowScene = closingWin.windowScene;
  }
  [win makeKeyAndVisible];
  BlinkBootLog("AUTH_POPUP_GUARD: reactivated previous window after close");
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

@class BlinkerStartPageView;

@interface ContentShellWindowDelegate
    : UIViewController <UITextFieldDelegate, UIPopoverPresentationControllerDelegate> {
 @private
  raw_ptr<content::Shell> _shell;
}
// Toolbar containing navigation buttons and |urlField|.
@property(nonatomic, strong) UIStackView* toolbarBackgroundView;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* topPosConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* bottomPosConstraints;
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
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* loadingProgressConstraints;
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
- (void)setURL:(NSString*)url;
- (void)setContents:(UIView*)content;
- (void)stopTracing;
- (void)startTracingWithCategories:(const char*)categories;
- (UIAlertController*)actionSheetWithTitle:(nullable NSString*)title
                                   message:(nullable NSString*)message;
- (void)voiceOverStatusDidChange;
@end

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
  UIColor* red = [UIColor colorWithRed:224.0 / 255.0
                                 green:71.0 / 255.0
                                  blue:40.0 / 255.0
                                 alpha:1.0];
  self.tableView.backgroundColor = bg;
  self.tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
  self.tableView.rowHeight = self.isTabList ? 76 : (self.compactRows ? 48 : 58);
  self.tableView.tableFooterView = [[UIView alloc] init];
  UINavigationBar* bar = self.navigationController.navigationBar;
  bar.tintColor = [UIColor whiteColor];
  UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
  [ap configureWithOpaqueBackground];
  ap.backgroundColor = self.compactRows ? bg : red;
  ap.titleTextAttributes = @{
    NSForegroundColorAttributeName :
        (self.compactRows ? red : UIColor.whiteColor)
  };
  bar.standardAppearance = ap;
  bar.scrollEdgeAppearance = ap;
  bar.compactAppearance = ap;
}
- (void)doneTapped {
  [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)addTapped {
  if (self.isTabList) {
    BlinkBootLog("TAB_MANAGER_UI: plus tapped");
    BlinkBootLog("TAB_MANAGER_UI: requested new tab");
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
  if (!self.sectionStarts.count)
    return ip.row;
  return self.sectionStarts[ip.section].integerValue + ip.row;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return self.sectionStarts.count ? self.sectionStarts.count : 1;
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {
  if (!self.sectionStarts.count)
    return self.titles.count;
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
    c.imageView.clipsToBounds = YES;
    c.imageView.layer.cornerRadius = 7;
  } else if (row < (NSInteger)self.imageNames.count) {
    UIImage* icon = [UIImage systemImageNamed:self.imageNames[row]];
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
  return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
  [t deselectRowAtIndexPath:ip animated:NO];
  NSInteger row = [self globalRowForIndexPath:ip];
  if ([self.disabledRows containsIndex:row])
    return;
  if (self.isTabList) {
    char buf[96];
    snprintf(buf, sizeof(buf), "TAB_MANAGER_UI: existing tab tapped id=%ld",
             (long)row);
    BlinkBootLog(buf);
    snprintf(buf, sizeof(buf), "TAB_MANAGER_UI: requested switch to tab id=%ld",
             (long)row);
    BlinkBootLog(buf);
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
    char buf[96];
    snprintf(buf, sizeof(buf), "TAB_MANAGER_UI: close tapped id=%ld", (long)row);
    BlinkBootLog(buf);
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
  _nameField = [self fieldWithPlaceholder:self.folderMode ? @"Folder name" : @"Name"];
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
    [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                     constant:24],
    [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
    [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
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
  NSString* name = [_nameField.text stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString* url = [_urlField.text stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!name.length || (!self.folderMode && !url.length))
    return;
  if (!self.folderMode && ![url containsString:@"://"])
    url = [@"https://" stringByAppendingString:url];
  if (!self.folderMode && ![NSURL URLWithString:url].host.length)
    return;
  if (self.onSave)
    self.onSave(name, url ?: @"");
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
    _preview.layer.cornerCurve = kCACornerCurveContinuous;
    _preview.layer.borderWidth = 1;
    _preview.layer.borderColor =
        [UIColor colorWithWhite:0.24 alpha:1].CGColor;
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
    [_closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
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
      [_preview.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
      [_preview.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:3],
      [_preview.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-3],
      [_preview.heightAnchor constraintEqualToAnchor:self.contentView.heightAnchor
                                           multiplier:0.80],
      [_titleLabel.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:6],
      [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6],
      [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
      [_urlLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
      [_urlLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
      [_urlLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
      [_closeButton.topAnchor constraintEqualToAnchor:_preview.topAnchor constant:8],
      [_closeButton.trailingAnchor constraintEqualToAnchor:_preview.trailingAnchor constant:-8],
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
@end

@implementation BlinkTabsVC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Tabs";
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
  UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
  [ap configureWithOpaqueBackground];
  ap.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
  ap.titleTextAttributes =
      @{ NSForegroundColorAttributeName : BlinkerAccentColor() };
  self.navigationController.navigationBar.standardAppearance = ap;
  self.navigationController.navigationBar.scrollEdgeAppearance = ap;
  self.navigationController.navigationBar.tintColor = BlinkerAccentColor();
}
- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)add {
  void (^handler)(void) = self.onAdd;
  [self dismissViewControllerAnimated:YES completion:^{
    if (handler) handler();
  }];
}
- (NSInteger)collectionView:(UICollectionView*)view
     numberOfItemsInSection:(NSInteger)section {
  return self.titles.count;
}
- (UICollectionViewCell*)collectionView:(UICollectionView*)view
                 cellForItemAtIndexPath:(NSIndexPath*)path {
  BlinkTabCardCell* cell =
      [view dequeueReusableCellWithReuseIdentifier:@"tab" forIndexPath:path];
  cell.titleLabel.text = self.titles[path.item];
  cell.urlLabel.text = self.urls[path.item];
  cell.preview.image = self.previews[path.item];
  cell.closeButton.tag = path.item;
  [cell.closeButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
  [cell.closeButton addTarget:self
                       action:@selector(closeTapped:)
             forControlEvents:UIControlEventTouchUpInside];
  return cell;
}
- (void)collectionView:(UICollectionView*)view
    didSelectItemAtIndexPath:(NSIndexPath*)path {
  NSInteger index = path.item;
  void (^handler)(NSInteger) = self.onSelect;
  [self dismissViewControllerAnimated:YES completion:^{
    if (handler) handler(index);
  }];
}
- (void)closeTapped:(UIButton*)button {
  NSInteger index = button.tag;
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
    : UIView <UITextFieldDelegate, UIContextMenuInteractionDelegate>
@property(nonatomic, copy) void (^onNavigate)(NSString*);
@end

@implementation BlinkerStartPageView {
  UITextField* _search;
  UIStackView* _shortcutGrid;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor =
        [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0];

    UIImageView* logo =
        [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"blinker_logo"]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo.widthAnchor constraintEqualToConstant:120].active = YES;
    [logo.heightAnchor constraintEqualToConstant:120].active = YES;

    _search = [[UITextField alloc] init];
    _search.placeholder = @"Search or type URL";
    _search.backgroundColor =
        [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0];
    _search.textColor = [UIColor whiteColor];
    _search.font = [UIFont systemFontOfSize:17];
    _search.layer.cornerRadius = 26;
    _search.layer.cornerCurve = kCACornerCurveContinuous;
    _search.layer.borderWidth = 1;
    _search.layer.borderColor = BlinkerAccentColor().CGColor;
    _search.delegate = self;
    _search.returnKeyType = UIReturnKeyGo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.keyboardType = UIKeyboardTypeWebSearch;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    UIView* searchIconContainer =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    UIImageView* searchIcon =
        [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
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
      migrated[6] =
          @{ @"title" : @"ChatGPT", @"url" : @"https://chatgpt.com" };
      migrated[7] =
          @{ @"title" : @"Claude", @"url" : @"https://claude.ai/new" };
      [[NSUserDefaults standardUserDefaults] setObject:migrated
                                                forKey:@"BlinkShortcuts"];
      return migrated;
    }
    return saved;
  }
  return @[
    @{ @"title" : @"GitHub", @"url" : @"https://github.com" },
    @{ @"title" : @"Reddit", @"url" : @"https://www.reddit.com" },
    @{ @"title" : @"YouTube", @"url" : @"https://www.youtube.com" },
    @{ @"title" : @"Google", @"url" : @"https://www.google.com" },
    @{ @"title" : @"Gmail", @"url" : @"https://mail.google.com" },
    @{ @"title" : @"Proton", @"url" : @"https://mail.proton.me" },
    @{ @"title" : @"ChatGPT", @"url" : @"https://chatgpt.com" },
    @{ @"title" : @"Claude", @"url" : @"https://claude.ai/new" },
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
    iconSurface.backgroundColor =
        [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0];
    iconSurface.layer.cornerRadius = 29;
    iconSurface.layer.cornerCurve = kCACornerCurveContinuous;
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
      [monogram.leadingAnchor constraintEqualToAnchor:iconSurface.leadingAnchor],
      [monogram.trailingAnchor constraintEqualToAnchor:iconSurface.trailingAnchor],
      [monogram.topAnchor constraintEqualToAnchor:iconSurface.topAnchor],
      [monogram.bottomAnchor constraintEqualToAnchor:iconSurface.bottomAnchor],
      [favicon.leadingAnchor constraintEqualToAnchor:iconSurface.leadingAnchor constant:8],
      [favicon.trailingAnchor constraintEqualToAnchor:iconSurface.trailingAnchor constant:-8],
      [favicon.topAnchor constraintEqualToAnchor:iconSurface.topAnchor constant:8],
      [favicon.bottomAnchor constraintEqualToAnchor:iconSurface.bottomAnchor constant:-8],
      [caption.topAnchor constraintEqualToAnchor:iconSurface.bottomAnchor constant:3],
      [caption.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
      [caption.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
      [caption.bottomAnchor constraintLessThanOrEqualToAnchor:button.bottomAnchor],
    ]];
    [self loadFaviconForURL:link[@"url"]
                 intoView:favicon
                  fallback:monogram
               buttonIndex:button.tag];
    [button addTarget:self
                  action:@selector(linkTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    UIContextMenuInteraction* menu =
        [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [button addInteraction:menu];
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
  [[[NSURLSession sharedSession] dataTaskWithURL:touchIconURL
                               completionHandler:^(NSData* data,
                                                   NSURLResponse* response,
                                                   NSError* error) {
    UIImage* image = data.length ? [UIImage imageWithData:data] : nil;
    if (!image) {
      NSString* encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:
                                      NSCharacterSet.URLQueryAllowedCharacterSet];
      NSURL* highResolutionURL = [NSURL URLWithString:
          [NSString stringWithFormat:
              @"https://www.google.com/s2/favicons?domain_url=%@&sz=256",
              encoded]];
      [[[NSURLSession sharedSession]
          dataTaskWithURL:highResolutionURL
        completionHandler:^(NSData* fallbackData, NSURLResponse* fallbackResponse,
                            NSError* fallbackError) {
        UIImage* fallbackImage =
            fallbackData.length ? [UIImage imageWithData:fallbackData] : nil;
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

- (void)editShortcutButton:(UIButton*)button {
  NSMutableArray* links = [[self shortcutDefinitions] mutableCopy];
  NSDictionary* current = links[button.tag];
  UIAlertController* alert =
      [UIAlertController alertControllerWithTitle:@"Edit Shortcut"
                                          message:@"Change this website shortcut."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"Name";
    field.text = current[@"title"];
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"https://example.com";
    field.text = current[@"url"];
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  __weak BlinkerStartPageView* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
    NSString* title = alert.textFields.firstObject.text ?: @"Site";
    NSString* url = alert.textFields.lastObject.text ?: @"";
    if (url.length && ![url containsString:@"://"]) {
      url = [@"https://" stringByAppendingString:url];
    }
    NSURL* parsed = [NSURL URLWithString:url];
    if (!parsed.host.length) {
      return;
    }
    links[button.tag] = @{ @"title" : title.length ? title : parsed.host,
                           @"url" : url };
    [[NSUserDefaults standardUserDefaults] setObject:links
                                              forKey:@"BlinkShortcuts"];
    [weakSelf rebuildShortcutGrid];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [[self owningViewController] presentViewController:alert
                                            animated:YES
                                          completion:nil];
}

- (UIContextMenuConfiguration*)contextMenuInteraction:
                                   (UIContextMenuInteraction*)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
  UIButton* button = (UIButton*)interaction.view;
  __weak BlinkerStartPageView* weakSelf = self;
  UIAction* edit = [UIAction
      actionWithTitle:@"Edit Shortcut"
                image:[UIImage systemImageNamed:@"pencil"]
           identifier:nil
              handler:^(__kindof UIAction* action) {
                [weakSelf editShortcutButton:button];
              }];
  return [UIContextMenuConfiguration
      configurationWithIdentifier:nil
                   previewProvider:nil
                    actionProvider:^UIMenu*(NSArray<UIMenuElement*>* actions) {
                      return [UIMenu menuWithTitle:@"" children:@[ edit ]];
                    }];
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
  UIImpactFeedbackGenerator* feedback =
      [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
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
  return YES;
}

@end

@implementation ContentShellWindowDelegate
@synthesize backButton = _backButton;
@synthesize contentView = _contentView;
@synthesize urlField = _urlField;
@synthesize forwardButton = _forwardButton;
@synthesize reloadOrStopButton = _reloadOrStopButton;
@synthesize menuButton = _menuButton;
@synthesize toolbarBackgroundView = _toolbarBackgroundView;
@synthesize toolbarContentView = _toolbarContentView;
@synthesize tracingHandler = _tracingHandler;
std::unique_ptr<content::ScopedAccessibilityMode> _scopedAccessibilityMode;

+ (UIColor*)backgroundColorDefault {
  // Warm red-orange to match the ungoogled-chromium app icon.
  return [UIColor colorWithRed:224.0 / 255.0
                         green:71.0 / 255.0
                          blue:40.0 / 255.0
                         alpha:1.0];
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
    self.urlField = [self makeURLBar];
    self.tracingHandler = [[TracingHandler alloc] init];

    [self.view addSubview:_toolbarBackgroundView];
    [_toolbarBackgroundView addArrangedSubview:_toolbarContentView];

    [_toolbarContentView addArrangedSubview:_backButton];
    [_toolbarContentView addArrangedSubview:_forwardButton];
    [_toolbarContentView addArrangedSubview:_reloadOrStopButton];
    [_toolbarContentView addArrangedSubview:_menuButton];
    [_toolbarContentView addArrangedSubview:_urlField];

    self.loadingProgressView =
        [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _loadingProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingProgressView.progressTintColor = BlinkerAccentColor();
    _loadingProgressView.trackTintColor = UIColor.clearColor;
    _loadingProgressView.hidden = YES;
    [self.view addSubview:_loadingProgressView];

    self.view.accessibilityElements = @[ _toolbarBackgroundView, _contentView ];
    self.view.isAccessibilityElement = NO;

    // Constraint the toolbar background view. (Vertical position — top vs
    // bottom — is set by -applyToolbarPosition so it can be toggled in Settings.)
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
  [NSLayoutConstraint activateConstraints:@[
    [_contentView.leadingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_contentView.trailingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
  ]];
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
    self.view.window.overrideUserInterfaceStyle =
        (UIUserInterfaceStyle)appearance;
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
  if (![[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkAppLock"])
    return;
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
  if (_privacyLockView)
    return;
  UIView* cover = [[UIView alloc] init];
  cover.backgroundColor = [UIColor colorWithWhite:0.055 alpha:1];
  cover.translatesAutoresizingMaskIntoConstraints = NO;
  UIImageView* icon = [[UIImageView alloc]
      initWithImage:[UIImage systemImageNamed:@"lock.shield.fill"]];
  icon.tintColor = BlinkerAccentColor();
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel* title = [[UILabel alloc] init];
  title.text = @"Blinker Fluid Locked";
  title.textColor = UIColor.whiteColor;
  title.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
  title.translatesAutoresizingMaskIntoConstraints = NO;
  UIButton* unlock = [UIButton buttonWithType:UIButtonTypeSystem];
  [unlock setTitle:@"Open with Face ID/Password"
          forState:UIControlStateNormal];
  unlock.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
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
    [icon.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-65],
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
                            error:&error])
    return;
  [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
          localizedReason:@"Unlock your Blinker Fluid browsing session"
                    reply:^(BOOL success, NSError* authError) {
    if (!success)
      return;
    dispatch_async(dispatch_get_main_queue(), ^{
      g_blink_app_unlocked = true;
      for (content::Shell* shell : content::Shell::windows()) {
        UIWindow* window = shell->window().Get();
        if ([window.rootViewController
                isKindOfClass:[ContentShellWindowDelegate class]]) {
          [(ContentShellWindowDelegate*)window.rootViewController
              updatePrivacyLock];
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
    NSInteger se =
        [[NSUserDefaults standardUserDefaults] integerForKey:@"BlinkSearchEngine"];
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
  [button setImage:[UIImage imageNamed:imageName]
          forState:UIControlStateNormal];
  button.tintColor = [UIColor whiteColor];
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
  return field;
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
  UIImpactFeedbackGenerator* feedback =
      [[UIImpactFeedbackGenerator alloc] initWithStyle:
                                               UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  // NavigationController::Reload() crashes on many sites here, but
  // a normal navigation (typed URL / link click) works — so implement "reload"
  // as a fresh load of the current URL, which uses that working path. Always
  // reload (don't branch on IsLoading -> Stop, which made the button a no-op
  // on pages that report as perpetually loading).
  GURL url = _shell->web_contents()->GetLastCommittedURL();
  if (!url.is_valid()) {
    url = _shell->web_contents()->GetVisibleURL();
  }
  if (url.is_valid()) {
    _shell->LoadURL(url);
  }
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
  const std::string message = base::StringPrintf(
      "TAB_MANAGER: %s id=%d tab_count=%zu", action,
      [self tabIdForShell:shell], content::Shell::windows().size());
  BlinkBootLog(message.c_str());
}

- (void)showTabWindow:(content::Shell*)shell {
  if (!shell) {
    return;
  }
  if (shell->web_contents() && shell->web_contents()->WasDiscarded()) {
    GURL reload = shell->web_contents()->GetLastCommittedURL();
    shell->web_contents()->SetPageFrozen(false);
    if (reload.is_valid() && reload.SchemeIsHTTPOrHTTPS()) {
      BlinkBootLog("TAB_LIFECYCLE: reloading discarded tab");
      shell->LoadURL(reload);
    }
  }
  GURL pending = content::TakePendingRestoreURL(shell);
  if (pending.is_valid() && pending.SchemeIsHTTPOrHTTPS() &&
      shell->web_contents()) {
    BlinkBootLog("SESSION_RESTORE: loading deferred tab");
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
    win.windowScene = self.view.window.windowScene;
    win.hidden = NO;
    [win makeKeyAndVisible];
  }
  BlinkDiscardBackgroundTabs(shell);
  // Switching must NOT change the tab count or create a WebContents.
  char buf[160];
  snprintf(buf, sizeof(buf), "TAB_MANAGER: active tab id=%d web_contents=%p",
           [self tabIdForShell:shell],
           shell->web_contents() ? (void*)shell->web_contents() : nullptr);
  BlinkBootLog(buf);
  BlinkBootLog(shell->web_contents()
                   ? "TAB_MANAGER: invariant ok"
                   : "TAB_MANAGER: invariant failed active_missing");
}

- (void)openNewTab {
  BlinkBootLog("TAB_MANAGER: new tab requested");
  const size_t before = content::Shell::windows().size();
  // NOTE: true incognito needs a SEPARATE BrowserContext, but single-process
  // mode (forced on iOS 15 — BrowserEngineKit's multi-process model is 17.4+)
  // CHECKs exactly one browser context per process
  // (render_process_host_impl.cc) and aborts otherwise. So all tabs share the
  // one normal context. For privacy, use "Clear Browsing Data" in the menu.
  content::ShellBrowserContext* context =
      content::ShellContentBrowserClient::Get()->browser_context();
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
    BlinkBootLog("TAB_MANAGER: new tab request safely refused");
    const size_t after = content::Shell::windows().size();
    BlinkBootLog(after == before
                     ? "TAB_MANAGER: invariant ok blocked_no_count_change"
                     : "TAB_MANAGER: invariant failed blocked_changed_count");
    return;
  }
  [self logTab:"new tab created" shell:newShell];
  const size_t after = content::Shell::windows().size();
  BlinkBootLog(after == before + 1
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
          initWithImage:[UIImage systemImageNamed:@"chevron.left"]
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
  BlinkBootLog("TAB_MANAGER: tab button tapped");
  BlinkBootLog("TAB_MANAGER_UI: tab manager opened");
  [self logTab:"active tab" shell:_shell];
  UICollectionViewFlowLayout* layout = [[UICollectionViewFlowLayout alloc] init];
  CGFloat width = MIN(self.view.bounds.size.width, 600);
  CGFloat cardWidth = floor((width - 44) / 2);
  layout.itemSize = CGSizeMake(cardWidth, cardWidth * 1.34);
  layout.sectionInset = UIEdgeInsetsMake(16, 14, 24, 14);
  layout.minimumInteritemSpacing = 12;
  layout.minimumLineSpacing = 16;
  BlinkTabsVC* vc =
      [[BlinkTabsVC alloc] initWithCollectionViewLayout:layout];
  vc.titles = [NSMutableArray array];
  vc.urls = [NSMutableArray array];
  vc.previews = [NSMutableArray array];
  NSMutableArray<NSValue*>* shells = [NSMutableArray array];
  for (content::Shell* s : content::Shell::windows()) {
    std::u16string t = s->web_contents()->GetTitle();
    NSString* title = t.empty() ? @"New Tab" : base::SysUTF16ToNSString(t);
    [vc.titles addObject:title];
    [vc.urls
        addObject:base::SysUTF8ToNSString(
                      s->web_contents()->GetVisibleURL().possibly_invalid_spec())];
    UIImage* preview = BlinkCaptureTabPreview(s);
    [vc.previews addObject:preview ?: [[UIImage alloc] init]];
    [shells addObject:[NSValue valueWithPointer:s]];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    content::Shell* sel = (content::Shell*)[shells[i] pointerValue];
    const size_t before = content::Shell::windows().size();
    char b[160];
    snprintf(b, sizeof(b), "TAB_MANAGER: selected existing tab id=%d",
             [weakSelf tabIdForShell:sel]);
    BlinkBootLog(b);
    // Selecting an existing tab only switches — it must NEVER create a tab or
    // call CreateNewWindow.
    [weakSelf showTabWindow:sel];
    snprintf(b, sizeof(b), "TAB_MANAGER: switched to existing WebContents=%p",
             sel && sel->web_contents() ? (void*)sel->web_contents() : nullptr);
    BlinkBootLog(b);
    if (content::Shell::windows().size() == before) {
      BlinkBootLog("TAB_MANAGER: selection did not create new tab");
      BlinkBootLog("TAB_MANAGER: invariant ok select_no_count_change");
    } else {
      BlinkBootLog("TAB_MANAGER: invariant failed select_created_tab");
    }
  };
  vc.onAdd = ^{
    BlinkBootLog("TAB_MANAGER: new tab requested");
    [weakSelf openNewTab];
  };
  vc.onClose = ^BOOL(NSInteger i) {
    ContentShellWindowDelegate* strongSelf = weakSelf;
    if (!strongSelf) {
      return NO;
    }
    content::Shell* s = (content::Shell*)[shells[i] pointerValue];
    if (content::Shell::windows().size() <= 1) {
      BlinkBootLog("TAB_MANAGER: kept final tab open");
      return NO;
    }
    [strongSelf logTab:"close tab requested" shell:s];
    if (s == strongSelf->_shell) {
      for (content::Shell* replacement : content::Shell::windows()) {
        if (replacement != s) {
          content::Shell* selectedReplacement = replacement;
          [strongSelf dismissViewControllerAnimated:NO completion:^{
            [strongSelf showTabWindow:selectedReplacement];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                  s->Close();
                  BlinkSaveOpenTabs();
                });
          }];
          BlinkBootLog("TAB_MANAGER: active close handed off to replacement");
          break;
        }
      }
      return NO;
    }
    [shells removeObjectAtIndex:i];
    s->Close();
    BlinkBootLog("TAB_MANAGER: close dispatched");
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
  if (!saved)
    return [NSMutableArray array];
  NSData* data = [NSPropertyListSerialization dataWithPropertyList:saved
                                                            format:
                                                NSPropertyListBinaryFormat_v1_0
                                                           options:0
                                                             error:nil];
  return data ? [NSPropertyListSerialization propertyListWithData:data
                                                           options:
                                                NSPropertyListMutableContainers
                                                            format:nil
                                                             error:nil]
              : [NSMutableArray array];
}

- (void)addBookmarkWithCompletion:(void (^)(NSDictionary*))completion {
  UIAlertController* alert =
      [UIAlertController alertControllerWithTitle:@"Add Bookmark"
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
  [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
    NSString* title = alert.textFields.firstObject.text ?: @"";
    NSString* value = alert.textFields.lastObject.text ?: @"";
    value = [value stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length && ![value containsString:@"://"]) {
      value = [@"https://" stringByAppendingString:value];
    }
    NSURL* url = [NSURL URLWithString:value];
    if (!url.host.length) {
      UIAlertController* invalid =
          [UIAlertController alertControllerWithTitle:@"Invalid address"
                                              message:@"Enter a complete website address."
                                       preferredStyle:UIAlertControllerStyleAlert];
      [invalid addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
      UIViewController* host =
          weakSelf.presentedViewController ?: weakSelf;
      [host presentViewController:invalid animated:YES completion:nil];
      return;
    }
    NSDictionary* bookmark =
        @{ @"title" : title.length ? title : url.host, @"url" : value };
    if (completion) {
      completion(bookmark);
    }
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  UIViewController* presenter = self.presentedViewController ?: self;
  [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)showBookmarks {
  [self showBookmarksAtPath:@[] title:@"Bookmarks"];
}

- (NSMutableArray*)bookmarkItemsInRoot:(NSMutableArray*)root
                                  path:(NSArray<NSNumber*>*)path {
  NSMutableArray* items = root;
  for (NSNumber* component in path) {
    NSInteger index = component.integerValue;
    if (index < 0 || index >= (NSInteger)items.count)
      return nil;
    NSMutableDictionary* folder = items[index];
    if (![folder isKindOfClass:NSMutableDictionary.class])
      return nil;
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
  if (!bms)
    return;
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
    [vc.subtitles addObject:folder
                                ? [NSString stringWithFormat:@"%lu items",
                                      (unsigned long)[b[@"children"] count]]
                                : url];
    [icons addObject:folder ? @"folder.fill" : @"bookmark"];
  }
  vc.imageNames = icons;
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    if (i >= (NSInteger)bms.count)
      return;
    NSDictionary* item = bms[i];
    if ([item[@"children"] isKindOfClass:NSArray.class]) {
      [weakSelf showBookmarksAtPath:
                    [path arrayByAddingObject:@(i)]
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
            folder ? [@{ @"title" : name,
                         @"children" : [NSMutableArray array] } mutableCopy]
                   : [@{ @"title" : name, @"url" : url } mutableCopy];
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
    [weakBookmarksVC.navigationController pushViewController:chooser animated:YES];
  };
  [self presentList:vc];
}

// Downloads — content_shell saves to <data>/MyFiles/Downloads.
- (void)showDownloads {
  base::FilePath p = _shell->web_contents()
                         ->GetBrowserContext()
                         ->GetPath()
                         .Append(FILE_PATH_LITERAL("MyFiles"))
                         .Append(FILE_PATH_LITERAL("Downloads"));
  NSString* dir = base::SysUTF8ToNSString(p.value());
  NSFileManager* fm = [NSFileManager defaultManager];
  NSArray* files = [fm contentsOfDirectoryAtPath:dir error:nil];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Downloads";
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
    NSSet* imageExtensions =
        [NSSet setWithArray:@[ @"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp" ]];
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
      CGImageRef frame = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600)
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
  [NSLayoutConstraint deactivateConstraints:_topPosConstraints];
  [NSLayoutConstraint deactivateConstraints:_bottomPosConstraints];
  if (content::Shell::ShouldHideToolbar() || !_toolbarBackgroundView) {
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
    bottom
        ? [_loadingProgressView.bottomAnchor
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
    // rather than the safe-area line, which otherwise leaves an empty white bar.
    [_contentView.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor
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
  [NSLayoutConstraint activateConstraints:bottom ? _bottomPosConstraints
                                                 : _topPosConstraints];
}

- (void)setPageLoading:(BOOL)loading {
  if (!_loadingProgressView) {
    return;
  }
  [_loadingProgressView.layer removeAllAnimations];
  if (loading) {
    _loadingProgressView.hidden = NO;
    [_loadingProgressView setProgress:0.12 animated:NO];
    [UIView animateWithDuration:8.0 animations:^{
      [self.loadingProgressView setProgress:0.86 animated:YES];
    }];
  } else {
    [_loadingProgressView setProgress:1 animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      self.loadingProgressView.hidden = YES;
      [self.loadingProgressView setProgress:0 animated:NO];
    });
  }
}

- (void)setKeyboardViewportInset:(CGFloat)inset {
  CGFloat clamped = MAX((CGFloat)0, inset);
  if (fabs(_keyboardViewportInset - clamped) < 1)
    return;
  _keyboardViewportInset = clamped;
  [self applyToolbarPosition];
  [UIView animateWithDuration:0.20
                   animations:^{
                     [self.view layoutIfNeeded];
                   }];
}

- (void)toggleToolbarPosition {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setBool:![d boolForKey:@"BlinkToolbarBottom"] forKey:@"BlinkToolbarBottom"];
  for (content::Shell* s : content::Shell::windows()) {
    UIWindow* w = s->window().Get();
    if ([w.rootViewController isKindOfClass:[ContentShellWindowDelegate class]]) {
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
      if (window.isKeyWindow || inset == 0)
        [delegate setKeyboardViewportInset:inset];
    }
  });
}

- (void)showMainMenu {
  UIImpactFeedbackGenerator* feedback =
      [[UIImpactFeedbackGenerator alloc] initWithStyle:
                                               UIImpactFeedbackStyleLight];
  [feedback impactOccurred];
  __weak ContentShellWindowDelegate* weakSelf = self;
  bool isDesktop = _shell && _shell->web_contents() &&
                   !_shell->web_contents()
                        ->GetUserAgentOverride()
                        .ua_string_override.empty();
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Menu";
  vc.compactRows = YES;
  vc.dismissOnSelect = NO;
  vc.titles = [@[
    @"Reload", @"New Tab",
    [NSString stringWithFormat:@"Tabs (%zu)", content::Shell::windows().size()],
    @"Home", @"Bookmarks", @"Downloads",
    isDesktop ? @"Request Mobile Page" : @"Request Desktop Page",
    @"Share Link", @"Settings", @"Check for Updates"
  ] mutableCopy];
  vc.subtitles = [@[
    @"", @"", @"", @"", @"", @"",
    @"", @"", @"", @"Latest GitHub release"
  ] mutableCopy];
  vc.imageNames = @[
    @"arrow.clockwise", @"plus", @"square.on.square", @"house",
    @"bookmark", @"arrow.down.circle", @"desktopcomputer",
    @"square.and.arrow.up", @"gearshape", @"arrow.triangle.2.circlepath"
  ];
  vc.sectionTitles = @[ @"BROWSER", @"LIBRARY", @"APP" ];
  vc.sectionStarts = @[ @0, @4, @8 ];
  __weak BlinkListVC* weakMenu = vc;
  vc.onSelect = ^(NSInteger row) {
    void (^dismissThen)(dispatch_block_t) = ^(dispatch_block_t action) {
      [weakMenu.navigationController dismissViewControllerAnimated:YES
                                                        completion:action];
    };
    if (row == 0) dismissThen(^{ [weakSelf reloadOrStop]; });
    else if (row == 1) dismissThen(^{ [weakSelf openNewTab]; });
    else if (row == 2) dismissThen(^{ [weakSelf showTabSwitcher]; });
    else if (row == 3) dismissThen(^{ [weakSelf goHome]; });
    else if (row == 4) [weakSelf showBookmarks];
    else if (row == 5) [weakSelf showDownloads];
    else if (row == 6) dismissThen(^{ [weakSelf toggleDesktopSite]; });
    else if (row == 7) dismissThen(^{ [weakSelf shareCurrentLink]; });
    else if (row == 8) [weakSelf showSettings];
    else if (row == 9) [weakSelf checkForUpdates];
  };
  UINavigationController* nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationPopover;
  nav.preferredContentSize = CGSizeMake(MIN(340, self.view.bounds.size.width - 36),
                                       MIN(500, self.view.bounds.size.height - 130));
  UIPopoverPresentationController* popover = nav.popoverPresentationController;
  popover.delegate = self;
  popover.sourceView = _menuButton;
  popover.sourceRect = _menuButton.bounds;
  popover.permittedArrowDirections =
      UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
  popover.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
  [self presentViewController:nav animated:YES completion:nil];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:
    (UIPresentationController*)controller {
  return UIModalPresentationNone;
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
  UIActivityViewController* share = [[UIActivityViewController alloc]
      initWithActivityItems:@[ url ?: value ]
      applicationActivities:nil];
  share.popoverPresentationController.sourceView = self.menuButton;
  share.popoverPresentationController.sourceRect = self.menuButton.bounds;
  [self presentViewController:share animated:YES completion:nil];
}

- (void)updateBackground {
  _toolbarBackgroundView.backgroundColor =
      [_tracingHandler isTracing]
          ? [ContentShellWindowDelegate backgroundColorTracing]
          : [ContentShellWindowDelegate backgroundColorDefault];
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
  BOOL isStartPage =
      (url.length == 0) || [url isEqualToString:@"about:blank"];
  [self showStartPage:isStartPage];
  _urlField.text = isStartPage ? @"" : url;
  if (!isStartPage &&
      ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"])) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString*>* history =
        [[defaults stringArrayForKey:@"BlinkHistory"] mutableCopy] ?:
        [NSMutableArray array];
    if (![history.firstObject isEqualToString:url]) {
      [history insertObject:url atIndex:0];
      if (history.count > 250)
        [history removeObjectsInRange:NSMakeRange(250, history.count - 250)];
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
  UIAlertController* sheet =
      [self actionSheetWithTitle:@"Search engine" message:nil];
  for (size_t i = 0; i < std::size(kSearchEngines); ++i) {
    NSString* title = [NSString stringWithUTF8String:kSearchEngines[i].name];
    [sheet addAction:[UIAlertAction actionWithTitle:title
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              g_search_engine = (int)i;
                                              [[NSUserDefaults standardUserDefaults]
                                                  setInteger:i
                                                      forKey:@"BlinkSearchEngine"];
                                            }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self tintMenu:sheet color:BlinkerAccentColor()];
  UIViewController* presenter =
      self.presentedViewController ?: self;
  [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)checkForUpdates {
  NSURL* endpoint = [NSURL URLWithString:
      @"https://api.github.com/repos/Nodesclock/Blinker-fluid/releases/latest"];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:endpoint];
  [request setValue:@"application/vnd.github+json"
      forHTTPHeaderField:@"Accept"];
  [request setValue:@"Blinker-Fluid/0.2.1"
      forHTTPHeaderField:@"User-Agent"];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSDictionary* release =
        data.length ? [NSJSONSerialization JSONObjectWithData:data
                                                     options:0
                                                       error:nil]
                    : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      ContentShellWindowDelegate* strongSelf = weakSelf;
      if (!strongSelf)
        return;
      NSString* tag = [release[@"tag_name"] isKindOfClass:NSString.class]
                          ? release[@"tag_name"]
                          : nil;
      if (error || !tag.length) {
        UIAlertController* failed = [UIAlertController
            alertControllerWithTitle:@"Couldn’t Check for Updates"
                             message:@"No published GitHub release was found, or "
                                     @"GitHub could not be reached."
                      preferredStyle:UIAlertControllerStyleAlert];
        [failed addAction:[UIAlertAction actionWithTitle:@"OK"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];
        UIViewController* host =
            strongSelf.presentedViewController ?: strongSelf;
        [host presentViewController:failed animated:YES completion:nil];
        return;
      }
      NSString* normalized =
          [[tag lowercaseString] stringByReplacingOccurrencesOfString:@"v"
                                                            withString:@""];
      BOOL newer =
          [normalized compare:@"0.2.1"
                      options:NSNumericSearch] == NSOrderedDescending;
      NSString* notes = [release[@"body"] isKindOfClass:NSString.class]
                            ? release[@"body"]
                            : @"No changelog was supplied.";
      if (notes.length > 1800)
        notes = [[notes substringToIndex:1800]
            stringByAppendingString:@"\n\n…"];
      NSMutableArray* assets = [release[@"assets"] isKindOfClass:NSArray.class]
                                   ? release[@"assets"]
                                   : nil;
      __block NSString* ipaURL = nil;
      for (NSDictionary* asset in assets) {
        NSString* candidate = asset[@"browser_download_url"];
        if ([candidate.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
          ipaURL = candidate;
          break;
        }
      }
      NSString* title = newer ? [NSString stringWithFormat:@"Update %@", tag]
                              : @"Blinker Fluid is Up to Date";
      NSString* message =
          [NSString stringWithFormat:@"Installed: 0.2.1\nLatest: %@\n\n%@",
                                     tag, notes];
      UIAlertController* result =
          [UIAlertController alertControllerWithTitle:title
                                              message:message
                                       preferredStyle:UIAlertControllerStyleAlert];
      if (newer && ipaURL.length) {
        [result addAction:[UIAlertAction actionWithTitle:@"Update with TrollStore"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction* action) {
          NSString* encoded =
              [ipaURL stringByAddingPercentEncodingWithAllowedCharacters:(^{
                NSMutableCharacterSet* allowed =
                    [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
                [allowed removeCharactersInString:@"&=?#"];
                return allowed;
              })()];
          NSURL* install = [NSURL URLWithString:
              [@"apple-magnifier://install?url=" stringByAppendingString:encoded]];
          [[UIApplication sharedApplication] openURL:install
                                             options:@{}
                                   completionHandler:nil];
        }]];
      }
      [result addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
      UIViewController* host =
          strongSelf.presentedViewController ?: strongSelf;
      [host presentViewController:result animated:YES completion:nil];
    });
  }] resume];
}

// Settings that are global browser preferences.
- (void)showSettings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Settings";
  vc.dismissOnSelect = NO;
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  BOOL bottom = [d boolForKey:@"BlinkToolbarBottom"];
  UIUserInterfaceStyle st = self.view.window.overrideUserInterfaceStyle;
  NSString* theme = st == UIUserInterfaceStyleDark
                        ? @"Dark"
                        : (st == UIUserInterfaceStyleLight ? @"Light" : @"System");
  [vc.titles addObject:@"Search Engine"];
  [vc.subtitles addObject:[NSString stringWithUTF8String:
                                        kSearchEngines[g_search_engine].name]];
  [vc.titles addObject:@"Appearance"];
  [vc.subtitles addObject:theme];
  [vc.titles addObject:@"Toolbar Position"];
  [vc.subtitles addObject:bottom ? @"Bottom" : @"Top"];
  NSString* proxy = [d stringForKey:@"BlinkProxy"];
  [vc.titles addObject:@"Tor / Proxy"];
  [vc.subtitles addObject:proxy.length ? proxy : @"Off"];
  [vc.titles addObject:@"Password / Face ID Lock"];
  [vc.subtitles addObject:[d boolForKey:@"BlinkAppLock"] ? @"On" : @"Off"];
  [vc.titles addObject:@"HTTPS-First Navigation"];
  [vc.subtitles addObject:[d boolForKey:@"BlinkHTTPSFirst"] ? @"On" : @"Off"];
  [vc.titles addObject:@"Website Permissions"];
  [vc.subtitles addObject:@"Location, camera and microphone"];
  [vc.titles addObject:@"Clear Browsing Data"];
  [vc.subtitles addObject:@"History and website data"];
  [vc.titles addObject:@"History"];
  [vc.subtitles addObject:@"Recently visited pages"];
  [vc.titles addObject:@"About Blinker Fluid"];
  [vc.subtitles addObject:@"Version, source and developer"];
  vc.imageNames =
      @[ @"magnifyingglass", @"circle.lefthalf.filled", @"rectangle.bottomthird.inset.filled",
         @"lock.shield", @"lock.fill", @"checkmark.shield", @"hand.raised",
         @"trash", @"clock.arrow.circlepath", @"info.circle" ];
  vc.titleColors =
      @[ [NSNull null], [NSNull null], [NSNull null], BlinkerTorColor(),
         [NSNull null], [NSNull null], [NSNull null], [NSNull null],
         [NSNull null], [NSNull null] ];
  vc.sectionTitles = @[ @"GENERAL", @"PRIVACY", @"ABOUT" ];
  vc.sectionStarts = @[ @0, @3, @9 ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  __weak BlinkListVC* weakSettings = vc;
  vc.onSelect = ^(NSInteger i) {
    if (i == 0) {
      [weakSelf presentSearchEngineMenu];
    } else if (i == 1) {
      [weakSelf showAppearanceMenu];
    } else if (i == 2) {
      [weakSelf toggleToolbarPosition];
      BOOL nowBottom =
          [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkToolbarBottom"];
      weakSettings.subtitles[2] = nowBottom ? @"Bottom" : @"Top";
      [weakSettings.tableView reloadData];
    } else if (i == 3) {
      [weakSelf showProxySettings];
    } else if (i == 4) {
      [weakSelf toggleAppLockFromSettings:weakSettings];
    } else if (i == 5) {
      BOOL enabled = ![[NSUserDefaults standardUserDefaults]
          boolForKey:@"BlinkHTTPSFirst"];
      [[NSUserDefaults standardUserDefaults] setBool:enabled
                                             forKey:@"BlinkHTTPSFirst"];
      weakSettings.subtitles[5] = enabled ? @"On" : @"Off";
      [weakSettings.tableView reloadData];
    } else if (i == 6) {
      [weakSelf showWebsitePermissions];
    } else if (i == 7) {
      [weakSelf showClearBrowsingData];
    } else if (i == 8) {
      [weakSelf showHistory];
    } else if (i == 9) {
      [weakSelf showAbout];
    }
  };
  [self presentList:vc];
}

- (void)toggleAppLockFromSettings:(BlinkListVC*)settings {
  LAContext* context = [[LAContext alloc] init];
  NSError* error = nil;
  if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error])
    return;
  BOOL currentlyEnabled =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkAppLock"];
  NSString* reason = currentlyEnabled
                         ? @"Authenticate to turn off Blinker Fluid App Lock"
                         : @"Authenticate to protect Blinker Fluid";
  __weak ContentShellWindowDelegate* weakSelf = self;
  [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
          localizedReason:reason
                    reply:^(BOOL success, NSError* authError) {
    if (!success)
      return;
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL enabled = !currentlyEnabled;
      [[NSUserDefaults standardUserDefaults] setBool:enabled
                                             forKey:@"BlinkAppLock"];
      g_blink_app_unlocked = enabled;
      settings.subtitles[4] = enabled ? @"On" : @"Off";
      [settings.tableView reloadData];
      [weakSelf updatePrivacyLock];
    });
  }];
}

- (void)showWebsitePermissions {
  NSString* (^state)(int) = ^NSString*(int permission) {
    if (BlinkIOSSystemPermissionStatus(permission))
      return @"Allowed in iOS Settings";
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
  vc.title = @"Website Permissions";
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
        [UIApplication.sharedApplication openURL:url options:@{}
                               completionHandler:nil];
      }
    } else if (row == 1 || row == 2) {
      int permission = row == 1 ? 2 : 1;
      AVMediaType type =
          permission == 1 ? AVMediaTypeAudio : AVMediaTypeVideo;
      AVAuthorizationStatus status =
          [AVCaptureDevice authorizationStatusForMediaType:type];
      if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:type
                                 completionHandler:^(BOOL granted) {
          dispatch_async(dispatch_get_main_queue(), ^{
            weakPermissions.subtitles[row] =
                granted ? @"Allowed in iOS Settings"
                        : @"Off — change in iOS Settings";
            [weakPermissions.tableView reloadData];
          });
        }];
      } else {
        NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [UIApplication.sharedApplication openURL:url options:@{}
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
          mutableCopy] ?: [NSMutableArray array];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"History";
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
    if (row < (NSInteger)history.count)
      [weakSelf openUserInput:history[row]];
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
  UIAlertController* alert =
      [UIAlertController alertControllerWithTitle:@"Clear Browsing Data"
                                          message:@"Clear browsing history and "
                                                  @"reload all open tabs? Website "
                                                  @"cookies remain available so "
                                                  @"you are not signed out."
                                   preferredStyle:UIAlertControllerStyleAlert];
  __weak ContentShellWindowDelegate* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction* action) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BlinkHistory"];
    for (content::Shell* shell : content::Shell::windows()) {
      if (shell->web_contents())
        shell->web_contents()->GetController().Reload(
            content::ReloadType::NORMAL, true);
    }
    [weakSelf.navigationController popViewControllerAnimated:YES];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  UIViewController* host = self.presentedViewController ?: self;
  [host presentViewController:alert animated:YES completion:nil];
}

- (void)showAbout {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"About";
  vc.titles =
      [@[ @"Blinker Fluid", @"GitHub Repository", @"Nodesclock on GitHub",
           @"Monero (XMR)", @"Litecoin (LTC)" ] mutableCopy];
  vc.subtitles =
      [@[ @"Version 0.2.1", @"github.com/Nodesclock/Blinker-fluid",
           @"github.com/Nodesclock",
           @"8Ab52zsnVgzRRKp1HnhT6UWZY6GmUK67HXKZtQ8wHPMF4LXbDLiwSeJR2uHaRox71eQWxLk7BczDD1N7v9QbHWt5CK6Qtfw",
           @"ltc1q4zhq6sszzwvez79g9drzs29q9f5czdv9kcqtcc" ] mutableCopy];
  vc.imageNames = @[ @"safari", @"chevron.left.forwardslash.chevron.right",
                     @"person.crop.circle", @"heart.circle", @"heart.circle" ];
  vc.sectionTitles = @[ @"ABOUT", @"DONATIONS — TAP TO COPY" ];
  vc.sectionStarts = @[ @0, @3 ];
  vc.disabledRows = [NSIndexSet indexSetWithIndex:0];
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger row) {
    if (row == 1)
      [weakSelf openUserInput:@"https://github.com/Nodesclock/Blinker-fluid"];
    else if (row == 2)
      [weakSelf openUserInput:@"https://github.com/Nodesclock"];
    else if (row == 3) {
      UIPasteboard.generalPasteboard.string =
          @"8Ab52zsnVgzRRKp1HnhT6UWZY6GmUK67HXKZtQ8wHPMF4LXbDLiwSeJR2uHaRox71eQWxLk7BczDD1N7v9QbHWt5CK6Qtfw";
      [[[UINotificationFeedbackGenerator alloc] init]
          notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (row == 4) {
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
      alertControllerWithTitle:@"Tor / Proxy"
                       message:@"Enter an existing SOCKS5/HTTP proxy supplied "
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
  [a addAction:[UIAlertAction
                   actionWithTitle:@"Save"
                             style:UIAlertActionStyleDefault
                           handler:^(UIAlertAction* act) {
                             NSString* v =
                                 weakAlert.textFields.firstObject.text ?: @"";
                             v = [v stringByTrimmingCharactersInSet:
                                          [NSCharacterSet
                                              whitespaceCharacterSet]];
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
                                   alertControllerWithTitle:@"Invalid proxy"
                                                    message:@"Use a complete address such as socks5://127.0.0.1:9050."
                                             preferredStyle:UIAlertControllerStyleAlert];
                               [bad addAction:[UIAlertAction
                                   actionWithTitle:@"OK"
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
                                 alertControllerWithTitle:@"Restart required"
                                                  message:@"Quit and reopen the "
                                                          @"app to apply."
                                           preferredStyle:
                                               UIAlertControllerStyleAlert];
                             [r addAction:[UIAlertAction
                                              actionWithTitle:@"OK"
                                                        style:
                                                            UIAlertActionStyleDefault
                                                      handler:nil]];
                             UIViewController* host =
                                 weakSelf.presentedViewController ?: weakSelf;
                             [host presentViewController:r
                                               animated:YES
                                             completion:nil];
                           }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [self tintMenu:a color:BlinkerTorColor()];
  UIViewController* presenter =
      self.presentedViewController ?: self;
  [presenter presentViewController:a animated:YES completion:nil];
}

// Homepage: a custom start-page URL (blank = the built-in start page). Read by
// GetStartupURL on launch and by openNewTab for new tabs.
- (void)showHomepageSettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:@"Homepage"
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
                   actionWithTitle:@"Save"
                             style:UIAlertActionStyleDefault
                           handler:^(UIAlertAction* act) {
                             NSString* v =
                                 weakAlert.textFields.firstObject.text ?: @"";
                             v = [v stringByTrimmingCharactersInSet:
                                          [NSCharacterSet
                                              whitespaceCharacterSet]];
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
  [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [self tintMenu:a color:BlinkerAccentColor()];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)showAppearanceMenu {
  UIAlertController* sheet =
      [self actionSheetWithTitle:@"Appearance" message:nil];
  NSArray* options = @[
    @[ @"System", @(UIUserInterfaceStyleUnspecified) ],
    @[ @"Light", @(UIUserInterfaceStyleLight) ],
    @[ @"Dark", @(UIUserInterfaceStyleDark) ],
  ];
  for (NSArray* opt in options) {
    UIUserInterfaceStyle style = (UIUserInterfaceStyle)[opt[1] integerValue];
    [sheet addAction:[UIAlertAction actionWithTitle:opt[0]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* a) {
                                              for (content::Shell* s :
                                                   content::Shell::windows()) {
                                                UIWindow* w = s->window().Get();
                                                if (w) {
                                                  w.overrideUserInterfaceStyle =
                                                      style;
                                                }
                                              }
                                              [self applyWebColorScheme:style];
                                              [[NSUserDefaults standardUserDefaults]
                                                  setInteger:style
                                                      forKey:@"BlinkAppearance"];
                                            }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self tintMenu:sheet color:BlinkerAccentColor()];
  UIViewController* presenter =
      self.presentedViewController ?: self;
  [presenter presentViewController:sheet animated:YES completion:nil];
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
    if (!shell->web_contents())
      continue;
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
    BlinkBootLog("AUTH_FLOW: site mode locked during auth");
    BlinkBootLog("AUTH_FLOW: user agent stable during auth");
    return;
  }
  BlinkBootLog("SITE_MODE: button toggled");
  const GURL page_url = _shell->web_contents()->GetLastCommittedURL();
  NSString* modeKey = [NSString
      stringWithFormat:@"BlinkDesktopMode_%@",
                       base::SysUTF8ToNSString(page_url.host())];
  bool isDesktop =
      [[NSUserDefaults standardUserDefaults] boolForKey:modeKey];
  const bool setDesktop = !isDesktop;
  std::string ua =
      setDesktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 "
                   "Safari/537.36"
                 : std::string();
  BlinkBootLog(setDesktop ? "SITE_MODE: set desktop" : "SITE_MODE: set mobile");
  char uaLog[384];
  snprintf(uaLog, sizeof(uaLog), "SITE_MODE: applying user agent=%s",
           setDesktop ? ua.c_str() : "default mobile");
  BlinkBootLog(uaLog);
  blink::UserAgentOverride uaOverride;
  uaOverride.ua_string_override = ua;
  if (setDesktop) {
    // Sec-CH-UA-Mobile=?0 + macOS platform to match the desktop UA string.
    uaOverride.ua_metadata_override =
        content::GetShellUserAgentMetadataForSiteMode(/*desktop=*/true);
  }
  _shell->web_contents()->SetUserAgentOverride(uaOverride, true);
  BlinkBootLog(setDesktop ? "SITE_MODE: UA metadata mobile=false"
                          : "SITE_MODE: UA metadata mobile=true");

  // Native desktop mode via Chromium renderer prefs / device metrics (NO JS,
  // NO <meta viewport> injection). OverrideWebPreferences reads this flag to set
  // a wide (~980 CSS-px) desktop layout viewport; mobile restores device-width.
  // Cookies / localStorage / IndexedDB are left intact.
  content::g_force_desktop_site = setDesktop ? 1 : 0;
  [[NSUserDefaults standardUserDefaults] setBool:setDesktop forKey:modeKey];
  _shell->web_contents()->NotifyPreferencesChanged();
  BlinkBootLog("SITE_MODE: renderer prefs updated");
  BlinkBootLog(setDesktop ? "SITE_MODE: desktop device metrics width=980"
                          : "SITE_MODE: mobile device metrics restored");
  GURL current = _shell->web_contents()->GetLastCommittedURL();
  if (!current.is_valid()) {
    current = _shell->web_contents()->GetVisibleURL();
  }
  if (current.is_valid() && current.SchemeIsHTTPOrHTTPS()) {
    BlinkBootLog("SITE_MODE: reload after UA change");
    BlinkBootLog("SITE_MODE: reload after device metrics change");
    _shell->LoadURL(current);
  }
}

- (void)setContents:(UIView*)content {
  [_contentView addSubview:content];
}

- (UIAlertController*)actionSheetWithTitle:(nullable NSString*)title
                                   message:(nullable NSString*)message {
  UIAlertController* alertController = [UIAlertController
      alertControllerWithTitle:title
                       message:message
                preferredStyle:UIAlertControllerStyleActionSheet];
  alertController.popoverPresentationController.sourceView = _menuButton;
  alertController.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetWidth(_menuButton.bounds) / 2,
                 CGRectGetHeight(_menuButton.bounds), 1, 1);
  alertController.view.tintColor = BlinkerAccentColor();
  return alertController;
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

extern "C" void BlinkBootLog(const char* stage);

void ShellPlatformDelegate::CreatePlatformWindow(
    Shell* shell,
    const gfx::Size& initial_size) {
  BlinkBootLog("C1: ShellPlatformDelegate::CreatePlatformWindow");
  size_t active_frames = 0;
  for (content::Shell* window : content::Shell::windows()) {
    content::WebContents* contents = window->web_contents();
    if (contents && contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
      ++active_frames;
    }
  }
  const GURL last_url =
      shell && shell->web_contents() ? shell->web_contents()->GetVisibleURL()
                                     : GURL();
  char create_log[384];
  snprintf(create_log, sizeof(create_log),
           "C1a: CreatePlatformWindow web_contents=%zu active_frames=%zu "
           "last_url=%s",
           content::Shell::windows().size(), active_frames,
           last_url.spec().c_str());
  BlinkBootLog(create_log);
  DCHECK(!shell_data_map_.contains(shell));
  ShellData& shell_data = shell_data_map_[shell];

  UIWindow* window =
      [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  window.backgroundColor = [UIColor whiteColor];
#if !BUILDFLAG(IS_IOS_TVOS)
  // Leaves `tintColor` by default on tvOS. Refer to crbug.com/454180134.
  window.tintColor = [UIColor darkGrayColor];
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
    [(ContentShellWindowDelegate*)window.rootViewController
        setPageLoading:loading];
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
  [BlinkTabPreviewCache()
      removeObjectForKey:[NSValue valueWithPointer:shell]];
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
  [((ContentShellWindowDelegate*)shell_data.window.rootViewController)
      toolbarContentView]
      .hidden = enter_fullscreen;
}

bool ShellPlatformDelegate::IsFullscreenForTabOrPending(
    Shell* shell,
    const WebContents* web_contents) const {
  DCHECK(shell_data_map_.contains(shell));
  auto iter = shell_data_map_.find(shell);
  return iter->second.fullscreen;
}

}  // namespace content
