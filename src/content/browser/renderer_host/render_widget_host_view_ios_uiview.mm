// Copyright 2024 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/browser/renderer_host/render_widget_host_view_ios_uiview.h"

#include <math.h>
#include <stdio.h>

#include "base/apple/foundation_util.h"
#include "base/strings/sys_string_conversions.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/input/web_input_event_builders_ios.h"
#include "components/strings/grit/components_strings.h"
#include "content/browser/renderer_host/ios_extended_text_input_traits.h"
#include "ui/accessibility/platform/browser_accessibility_manager.h"
#include "ui/base/ime/text_input_flags.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/events/base_event_utils.h"
#include "ui/events/keycodes/keyboard_codes.h"

// Defined in shell.cc; chat-site fallback bottom ratio for keyboard relocation
// When Blink caret metrics are unavailable. 0 = no fallback.
extern "C" float BlinkKeyboardChatFallbackRatio();
// Defined in shell.cc; the current top-level host and whether it is a chat
// relocation site (chatgpt/claude/gemini). Used to log and gate the fallback
// (.3) — the keyboard code path has no URL of its own.
extern "C" int BlinkIsChatKeyboardRelocationSite();
extern "C" void BlinkSetKeyboardViewportInset(float inset);

static void* kObservingContext = &kObservingContext;
static CGFloat g_keyboard_bottom_inset = 0;
static CGFloat g_pending_keyboard_height = 0;
static CGFloat g_last_keyboard_height = 0;
static NSTimeInterval g_last_keyboard_notification_time = 0;
static CGRect g_last_focused_editable_rect = CGRectZero;
static BOOL g_has_plausible_focused_rect = NO;
// User-dismiss cooldown + focus session, to stop the becomeFirstResponder
// pop-back loop. The renderer re-asserts editable focus on every
// text-input-state renderer-driven refocus for a short window so the keyboard
// stays down.
static BOOL g_keyboard_user_dismissed = NO;
static NSTimeInterval g_keyboard_dismiss_time = 0;
static const NSTimeInterval kKeyboardDismissCooldown = 0.35;
// A real software keyboard is taller than the accessory bar. If only the
// accessory bar appears we treat it as failure and run a one-shot recovery.
static const CGFloat kRealKeyboardMinHeight = 150;
static BOOL g_keyboard_recovery_used = NO;
static BOOL g_keyboard_body_retry_in_progress = NO;
static BOOL g_hardware_keyboard_seen = NO;
// Some iOS 15 input sessions initially present only the accessory strip. Retry
// once; notification ownership prevents inactive tabs from joining the retry.
static BOOL g_enable_keyboard_recovery = YES;
static BOOL g_touch_sequence_active = NO;
static BOOL g_touch_sequence_moved = NO;
static CGPoint g_touch_sequence_origin = CGPointZero;
static NSTimeInterval g_last_scroll_touch_end = 0;

// Keyboard relocation state machine. Stops the post-typing regression
// where committed text re-presents the keyboard, iOS emits a bogus height=0
// did-show, and relocation snaps the page back under the keyboard.
typedef NS_ENUM(int, BlinkKeyboardState) {
  BlinkKeyboardHidden = 0,
  BlinkKeyboardPresenting,
  BlinkKeyboardVisible,
  BlinkKeyboardDismissing,
};
static BlinkKeyboardState g_keyboard_state = BlinkKeyboardHidden;
static CGFloat g_current_relocation_offset = 0;
// Keyboard notifications are process-wide and every renderer view observes
// them. Keep the view that actually presented the keyboard so a stale renderer
// cannot tear down the active view's relocation on a transient hide burst.
static __weak RenderWidgetUIView* g_keyboard_owner = nil;
// Cached focused-element bottom ratio for the active focus session.
static float g_cached_bottom_ratio = -1.0f;
// DOM element bounds outrank caret bounds because a multiline input can extend
// below its active caret line.
typedef NS_ENUM(int, BlinkRatioSource) {
  BlinkRatioNone = 0,
  BlinkRatioFallback,
  BlinkRatioCaret,
  BlinkRatioDom,
};
static BlinkRatioSource g_cached_ratio_source = BlinkRatioNone;
static int g_focus_session_id = 0;
// DOM metrics queries are rate-limited and tied to the current focus session.
static BOOL g_dom_ratio_query_in_flight = NO;
static NSTimeInterval g_last_dom_query_time = 0;
// Relocation strategy at runtime. 0 = compositor transform (default,
// known-good). 1 = container/constraint shift (translate the wrapper scroll
// view, leaving the compositor layer's own transform identity). Math always
// uses the untransformed self.bounds, so switching strategy is side-effect
// free.
static int g_keyboard_relocate_strategy = 2;

namespace {
NSString* const kPreviousAccessoryImageName = @"chevron.up";
NSString* const kNextAccessoryImageName = @"chevron.down";
NSString* const kDoneAccessoryImageName = @"checkmark";
}  // namespace

#pragma mark - BETextPosition
@interface BETextPosition : UITextPosition {
  CGRect rect_;
}
- (instancetype)initWithRect:(CGRect)rect;
- (CGRect)rect;

@end

@implementation BETextPosition
- (instancetype)initWithRect:(CGRect)rect {
  rect_ = rect;
  return [self init];
}
- (CGRect)rect {
  return rect_;
}
@end

#pragma mark - BETextRange
@interface BETextRange : UITextRange {
  CGRect start_;
  CGRect end_;
}
- (instancetype)initWithRegion:
    (const content::TextInputManager::SelectionRegion*)region;
- (instancetype)initWithStart:(BETextPosition*)start end:(BETextPosition*)end;
@end

@implementation BETextRange

- (instancetype)initWithRegion:
    (const content::TextInputManager::SelectionRegion*)region {
  start_ = CGRectMake(region->anchor.edge_start_rounded().x(),
                      region->anchor.edge_start_rounded().y(), 1,
                      region->anchor.GetHeight());

  end_ = CGRectMake(region->focus.edge_start_rounded().x(),
                    region->focus.edge_start_rounded().y(), 1,
                    region->focus.GetHeight());
  return [self init];
}

- (instancetype)initWithStart:(BETextPosition*)start end:(BETextPosition*)end {
  start_ = [start rect];
  end_ = [end rect];
  return [self init];
}

- (BOOL)isEmpty {
  return CGRectEqualToRect(start_, end_);
}

- (UITextPosition*)start {
  return [[BETextPosition alloc] initWithRect:start_];
}
- (UITextPosition*)end {
  return [[BETextPosition alloc] initWithRect:end_];
}
@end

#pragma mark - BETextSelectionHandles
@interface BETextSelectionHandles : UITextSelectionRect
- (instancetype)initWithCGRect:(CGRect)rect atStart:(BOOL)start;
@end
@implementation BETextSelectionHandles {
  CGRect rect_;
  BOOL start_;
}
- (instancetype)initWithCGRect:(CGRect)rect atStart:(BOOL)start {
  rect_ = rect;
  start_ = start;
  return [self init];
}
- (NSWritingDirection)writingDirection {
  return NSWritingDirectionLeftToRight;
}
- (CGRect)rect {
  return rect_;
}
- (BOOL)containsStart {
  return start_;
}
- (BOOL)containsEnd {
  return !start_;
}
@end

#pragma mark - BETextSelectionRect
@interface BETextSelectionRect : UITextSelectionRect {
  CGRect rect_;
}
- (instancetype)initWithCGRect:(CGRect)rect;
@end

