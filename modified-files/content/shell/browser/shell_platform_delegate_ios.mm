// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_platform_delegate.h"

#import <UIKit/UIKit.h>

#include <iterator>
#include <stdio.h>

extern "C" void BlinkBootLog(const char* stage);

#include "base/files/file.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
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
// Defined in shell.cc; true while an auth redirect chain is in flight so the
// UA/site-mode is not changed mid-auth.
bool BlinkShellIsInAuthFlow();
}  // namespace content

namespace {

const char kGraphicsTracingCategories[] =
    "-*,blink,cc,gpu,renderer.scheduler,sequence_manager,v8,toplevel,viz,evdev,"
    "input,benchmark";

const char kDetailedGraphicsTracingCategories[] =
    "-*,blink,cc,gpu,renderer.scheduler,sequence_manager,v8,toplevel,viz,evdev,"
    "input,benchmark,disabled-by-default-skia,disabled-by-default-skia.gpu,"
    "disabled-by-default-skia.gpu.cache,disabled-by-default-skia.shaders,"
    "disabled-by-default-gpu.dawn,disabled-by-default-gpu.graphite.dawn";

const char kNavigationTracingCategories[] =
    "-*,benchmark,toplevel,ipc,base,browser,navigation,omnibox,ui,shutdown,"
    "safe_browsing,loading,startup,mojom,renderer_host,"
    "disabled-by-default-system_stats,disabled-by-default-cpu_profiler,dwrite,"
    "fonts,ServiceWorker,passwords,disabled-by-default-file,sql,"
    "disabled-by-default-user_action_samples,disk_cache";

const char kAllTracingCategories[] = "*";

// Selectable search engines (long-press the URL bar). An empty query string
// means input is always treated as a URL.
struct SearchEngine {
  const char* name;
  const char* query;  // search prefix; the (escaped) term is appended.
};
const SearchEngine kSearchEngines[] = {
    {"Google", "https://www.google.com/search?q="},
    {"DuckDuckGo", "https://duckduckgo.com/?q="},
    {"Bing", "https://www.bing.com/search?q="},
    {"Yahoo", "https://search.yahoo.com/search?p="},
    {"None (treat input as URL)", ""},
};
int g_search_engine = 0;  // Default: Google.

// Accent color for menu/start-page text, matching the toolbar. The Tor proxy
// setting uses a distinct purple.
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

// Persist the URLs of every open tab so they survive app close/reopen.
// Called on each navigation and on tab open/close; restored at launch by
// ShellBrowserMainParts::InitializeMessageLoopContext. UIKit state
// restoration stays disabled.
void BlinkSaveOpenTabs() {
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (content::Shell* s : content::Shell::windows()) {
    if (!s->web_contents()) {
      continue;
    }
    GURL u = s->web_contents()->GetLastCommittedURL();
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

}  // namespace

// Window bridges for shell.cc, which cannot touch UIKit. Used by the Google
// sign-in popup flow.

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
  [win makeKeyAndVisible];
  BlinkBootLog("AUTH_POPUP_GUARD: shell window presented");
}

// Called right before a script-initiated close (window.close()). If the
// closing shell owns the key window, activate another shell's window first,
// preferring |preferred_opener|'s. Closing a background tab must not touch
// the visible window.
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

@interface ContentShellWindowDelegate : UIViewController <UITextFieldDelegate> {
 @private
  raw_ptr<content::Shell> _shell;
}
// Toolbar containing navigation buttons and |urlField|.
@property(nonatomic, strong) UIStackView* toolbarBackgroundView;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* topPosConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* bottomPosConstraints;
// The native start page, shown over a blank tab.
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

// Reusable modal list view for Tabs, Bookmarks and Downloads (tap to open,
// swipe to delete, + to add).
@interface BlinkListVC : UITableViewController
@property(nonatomic, strong) NSMutableArray<NSString*>* titles;
@property(nonatomic, strong) NSMutableArray<NSString*>* subtitles;
// Optional per-row title colors (parallel to titles; use NSNull for default).
@property(nonatomic, strong) NSArray* titleColors;
@property(nonatomic, assign) NSInteger protectedIndex;  // -1 = none
@property(nonatomic, assign) BOOL isTabList;  // YES = emit TAB_MANAGER_UI logs
@property(nonatomic, copy) void (^onSelect)(NSInteger);
@property(nonatomic, copy) void (^onDelete)(NSInteger);  // nil = no delete
@property(nonatomic, copy) void (^onAdd)(void);          // nil = no + button
@end

@implementation BlinkListVC
- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStylePlain])) {
    _protectedIndex = -1;
  }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(doneTapped)];
  if (self.onAdd) {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(addTapped)];
  }
  // Dark theme with the red accent of the app.
  UIColor* bg = [UIColor colorWithWhite:0.09 alpha:1.0];
  UIColor* red = [UIColor colorWithRed:224.0 / 255.0
                                 green:71.0 / 255.0
                                  blue:40.0 / 255.0
                                 alpha:1.0];
  self.tableView.backgroundColor = bg;
  self.tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
  self.tableView.rowHeight = 62;
  self.tableView.tableFooterView = [[UIView alloc] init];
  UINavigationBar* bar = self.navigationController.navigationBar;
  bar.tintColor = [UIColor whiteColor];
  UINavigationBarAppearance* ap = [[UINavigationBarAppearance alloc] init];
  [ap configureWithOpaqueBackground];
  ap.backgroundColor = red;
  ap.titleTextAttributes = @{NSForegroundColorAttributeName : UIColor.whiteColor};
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
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (add) {
                               add();
                             }
                           }];
}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {
  return self.titles.count;
}
- (UITableViewCell*)tableView:(UITableView*)t
    cellForRowAtIndexPath:(NSIndexPath*)ip {
  UITableViewCell* c = [t dequeueReusableCellWithIdentifier:@"c"];
  if (!c) {
    c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:@"c"];
  }
  c.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
  c.textLabel.text = self.titles[ip.row];
  c.textLabel.numberOfLines = 1;
  UIColor* titleColor = BlinkerAccentColor();
  if (ip.row < (NSInteger)self.titleColors.count &&
      [self.titleColors[ip.row] isKindOfClass:[UIColor class]]) {
    titleColor = self.titleColors[ip.row];
  }
  c.textLabel.textColor = titleColor;
  c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
  c.detailTextLabel.text =
      (ip.row < (NSInteger)self.subtitles.count) ? self.subtitles[ip.row] : @"";
  c.detailTextLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
  c.detailTextLabel.numberOfLines = 1;
  UIView* sel = [[UIView alloc] init];
  sel.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
  c.selectedBackgroundView = sel;
  return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
  [t deselectRowAtIndexPath:ip animated:NO];
  if (self.isTabList) {
    char buf[96];
    snprintf(buf, sizeof(buf), "TAB_MANAGER_UI: existing tab tapped id=%ld",
             (long)ip.row);
    BlinkBootLog(buf);
    snprintf(buf, sizeof(buf), "TAB_MANAGER_UI: requested switch to tab id=%ld",
             (long)ip.row);
    BlinkBootLog(buf);
  }
  void (^sel)(NSInteger) = self.onSelect;
  NSInteger row = ip.row;
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             if (sel) {
                               sel(row);
                             }
                           }];
}
- (BOOL)tableView:(UITableView*)t canEditRowAtIndexPath:(NSIndexPath*)ip {
  return self.onDelete != nil && ip.row != self.protectedIndex;
}
- (void)tableView:(UITableView*)t
    commitEditingStyle:(UITableViewCellEditingStyle)style
     forRowAtIndexPath:(NSIndexPath*)ip {
  if (style != UITableViewCellEditingStyleDelete || !self.onDelete) {
    return;
  }
  NSInteger row = ip.row;
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
  [t deleteRowsAtIndexPaths:@[ ip ]
           withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

// The native start page: a UIKit view (logo, search box, quick links) shown
// over a blank tab, so it never appears as a URL in the bar.
@interface BlinkerStartPageView : UIView <UITextFieldDelegate>
@property(nonatomic, copy) void (^onNavigate)(NSString*);
@end

@implementation BlinkerStartPageView {
  UITextField* _search;
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

    UILabel* name = [[UILabel alloc] init];
    name.text = @"Blinker Fluid";
    name.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBold];
    name.textColor = BlinkerAccentColor();

    _search = [[UITextField alloc] init];
    _search.placeholder = @"Search the web";
    _search.backgroundColor =
        [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0];
    _search.textColor = [UIColor whiteColor];
    _search.font = [UIFont systemFontOfSize:17];
    _search.layer.cornerRadius = 12;
    _search.layer.borderWidth = 1;
    _search.layer.borderColor = [UIColor colorWithWhite:0.21 alpha:1.0].CGColor;
    _search.delegate = self;
    _search.returnKeyType = UIReturnKeyGo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.keyboardType = UIKeyboardTypeWebSearch;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    _search.leftViewMode = UITextFieldViewModeAlways;
    [_search.heightAnchor constraintEqualToConstant:52].active = YES;

    UIStackView* row1 = [self rowWithLinks:@[
      @[ @"GitHub", @"https://github.com" ],
      @[ @"Reddit", @"https://www.reddit.com" ],
      @[ @"YouTube", @"https://www.youtube.com" ],
    ]];
    UIStackView* row2 = [self rowWithLinks:@[
      @[ @"Gmail", @"https://mail.google.com" ],
      @[ @"Proton Mail", @"https://mail.proton.me" ],
    ]];

    UIStackView* column = [[UIStackView alloc]
        initWithArrangedSubviews:@[ logo, name, _search, row1, row2 ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentCenter;
    column.spacing = 16;
    [column setCustomSpacing:26 afterView:name];
    [column setCustomSpacing:30 afterView:_search];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];

    NSLayoutConstraint* width =
        [column.widthAnchor constraintEqualToConstant:540];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
      [column.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [column.topAnchor
          constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                         constant:64],
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

- (UIStackView*)rowWithLinks:(NSArray*)links {
  NSMutableArray* buttons = [NSMutableArray array];
  for (NSArray* link in links) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:link[0] forState:UIControlStateNormal];
    [button setTitleColor:BlinkerAccentColor() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    button.backgroundColor =
        [UIColor colorWithRed:0.11 green:0.11 blue:0.125 alpha:1.0];
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:0.18 alpha:1.0].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
    button.accessibilityIdentifier = link[1];  // stores the link URL
    [button addTarget:self
                  action:@selector(linkTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [buttons addObject:button];
  }
  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 10;
  return row;
}

- (void)linkTapped:(UIButton*)button {
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
  // Warm red-orange to match the app icon.
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
//
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

    self.view.accessibilityElements = @[ _toolbarBackgroundView, _contentView ];
    self.view.isAccessibilityElement = NO;

    // Constrain the toolbar background view. Vertical position is set by
    // -applyToolbarPosition so it can be toggled in Settings.
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

  // Constrain the web content view. Horizontal only; vertical is managed by
  // -applyToolbarPosition together with the toolbar.
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
  [button addTarget:self
                action:action
      forControlEvents:UIControlEventTouchUpInside |
                       UIControlEventPrimaryActionTriggered];
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
  // NavigationController::Reload() crashes on many sites here, but a normal
  // navigation works, so implement reload as a fresh load of the current URL.
  // Always reload; branching on IsLoading made the button a no-op on pages
  // that report as perpetually loading.
  GURL url = _shell->web_contents()->GetLastCommittedURL();
  if (!url.is_valid()) {
    url = _shell->web_contents()->GetVisibleURL();
  }
  if (url.is_valid()) {
    _shell->LoadURL(url);
  }
}

// Tab management. Each tab is a content::Shell owning its own UIWindow;
// switching tabs makes the chosen shell's window key+visible in the scene.
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
  char buf[160];
  snprintf(buf, sizeof(buf), "TAB_MANAGER: %s id=%d tab_count=%zu", action,
           [self tabIdForShell:shell], content::Shell::windows().size());
  BlinkBootLog(buf);
}

- (void)showTabWindow:(content::Shell*)shell {
  if (!shell) {
    return;
  }
  [self logTab:"switched to tab" shell:shell];
  UIWindow* win = shell->window().Get();
  if (win) {
    win.windowScene = self.view.window.windowScene;
    [win makeKeyAndVisible];
  }
  // Switching must not change the tab count or create a WebContents.
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
  // True incognito needs a separate BrowserContext, but single-process mode
  // CHECKs exactly one browser context per process, so all tabs share the
  // normal context.
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

// Navigate the current tab to the built-in start page.
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
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.isTabList = YES;
  vc.title = @"Tabs";
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSValue*>* shells = [NSMutableArray array];
  NSInteger idx = 0;
  for (content::Shell* s : content::Shell::windows()) {
    std::u16string t = s->web_contents()->GetTitle();
    NSString* title = t.empty() ? @"New Tab" : base::SysUTF16ToNSString(t);
    [vc.titles addObject:title];
    [vc.subtitles
        addObject:base::SysUTF8ToNSString(
                      s->web_contents()->GetVisibleURL().possibly_invalid_spec())];
    [shells addObject:[NSValue valueWithPointer:s]];
    if (s == _shell) {
      vc.protectedIndex = idx;  // can't close the tab the switcher opened from
    }
    idx++;
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    content::Shell* sel = (content::Shell*)[shells[i] pointerValue];
    const size_t before = content::Shell::windows().size();
    char b[160];
    snprintf(b, sizeof(b), "TAB_MANAGER: selected existing tab id=%d",
             [weakSelf tabIdForShell:sel]);
    BlinkBootLog(b);
    // Selecting an existing tab only switches; it must never create a tab.
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
  vc.onDelete = ^(NSInteger i) {
    content::Shell* s = (content::Shell*)[shells[i] pointerValue];
    const size_t before = content::Shell::windows().size();
    [weakSelf logTab:"close tab requested" shell:s];
    [shells removeObjectAtIndex:i];
    s->Close();
    BlinkBootLog(content::Shell::windows().size() == before - 1
                     ? "TAB_MANAGER: invariant ok"
                     : "TAB_MANAGER: invariant failed reason=close did not "
                       "remove exactly one");
    BlinkSaveOpenTabs();
  };
  [self presentList:vc];
}

// Bookmarks (stored in NSUserDefaults).
- (NSMutableArray*)bookmarks {
  NSArray* saved =
      [[NSUserDefaults standardUserDefaults] arrayForKey:@"BlinkBookmarks"];
  return saved ? [saved mutableCopy] : [NSMutableArray array];
}

- (void)addBookmark {
  GURL url = _shell->web_contents()->GetVisibleURL();
  if (!url.is_valid()) {
    return;
  }
  std::u16string t = _shell->web_contents()->GetTitle();
  NSString* title =
      t.empty() ? base::SysUTF8ToNSString(url.spec()) : base::SysUTF16ToNSString(t);
  NSMutableArray* bms = [self bookmarks];
  [bms addObject:@{
    @"title" : title,
    @"url" : base::SysUTF8ToNSString(url.spec())
  }];
  [[NSUserDefaults standardUserDefaults] setObject:bms forKey:@"BlinkBookmarks"];
  UIAlertController* a =
      [UIAlertController alertControllerWithTitle:@"Bookmarked"
                                          message:title
                                   preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                        style:UIAlertActionStyleDefault
                                      handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)showBookmarks {
  NSMutableArray* bms = [self bookmarks];
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Bookmarks";
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (NSDictionary* b in bms) {
    NSString* u = b[@"url"] ?: @"";
    [vc.titles addObject:(b[@"title"] ?: u)];
    [vc.subtitles addObject:u];
    [urls addObject:u];
  }
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    [weakSelf loadURLString:urls[i]];
  };
  vc.onDelete = ^(NSInteger i) {
    NSMutableArray* cur = [weakSelf bookmarks];
    if (i < (NSInteger)cur.count) {
      [cur removeObjectAtIndex:i];
      [[NSUserDefaults standardUserDefaults] setObject:cur
                                                forKey:@"BlinkBookmarks"];
    }
  };
  [self presentList:vc];
}

// Downloads; content_shell saves to <data>/MyFiles/Downloads.
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
  for (NSString* f in files) {
    NSString* full = [dir stringByAppendingPathComponent:f];
    NSDictionary* attrs = [fm attributesOfItemAtPath:full error:nil];
    [vc.titles addObject:f];
    [vc.subtitles
        addObject:[NSByteCountFormatter
                      stringFromByteCount:(long long)[attrs fileSize]
                               countStyle:NSByteCountFormatterCountStyleFile]];
    [paths addObject:full];
  }
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
      [_contentView.bottomAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ];
    _bottomPosConstraints = nil;
    [NSLayoutConstraint activateConstraints:_topPosConstraints];
    return;
  }
  BOOL bottom =
      [[NSUserDefaults standardUserDefaults] boolForKey:@"BlinkToolbarBottom"];
  _topPosConstraints = @[
    [_toolbarBackgroundView.topAnchor
        constraintEqualToAnchor:self.view.topAnchor],
    [_contentView.topAnchor
        constraintEqualToAnchor:_toolbarBackgroundView.bottomAnchor],
    [_contentView.bottomAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
  ];
  _bottomPosConstraints = @[
    [_toolbarBackgroundView.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor],
    [_contentView.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_contentView.bottomAnchor
        constraintEqualToAnchor:_toolbarBackgroundView.topAnchor],
  ];
  [NSLayoutConstraint activateConstraints:bottom ? _bottomPosConstraints
                                                 : _topPosConstraints];
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

- (void)showMainMenu {
  UIAlertController* alertController = [self actionSheetWithTitle:@"Main menu"
                                                          message:nil];

  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                         style:UIAlertActionStyleCancel
                                       handler:nil]];

  __weak ContentShellWindowDelegate* weakSelf = self;

  // Tabs. True incognito needs a second browser context, which
  // single-process mode forbids (see openNewTab), so there is no incognito
  // item.
  [alertController
      addAction:[UIAlertAction actionWithTitle:@"New Tab"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf openNewTab];
                                       }]];
  [alertController
      addAction:[UIAlertAction
                    actionWithTitle:[NSString stringWithFormat:@"Tabs (%zu)",
                                                              content::Shell::
                                                                  windows()
                                                                      .size()]
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction* action) {
                              [weakSelf showTabSwitcher];
                            }]];

  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Home (Blinker Fluid)"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf goHome];
                                       }]];

  if ([UIPasteboard generalPasteboard].hasStrings) {
    [alertController
        addAction:[UIAlertAction actionWithTitle:@"Paste & Go"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction* action) {
                                           [weakSelf pasteAndGo];
                                         }]];
  }

  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Reload"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf reloadOrStop];
                                       }]];

  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Add Bookmark"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf addBookmark];
                                       }]];
  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Bookmarks"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf showBookmarks];
                                       }]];
  [alertController
      addAction:[UIAlertAction actionWithTitle:@"Downloads"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction* action) {
                                         [weakSelf showDownloads];
                                       }]];
  if (content::Shell::windows().size() > 1) {
    [alertController
        addAction:[UIAlertAction actionWithTitle:@"Close This Tab"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction* action) {
                                           [weakSelf closeCurrentTab];
                                         }]];
  }

  GURL visibleURL = _shell->web_contents()->GetVisibleURL();
  if (visibleURL.is_valid() && !visibleURL.SchemeIs("data")) {
    NSString* urlStr = base::SysUTF8ToNSString(visibleURL.spec());
    [alertController
        addAction:[UIAlertAction
                      actionWithTitle:@"Share / Copy Link"
                                style:UIAlertActionStyleDefault
                              handler:^(UIAlertAction* action) {
                                NSURL* nsurl = [NSURL URLWithString:urlStr];
                                UIActivityViewController* share =
                                    [[UIActivityViewController alloc]
                                        initWithActivityItems:@[ nsurl
                                                                     ?: urlStr ]
                                        applicationActivities:nil];
                                share.popoverPresentationController.sourceView =
                                    weakSelf.menuButton;
                                // iPad: anchor the share popover to the whole
                                // menu button (a zero sourceRect points the
                                // arrow at its corner).
                                share.popoverPresentationController.sourceRect =
                                    weakSelf.menuButton.bounds;
                                [weakSelf presentViewController:share
                                                       animated:YES
                                                     completion:nil];
                              }]];
  }

  [alertController addAction:[UIAlertAction
                                actionWithTitle:@"Settings"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          [weakSelf showSettings];
                                        }]];

  [self tintMenu:alertController color:BlinkerAccentColor()];
  [self presentViewController:alertController animated:YES completion:nil];
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
  // A blank tab shows the native start page and an empty URL bar; a real
  // page hides it and shows its URL.
  BOOL isStartPage =
      (url.length == 0) || [url isEqualToString:@"about:blank"];
  [self showStartPage:isStartPage];
  _urlField.text = isStartPage ? @"" : url;
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