@implementation BETextSelectionRect
- (instancetype)initWithCGRect:(CGRect)rect {
  rect_ = rect;
  return [self init];
}
- (CGRect)rect {
  return rect_;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
// BrowserEngineKit protocol methods are invoked only on supported systems.
// Construction of BETextInteraction remains explicitly guarded above.
@implementation RenderWidgetUIView
@synthesize tokenizer;

- (instancetype)initWithWidget:
    (base::WeakPtr<content::RenderWidgetHostViewIOS>)view {
  self = [self init];
  if (self) {
    _view = view;
    _extendedTextInputTraits = [[IOSExtendedTextInputTraits alloc] init];
    if (@available(iOS 17.4, *)) {
      text_interaction_ = [[BETextInteraction alloc] init];
      if (text_interaction_) {
        [self addInteraction:text_interaction_];
      }
    }
    self.multipleTouchEnabled = YES;
    self.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self initializeInputAccessoryToolbar];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(keyboardWillShow:)
               name:UIKeyboardWillShowNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(keyboardDidShow:)
               name:UIKeyboardDidShowNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(keyboardWillHide:)
               name:UIKeyboardWillHideNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(keyboardDidHide:)
               name:UIKeyboardDidHideNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(keyboardWillChangeFrame:)
               name:UIKeyboardWillChangeFrameNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (g_keyboard_owner == self) {
    g_keyboard_owner = nil;
    g_keyboard_state = BlinkKeyboardHidden;
    g_last_keyboard_height = 0;
    g_pending_keyboard_height = 0;
    BlinkSetKeyboardViewportInset(0);
  }
}

- (CGFloat)keyboardHeightFromNotification:(NSNotification*)notification {
  NSValue* frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
  if (!frameValue || !self.window) {
    return 0;
  }
  CGRect keyboardFrameInWindow =
      [self.window convertRect:[frameValue CGRectValue] fromWindow:nil];
  CGRect overlap =
      CGRectIntersection(self.window.bounds, keyboardFrameInWindow);
  return CGRectIsNull(overlap) ? 0 : overlap.size.height;
}

- (BOOL)isAccessoryBarOnlyHeight:(CGFloat)height {
  return height >= 40 && height <= 80;
}

- (BOOL)isPlausibleFocusedRect:(CGRect)rect
                  inScrollView:(UIScrollView*)scrollView {
  if (CGRectIsEmpty(rect) || rect.size.height <= 0 || rect.size.width <= 0) {
    return NO;
  }
  const CGFloat viewportWidth = scrollView.bounds.size.width;
  const CGFloat viewportHeight = scrollView.bounds.size.height;
  if (rect.size.width >= viewportWidth * 0.90 &&
      rect.size.height >= viewportHeight * 0.70) {
    return NO;
  }
  return rect.size.height < 250;
}

- (void)rememberFocusedRectIfPlausible:(CGRect)bounds {
  UIScrollView* scrollView = (UIScrollView*)[self superview];
  if (![scrollView isKindOfClass:[UIScrollView class]]) {
    return;
  }
  CGRect focusedRect = [self convertRect:bounds toView:scrollView];

  if (![self isPlausibleFocusedRect:focusedRect inScrollView:scrollView]) {
    g_has_plausible_focused_rect = NO;
    g_last_focused_editable_rect = CGRectZero;
    // Bogus full-viewport rect (e.g. 390x715): apply bottom inset only, never
    // Force-scroll or jump the page. JS scrollIntoView stays disabled.

    return;
  }
  g_has_plausible_focused_rect = YES;
  g_last_focused_editable_rect = bounds;
}

- (void)applyKeyboardBottomInset:(CGFloat)bottomInset {
  g_keyboard_bottom_inset = bottomInset;
  UIScrollView* scrollView = (UIScrollView*)[self superview];
  if (![scrollView isKindOfClass:[UIScrollView class]]) {
    return;
  }
  UIEdgeInsets inset = scrollView.contentInset;
  inset.bottom = bottomInset;
  scrollView.contentInset = inset;
  scrollView.scrollIndicatorInsets = inset;
}

- (void)scrollFocusedEditableAboveKeyboardIfNeeded {
  if (g_keyboard_bottom_inset <= 0) {
    return;  // keyboard not visible; nothing to do.
  }
  // With no plausible focused rect we apply the bottom inset only and
  // never force-scroll/jump the page (and never call JS).
  if (!g_has_plausible_focused_rect ||
      CGRectIsEmpty(g_last_focused_editable_rect)) {
    return;
  }
  UIScrollView* scrollView = (UIScrollView*)[self superview];
  if (![scrollView isKindOfClass:[UIScrollView class]]) {
    return;
  }
  CGRect focusedRect = [self convertRect:g_last_focused_editable_rect
                                  toView:scrollView];
  if (![self isPlausibleFocusedRect:focusedRect inScrollView:scrollView]) {
    return;
  }
  CGFloat visibleHeight =
      scrollView.bounds.size.height - g_keyboard_bottom_inset;
  CGFloat focusedBottom = CGRectGetMaxY(focusedRect);
  CGFloat delta = focusedBottom - visibleHeight + 18;
  if (delta <= 0) {
    return;
  }

  if (delta > 180) {
    delta = 180;
  }
  CGPoint offset = scrollView.contentOffset;
  offset.y += delta;
  [scrollView setContentOffset:offset animated:YES];
}

// Fire the async isolated-world DOM query for
// the focused input's bottom ratio. The result re-runs relocation with a real
// ratio, replacing the coarse chat-site fallback — and covering non-chat sites
// that previously got no relocation at all.
- (void)queryDomFocusedInputRatio {
  if (!_view) {
    return;
  }
  if (g_dom_ratio_query_in_flight) {
    return;
  }
  // Rate-limit refreshes once a DOM measurement exists; the first measurement
  // of a focus session always goes through.
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (g_cached_ratio_source == BlinkRatioDom &&
      now - g_last_dom_query_time < 0.35) {
    return;
  }
  g_last_dom_query_time = now;
  g_dom_ratio_query_in_flight = YES;
  const int sessionAtRequest = g_focus_session_id;
  __weak RenderWidgetUIView* weakSelf = self;
  _view->RequestFocusedInputBottomRatioFromDOM(base::BindOnce(^(float ratio) {
    g_dom_ratio_query_in_flight = NO;
    RenderWidgetUIView* strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    [strongSelf onDomFocusedInputRatio:ratio forSession:sessionAtRequest];
  }));
}

- (void)onDomFocusedInputRatio:(float)ratio forSession:(int)session {
  if (session != g_focus_session_id) {
    return;
  }
  if (g_keyboard_state != BlinkKeyboardPresenting &&
      g_keyboard_state != BlinkKeyboardVisible) {
    return;
  }
  if (ratio <= 0.0f || ratio > 2.0f) {
    // No focused editable in the DOM either — keep whatever fallback offset is
    // already applied (never zero-reset a live keyboard).

    return;
  }
  // The DOM prompt-box measurement is authoritative (.2): it wins over
  // the chat-site fallback AND the caret, for the rest of the focus session.
  g_cached_bottom_ratio = ratio;
  g_cached_ratio_source = BlinkRatioDom;

  if (g_last_keyboard_height > kRealKeyboardMinHeight &&
      g_keyboard_state == BlinkKeyboardVisible) {
    [self relocateFocusedInputAboveKeyboard:g_last_keyboard_height];
  }
}

// Uses the site fallback only when neither DOM nor caret metrics arrive.
- (void)applyDeferredChatFallback {
  if (g_keyboard_state != BlinkKeyboardVisible &&
      g_keyboard_state != BlinkKeyboardPresenting) {
    return;
  }
  if (g_cached_ratio_source >= BlinkRatioCaret) {
    // Real metrics arrived during the grace period and already relocated.
    return;
  }
  const float fallback = BlinkKeyboardChatFallbackRatio();
  if (fallback <= 0.0f) {
    return;
  }
  g_cached_bottom_ratio = fallback;
  g_cached_ratio_source = BlinkRatioFallback;

  if (g_last_keyboard_height > kRealKeyboardMinHeight) {
    [self relocateFocusedInputAboveKeyboard:g_last_keyboard_height];
  }
}

// Native relocation: shift the whole web content view up so the
// focused input clears the keyboard, using Blink's caret bottom-ratio (no JS,
// no DOM scroll, no trust in the bogus UIKit focused rect).
- (void)relocateFocusedInputAboveKeyboard:(CGFloat)keyboardHeight {
  const CGFloat contentHeight = self.bounds.size.height;
  if (contentHeight <= 1) {
    return;
  }
  const CGFloat keyboardOverlap = keyboardHeight;
  // Precedence (.2): DOM prompt-box ratio > live caret ratio > cached
  // ratio for this focus session > (deferred) chat-site fallback. Once a real
  // ratio is known we never drop back to the fallback, and the caret never
  // downgrades a DOM-derived lift (it only measures its own line).
  BOOL usingFallback = NO;
  float ratio = -1.0f;
  const float caretRatio = _view ? _view->GetFocusedInputBottomRatio() : -1.0f;
  if (g_cached_ratio_source == BlinkRatioDom) {
    // The DOM prompt-box ratio outranks the caret — the caret only
    // proves where its own LINE is; the box (send/button row) extends below
    // it, and letting the caret win snapped the lifted prompt back under the
    // keyboard on the first keystroke. A caret ABOVE the box bottom never
    // downgrades the lift. A caret BELOW it means the DOM measurement is
    // stale (box grew downward): lift by the caret now and re-measure.
    ratio = g_cached_bottom_ratio;
    if (caretRatio > ratio + 0.02f) {
      ratio = caretRatio;

      [self queryDomFocusedInputRatio];
    }

  } else if (caretRatio >= 0.0f) {
    ratio = caretRatio;
    g_cached_bottom_ratio = caretRatio;
    g_cached_ratio_source = BlinkRatioCaret;

    // The caret is a lower bound; ask the DOM for the whole
    // prompt-box bottom, which re-runs relocation and takes precedence.
    [self queryDomFocusedInputRatio];
  } else if (g_cached_ratio_source != BlinkRatioNone &&
             g_cached_bottom_ratio >= 0.0f) {
    ratio = g_cached_bottom_ratio;
    usingFallback = (g_cached_ratio_source == BlinkRatioFallback);
    if (usingFallback) {
      // Keep trying for a real DOM ratio to replace the fallback.
      [self queryDomFocusedInputRatio];
    }
  } else {
    // Metrics unavailable AND nothing cached for this focus session.

    // Ask the renderer's DOM for the real ratio.
    // The result re-enters this method with a cached real ratio.
    [self queryDomFocusedInputRatio];
    const float fallback = BlinkKeyboardChatFallbackRatio();
    if (fallback > 0.0f) {
      // Do NOT lift by the coarse 0.92 guess immediately — on pages
      // whose input is not at the bottom (claude.ai/login) that shoved the
      // field off the top and it visibly jumped when real metrics arrived a
      // beat later. Defer the fallback briefly; caret/DOM metrics normally
      // land first and win. If they don't (metrics dead), the deferred pass
      // applies the fallback so chat prompts still get lifted.

      [NSObject cancelPreviousPerformRequestsWithTarget:self
                                               selector:@selector
                                               (applyDeferredChatFallback)
                                                 object:nil];
      [self performSelector:@selector(applyDeferredChatFallback)
                 withObject:nil
                 afterDelay:0.25];
      return;
    } else {
      // Not a chat site. never zero-reset a live keyboard — if we
      // already shifted the page, keep that offset rather than snapping to 0.
      if (g_keyboard_state == BlinkKeyboardVisible &&
          g_current_relocation_offset > 0) {
        return;
      }

      return;
    }
  }
  if (keyboardOverlap <= 0) {
    // Bogus zero-overlap event — keep the existing offset.

    return;
  }
  const CGFloat clearance = 12;
  const CGFloat focusBottom = contentHeight * ratio;
  const CGFloat visibleBottom = contentHeight - keyboardOverlap - clearance;
  CGFloat offset =
      MIN(keyboardOverlap, MAX((CGFloat)0, focusBottom - visibleBottom));

  // A caret update describes the insertion line, not the entire input
  // container. Keep the largest offset for the current focus session so a
  // keystroke cannot move the input back under the keyboard.
  if (g_keyboard_state == BlinkKeyboardVisible &&
      offset < g_current_relocation_offset) {
    offset = g_current_relocation_offset;
  }

  [self applyRelocationOffset:offset];
}

// Apply the relocation offset using the active strategy. Strategy 0
// transforms the compositor view itself; strategy 1 shifts the wrapper scroll
// view (container) instead, leaving the compositor layer's own transform
// identity (less likely to confuse site height / drag math).
- (void)applyRelocationOffset:(CGFloat)offset {
  g_current_relocation_offset = offset;
  if (g_keyboard_relocate_strategy == 2) {
    self.transform = CGAffineTransformIdentity;
    UIView* container = [self superview];
    if (container) {
      container.transform = CGAffineTransformIdentity;
    }
    BlinkSetKeyboardViewportInset(g_last_keyboard_height);

  } else if (g_keyboard_relocate_strategy == 1) {
    UIView* container = [self superview];

    if (container) {
      // Keep the compositor view itself untransformed under the constraint
      // strategy so its bounds-based math stays clean.
      self.transform = CGAffineTransformIdentity;
      container.transform = CGAffineTransformMakeTranslation(0, -offset);
    } else {
      self.transform = CGAffineTransformMakeTranslation(0, -offset);
    }
  } else {
    self.transform = CGAffineTransformMakeTranslation(0, -offset);
  }
}

- (void)resetFocusedInputRelocation {
  g_current_relocation_offset = 0;
  // A cached FALLBACK guess doesn't outlive the relocation it justified; real
  // (caret/DOM) ratios stay until the focus session ends.
  if (g_cached_ratio_source == BlinkRatioFallback) {
    g_cached_ratio_source = BlinkRatioNone;
    g_cached_bottom_ratio = -1.0f;
  }
  BOOL changed = NO;
  if (!CGAffineTransformIsIdentity(self.transform)) {
    self.transform = CGAffineTransformIdentity;
    changed = YES;
  }
  // Also clear any container shift left by the constraint strategy.
  UIView* container = [self superview];
  if (container && !CGAffineTransformIsIdentity(container.transform)) {
    container.transform = CGAffineTransformIdentity;
    changed = YES;
  }
  if (changed) {
  }
  BlinkSetKeyboardViewportInset(0);
}

// After committed/marked text we don't re-present the keyboard; we only
// re-run relocation against the already-known real keyboard height so the
// prompt stays put as the caret moves.
- (void)refreshRelocationAfterTextCommit {
  if (g_keyboard_state != BlinkKeyboardVisible ||
      g_last_keyboard_height <= kRealKeyboardMinHeight) {
    return;
  }
  if (g_keyboard_relocate_strategy == 2) {
    BlinkSetKeyboardViewportInset(g_last_keyboard_height);

    return;
  }

  [self relocateFocusedInputAboveKeyboard:g_last_keyboard_height];
}

- (void)applyPendingKeyboardFrame {
  if (g_keyboard_owner != self) {
    return;
  }
  const CGFloat height = g_pending_keyboard_height;
  // A zero / sub-real-height frame while the keyboard is already visible
  // is a bogus iOS event (emitted right after reloadInputViews on a keystroke).
  // Ignore it — keep the existing relocation instead of snapping the page back
  // under the keyboard.
  if (height <= kRealKeyboardMinHeight &&
      g_keyboard_state == BlinkKeyboardVisible) {
    return;
  }
  if ([self isAccessoryBarOnlyHeight:height]) {
    return;
  }
  if (height <= kRealKeyboardMinHeight) {
    return;
  }

  g_last_keyboard_height = height;
  g_keyboard_state = BlinkKeyboardVisible;

  if (g_keyboard_relocate_strategy == 2) {
    BlinkSetKeyboardViewportInset(height);
    [self applyRelocationOffset:0];

    return;
  }
  // Single relocation strategy at a time — never also apply a bottom inset (the
  // Two fought and broke the page height). the strategy is runtime-
  // selectable; the detailed strategy/offset lines are logged in
  // applyRelocationOffset:.

  [self relocateFocusedInputAboveKeyboard:height];
}

- (void)coalesceKeyboardNotification:(NSNotification*)notification {
  // Keyboard notifications are process-wide. Only the renderer view that owns
  // first responder may mutate the shared keyboard state or browser viewport.
  if (g_keyboard_owner != self) {
    return;
  }

  CGFloat height = [self keyboardHeightFromNotification:notification];
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (fabs(height - g_last_keyboard_height) < 4 &&
      now - g_last_keyboard_notification_time < 0.250) {
    return;
  }
  g_last_keyboard_notification_time = now;
  g_pending_keyboard_height = height;
  if ([self isAccessoryBarOnlyHeight:height]) {
    return;
  }

  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (applyPendingKeyboardFrame)
                                             object:nil];
  [self performSelector:@selector(applyPendingKeyboardFrame)
             withObject:nil
             afterDelay:0.05];
}

- (void)keyboardWillShow:(NSNotification*)notification {
  [self coalesceKeyboardNotification:notification];
}

- (void)keyboardDidShow:(NSNotification*)notification {
  [self coalesceKeyboardNotification:notification];
}

- (void)keyboardWillChangeFrame:(NSNotification*)notification {
  [self coalesceKeyboardNotification:notification];
}

- (void)keyboardWillHide:(NSNotification*)notification {
  if (g_keyboard_owner != self) {
    return;
  }

  if (g_keyboard_state == BlinkKeyboardPresenting &&
      !g_keyboard_user_dismissed && g_keyboard_owner &&
      [g_keyboard_owner isFirstResponder]) {
    return;
  }
  // UIKit's keyboard-down control, third-party keyboard tweaks, and tapping
  // outside the field do not call userDismissKeyboard. Treat a hide from a
  // fully visible session exactly like the accessory checkmark so Blink's
  // still-focused renderer cannot immediately present it again.
  if (g_keyboard_state == BlinkKeyboardVisible) {
    g_keyboard_user_dismissed = YES;
    g_keyboard_dismiss_time = [NSDate timeIntervalSinceReferenceDate];
  }
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (g_last_keyboard_height == 0 &&
      now - g_last_keyboard_notification_time < 0.250) {
    return;
  }
  g_last_keyboard_notification_time = now;
  g_last_keyboard_height = 0;
  // Real hide: clear state + cached focus ratio and reset the relocation. (Only
  // a genuine willHide/resign/nav resets — not the bogus zero-height did-show.)
  g_keyboard_state = BlinkKeyboardHidden;
  g_cached_bottom_ratio = -1.0f;
  g_cached_ratio_source = BlinkRatioNone;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (applyPendingKeyboardFrame)
                                             object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (applyDeferredChatFallback)
                                             object:nil];
  [self resetFocusedInputRelocation];
}

- (void)keyboardDidHide:(NSNotification*)notification {
  if (g_keyboard_owner != self) {
    return;
  }
  const BOOL shouldRetryKeyboardBody = g_keyboard_body_retry_in_progress;

  g_keyboard_state = BlinkKeyboardHidden;
  g_keyboard_owner = nil;
  g_last_keyboard_height = 0;
  g_pending_keyboard_height = 0;
  g_keyboard_recovery_used = shouldRetryKeyboardBody;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (attemptAccessoryOnlyRecovery)
                                             object:nil];
  [NSObject
      cancelPreviousPerformRequestsWithTarget:self
                                     selector:@selector
                                     (retryKeyboardAfterAccessoryOnlyFailure)
                                       object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (finishAccessoryOnlyRecovery)
                                             object:nil];
  if (!shouldRetryKeyboardBody) {
    g_keyboard_body_retry_in_progress = NO;
    [self setIsEditable:NO];
  }
  BlinkSetKeyboardViewportInset(0);
  if (shouldRetryKeyboardBody) {
    // Wait until UIKit has completely ended the accessory-only input session.
    // Retrying before didHide races the old session and produces another strip.
    [self performSelector:@selector(retryKeyboardAfterAccessoryOnlyFailure)
               withObject:nil
               afterDelay:0.05];
  }
  // Some keyboard tweaks finish their own frame animation after willHide.
  // Reassert the zero inset after that animation so a stale queued frame from
  // another renderer observer cannot leave the viewport shortened.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        BlinkSetKeyboardViewportInset(0);
      });
}

- (void)layoutSubviews {
  CHECK(_view);
  [super layoutSubviews];
  _view->UpdateScreenInfo();

  // TODO(dtapuska): This isn't correct, we need to figure out when the window
  // gains/loses focus.
  _view->SetActive(true);
}

- (UIView*)inputAccessoryView {
  return _inputAccessoryContainerView;
}

- (void)initializeInputAccessoryToolbar {
  UIToolbar* toolbar = [[UIToolbar alloc] init];
  [toolbar sizeToFit];

  CGSize toolbarSize = toolbar.frame.size;

  _inputAccessoryContainerView = [[UIView alloc]
      initWithFrame:CGRectMake(0, 0, toolbarSize.width,
                               toolbarSize.height +
                                   kInputAccessoryToolbarBottomMargin)];
  toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [_inputAccessoryContainerView addSubview:toolbar];

  if (@available(iOS 13.0, *)) {
    _previousAccessoryButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:kPreviousAccessoryImageName]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(handlePreviousAccessoryAction)];
  } else {
    _previousAccessoryButton = [[UIBarButtonItem alloc]
        initWithTitle:@"‹"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(handlePreviousAccessoryAction)];
  }
  _previousAccessoryButton.accessibilityLabel =
      l10n_util::GetNSString(IDS_ACCNAME_PREVIOUS);
  if (@available(iOS 13.0, *)) {
    _nextAccessoryButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:kNextAccessoryImageName]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(handleNextAccessoryAction)];
  } else {
    _nextAccessoryButton = [[UIBarButtonItem alloc]
        initWithTitle:@"›"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(handleNextAccessoryAction)];
  }
  _nextAccessoryButton.accessibilityLabel =
      l10n_util::GetNSString(IDS_ACCNAME_NEXT);
  UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];
  UIBarButtonItem* doneButton;
  if (@available(iOS 13.0, *)) {
    doneButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:kDoneAccessoryImageName]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(userDismissKeyboard)];
  } else {
    doneButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(userDismissKeyboard)];
  }
  doneButton.accessibilityLabel = l10n_util::GetNSString(IDS_DONE);

  toolbar.items = @[
    _previousAccessoryButton, _nextAccessoryButton, flexSpace, doneButton
  ];
}

- (ui::CALayerFrameSink*)frameSink {
  return _view.get();
}

- (BOOL)canBecomeFirstResponder {
  return YES;
}

- (BOOL)becomeFirstResponder {
  CHECK(_view);
  // Authentication flows can move the renderer into a newly-created UIWindow
  // while the address field or previous browser window remains key. UIKit
  // refuses to present an input view for a responder in a non-key window.
  if (self.window && !self.window.isKeyWindow) {
    [self.window makeKeyWindow];
  }
  BOOL result = [super becomeFirstResponder];
  if (result || _view->CanBecomeFirstResponderForTesting()) {
    _view->OnFirstResponderChanged();
  }
  return result;
}