// Paste a URL or search text from another app and open it, without touching
// the web text-input pipeline.
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
    NSString* title = [NSString
        stringWithFormat:@"%s%s", (g_search_engine == (int)i) ? "✓ " : "",
                         kSearchEngines[i].name];
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
  [self presentViewController:sheet animated:YES completion:nil];
}

// Settings menu (search engine, appearance, desktop/mobile site).
- (void)showSettings {
  BlinkListVC* vc = [[BlinkListVC alloc] init];
  vc.title = @"Settings";
  vc.titles = [NSMutableArray array];
  vc.subtitles = [NSMutableArray array];
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  bool isDesktop = _shell && _shell->web_contents() &&
                   !_shell->web_contents()
                        ->GetUserAgentOverride()
                        .ua_string_override.empty();
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
  [vc.titles addObject:isDesktop ? @"Request Mobile Site"
                                 : @"Request Desktop Site"];
  [vc.subtitles addObject:isDesktop ? @"Desktop" : @"Mobile"];
  [vc.titles addObject:@"Toolbar Position"];
  [vc.subtitles addObject:bottom ? @"Bottom" : @"Top"];
  NSString* proxy = [d stringForKey:@"BlinkProxy"];
  [vc.titles addObject:@"Tor / Proxy"];
  [vc.subtitles addObject:(proxy.length ? proxy : @"Tap to set a SOCKS5 proxy")];
  NSString* homepage = [d stringForKey:@"BlinkHomepage"];
  [vc.titles addObject:@"Homepage"];
  [vc.subtitles addObject:(homepage.length ? homepage : @"Start page (default)")];
  // Tor / Proxy (index 4) is purple; everything else uses the default accent.
  vc.titleColors = @[
    [NSNull null], [NSNull null], [NSNull null], [NSNull null],
    BlinkerTorColor(), [NSNull null]
  ];
  __weak ContentShellWindowDelegate* weakSelf = self;
  vc.onSelect = ^(NSInteger i) {
    if (i == 0) {
      [weakSelf presentSearchEngineMenu];
    } else if (i == 1) {
      [weakSelf showAppearanceMenu];
    } else if (i == 2) {
      [weakSelf toggleDesktopSite];
      [weakSelf showSettings];
    } else if (i == 3) {
      [weakSelf toggleToolbarPosition];
      [weakSelf showSettings];
    } else if (i == 4) {
      [weakSelf showProxySettings];
    } else if (i == 5) {
      [weakSelf showHomepageSettings];
    }
  };
  [self presentList:vc];
}