- (BOOL)resignFirstResponder {
  BOOL result = [super resignFirstResponder];
  if (_view && (result || _view->CanResignFirstResponderForTesting())) {
    _view->OnFirstResponderChanged();
  }
  return result;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  UITouch* firstTouch = touches.anyObject;
  g_touch_sequence_active = firstTouch != nil;
  g_touch_sequence_moved = NO;
  if (firstTouch) {
    g_touch_sequence_origin = [firstTouch locationInView:self];
  }
  // editState describes the renderer's currently focused element, not the
  // location of this touch. Gemini keeps its prompt focused after dismissal,
  // so using editState here made every page tap reopen the keyboard. Forward
  // the touch first; Blink's subsequent show_ime_if_needed update is the only
  // authoritative request to present it.
  for (UITouch* touch in touches) {
    blink::WebTouchEvent webTouchEvent = input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchStart, touch, event, self,
        _viewOffsetDuringTouchSequence);
    if (!_viewOffsetDuringTouchSequence) {
      _viewOffsetDuringTouchSequence =
          webTouchEvent.touches[0].PositionInWidget() -
          webTouchEvent.touches[0].PositionInScreen();
    }
    _view->OnTouchEvent(std::move(webTouchEvent));
  }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  for (UITouch* touch in touches) {
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchEnd, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
  if (event.allTouches.count == 1) {
    _viewOffsetDuringTouchSequence.reset();
  }
  if (g_touch_sequence_moved) {
    g_last_scroll_touch_end = [NSDate timeIntervalSinceReferenceDate];
    if (g_keyboard_owner == self) {
      [self resignFirstResponder];
      [self setIsEditable:NO];
      g_keyboard_owner = nil;
      g_keyboard_state = BlinkKeyboardHidden;
      BlinkSetKeyboardViewportInset(0);
    }
  }
  g_touch_sequence_active = NO;
  g_touch_sequence_moved = NO;
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  for (UITouch* touch in touches) {
    CGPoint point = [touch locationInView:self];
    if (hypot(point.x - g_touch_sequence_origin.x,
              point.y - g_touch_sequence_origin.y) > 8) {
      g_touch_sequence_moved = YES;
      if (g_keyboard_owner == self) {
        [self resignFirstResponder];
        [self setIsEditable:NO];
        g_keyboard_owner = nil;
        g_keyboard_state = BlinkKeyboardHidden;
        BlinkSetKeyboardViewportInset(0);
      }
    }
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchMove, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  for (UITouch* touch in touches) {
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchCancel, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
  _viewOffsetDuringTouchSequence.reset();
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  CHECK(_view);
  if (context == kObservingContext) {
    _view->ContentInsetChanged();
  } else {
    [super observeValueForKeyPath:keyPath
                         ofObject:object
                           change:change
                          context:context];
  }
}

- (void)removeView {
  UIScrollView* view = (UIScrollView*)[self superview];
  [view removeObserver:self
            forKeyPath:NSStringFromSelector(@selector(contentInset))];
  [self removeFromSuperview];
}

- (BETextInteraction*)textInteraction {
  return text_interaction_;
}

- (void)updateView:(UIScrollView*)view {
  if ([self superview]) {
    [self removeFromSuperview];
  }

  [view addSubview:self];
  view.scrollEnabled = NO;
  // Remove all existing gestureRecognizers since the header might be reused.
  for (UIGestureRecognizer* recognizer in view.gestureRecognizers) {
    [view removeGestureRecognizer:recognizer];
  }
  [view addObserver:self
         forKeyPath:NSStringFromSelector(@selector(contentInset))
            options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
            context:kObservingContext];
}

- (BOOL)isEditable {
  return _isEditable;
}

- (BOOL)setIsEditable:(BOOL)isEditable {
  if (isEditable == _isEditable) {
    return NO;
  }

  _isEditable = isEditable;
  [self updateLegacyTextInteraction];
  if (!isEditable) {
    // The inset is only ever cleared from keyboardWillHide, which does not
    // arrive when the keyboard goes away by other means -- endEditing during a
    // fullscreen transition, for one. It then kept the content view short by
    // the accessory bar's height, leaving a band of empty window below the
    // page that outlived the transition entirely.
    BlinkSetKeyboardViewportInset(0);
  }
  return YES;
}

// BETextInteraction is BrowserEngineKit, so upstream's caret dragging,
// selection grabbers and magnifier begin at iOS 17.4 -- which upstream can
// assume and this port cannot, since it runs on 14 through 17.3 as well.
// UITextInteraction has provided the same affordances since iOS 13 and drives
// them off UITextInput, which this view implements.
//
// It is attached only while a field is focused, and removed the moment focus
// leaves. An always-installed interaction claims touches that the view never
// sees cancelled, which strands entries in the touch table in
// web_input_event_builders_ios.mm; scoping it to editing keeps that confined to
// a state the user leaves by dismissing the keyboard, and the table now
// recovers on its own besides.
- (void)updateLegacyTextInteraction {
  if (!@available(iOS 13.0, *)) {
    // UITextInteraction does not exist on iOS 12. Blink still paints the text
    // selection itself and the responder exposes the native UIMenuController,
    // but asking UIKit for this interaction would be an unrecognized selector.
    return;
  }
  if (@available(iOS 17.4, *)) {
    return;
  }
  const BOOL wanted = _isEditable;
  if (wanted == (_legacyTextInteraction != nil)) {
    return;
  }
  if (wanted) {
    _legacyTextInteraction = [UITextInteraction
        textInteractionForMode:UITextInteractionModeEditable];
    _legacyTextInteraction.textInput = self;
    _legacyTextInteraction.delegate = self;
    [self addInteraction:_legacyTextInteraction];

  } else {
    _legacyTextInteraction.delegate = nil;
    [self removeInteraction:_legacyTextInteraction];
    _legacyTextInteraction = nil;
  }
}

// The interaction's gesture recognizers cover the whole view, so while a field
// was focused they swallowed taps meant for the rest of the page -- other text
// boxes and buttons stopped responding until the keyboard went away, and the
// interaction's own bar could surface over the input accessory toolbar. Confine
// it to the focused element's box (plus enough slop to grab a selection handle
// sitting just outside it); anywhere else the touch falls through to Blink.
- (BOOL)interactionShouldBegin:(UITextInteraction*)interaction
                       atPoint:(CGPoint)point {
  if (CGRectIsEmpty(g_last_focused_editable_rect)) {
    return NO;
  }
  const CGFloat slop = 16;
  return CGRectContainsPoint(
      CGRectInset(g_last_focused_editable_rect, -slop, -slop), point);
}

- (BOOL)automaticallyPresentEditMenu {
  // Needs an edit menu implementation.
  return NO;
}

- (BOOL)isReplaceAllowed {
  // Needs an implementatino to check if the focused field allows replacements,
  // e.g. password fields do not.
  return NO;
}

- (BOOL)isSelectionAtDocumentStart {
  // Unclear what this does if true.
  return NO;
}

- (NSAttributedString*)attributedMarkedText {
  NSString* text = [self markedText];
  if (!text) {
    return nil;
  }
  return [[NSAttributedString alloc] initWithString:text];
}

- (CGRect)textFirstRect {
  UITextRange* range = [self selectedTextRange];
  return range ? [self caretRectForPosition:range.start] : CGRectNull;
}

- (CGRect)textLastRect {
  UITextRange* range = [self selectedTextRange];
  return range ? [self caretRectForPosition:range.end] : CGRectNull;
}

- (CGRect)unobscuredContentRect {
  return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
}

- (UIView*)unscaledView {
  // View representing the web content that is agnostic of zoom state, so
  // returning self is a simple hack and wrong.
  return self;
}

- (id<BETextInputDelegate>)asyncInputDelegate {
  return be_text_input_delegate_;
}

- (id<UITextInputDelegate>)inputDelegate {
  return input_delegate_;
}

- (void)setInputDelegate:(id<UITextInputDelegate>)inputDelegate {
  input_delegate_ = inputDelegate;
}

- (void)selectionDidChange {
  // UITextInteraction relies on UITextInputDelegate notifications to refresh
  // Apple's caret, highlight and grabber geometry. Dropping the delegate made
  // the system retain stale selection rectangles until another gesture.
  [input_delegate_ selectionWillChange:self];
  [input_delegate_ selectionDidChange:self];
}

- (void)setAsyncInputDelegate:(id<BETextInputDelegate>)delegate {
  be_text_input_delegate_ = delegate;
}

- (UIView*)textInputView {
  return self;
}

- (BOOL)hasMarkedText {
  return _markedText.length() > 0;
}

- (NSString*)markedText {
  if (![self hasMarkedText]) {
    return nil;
  }
  return base::SysUTF16ToNSString(_markedText);
}

- (NSString*)selectedText {
  auto* selection = [self textSelection];
  if (!selection || !selection->selected_text().length()) {
    return nil;
  }

  return base::SysUTF16ToNSString(selection->selected_text());
}

- (void)unmarkText {
  if (![self hasMarkedText]) {
    return;
  }

  CHECK(_view);
  _view->ImeFinishComposingText(false);
  _markedText.clear();
}

- (CGRect)selectionClipRect {
  auto rect = [self textControlBounds];
  if (!rect) {
    return CGRectNull;
  }
  // Need to get a more realistic rect here. If this clip is too small,
  // selection handles won't draw correctly.
  return CGRectMake(rect->x(), rect->y(), rect->width(), rect->height());
}

- (id<BEExtendedTextInputTraits>)extendedTextInputTraits {
  return _extendedTextInputTraits;
}

// UIKit reads UITextInputTraits off the first responder itself; only 17.4+
// BrowserEngineKit goes through -extendedTextInputTraits above. Without these
// forwards the traits computed from Blink's TextInputState never reached the
// keyboard below 17.4, so every field got UIKit's defaults: no autocorrect or
// suggestion bar driven by the field, wrong keyboard layout for email/number/
// url inputs, and password fields not marked secure.
- (UITextAutocapitalizationType)autocapitalizationType {
  return _extendedTextInputTraits.autocapitalizationType;
}

- (UITextAutocorrectionType)autocorrectionType {
  return _extendedTextInputTraits.autocorrectionType;
}

- (UITextSpellCheckingType)spellCheckingType {
  return _extendedTextInputTraits.spellCheckingType;
}

- (UITextSmartQuotesType)smartQuotesType {
  return _extendedTextInputTraits.smartQuotesType;
}

- (UITextSmartDashesType)smartDashesType {
  return _extendedTextInputTraits.smartDashesType;
}

- (UITextSmartInsertDeleteType)smartInsertDeleteType {
  return _extendedTextInputTraits.smartInsertDeleteType;
}

- (UITextInlinePredictionType)inlinePredictionType API_AVAILABLE(ios(17.0)) {
  return _extendedTextInputTraits.inlinePredictionType;
}

- (UIKeyboardType)keyboardType {
  return _extendedTextInputTraits.keyboardType;
}

- (UIKeyboardAppearance)keyboardAppearance {
  return _extendedTextInputTraits.keyboardAppearance;
}

- (UIReturnKeyType)returnKeyType {
  return _extendedTextInputTraits.returnKeyType;
}

- (BOOL)isSecureTextEntry {
  return _extendedTextInputTraits.isSecureTextEntry;
}

- (BOOL)enablesReturnKeyAutomatically {
  return _extendedTextInputTraits.enablesReturnKeyAutomatically;
}

- (UITextContentType)textContentType {
  return _extendedTextInputTraits.textContentType;
}

- (UITextInputPasswordRules*)passwordRules {
  return _extendedTextInputTraits.passwordRules;
}

- (void)handleEditCommands:(const std::vector<std::string>&)commands {
  CHECK(_view);
  // If there's a pending key down event, forward it along with the edit
  // commands to the renderer. This allows the renderer to associate the
  // commands with the keyboard event that triggered them.
  if (auto event = std::exchange(_currentKeyDownEvent, std::nullopt)) {
    std::vector<blink::mojom::EditCommandPtr> editCommands;
    editCommands.reserve(commands.size());
    for (const auto& command : commands) {
      editCommands.push_back(blink::mojom::EditCommand::New(command, ""));
    }
    _view->ForwardKeyboardEventWithCommands(*event, std::move(editCommands));
    return;
  }
  // No pending key event - execute the edit commands directly. This handles
  // cases where commands are triggered by non-keyboard input.
  for (const auto& command : commands) {
    _view->ExecuteEditCommand(command);
  }
}

- (std::string)moveSelectionCommand:(UITextLayoutDirection)direction {
  switch (direction) {
    case UITextLayoutDirectionLeft:
      return "moveLeft";
    case UITextLayoutDirectionRight:
      return "moveRight";
    case UITextLayoutDirectionUp:
      return "moveUp";
    case UITextLayoutDirectionDown:
      return "moveDown";
  }
  NOTREACHED() << "Unknown Text Layout Direction";
}

- (void)moveInLayoutDirection:(UITextLayoutDirection)direction {
  [self handleEditCommands:{[self moveSelectionCommand:direction]}];
}

- (std::string)extendSelectionCommand:(UITextLayoutDirection)direction {
  switch (direction) {
    case UITextLayoutDirectionLeft:
      return "moveLeftAndModifySelection";
    case UITextLayoutDirectionRight:
      return "moveRightAndModifySelection";
    case UITextLayoutDirectionUp:
      return "moveUpAndModifySelection";
    case UITextLayoutDirectionDown:
      return "moveDownAndModifySelection";
  }
  NOTREACHED() << "Unknown Text Layout Direction";
}

- (void)extendInLayoutDirection:(UITextLayoutDirection)direction {
  [self handleEditCommands:{[self extendSelectionCommand:direction]}];
}

- (std::vector<std::string>)
    moveSelectionCommands:(UITextStorageDirection)direction
            byGranularity:(UITextGranularity)granularity {
  if (granularity == UITextGranularityCharacter) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveForward"}
               : std::vector<std::string>{"moveBackward"};
  }
  if (granularity == UITextGranularityWord) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveWordForward"}
               : std::vector<std::string>{"moveWordBackward"};
  }
  if (granularity == UITextGranularitySentence) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveToEndOfSentence"}
               : std::vector<std::string>{"moveToBeginningOfSentence"};
  }
  if (granularity == UITextGranularityParagraph) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveForward", "moveToEndOfParagraph"}
               : std::vector<std::string>{"moveBackward",
                                          "moveToBeginningOfParagraph"};
  }
  if (granularity == UITextGranularityLine) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveToEndOfLine"}
               : std::vector<std::string>{"moveToBeginningOfLine"};
  }
  return direction == UITextStorageDirectionForward
             ? std::vector<std::string>{"moveToEndOfDocument"}
             : std::vector<std::string>{"moveToBeginningOfDocument"};
}

- (void)moveInStorageDirection:(UITextStorageDirection)direction
                 byGranularity:(UITextGranularity)granularity {
  [self handleEditCommands:[self moveSelectionCommands:direction
                                         byGranularity:granularity]];
}

- (std::vector<std::string>)
    extendSelectionCommands:(UITextStorageDirection)direction
              byGranularity:(UITextGranularity)granularity {
  if (granularity == UITextGranularityCharacter) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveBackwardAndModifySelection"}
               : std::vector<std::string>{"moveForwardAndModifySelection"};
  }
  if (granularity == UITextGranularityWord) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveWordForwardAndModifySelection"}
               : std::vector<std::string>{"moveWordBackwardAndModifySelection"};
  }
  if (granularity == UITextGranularitySentence) {
    return direction == UITextStorageDirectionForward
               ? std::vector<
                     std::string>{"moveToEndOfSentenceAndModifySelection"}
               : std::vector<std::string>{
                     "moveToBeginningOfSentenceAndModifySelection"};
  }
  if (granularity == UITextGranularityParagraph) {
    return direction == UITextStorageDirectionForward
               ? std::vector<
                     std::string>{"moveForwardAndModifySelection",
                                  "moveToEndOfParagraphAndModifySelection"}
               : std::vector<std::string>{
                     "moveBackwardAndModifySelection",
                     "moveToBeginningOfParagraphAndModifySelection"};
  }
  if (granularity == UITextGranularityLine) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"moveToEndOfLineAndModifySelection"}
               : std::vector<std::string>{
                     "moveToBeginningOfLineAndModifySelection"};
  }
  return direction == UITextStorageDirectionForward
             ? std::vector<std::string>{"moveToEndOfDocumentAndModifySelection"}
             : std::vector<std::string>{
                   "moveToBeginningOfDocumentAndModifySelection"};
}

- (void)extendInStorageDirection:(UITextStorageDirection)direction
                   byGranularity:(UITextGranularity)granularity {
  [self handleEditCommands:[self extendSelectionCommands:direction
                                           byGranularity:granularity]];
}

- (BOOL)canPerformAction:(SEL)action withSender:(nullable id)sender {
  if (action == @selector(paste:)) {
    return [UIPasteboard generalPasteboard].hasStrings;
  }
  if (action == @selector(copy:) || action == @selector(cut:) ||
      action == @selector(selectAll:)) {
    return YES;
  }
  return NO;
}

- (void)copy:(nullable id)sender {
  if (!_view) {
    return;
  }
  [self handleEditCommands:{"copy"}];
}

- (void)cut:(nullable id)sender {
  if (!_view) {
    return;
  }
  [self handleEditCommands:{"cut"}];
}

- (void)paste:(nullable id)sender {
  if (!_view || ![UIPasteboard generalPasteboard].hasStrings) {
    return;
  }
  NSString* text = [UIPasteboard generalPasteboard].string;
  if (text.length == 0) {
    return;
  }
  // This iOS content_shell port has no browser/renderer clipboard IPC split.
  // Commit the system pasteboard text through the same IME path as keyboard
  // input so paste works in regular, contenteditable, and secure web fields.
  _markedText.clear();
  _view->ImeCommitText(base::SysNSStringToUTF16(text),
                       gfx::Range::InvalidRange(), 0);
}

- (BOOL)shouldInsertCharacter:(const blink::WebKeyboardEvent&)webKeyboardEvent {
  size_t textLength =
      std::char_traits<char16_t>::length(webKeyboardEvent.text.data());

  // For inputting emojis (multiple characters)
  if (textLength > 1) {
    return YES;
  }

  if (textLength == 0) {
    return NO;
  }

  // Check the first character if text is available
  char16_t ch = webKeyboardEvent.text[0];
  if (ch < ' ') {
    return NO;
  }

  // Check for ASCII control characters with modifiers
  if (ch < 0x80) {
    int modifiers = webKeyboardEvent.GetModifiers();
    if ((modifiers & blink::WebInputEvent::kControlKey) ||
        (modifiers & blink::WebInputEvent::kMetaKey)) {
      return NO;
    }
  }

  return YES;
}

- (void)handleKeyEntry:(BEKeyEntry*)entry
    withCompletionHandler:
        (void (^)(BEKeyEntry* theEvent, BOOL wasHandled))completionHandler {
  CHECK(_view);

  input::NativeWebKeyboardEvent nativeEvent(
      (base::apple::OwnedBEKeyEntry(entry)));
  if (entry.state != BEKeyPressState::BEKeyPressStateDown) {
    _currentKeyDownEvent.reset();
    _view->SendKeyEvent(nativeEvent);
    completionHandler(entry, YES);
    return;
  }

  _currentKeyDownEvent = nativeEvent;
  BEKeyEntryContext* contextForKeyDown =
      [[BEKeyEntryContext alloc] initWithKeyEntry:entry];
  [contextForKeyDown setDocumentEditable:[self isEditable]];
  // To trigger key commands correctly, e.g. trigger
  // `transposeCharactersAroundSelection` on Ctrl+T, we need to set
  // `shouldInsertCharacter` to NO when users are not inputting characters.
  // Otherwise, the key commands will not be triggered.
  [contextForKeyDown
      setShouldInsertCharacter:[self shouldInsertCharacter:nativeEvent]];

  BOOL handled = [[self asyncInputDelegate]
      shouldDeferEventHandlingToSystemForTextInput:self
                                           context:contextForKeyDown];
  if (!handled) {
    // The system did not handle the event (e.g., the user pressed Enter).
    auto event = std::exchange(_currentKeyDownEvent, std::nullopt);
    // Reset to kKeyDown so Blink dispatches both keydown and keypress events.
    event->SetType(blink::WebInputEvent::Type::kKeyDown);
    _view->SendKeyEvent(*event);
  }
  completionHandler(entry, YES);
}

// Physical-keyboard support below iOS 17.4.
//
// Keyboard input normally arrives through BrowserEngineKit's handleKeyEntry:
// above, but BEKeyEntry is 17.4+, so on iOS 14-17.3 no key event ever reached
// Blink: text input worked (it goes through UITextInput) while page-level
// shortcuts did not. Upstream does have a UIPress path, but it is compiled only
// for tvOS -- the builder branch, the UIPress conversion helpers in
// keyboard_code_conversion_ios, and the OwnedUIPress variant member are all
// behind BUILDFLAG(IS_IOS_TVOS). Rather than ungate six upstream files, the
// event is built here from UIKey, which is available from iOS 13.4.
//
// Only keydown/keyup are sent, never a Char event: text entry already works
// through the UITextInput path and synthesizing Char here would double-insert
// characters into form fields. See GitHub issue #9.

// Maps a USB HID keyboard usage (what UIKey.keyCode reports) to a Windows-style
// virtual key code. Covers the printable and navigation keys pages rely on for
// shortcuts; anything unmapped falls through to the system.
static ui::KeyboardCode BlinkKeyboardCodeFromHIDUsage(long usage) {
  if (usage >= 0x04 && usage <= 0x1D) {  // A-Z
    return static_cast<ui::KeyboardCode>(ui::VKEY_A + (usage - 0x04));
  }
  if (usage >= 0x1E && usage <= 0x26) {  // 1-9
    return static_cast<ui::KeyboardCode>(ui::VKEY_1 + (usage - 0x1E));
  }
  if (usage >= 0x3A && usage <= 0x45) {  // F1-F12
    return static_cast<ui::KeyboardCode>(ui::VKEY_F1 + (usage - 0x3A));
  }
  switch (usage) {
    case 0x27:
      return ui::VKEY_0;
    case 0x28:
      return ui::VKEY_RETURN;
    case 0x29:
      return ui::VKEY_ESCAPE;
    case 0x2A:
      return ui::VKEY_BACK;
    case 0x2B:
      return ui::VKEY_TAB;
    case 0x2C:
      return ui::VKEY_SPACE;
    case 0x2D:
      return ui::VKEY_OEM_MINUS;
    case 0x2E:
      return ui::VKEY_OEM_PLUS;
    case 0x4C:
      return ui::VKEY_DELETE;
    case 0x4A:
      return ui::VKEY_HOME;
    case 0x4D:
      return ui::VKEY_END;
    case 0x4B:
      return ui::VKEY_PRIOR;
    case 0x4E:
      return ui::VKEY_NEXT;
    case 0x4F:
      return ui::VKEY_RIGHT;
    case 0x50:
      return ui::VKEY_LEFT;
    case 0x51:
      return ui::VKEY_DOWN;
    case 0x52:
      return ui::VKEY_UP;
    default:
      return ui::VKEY_UNKNOWN;
  }
}