// Tor / proxy: a SOCKS5 (or HTTP) proxy, saved to NSUserDefaults and applied
// as --proxy-server on next launch. SOCKS5 resolves hostnames remotely, so
// .onion works through a Tor daemon.
- (void)showProxySettings {
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:@"Tor / Proxy"
                       message:@"Route all traffic through a SOCKS5/HTTP proxy "
                               @"(e.g. a local Tor daemon). For .onion use a "
                               @"socks5:// proxy. Restart the app to apply. "
                               @"Leave blank to turn off."
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField* tf) {
    tf.placeholder = @"socks5://127.0.0.1:9050";
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
                             if (v.length) {
                               [d setObject:v forKey:@"BlinkProxy"];
                             } else {
                               [d removeObjectForKey:@"BlinkProxy"];
                             }
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
                             [weakSelf presentViewController:r
                                                    animated:YES
                                                  completion:nil];
                           }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                        style:UIAlertActionStyleCancel
                                      handler:nil]];
  [self tintMenu:a color:BlinkerTorColor()];
  [self presentViewController:a animated:YES completion:nil];
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
  [self presentViewController:sheet animated:YES completion:nil];
}

// Force the web content's prefers-color-scheme (so sites render their own
// native dark/light theme), by overriding the NativeTheme used for web prefs.
- (void)applyWebColorScheme:(UIUserInterfaceStyle)style {
  // OverrideWebPreferences reads this global to set the web content's
  // prefers-color-scheme (UIUserInterfaceStyle: 1=Light, 2=Dark,
  // 0=System->light); content_shell otherwise hardcodes light.
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
  // Reload the current tab so the new scheme is re-evaluated immediately.
  if (_shell && _shell->web_contents()) {
    GURL u = _shell->web_contents()->GetLastCommittedURL();
    if (u.is_valid()) {
      _shell->LoadURL(u);
    }
  }
}