- (BOOL)blinkSendPress:(UIPress*)press type:(blink::WebInputEvent::Type)type {
  UIKey* key = press.key;
  if (!key || !_view) {
    return NO;
  }
  const ui::KeyboardCode code =
      BlinkKeyboardCodeFromHIDUsage(static_cast<long>(key.keyCode));
  if (code == ui::VKEY_UNKNOWN) {
    return NO;
  }

  int modifiers = 0;
  const UIKeyModifierFlags flags = key.modifierFlags;
  if (flags & UIKeyModifierShift) {
    modifiers |= blink::WebInputEvent::kShiftKey;
  }
  if (flags & UIKeyModifierControl) {
    modifiers |= blink::WebInputEvent::kControlKey;
  }
  if (flags & UIKeyModifierAlternate) {
    modifiers |= blink::WebInputEvent::kAltKey;
  }
  if (flags & UIKeyModifierCommand) {
    modifiers |= blink::WebInputEvent::kMetaKey;
  }

  blink::WebKeyboardEvent web_event(type, modifiers, ui::EventTimeForNow());
  web_event.windows_key_code = code;
  web_event.native_key_code = static_cast<int>(key.keyCode);
  // ui::DomCode values on the keyboard usage page are 0x070000 | HID usage.
  web_event.dom_code =
      static_cast<int>(0x070000 | static_cast<int>(key.keyCode));

  // Populate text so Blink can resolve event.key for shortcut handlers, without
  // sending a separate Char event.
  NSString* characters = key.charactersIgnoringModifiers;
  if (characters.length == 1) {
    const char16_t ch = static_cast<char16_t>([characters characterAtIndex:0]);
    if (ch >= ' ') {
      web_event.text[0] = ch;
      web_event.unmodified_text[0] = ch;
    }
  }

  input::NativeWebKeyboardEvent native_event(web_event, _view->GetNativeView());
  _view->SendKeyEvent(native_event);
  return YES;
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses
           withEvent:(UIPressesEvent*)event {
  for (UIPress* press in presses) {
    if (press.key) {
      g_hardware_keyboard_seen = YES;
      break;
    }
  }
  if (@available(iOS 17.4, *)) {
    // BrowserEngineKit's handleKeyEntry: already delivers these; sending them
    // again here would dispatch every key twice.
    [super pressesBegan:presses withEvent:event];
    return;
  }
  NSMutableSet<UIPress*>* unhandled = [NSMutableSet set];
  NSMutableSet<UIPress*>* textInputPresses = [NSMutableSet set];
  for (UIPress* press in presses) {
    if (![self blinkSendPress:press
                         type:blink::WebInputEvent::Type::kRawKeyDown]) {
      [unhandled addObject:press];
      continue;
    }

    // Sending RawKeyDown gives JavaScript the physical key event, but UIKit
    // still has to translate an unmodified printable key through UIKeyInput's
    // insertText:. Consuming the UIPress here prevented that translation on
    // iOS 14-17.3, so editors backed by hidden textareas (Monaco/xterm.js)
    // received keydown but no beforeinput/input text. Pass only printable,
    // editable presses to super; shortcuts stay exclusively in Blink and do
    // not trigger UIKit editing commands a second time.
    UIKey* key = press.key;
    const UIKeyModifierFlags commandModifiers =
        key.modifierFlags &
        (UIKeyModifierControl | UIKeyModifierAlternate | UIKeyModifierCommand);
    if ([self isEditable] && commandModifiers == 0 &&
        key.characters.length > 0) {
      [textInputPresses addObject:press];
    }
  }
  if (unhandled.count > 0) {
    [super pressesBegan:unhandled withEvent:event];
  }
  if (textInputPresses.count > 0) {
    [super pressesBegan:textInputPresses withEvent:event];
  }
}

- (void)pressesEnded:(NSSet<UIPress*>*)presses
           withEvent:(UIPressesEvent*)event {
  if (@available(iOS 17.4, *)) {
    [super pressesEnded:presses withEvent:event];
    return;
  }
  NSMutableSet<UIPress*>* unhandled = [NSMutableSet set];
  for (UIPress* press in presses) {
    if (![self blinkSendPress:press type:blink::WebInputEvent::Type::kKeyUp]) {
      [unhandled addObject:press];
    }
  }
  if (unhandled.count > 0) {
    [super pressesEnded:unhandled withEvent:event];
  }
}

- (void)shiftKeyStateChangedFromState:(BEKeyModifierFlags)oldState
                              toState:(BEKeyModifierFlags)newState {
}

- (std::vector<std::string>)
    deleteSelectionCommands:(UITextStorageDirection)direction
              toGranularity:(UITextGranularity)granularity {
  if (granularity == UITextGranularityCharacter) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"deleteForward"}
               : std::vector<std::string>{"deleteBackward"};
  }
  if (granularity == UITextGranularityWord) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"deleteWordForward"}
               : std::vector<std::string>{"deleteWordBackward"};
  }
  if (granularity == UITextGranularitySentence) {
    return {direction == UITextStorageDirectionForward
                ? "moveToEndOfSentenceAndModifySelection"
                : "moveToBeginningOfSentenceAndModifySelection",
            "deleteBackward"};
  }
  if (granularity == UITextGranularityParagraph) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"deleteToEndOfParagraph"}
               : std::vector<std::string>{"deleteToBeginningOfParagraph"};
  }
  if (granularity == UITextGranularityLine) {
    return direction == UITextStorageDirectionForward
               ? std::vector<std::string>{"deleteToEndOfLine"}
               : std::vector<std::string>{"deleteToBeginningOfLine"};
  }
  return {direction == UITextStorageDirectionForward
              ? "moveToEndOfDocumentAndModifySelection"
              : "moveToBeginningOfDocumentAndModifySelection",
          "deleteBackward"};
}

- (void)deleteInDirection:(UITextStorageDirection)direction
            toGranularity:(UITextGranularity)granularity {
  [self handleEditCommands:[self deleteSelectionCommands:direction
                                           toGranularity:granularity]];
}

- (void)transposeCharactersAroundSelection {
  [self handleEditCommands:{"transpose"}];
}

- (BOOL)replaceText:(NSString*)originalText
           withText:(NSString*)replacementText {
  if (replacementText == originalText) {
    return NO;
  }

  // If we call ExtendSelectionAndReplace with an empty replacementText,
  // textarea will be broken, users cannot focus and input in textarea.
  // TODO(crbug.com/428561251): Call ExtendSelectionAndReplace with an empty
  // replacementText will make textarea broken
  if (!replacementText.length) {
    _view->ExtendSelectionAndDelete(originalText.length, 0);
  } else {
    _view->ExtendSelectionAndReplace(originalText.length, 0,
                                     base::SysNSStringToUTF16(replacementText));
  }
  return YES;
}

- (void)replaceText:(NSString*)originalText
             withText:(NSString*)replacementText
              options:(BETextReplacementOptions)options
    completionHandler:
        (void (^)(NSArray<UITextSelectionRect*>* rects))completionHandler {
  if (![self replaceText:originalText withText:replacementText]) {
    completionHandler(@[]);
    return;
  }

  // TODO: bug 388320178 - still don't know what to do with this.
  completionHandler(@[]);
}

- (void)requestTextContextForAutocorrectionWithCompletionHandler:
    (void (^)(BETextDocumentContext* context))completionHandler {
  completionHandler(nil);
}

- (void)requestTextRectsForString:(NSString*)input
            withCompletionHandler:
                (void (^)(NSArray<UITextSelectionRect*>* rects))
                    completionHandler {
  auto* state = [self editState];
  if (!state || !state->selection.is_empty()) {
    completionHandler(@[]);
    return;
  }

  NSRange range =
      [[self editText] rangeOfString:input
                             options:NSLiteralSearch
                               range:NSMakeRange(0, state->selection.start())];
  if (range.location == NSNotFound) {
    completionHandler(@[]);
    return;
  }

  _view->RectForEditFieldChars(
      gfx::Range(range),
      base::BindOnce(
          [](void (^completionHandler)(NSArray<UITextSelectionRect*>* rects),
             const gfx::Rect& rect) {
            if (rect.IsEmpty()) {
              completionHandler(@[]);
              return;
            }
            completionHandler(@[ [[BETextSelectionRect alloc]
                initWithCGRect:rect.ToCGRect()] ]);
          },
          completionHandler));
}

- (void)requestPreferredArrowDirectionForEditMenuWithCompletionHandler:
    (void (^)(UIEditMenuArrowDirection))completionHandler {
  completionHandler(UIEditMenuArrowDirectionAutomatic);
}

- (void)systemWillPresentEditMenuWithAnimator:
    (id<UIEditMenuInteractionAnimating>)animator
    API_UNAVAILABLE(watchos, tvos) {
}

- (void)systemWillDismissEditMenuWithAnimator:
    (id<UIEditMenuInteractionAnimating>)animator
    API_UNAVAILABLE(watchos, tvos) {
}

- (nullable NSDictionary<NSAttributedStringKey, id>*)
    textStylingAtPosition:(UITextPosition*)position
              inDirection:(UITextStorageDirection)direction {
  return nil;
}

- (void)replaceSelectedText:(NSString*)text
                   withText:(NSString*)replacementText {
}

- (void)updateCurrentSelectionTo:(CGPoint)point
                     fromGesture:(BEGestureType)gestureType
                         inState:(UIGestureRecognizerState)state {
  if (!_view) {
    return;
  }
  _view->host()->delegate()->MoveRangeSelectionExtent(
      gfx::Point(point.x, point.y));
}

- (void)setSelectionFromPoint:(CGPoint)from
                      toPoint:(CGPoint)to
                      gesture:(BEGestureType)gesture
                        state:(UIGestureRecognizerState)state
    NS_SWIFT_NAME(setSelection(from:to:gesture:state:)) {
}

- (void)adjustSelectionBoundaryToPoint:(CGPoint)point
                            touchPhase:(BESelectionTouchPhase)touch
                           baseIsStart:(BOOL)boundaryIsStart
                                 flags:(BESelectionFlags)flags {
  auto* region = [self selectionRegion];
  if (!region || !region->focus.HasHandle()) {
    return;
  }

  // A simple naive implementation that updates the selection range based on
  // a combination of boundaryIsStart (to know which handle was grabbed) and
  // SelectionRegion data. In the future this could be simplified with more
  // data, such as document position of selection to know which should be
  // start and end.
  CGPoint start, end;
  if (region->focus.type() == gfx::SelectionBound::RIGHT) {
    start = CGPointMake(region->focus.edge_start_rounded().x(),
                        region->focus.edge_start_rounded().y());
    end = CGPointMake(region->anchor.edge_start_rounded().x(),
                      region->anchor.edge_start_rounded().y());
  } else {
    end = CGPointMake(region->focus.edge_start_rounded().x(),
                      region->focus.edge_start_rounded().y());
    start = CGPointMake(region->anchor.edge_start_rounded().x(),
                        region->anchor.edge_start_rounded().y());
  }

  if (boundaryIsStart) {
    end = point;
  } else {
    start = point;
  }

  // This should look at document position instead, but for a naive
  // implementation works well enough.
  if (end.x < start.x && end.y < start.y) {
    flags = BESelectionFlipped;
    CGPoint flip = start;
    start = end;
    end = flip;
  }

  _view->host()->delegate()->SelectRange(gfx::Point(start.x, start.y),
                                         gfx::Point(end.x, end.y));

  // Tells the system the selection adjustment has been handled for the given
  // `point` and touch.
  [text_interaction_ selectionBoundaryAdjustedToPoint:point
                                           touchPhase:touch
                                                flags:flags];
}

- (BOOL)textInteractionGesture:(BEGestureType)gestureType
            shouldBeginAtPoint:(CGPoint)point {
  // Check if point is really selectable here.
  return NO;
}

- (void)selectWordForReplacement {
}

- (void)updateSelectionWithExtentPoint:(CGPoint)point
                              boundary:(UITextGranularity)granularity
                     completionHandler:(void (^)(BOOL selectionEndIsMoving))
                                           completionHandler {
  if (!_view) {
    completionHandler(false);
    return;
  }
  _view->host()->delegate()->MoveRangeSelectionExtent(
      gfx::Point(point.x, point.y));
  completionHandler(true);
}

- (void)selectTextInGranularity:(UITextGranularity)granularity
                        atPoint:(CGPoint)point
              completionHandler:(void (^)(void))completionHandler {
  if (!_view) {
    completionHandler();
    return;
  }
  _view->host()->delegate()->MoveCaret(gfx::Point(point.x, point.y));
  _view->host()->delegate()->SelectRange(gfx::Point(point.x, point.y),
                                         gfx::Point(point.x, point.y));
  _view->host()->delegate()->SelectAroundCaret(
      blink::mojom::SelectionGranularity::kWord,
      /*should_show_handle=*/true,
      /*should_show_context_menu=*/false);
  completionHandler();
}

// To set caret when users long-press on spacebar and move.
- (void)selectPositionAtPoint:(CGPoint)point
            completionHandler:(void (^)(void))completionHandler {
  if (!_view) {
    completionHandler();
    return;
  }

  CGFloat x = point.x;
  CGFloat y = point.y;
  // Constrain point to bounds of focused element.
  auto textControlBounds = [self textControlBounds];
  if (textControlBounds.has_value()) {
    x = std::clamp<CGFloat>(x, textControlBounds->x(),
                            textControlBounds->right());
    y = std::clamp<CGFloat>(y, textControlBounds->y(),
                            textControlBounds->bottom());
  }
  _view->host()->delegate()->MoveCaret(gfx::ToRoundedPoint(gfx::PointF(x, y)));
  completionHandler();
}