- (void)toggleDesktopSite {
  if (!_shell || !_shell->web_contents()) {
    return;
  }
  if (content::BlinkShellIsInAuthFlow()) {
    // Don't flip UA/device-metrics during an auth redirect chain; that
    // breaks login flows.
    BlinkBootLog("AUTH_FLOW: site mode locked during auth");
    BlinkBootLog("AUTH_FLOW: user agent stable during auth");
    return;
  }
  BlinkBootLog("SITE_MODE: button toggled");
  bool isDesktop = !_shell->web_contents()
                        ->GetUserAgentOverride()
                        .ua_string_override.empty();
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

  // Desktop mode via renderer prefs / device metrics. OverrideWebPreferences
  // reads this flag to set a wide (~980 CSS px) desktop layout viewport;
  // mobile restores device-width. Site data is left intact.
  content::g_force_desktop_site = setDesktop ? 1 : 0;
  _shell->web_contents()->NotifyPreferencesChanged();
  BlinkBootLog("SITE_MODE: renderer prefs updated");
  BlinkBootLog(setDesktop ? "SITE_MODE: desktop device metrics width=980"
                          : "SITE_MODE: mobile device metrics restored");
  GURL current = _shell->web_contents()->GetLastCommittedURL();
  if (!current.is_valid()) {
    current = _shell->web_contents()->GetVisibleURL();
  }
  if (current.is_valid() && current.has_scheme()) {
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

// Colors an alert/action-sheet's option text; tintColor alone doesn't always
// stick. Destructive actions keep their red.
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

  // Persist the tab set on every address change so reopening the app
  // restores the open tabs.
  BlinkSaveOpenTabs();
}

void ShellPlatformDelegate::SetIsLoading(Shell* shell, bool loading) {}

void ShellPlatformDelegate::SetTitle(Shell* shell,
                                     const std::u16string& title) {
  DCHECK(shell_data_map_.contains(shell));
}

void ShellPlatformDelegate::MainFrameCreated(Shell* shell,
                                             RenderFrameHost* main_frame) {}

bool ShellPlatformDelegate::DestroyShell(Shell* shell) {
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