- (void)selectPositionAtPoint:(CGPoint)point
           withContextRequest:(BETextDocumentRequest*)request
            completionHandler:
                (void (^)(BETextDocumentContext*))completionHandler {
}

- (void)adjustSelectionByRange:(BEDirectionalTextRange)range
             completionHandler:(void (^)(void))completionHandler {
}

- (void)moveByOffset:(NSInteger)offset {
}

- (void)moveSelectionAtBoundary:(UITextGranularity)granularity
             inStorageDirection:(UITextStorageDirection)direction
              completionHandler:(void (^)(void))completionHandler {
}

- (void)
    selectTextForEditMenuWithLocationInView:(CGPoint)locationInView
                          completionHandler:
                              (void (^)(BOOL shouldPresentMenu,
                                        NSString* _Nullable contextString,
                                        NSRange selectedRangeInContextString))
                                  completionHandler {
}

- (void)setAttributedMarkedText:(nullable NSAttributedString*)markedText
                  selectedRange:(NSRange)selectedRange {
  [self setMarkedText:markedText.string selectedRange:selectedRange];
}

- (BOOL)isPointNearMarkedText:(CGPoint)point {
  // This needs a real implementation.
  return YES;
}

- (void)requestDocumentContext:(BETextDocumentRequest*)request
             completionHandler:
                 (void (^)(BETextDocumentContext*))completionHandler {
  completionHandler(nil);
}

- (void)willInsertFinalDictationResult {
}

- (void)replaceDictatedText:(NSString*)oldText withText:(NSString*)newText {
  [self replaceText:oldText withText:newText];
}

- (void)didInsertFinalDictationResult {
}

- (nullable NSArray<BETextAlternatives*>*)alternativesForSelectedText {
  return nil;
}

- (void)addTextAlternatives:(BETextAlternatives*)alternatives {
}

- (void)insertTextAlternatives:(BETextAlternatives*)alternatives {
  auto text = alternatives.primaryString;
  [self insertText:text];
}

- (void)insertTextPlaceholderWithSize:(CGSize)size
                    completionHandler:
                        (void (^)(UITextPlaceholder*))completionHandler {
}

- (void)removeTextPlaceholder:(UITextPlaceholder*)placeholder
               willInsertText:(BOOL)willInsertText
            completionHandler:(void (^)(void))completionHandler {
}

- (void)insertTextSuggestion:(BETextSuggestion*)textSuggestion {
}

- (void)autoscrollToPoint:(CGPoint)point {
  _view->StartAutoscrollForSelectionToPoint(gfx::PointF(point.x, point.y));
}

- (void)cancelAutoscroll {
  _view->StopAutoscroll();
}

- (UITextRange*)markedTextRange {
  return nil;
}

- (NSDictionary*)markedTextStyle {
  return nil;
}

- (void)setMarkedTextStyle:(NSDictionary*)styleDictionary {
}

- (UITextPosition*)beginningOfDocument {
  if (auto bounds = [self textControlBounds]) {
    return [[BETextPosition alloc]
        initWithRect:CGRectMake(bounds->x(), bounds->y(), 1,
                                std::max(1, bounds->height()))];
  }
  return [[BETextPosition alloc] initWithRect:CGRectMake(0, 0, 1, 1)];
}

- (UITextPosition*)endOfDocument {
  if (auto bounds = [self textControlBounds]) {
    return [[BETextPosition alloc]
        initWithRect:CGRectMake(bounds->right(), bounds->bottom(), 1,
                                std::max(1, bounds->height()))];
  }
  return [[BETextPosition alloc]
      initWithRect:CGRectMake(CGRectGetMaxX(self.bounds),
                              CGRectGetMaxY(self.bounds), 1, 1)];
}

- (BOOL)hasText {
  const ui::mojom::TextInputState* state = [self editState];
  if (state && state->value.has_value()) {
    return state->value->size() > 0;
  } else {
    return NO;
  }
}

- (void)insertText:(NSString*)text {
  CHECK(_view);
  if (auto event = std::exchange(_currentKeyDownEvent, std::nullopt)) {
    // If this insert was triggered by a key down event, forward it to the
    // renderer as kKeyDown. This ensures both keydown and keypress events
    // are dispatched to JavaScript with the correct text.
    event->SetType(blink::WebInputEvent::Type::kKeyDown);
    _view->SendKeyEvent(*event);
    return;
  }
  if (text.length == 0) {
    return;
  }

  _markedText.clear();
  _view->ImeCommitText(base::SysNSStringToUTF16(text),
                       gfx::Range::InvalidRange(), 0);
}

- (void)deleteBackward {
  [self handleEditCommands:{"deleteBackward"}];
}

- (void)selectAll:(nullable id)sender {
  [self handleEditCommands:{"selectAll"}];
}

- (void)setSelectedTextRange:(UITextRange*)range {
  if (!_view) {
    return;
  }
  BETextPosition* start = base::apple::ObjCCast<BETextPosition>(range.start);
  BETextPosition* end = base::apple::ObjCCast<BETextPosition>(range.end);
  if (!start || !end) {
    return;
  }
  CGRect startRect = [start rect];
  CGRect endRect = [end rect];
  _view->host()->delegate()->SelectRange(
      gfx::Point(CGRectGetMidX(startRect), CGRectGetMidY(startRect)),
      gfx::Point(CGRectGetMidX(endRect), CGRectGetMidY(endRect)));
}

- (UITextRange*)selectedTextRange {
  auto* region = [self selectionRegion];
  if (region) {
    return [[BETextRange alloc] initWithRegion:region];
  }

  return nil;
}
- (nullable NSString*)textInRange:(UITextRange*)range {
  return nil;
}

- (void)replaceRange:(UITextRange*)range withText:(NSString*)text {
  if (!_view || text.length == 0) {
    return;
  }
  _markedText.clear();
  _view->ImeCommitText(base::SysNSStringToUTF16(text),
                       gfx::Range::InvalidRange(), 0);
}

- (void)setMarkedText:(nullable NSString*)markedText
        selectedRange:(NSRange)selectedRange {
  _markedText = base::SysNSStringToUTF16(markedText);
  std::vector<ui::ImeTextSpan> imeTextSpans;
  if (_markedText.length() > 0) {
    ui::ImeTextSpan span;
    span.start_offset = 0;
    span.end_offset = _markedText.length();
    span.underline_style = ui::ImeTextSpan::UnderlineStyle::kSolid;
    imeTextSpans.push_back(span);
  }

  CHECK(_view);
  if (auto event = std::exchange(_currentKeyDownEvent, std::nullopt)) {
    // If an Input Method Editor is processing key input and the event is
    // keydown, keyCode should return 229, see:
    // https://lists.w3.org/Archives/Public/www-dom/2010JulSep/att-0182/keyCode-spec.html
    event->windows_key_code = 0xE5;  // VKEY_PROCESSKEY
    _view->SendKeyEvent(*event);
  }
  _view->ImeSetComposition(_markedText, imeTextSpans,
                           gfx::Range::InvalidRange(), selectedRange.location,
                           selectedRange.location + selectedRange.length);
}

- (nullable UITextRange*)textRangeFromPosition:(UITextPosition*)fromPosition
                                    toPosition:(UITextPosition*)toPosition {
  BETextPosition* start = base::apple::ObjCCast<BETextPosition>(fromPosition);
  BETextPosition* end = base::apple::ObjCCast<BETextPosition>(toPosition);
  return start && end ? [[BETextRange alloc] initWithStart:start end:end] : nil;
}

- (nullable UITextPosition*)positionFromPosition:(UITextPosition*)position
                                          offset:(NSInteger)offset {
  return position;
}

- (nullable UITextPosition*)positionFromPosition:(UITextPosition*)position
                                     inDirection:
                                         (UITextLayoutDirection)direction
                                          offset:(NSInteger)offset {
  return position;
}

- (NSComparisonResult)comparePosition:(UITextPosition*)position
                           toPosition:(UITextPosition*)other {
  BETextPosition* first = base::apple::ObjCCast<BETextPosition>(position);
  BETextPosition* second = base::apple::ObjCCast<BETextPosition>(other);
  if (!first || !second) {
    return NSOrderedSame;
  }
  CGRect a = [first rect];
  CGRect b = [second rect];
  if (CGRectGetMidY(a) < CGRectGetMidY(b) ||
      (CGRectGetMidY(a) == CGRectGetMidY(b) &&
       CGRectGetMidX(a) < CGRectGetMidX(b))) {
    return NSOrderedAscending;
  }
  return CGRectEqualToRect(a, b) ? NSOrderedSame : NSOrderedDescending;
}

- (NSInteger)offsetFromPosition:(UITextPosition*)from
                     toPosition:(UITextPosition*)toPosition {
  return 0;
}

- (nullable UITextPosition*)positionWithinRange:(UITextRange*)range
                            farthestInDirection:
                                (UITextLayoutDirection)direction {
  return (direction == UITextLayoutDirectionLeft ||
          direction == UITextLayoutDirectionUp)
             ? range.start
             : range.end;
}

- (nullable UITextRange*)
    characterRangeByExtendingPosition:(UITextPosition*)position
                          inDirection:(UITextLayoutDirection)direction {
  return [self textRangeFromPosition:position toPosition:position];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition*)position
                                          inDirection:(UITextStorageDirection)
                                                          direction {
  return NSWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection
                       forRange:(UITextRange*)range {
}

- (CGRect)caretRectForPosition:(UITextPosition*)position {
  BETextPosition* be_position = base::apple::ObjCCast<BETextPosition>(position);
  if (be_position) {
    return [be_position rect];
  }
  return CGRectNull;
}

- (NSArray<UITextSelectionRect*>*)selectionRectsForRange:(UITextRange*)range {
  auto* region = [self selectionRegion];
  // The following should instead use |range| rather than assuming
  // GetSelectionRegion. Consider this proof-of-concept only.
  if (!region || !region->focus.HasHandle() ||
      region->focus.type() == gfx::SelectionBound::CENTER) {
    return @[];
  }

  UITextSelectionRect* start = [[BETextSelectionHandles alloc]
      initWithCGRect:CGRectMake(region->focus.edge_start_rounded().x(),
                                region->focus.edge_start_rounded().y(), 1,
                                region->focus.GetHeight())
             atStart:region->focus.type() == gfx::SelectionBound::RIGHT];
  UITextSelectionRect* end = [[BETextSelectionHandles alloc]
      initWithCGRect:CGRectMake(region->anchor.edge_start_rounded().x(),
                                region->anchor.edge_start_rounded().y(), 1,
                                region->anchor.GetHeight())
             atStart:region->anchor.type() == gfx::SelectionBound::RIGHT];
  return @[ start, end ];
}

#pragma mark - Hit testing

- (nullable UITextPosition*)closestPositionToPoint:(CGPoint)point {
  CGFloat height = 20;
  if (auto bounds = [self textControlBounds]) {
    point.x = std::clamp<CGFloat>(point.x, bounds->x(), bounds->right());
    point.y = std::clamp<CGFloat>(point.y, bounds->y(), bounds->bottom());
    height = std::max<CGFloat>(1, std::min<CGFloat>(bounds->height(), 44));
  }
  return [[BETextPosition alloc]
      initWithRect:CGRectMake(point.x, point.y - height / 2, 1, height)];
}

- (nullable UITextPosition*)closestPositionToPoint:(CGPoint)point
                                       withinRange:(UITextRange*)range {
  return [self closestPositionToPoint:point];
}

- (nullable UITextRange*)characterRangeAtPoint:(CGPoint)point {
  UITextPosition* position = [self closestPositionToPoint:point];
  return [self textRangeFromPosition:position toPosition:position];
}

- (NSArray*)accessibilityElements {
  ui::BrowserAccessibilityManager* manager =
      _view->host()->GetRootBrowserAccessibilityManager();
  if (manager) {
    id root =
        manager->GetBrowserAccessibilityRoot()->GetNativeViewAccessible().Get();
    if (root) {
      return @[ root ];
    }
  }
  return nil;
}

- (const std::optional<gfx::Rect>)textControlBounds {
  if (!_view || !_view->GetTextInputManager()) {
    return std::nullopt;
  }
  return _view->GetTextInputManager()->GetTextControlBounds();
}

- (const content::TextInputManager::SelectionRegion*)selectionRegion {
  if (!_view || !_view->GetTextInputManager()) {
    return nil;
  }
  return _view->GetTextInputManager()->GetSelectionRegion(_view.get());
}

- (const content::TextInputManager::TextSelection*)textSelection {
  if (!_view || !_view->GetTextInputManager()) {
    return nil;
  }
  return _view->GetTextInputManager()->GetTextSelection(_view.get());
}

- (const ui::mojom::TextInputState*)editState {
  if (!_view || !_view->GetTextInputManager()) {
    return nil;
  }
  return _view->GetTextInputManager()->GetTextInputState();
}

- (NSString*)editText {
  const ui::mojom::TextInputState* state = [self editState];
  if (state && state->value.has_value()) {
    const unichar* pchars = (const unichar*)state->value->c_str();
    NSString* result = [NSString stringWithCharacters:pchars
                                               length:state->value->size()];
    return result;
  } else {
    return @"";
  }
}

- (BOOL)isAccessibilityElement {
  return NO;
}

- (CGRect)firstRectForRange:(UITextRange*)range {
  return CGRectZero;
}

- (void)onUpdateTextInputState:(const ui::mojom::TextInputState&)state
                    withBounds:(CGRect)bounds {
  const BOOL traitsChanged =
      [_extendedTextInputTraits updateFromTextInputState:state];
  if (traitsChanged && self.isFirstResponder) {
    // Below 17.4 UIKit caches the traits it read when the keyboard came up, so
    // moving between fields with different traits (a text field to a password
    // or number field, say) needs an explicit reload to re-query them.
    if (@available(iOS 17.4, *)) {
    } else {
      [self reloadInputViews];
    }
  }
  const bool editable = state.type != ui::TextInputType::TEXT_INPUT_TYPE_NONE;
  if (editable) {
    [self rememberFocusedRectIfPlausible:bounds];
  }
  _previousAccessoryButton.enabled =
      (state.flags & ui::TEXT_INPUT_FLAG_HAVE_PREVIOUS_FOCUSABLE_ELEMENT) != 0;
  _nextAccessoryButton.enabled =
      (state.flags & ui::TEXT_INPUT_FLAG_HAVE_NEXT_FOCUSABLE_ELEMENT) != 0;

  // Check for the visibility request and policy if VK APIs are enabled.
  if (state.vk_policy == ui::mojom::VirtualKeyboardPolicy::MANUAL) {
    // policy is manual.
    if (state.last_vk_visibility_request ==
        ui::mojom::VirtualKeyboardVisibilityRequest::SHOW) {
      [self showKeyboard:(state.value && !state.value->empty())
              withBounds:bounds];
    } else if (state.last_vk_visibility_request ==
               ui::mojom::VirtualKeyboardVisibilityRequest::HIDE) {
      [self hideKeyboard];
    }
  } else {
    bool hide = state.always_hide_ime ||
                state.mode == ui::TextInputMode::TEXT_INPUT_MODE_NONE ||
                state.type == ui::TextInputType::TEXT_INPUT_TYPE_NONE;
    if (hide) {
      [self hideKeyboard];
    } else if (state.show_ime_if_needed) {
      [self showKeyboard:(state.value && !state.value->empty())
              withBounds:bounds];
    }
  }
}

- (void)handlePreviousAccessoryAction {
  CHECK(_view);
  _view->AdvanceFocusForIME(blink::mojom::FocusType::kBackward);
}

- (void)handleNextAccessoryAction {
  CHECK(_view);
  _view->AdvanceFocusForIME(blink::mojom::FocusType::kForward);
}

// One-shot recovery if only the accessory bar appeared (no real keyboard body).
- (void)attemptAccessoryOnlyRecovery {
  if (!g_enable_keyboard_recovery) {
    return;
  }
  if (g_keyboard_recovery_used) {
    return;
  }
  if (g_last_keyboard_height > kRealKeyboardMinHeight) {
    return;  // a real keyboard did present; nothing to recover.
  }
  // A connected hardware keyboard intentionally has no software-keyboard
  // body. Treating that as an accessory-only failure resigns the renderer
  // roughly half a second after focus, so typing stops until the field is
  // tapped again. iPad is the primary hardware-keyboard form factor; a seen
  // UIPress also covers external keyboards on phones.
  if ([self isFirstResponder] &&
      (g_hardware_keyboard_seen ||
       UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)) {
    g_keyboard_state = BlinkKeyboardVisible;
    g_keyboard_owner = self;
    BlinkSetKeyboardViewportInset(0);

    return;
  }
  g_keyboard_recovery_used = YES;
  g_keyboard_body_retry_in_progress = YES;

  // End the incomplete presentation. keyboardDidHide starts the retry after
  // UIKit has torn down the old input session.
  g_keyboard_state = BlinkKeyboardDismissing;
  [self resignFirstResponder];
  // Fallback for keyboard implementations that omit didHide.
  [self performSelector:@selector(retryKeyboardAfterAccessoryOnlyFailure)
             withObject:nil
             afterDelay:0.65];
}

- (void)retryKeyboardAfterAccessoryOnlyFailure {
  g_keyboard_state = BlinkKeyboardPresenting;
  // Own synchronous UIKit notifications emitted by becomeFirstResponder.
  g_keyboard_owner = self;
  [self setIsEditable:YES];
  BOOL result = [self becomeFirstResponder];
  [self reloadInputViews];
  [self setIsEditable:result || [self isFirstResponder]];
  if (!(result || [self isFirstResponder])) {
    g_keyboard_owner = nil;
    g_keyboard_state = BlinkKeyboardHidden;
  }
  [self performSelector:@selector(finishAccessoryOnlyRecovery)
             withObject:nil
             afterDelay:0.50];
}

- (void)finishAccessoryOnlyRecovery {
  if (g_last_keyboard_height > kRealKeyboardMinHeight) {
    g_keyboard_body_retry_in_progress = NO;

  } else {
    g_keyboard_body_retry_in_progress = NO;

    // Do not leave the global session stuck in Presenting. Hide the orphaned
    // accessory view and let the next explicit tap start a clean session.
    g_keyboard_state = BlinkKeyboardDismissing;
    [self resignFirstResponder];
    [self setIsEditable:NO];
  }
}

- (void)showKeyboard:(bool)has_text withBounds:(CGRect)bounds {
  // The renderer view is the page surface, not the focused DOM element.
  // Reframing it to Blink's text-state bounds moves or shrinks the whole page.
  [self rememberFocusedRectIfPlausible:bounds];
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (g_touch_sequence_moved || now - g_last_scroll_touch_end < 0.30) {
    [self setIsEditable:NO];

    return;
  }
  if (![self isFirstResponder] &&
      (CGRectIsEmpty(bounds) || bounds.size.width < 2 ||
       bounds.size.height < 2)) {
    [self setIsEditable:NO];
    return;
  }

  // After the user dismissed the keyboard (Done/checkmark), suppress the
  // renderer's automatic refocus for a short cooldown so it doesn't pop
  // straight back up. This ONLY affects renderer-driven refocus; an explicit
  // user tap (touchesBegan) clears the flag, and initial presentation is always
  // allowed.
  if (g_keyboard_user_dismissed &&
      now - g_keyboard_dismiss_time < kKeyboardDismissCooldown) {
    return;
  }
  if (g_keyboard_user_dismissed) {
    g_keyboard_user_dismissed = NO;
  }

  // /C: if we're already first responder, the keyboard is up for this
  // editable. Committed/marked text and selection changes must NOT re-present
  // it (that triggered the bogus iOS height=0 event that snapped the page
  // down). Just refresh relocation against the known keyboard height.
  const BOOL ownsKeyboard = g_keyboard_owner == self;
  if ([self isFirstResponder] ||
      (ownsKeyboard && (g_keyboard_state == BlinkKeyboardPresenting ||
                        g_keyboard_state == BlinkKeyboardVisible))) {
    [self refreshRelocationAfterTextCommit];
    [self setIsEditable:YES];
    return;
  }
  // Not first responder yet → a new editable focus. Present once.
  [self presentKeyboardForNewFocusSession];
}

// The one place that actually presents the keyboard (new editable focus
// or explicit tap). Starts a fresh focus session (resets the cached ratio).
- (void)presentKeyboardForNewFocusSession {
  if (g_keyboard_owner && g_keyboard_owner != self) {
    RenderWidgetUIView* previousOwner = g_keyboard_owner;
    [previousOwner resignFirstResponder];
    [previousOwner setIsEditable:NO];
    [previousOwner resetFocusedInputRelocation];
    g_keyboard_owner = nil;
    g_keyboard_state = BlinkKeyboardHidden;
    g_last_keyboard_height = 0;
    g_pending_keyboard_height = 0;
  }
  ++g_focus_session_id;
  g_cached_bottom_ratio = -1.0f;
  g_cached_ratio_source = BlinkRatioNone;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (applyDeferredChatFallback)
                                             object:nil];
  g_keyboard_state = BlinkKeyboardPresenting;
  g_keyboard_recovery_used = NO;
  g_keyboard_body_retry_in_progress = NO;
  // Claim ownership before UIKit emits any synchronous keyboard notification.
  g_keyboard_owner = self;
  // UIKit queries UITextInput synchronously during becomeFirstResponder. Mark
  // the renderer editable first so the initial input session contains the real
  // keyboard body instead of requiring a resign/retry cycle.
  [self setIsEditable:YES];
  BOOL result = [self becomeFirstResponder];
  if (!(result || [self isFirstResponder])) {
    g_keyboard_owner = nil;
    g_keyboard_state = BlinkKeyboardHidden;
    [self setIsEditable:NO];
  }
  [self reloadInputViews];
  [self setIsEditable:result || [self isFirstResponder]];
  if (g_enable_keyboard_recovery) {
    [self performSelector:@selector(attemptAccessoryOnlyRecovery)
               withObject:nil
               afterDelay:0.45];
  }
}

- (void)userDismissKeyboard {
  // The Done/checkmark accessory button: a user-initiated dismiss. Arm the
  // cooldown BEFORE resigning so the renderer's follow-up focus is suppressed.
  g_keyboard_user_dismissed = YES;
  g_keyboard_dismiss_time = [NSDate timeIntervalSinceReferenceDate];

  [self hideKeyboard];
}

- (void)hideKeyboard {
  g_keyboard_state = BlinkKeyboardDismissing;
  [self resignFirstResponder];
  [self reloadInputViews];
  [self setIsEditable:NO];
}

@end
#pragma clang diagnostic pop
