// Copyright 2024 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/browser/renderer_host/render_widget_host_view_ios_uiview.h"

#include <math.h>
#include <stdio.h>

#include <algorithm>

#include "base/apple/foundation_util.h"
#include "base/strings/sys_string_conversions.h"
#include "content/browser/renderer_host/blinker_selection_geometry.h"
#import "content/browser/renderer_host/blinker_selection_overlay.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/input/web_input_event_builders_ios.h"
#include "components/strings/grit/components_strings.h"
#include "content/browser/renderer_host/ios_extended_text_input_traits.h"
#include "ui/accessibility/platform/browser_accessibility_manager.h"
#include "ui/base/ime/text_input_flags.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/base_event_utils.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/dom/keycode_converter.h"
#include "ui/events/keycodes/keyboard_code_conversion.h"
#include "ui/gfx/geometry/point_conversions.h"

extern "C" float BlinkKeyboardChatFallbackRatio();
extern "C" int BlinkIsChatKeyboardRelocationSite();
extern "C" void BlinkSetKeyboardViewportInset(float inset);
extern "C" void BlinkSetKeyboardAnimation(double duration, int curve);
extern "C" void BlinkSearchSelectedText(const char* utf8);

// нижче iOS 16 меню питає першого відповідача, а це цей view
extern "C" int BlinkerExtensionMenuSlotCount();
extern "C" void BlinkerExtensionMenuSlotActivate(int index);
extern "C" void BlinkerTraceSelection(const char* event);

static const SEL kBlinkerExtensionItemSelectors[8] = {
    @selector(blinkerExtensionItem0:), @selector(blinkerExtensionItem1:),
    @selector(blinkerExtensionItem2:), @selector(blinkerExtensionItem3:),
    @selector(blinkerExtensionItem4:), @selector(blinkerExtensionItem5:),
    @selector(blinkerExtensionItem6:), @selector(blinkerExtensionItem7:)};
static void* kObservingContext = &kObservingContext;
static CGFloat g_keyboard_bottom_inset = 0;
static CGFloat g_pending_keyboard_height = 0;
static CGFloat g_last_keyboard_height = 0;
static NSTimeInterval g_last_keyboard_notification_time = 0;
static CGRect g_last_focused_editable_rect = CGRectZero;
static BOOL g_has_plausible_focused_rect = NO;
// пауза після закриття клавіатури користувачем, щоб рендерер не відкрив її
// знову
static BOOL g_keyboard_user_dismissed = NO;
static NSTimeInterval g_keyboard_dismiss_time = 0;
static const NSTimeInterval kKeyboardDismissCooldown = 0.35;
// справжня клавіатура вища за accessory bar, якщо зявився лиш bar то це збій
static const CGFloat kRealKeyboardMinHeight = 150;
static BOOL g_keyboard_recovery_used = NO;
static BOOL g_keyboard_body_retry_in_progress = NO;
static BOOL g_hardware_keyboard_seen = NO;
// на iOS 15 сесія вводу інколи показує лише accessory смужку
static BOOL g_enable_keyboard_recovery = YES;
static BOOL g_touch_sequence_active = NO;
static BOOL g_touch_sequence_moved = NO;
static CGPoint g_touch_sequence_origin = CGPointZero;
static NSTimeInterval g_last_scroll_touch_end = 0;

// без цього після вводу iOS шле хибний didShow з height=0
// і сторінка знову падає під клавіатуру
typedef NS_ENUM(int, BlinkKeyboardState) {
  BlinkKeyboardHidden = 0,
  BlinkKeyboardPresenting,
  BlinkKeyboardVisible,
  BlinkKeyboardDismissing,
};
static BlinkKeyboardState g_keyboard_state = BlinkKeyboardHidden;
static CGFloat g_current_relocation_offset = 0;
// тримаємо той view що реально показав клавіатуру, щоб старий рендерер
// не зняв чужий зсув
static __weak RenderWidgetUIView* g_keyboard_owner = nil;
// view, чию клавіатуру сховала система (аркуш Passwords, запит коду) при полі
// у фокусі. Коли iOS її повертає, view має знову стати editable, інакше
// порожній inputView ховає її одразу
static __weak RenderWidgetUIView* g_system_hidden_owner = nil;
// поки триває передача фокуса допоміжному полю, рендерер про неї не знає, а
// сповіщення клавіатури, що йдуть слідом, ігноруються
static BOOL g_input_session_handoff = NO;
static CFTimeInterval g_input_session_handoff_deadline = 0;
static float g_cached_bottom_ratio = -1.0f;
typedef NS_ENUM(int, BlinkRatioSource) {
  BlinkRatioNone = 0,
  BlinkRatioFallback,
  BlinkRatioCaret,
  BlinkRatioDom,
};
static BlinkRatioSource g_cached_ratio_source = BlinkRatioNone;
static int g_focus_session_id = 0;
static BOOL g_dom_ratio_query_in_flight = NO;
static NSTimeInterval g_last_dom_query_time = 0;
static int g_keyboard_relocate_strategy = 2;

namespace {
NSString* const kPreviousAccessoryImageName = @"chevron.up";
NSString* const kNextAccessoryImageName = @"chevron.down";
NSString* const kDoneAccessoryImageName = @"checkmark";

namespace selection_geometry = content::blinker_selection;

// Blink розпізнає довге натискання за пів секунди, раніші зміни мають іншу
// причину
constexpr NSTimeInterval kLongPressSelectionMinDelay = 0.25;

selection_geometry::Point GeometryPoint(CGPoint point) {
  return {static_cast<float>(point.x), static_cast<float>(point.y)};
}

selection_geometry::Bound GeometryBound(const gfx::SelectionBound& bound) {
  return {{bound.edge_start().x(), bound.edge_start().y()},
          {bound.edge_end().x(), bound.edge_end().y()}};
}

gfx::Point GfxPoint(selection_geometry::Point point) {
  return gfx::ToRoundedPoint(gfx::PointF(point.x, point.y));
}

}  // namespace

// меню в shell питає це, щоб не показати запізніле меню посеред перетягування
static BOOL g_selection_drag_active = NO;
extern "C" bool BlinkerSelectionDragActive() {
  return g_selection_drag_active;
}

#pragma mark - BETextPosition
@interface BETextPosition : UITextPosition {
  CGRect rect_;
}
- (instancetype)initWithRect:(CGRect)rect;
- (CGRect)rect;

@end

@implementation BETextPosition
- (instancetype)initWithRect:(CGRect)rect {
  if ((self = [super init])) {
    rect_ = rect;
  }
  return self;
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
  if ((self = [super init])) {
    const auto& start =
        region->is_anchor_first ? region->anchor : region->focus;
    const auto& end = region->is_anchor_first ? region->focus : region->anchor;
    start_ = CGRectMake(start.edge_start_rounded().x(),
                        start.edge_start_rounded().y(), 1, start.GetHeight());
    end_ = CGRectMake(end.edge_start_rounded().x(),
                      end.edge_start_rounded().y(), 1, end.GetHeight());
  }
  return self;
}

- (instancetype)initWithStart:(BETextPosition*)start end:(BETextPosition*)end {
  if ((self = [super init])) {
    start_ = [start rect];
    end_ = [end rect];
  }
  return self;
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
- (instancetype)initWithCGRect:(CGRect)rect
                       atStart:(BOOL)start
                     direction:(base::i18n::TextDirection)direction;
@end
@implementation BETextSelectionHandles {
  CGRect rect_;
  BOOL start_;
  NSWritingDirection direction_;
}
- (instancetype)initWithCGRect:(CGRect)rect
                       atStart:(BOOL)start
                     direction:(base::i18n::TextDirection)direction {
  if ((self = [super init])) {
    rect_ = rect;
    start_ = start;
    switch (direction) {
      case base::i18n::LEFT_TO_RIGHT:
        direction_ = NSWritingDirectionLeftToRight;
        break;
      case base::i18n::RIGHT_TO_LEFT:
        direction_ = NSWritingDirectionRightToLeft;
        break;
      case base::i18n::UNKNOWN_DIRECTION:
        direction_ = NSWritingDirectionNatural;
        break;
    }
  }
  return self;
}
- (NSWritingDirection)writingDirection {
  return direction_;
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
- (BOOL)isVertical {
  return NO;
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
  if ((self = [super init])) {
    rect_ = rect;
  }
  return self;
}
- (CGRect)rect {
  return rect_;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@interface RenderWidgetUIView (BlinkerSelection)
- (int)blinkHandleAtPoint:(CGPoint)point;
- (BOOL)blinkHasActiveTextInput;
- (BOOL)blinkHasFocusedEditable;
- (nullable NSString*)blinkTextBeforeCaret;
- (BOOL)blinkIsAtSentenceStartAfter:(NSString*)text;
- (UITextAutocapitalizationType)blinkEffectiveAutocapForState:
    (const ui::mojom::TextInputState&)state;
- (void)blinkCommitPastedText:(NSString*)text attempt:(int)attempt;
- (CGRect)blinkRectForBound:(const gfx::SelectionBound&)bound;
- (BOOL)blinkDrawsOwnHandles;
- (BOOL)blinkRegionHasRange:
    (const content::TextInputManager::SelectionRegion*)region;
- (BOOL)blinkOrderedBoundsFromRegion:
            (const content::TextInputManager::SelectionRegion*)region
                               start:(selection_geometry::Bound*)start
                                 end:(selection_geometry::Bound*)end;
- (BOOL)blinkBeginHandleDragWithTouch:(UITouch*)touch atPoint:(CGPoint)point;
- (BOOL)blinkStartSelectionDrag:(int)handle
                          touch:(UITouch*)touch
                        atPoint:(CGPoint)point;
- (CGPoint)blinkSelectionDragExtent;
- (void)blinkApplySelectionDragExtent;
- (void)blinkUpdateSelectionDragToPoint:(CGPoint)point;
- (void)blinkEndSelectionDragShowingMenu:(BOOL)showMenu;
- (void)blinkUpdateSelectionLoupe;
- (void)blinkUpdateSelectionAutoscroll;
- (void)blinkSelectionAutoscrollTick;
- (void)blinkStopSelectionAutoscroll;
- (void)blinkDismissEditMenus;
- (void)blinkShowSelectionMenu;
- (CGRect)blinkSelectionBoundingRect;
- (void)blinkNoteLongPressSelection:(BOOL)hasRange;
- (BOOL)blinkContinueLongPressSelection:(UITouch*)touch
                              withEvent:(UIEvent*)event;
- (void)blinkCancelTouchInRenderer:(UITouch*)touch withEvent:(UIEvent*)event;
- (CGRect)blinkCaretRect;
- (void)updateLegacyTextInteraction;
@end

@implementation RenderWidgetUIView
@synthesize tokenizer;

- (instancetype)initWithWidget:
    (base::WeakPtr<content::RenderWidgetHostViewIOS>)view {
  self = [self init];
  if (self) {
    _view = view;
    _extendedTextInputTraits = [[IOSExtendedTextInputTraits alloc] init];
    _blinkAppliedAutocap = -1;
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
    [self updateLegacyTextInteraction];
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
    // хибний rect на весь viewport (напр. 390x715), тоді тільки нижній відступ
    // без прокрутки сторінки

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
    return;
  }
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

- (void)queryDomFocusedInputRatio {
  if (!_view) {
    return;
  }
  if (g_dom_ratio_query_in_flight) {
    return;
  }
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
    return;
  }
  g_cached_bottom_ratio = ratio;
  g_cached_ratio_source = BlinkRatioDom;

  if (g_last_keyboard_height > kRealKeyboardMinHeight &&
      g_keyboard_state == BlinkKeyboardVisible) {
    [self relocateFocusedInputAboveKeyboard:g_last_keyboard_height];
  }
}

- (void)applyDeferredChatFallback {
  if (g_keyboard_state != BlinkKeyboardVisible &&
      g_keyboard_state != BlinkKeyboardPresenting) {
    return;
  }
  if (g_cached_ratio_source >= BlinkRatioCaret) {
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

- (void)relocateFocusedInputAboveKeyboard:(CGFloat)keyboardHeight {
  const CGFloat contentHeight = self.bounds.size.height;
  if (contentHeight <= 1) {
    return;
  }
  const CGFloat keyboardOverlap = keyboardHeight;
  BOOL usingFallback = NO;
  float ratio = -1.0f;
  const float caretRatio = _view ? _view->GetFocusedInputBottomRatio() : -1.0f;
  if (g_cached_ratio_source == BlinkRatioDom) {
    // поле з DOM важливіше за каретку, під рядком каретки ще кнопки
    ratio = g_cached_bottom_ratio;
    if (caretRatio > ratio + 0.02f) {
      ratio = caretRatio;

      [self queryDomFocusedInputRatio];
    }

  } else if (caretRatio >= 0.0f) {
    ratio = caretRatio;
    g_cached_bottom_ratio = caretRatio;
    g_cached_ratio_source = BlinkRatioCaret;

    [self queryDomFocusedInputRatio];
  } else if (g_cached_ratio_source != BlinkRatioNone &&
             g_cached_bottom_ratio >= 0.0f) {
    ratio = g_cached_bottom_ratio;
    usingFallback = (g_cached_ratio_source == BlinkRatioFallback);
    if (usingFallback) {
      [self queryDomFocusedInputRatio];
    }
  } else {
    [self queryDomFocusedInputRatio];
    const float fallback = BlinkKeyboardChatFallbackRatio();
    if (fallback > 0.0f) {
      // грубу оцінку 0.92 відкладаємо, бо на сторінках з полем не внизу
      // вона виштовхувала поле вгору

      [NSObject cancelPreviousPerformRequestsWithTarget:self
                                               selector:@selector
                                               (applyDeferredChatFallback)
                                                 object:nil];
      [self performSelector:@selector(applyDeferredChatFallback)
                 withObject:nil
                 afterDelay:0.25];
      return;
    } else {
      if (g_keyboard_state == BlinkKeyboardVisible &&
          g_current_relocation_offset > 0) {
        return;
      }

      return;
    }
  }
  if (keyboardOverlap <= 0) {
    return;
  }
  const CGFloat clearance = 12;
  const CGFloat focusBottom = contentHeight * ratio;
  const CGFloat visibleBottom = contentHeight - keyboardOverlap - clearance;
  CGFloat offset =
      MIN(keyboardOverlap, MAX((CGFloat)0, focusBottom - visibleBottom));

  // каретка описує рядок вставки а не все поле, тримаємо найбільший зсув сеансу
  if (g_keyboard_state == BlinkKeyboardVisible &&
      offset < g_current_relocation_offset) {
    offset = g_current_relocation_offset;
  }

  [self applyRelocationOffset:offset];
}

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
  if (g_cached_ratio_source == BlinkRatioFallback) {
    g_cached_ratio_source = BlinkRatioNone;
    g_cached_bottom_ratio = -1.0f;
  }
  BOOL changed = NO;
  if (!CGAffineTransformIsIdentity(self.transform)) {
    self.transform = CGAffineTransformIdentity;
    changed = YES;
  }
  UIView* container = [self superview];
  if (container && !CGAffineTransformIsIdentity(container.transform)) {
    container.transform = CGAffineTransformIdentity;
    changed = YES;
  }
  if (changed) {
  }
  BlinkSetKeyboardViewportInset(0);
}

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
  // нульова висота при видимій клавіатурі це хибна подія iOS після
  // reloadInputViews
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

  [self relocateFocusedInputAboveKeyboard:height];
}

- (void)coalesceKeyboardNotification:(NSNotification*)notification {
  // сповіщення клавіатури йдуть на весь процес, міняти стан може лиш перший
  // відповідач
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
  NSDictionary* info = notification.userInfo;
  BlinkSetKeyboardAnimation(
      [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue],
      [info[UIKeyboardAnimationCurveUserInfoKey] intValue]);

  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (applyPendingKeyboardFrame)
                                             object:nil];
  // наступний цикл, а не пів десятої секунди, щоб вміст не відставав від
  // клавіатури
  [self performSelector:@selector(applyPendingKeyboardFrame)
             withObject:nil
             afterDelay:0];
}

- (void)keyboardWillShow:(NSNotification*)notification {
  [self reclaimKeyboardAfterSystemHide];
  [self coalesceKeyboardNotification:notification];
}

- (void)reclaimKeyboardAfterSystemHide {
  if (g_system_hidden_owner != self) {
    return;
  }
  g_system_hidden_owner = nil;
  if (_isEditable || ![self isFirstResponder] || !self.window.isKeyWindow ||
      ![self blinkHasFocusedEditable]) {
    return;
  }
  [self presentKeyboardForNewFocusSession];
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
  if (CACurrentMediaTime() < g_input_session_handoff_deadline) {
    return;
  }
  BlinkSetKeyboardAnimation(
      [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey]
          doubleValue],
      [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] intValue]);

  if (g_keyboard_state == BlinkKeyboardPresenting &&
      !g_keyboard_user_dismissed && g_keyboard_owner &&
      [g_keyboard_owner isFirstResponder]) {
    return;
  }
  // власне приховування знімає _isEditable ще до цього сповіщення, тож
  // editable перший відповідач з полем у фокусі втратив клавіатуру через систему
  if (_isEditable && [self isFirstResponder] && [self blinkHasFocusedEditable]) {
    g_system_hidden_owner = self;
  } else if (g_system_hidden_owner == self) {
    g_system_hidden_owner = nil;
  }
  // кнопка клавіатури, твіки і дотик поза полем не кличуть userDismissKeyboard,
  // тому приховування з видимого стану рахуємо закриттям користувачем
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
  if (CACurrentMediaTime() < g_input_session_handoff_deadline) {
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
    // чекаємо поки UIKit закінчить сесію лише з accessory, повтор до didHide
    // змагається зі старою сесією і дає ще одну смужку
    [self performSelector:@selector(retryKeyboardAfterAccessoryOnlyFailure)
               withObject:nil
               afterDelay:0.05];
  }
  // деякі твіки докручують свою анімацію після willHide,
  // тому відступ нуль ставимо ще раз
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        BlinkSetKeyboardViewportInset(0);
      });
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (!self.window) {
    [self blinkEndSelectionDragShowingMenu:NO];
  }
}

- (void)layoutSubviews {
  CHECK(_view);
  [super layoutSubviews];
  _view->UpdateScreenInfo();

  // TODO(dtapuska) тут не правильно, треба визначати коли вікно отримує чи
  // втрачає фокус
  _view->SetActive(true);
}

- (UIView*)inputAccessoryView {
  return _isEditable ? _inputAccessoryContainerView : nil;
}

- (UIView*)inputView {
  if (_isEditable) {
    return nil;
  }
  static UIView* emptyInputView = [[UIView alloc] initWithFrame:CGRectZero];
  return emptyInputView;
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
  // вхід може перенести рендерер у нове UIWindow, а key лишається старе
  // UIKit не показує input view поза key вікном
  if (self.window && !self.window.isKeyWindow) {
    [self.window makeKeyWindow];
  }
  BOOL result = [super becomeFirstResponder];
  if (!g_input_session_handoff &&
      (result || _view->CanBecomeFirstResponderForTesting())) {
    _view->OnFirstResponderChanged();
  }
  return result;
}

- (BOOL)resignFirstResponder {
  BOOL result = [super resignFirstResponder];
  if (!g_input_session_handoff && _view &&
      (result || _view->CanResignFirstResponderForTesting())) {
    _view->OnFirstResponderChanged();
  }
  return result;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  if (!_isEditable && ![self isFirstResponder] && self.window.isKeyWindow) {
    [self becomeFirstResponder];
  }
  if (_draggingHandle) {
    const UITouchPhase phase = _handleDragTouch.phase;
    if ([event.allTouches containsObject:_handleDragTouch] &&
        phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled) {
      // поки один палець тягне межу, інші дотики не йдуть ні в Blink ні в
      // перетягування
      return;
    }
    // UIKit не завершив дотик перетягування (view зняли з вікна посеред руху)
    // без цього наступні дотики ігнорувались би
    [self blinkEndSelectionDragShowingMenu:NO];
  }
  if (event.allTouches.count == touches.count) {
    [_cancelledTouches removeAllObjects];
  }
  UITouch* firstTouch = touches.anyObject;
  g_touch_sequence_active = firstTouch != nil;
  g_touch_sequence_moved = NO;
  _longPressSelectionPending = NO;
  if (firstTouch) {
    g_touch_sequence_origin = [firstTouch locationInView:self];
    _touchSequenceStartTime = [NSDate timeIntervalSinceReferenceDate];
    const content::TextInputManager::TextSelection* selection =
        [self textSelection];
    _selectedTextAtTouchStart =
        selection ? selection->selected_text() : std::u16string();
    // дотик на маркері міняє виділення і в Blink не йде, інакше сторінка поїде
    if (touches.count == 1 && event.allTouches.count == 1 &&
        [self blinkBeginHandleDragWithTouch:firstTouch
                                    atPoint:g_touch_sequence_origin]) {
      return;
    }
  }
  // editState описує поле у фокусі рендерера, а не місце дотику
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
  if (_draggingHandle) {
    if ([touches containsObject:_handleDragTouch]) {
      [self blinkEndSelectionDragShowingMenu:YES];
      g_touch_sequence_active = NO;
      g_touch_sequence_moved = NO;
    }
    return;
  }
  _longPressSelectionPending = NO;
  for (UITouch* touch in touches) {
    if ([_cancelledTouches containsObject:touch]) {
      continue;
    }
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchEnd, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
  if (event.allTouches.count == 1) {
    _viewOffsetDuringTouchSequence.reset();
  }
  if (g_touch_sequence_moved) {
    g_last_scroll_touch_end = [NSDate timeIntervalSinceReferenceDate];
  }
  g_touch_sequence_active = NO;
  g_touch_sequence_moved = NO;
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  if (_draggingHandle) {
    if ([touches containsObject:_handleDragTouch]) {
      [self blinkUpdateSelectionDragToPoint:[_handleDragTouch
                                                locationInView:self]];
    }
    return;
  }
  if (_longPressSelectionPending && touches.count == 1 &&
      event.allTouches.count == 1 &&
      [self blinkContinueLongPressSelection:touches.anyObject
                                  withEvent:event]) {
    return;
  }
  for (UITouch* touch in touches) {
    if ([_cancelledTouches containsObject:touch]) {
      continue;
    }
    CGPoint point = [touch locationInView:self];
    // тільки позначка що дотик став перетягуванням, 8pt це звичайне тремтіння
    // і клавіатура лишається
    if (hypot(point.x - g_touch_sequence_origin.x,
              point.y - g_touch_sequence_origin.y) > 8) {
      g_touch_sequence_moved = YES;
    }
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchMove, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  CHECK(_view);
  if (_draggingHandle) {
    if ([touches containsObject:_handleDragTouch]) {
      [self blinkEndSelectionDragShowingMenu:NO];
      g_touch_sequence_active = NO;
      g_touch_sequence_moved = NO;
    }
    return;
  }
  _longPressSelectionPending = NO;
  // одна подія на весь жест, решту точок збирач сам позначає скасованими
  if (UITouch* touch = touches.anyObject) {
    _view->OnTouchEvent(input::WebTouchEventBuilder::Build(
        blink::WebInputEvent::Type::kTouchCancel, touch, event, self,
        _viewOffsetDuringTouchSequence));
  }
  if (!_cancelledTouches) {
    _cancelledTouches = [NSHashTable weakObjectsHashTable];
  }
  for (UITouch* touch in event.allTouches) {
    [_cancelledTouches addObject:touch];
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

- (CGFloat)keyboardHeight {
  return _keyboardHeight;
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
  if ([self isFirstResponder]) {
    [self reloadInputViews];
  }
  if (!isEditable) {
    // відступ скидає лише keyboardWillHide, а його нема коли клавіатура
    // зникає інакше, наприклад у fullscreen
    BlinkSetKeyboardViewportInset(0);
  }
  return YES;
}

- (void)updateLegacyTextInteraction {
  if (!@available(iOS 13.0, *)) {
    return;
  }
  if (@available(iOS 17.4, *)) {
    return;
  }
  // нередагована UITextInteraction не малює маркерів до iOS 17,
  // тому маркери тексту сторінки малює BlinkerSelectionOverlay
  const BOOL wanted = _isEditable;
  if (wanted == (_legacyTextInteraction != nil)) {
    return;
  }
  if (wanted) {
    _legacyTextInteractionMode = UITextInteractionModeEditable;
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

- (BOOL)interactionShouldBegin:(UITextInteraction*)interaction
                       atPoint:(CGPoint)point {
  if (CGRectIsEmpty(g_last_focused_editable_rect)) {
    return NO;
  }
  if ([self blinkHandleAtPoint:point] != 0) {
    return NO;
  }
  const CGFloat slop = 16;
  return CGRectContainsPoint(
      CGRectInset(g_last_focused_editable_rect, -slop, -slop), point);
}

- (BOOL)blinkDrawsOwnHandles {
  if (@available(iOS 17.4, *)) {
    return NO;
  }
  return YES;
}

- (BOOL)blinkRegionHasRange:
    (const content::TextInputManager::SelectionRegion*)region {
  return region && region->focus.edge_start() != region->anchor.edge_start() &&
         region->focus.GetHeight() > 0 && region->anchor.GetHeight() > 0;
}

- (BOOL)blinkOrderedBoundsFromRegion:
            (const content::TextInputManager::SelectionRegion*)region
                               start:(selection_geometry::Bound*)start
                                 end:(selection_geometry::Bound*)end {
  const selection_geometry::Bound anchor = GeometryBound(region->anchor);
  const selection_geometry::Bound focus = GeometryBound(region->focus);
  *start = region->is_anchor_first ? anchor : focus;
  *end = region->is_anchor_first ? focus : anchor;
  return region->is_anchor_first;
}

- (int)blinkHandleAtPoint:(CGPoint)point {
  if (![self blinkDrawsOwnHandles]) {
    return 0;
  }
  auto* region = [self selectionRegion];
  if (![self blinkRegionHasRange:region]) {
    return 0;
  }
  selection_geometry::Bound start;
  selection_geometry::Bound end;
  [self blinkOrderedBoundsFromRegion:region start:&start end:&end];
  switch (selection_geometry::HandleAtPoint(start, end, GeometryPoint(point))) {
    case selection_geometry::Handle::kStart:
      return 1;
    case selection_geometry::Handle::kEnd:
      return 2;
    case selection_geometry::Handle::kNone:
      return 0;
  }
  return 0;
}

- (BOOL)blinkBeginHandleDragWithTouch:(UITouch*)touch atPoint:(CGPoint)point {
  const int handle = [self blinkHandleAtPoint:point];
  if (handle == 0) {
    return NO;
  }
  return [self blinkStartSelectionDrag:handle touch:touch atPoint:point];
}

- (BOOL)blinkStartSelectionDrag:(int)handle
                          touch:(UITouch*)touch
                        atPoint:(CGPoint)point {
  auto* region = [self selectionRegion];
  if (!_view || !_view->host()->delegate() ||
      ![self blinkRegionHasRange:region]) {
    return NO;
  }
  selection_geometry::Bound start;
  selection_geometry::Bound end;
  const BOOL anchorFirst = [self blinkOrderedBoundsFromRegion:region
                                                        start:&start
                                                          end:&end];
  const selection_geometry::Bound& dragged = handle == 1 ? start : end;
  const selection_geometry::Bound& fixed = handle == 1 ? end : start;
  // MoveRangeSelectionExtent рухає лише focus, тому при тягненні anchor
  // кінці спершу міняємо місцями
  if ((handle == 1) == static_cast<bool>(anchorFirst)) {
    _view->host()->delegate()->SelectRange(
        GfxPoint(selection_geometry::LinePoint(fixed)),
        GfxPoint(selection_geometry::LinePoint(dragged)));
  }
  const selection_geometry::Point offset = selection_geometry::DragOffset(
      GeometryPoint(point), selection_geometry::LinePoint(dragged));
  _handleDragOffset = CGPointMake(offset.x, offset.y);
  _handleDragLastTouch = point;
  _handleDragTouch = touch;
  _draggingHandle = handle;
  _longPressSelectionPending = NO;
  g_selection_drag_active = YES;
  BlinkerTraceSelection("drag-start");
  [self blinkDismissEditMenus];
  [self blinkUpdateSelectionLoupe];
  return YES;
}

- (CGPoint)blinkSelectionDragExtent {
  const selection_geometry::Point extent = selection_geometry::ApplyOffset(
      GeometryPoint(_handleDragLastTouch), GeometryPoint(_handleDragOffset));
  return CGPointMake(extent.x, extent.y);
}

- (void)blinkApplySelectionDragExtent {
  if (!_view || !_view->host()->delegate()) {
    return;
  }
  const CGPoint extent = [self blinkSelectionDragExtent];
  _view->host()->delegate()->MoveRangeSelectionExtent(
      gfx::ToRoundedPoint(gfx::PointF(extent.x, extent.y)));
}

- (void)blinkUpdateSelectionDragToPoint:(CGPoint)point {
  if (!_draggingHandle || !_view) {
    return;
  }
  _handleDragLastTouch = point;
  [self blinkDismissEditMenus];
  [self blinkApplySelectionDragExtent];
  [self blinkUpdateSelectionLoupe];
  [self blinkUpdateSelectionAutoscroll];
}

- (void)blinkEndSelectionDragShowingMenu:(BOOL)showMenu {
  if (!_draggingHandle) {
    return;
  }
  _draggingHandle = 0;
  _handleDragTouch = nil;
  g_selection_drag_active = NO;
  BlinkerTraceSelection(showMenu ? "drag-end" : "drag-cancel");
  [self blinkStopSelectionAutoscroll];
  [_selectionLoupe dismiss];
  if (showMenu) {
    [self blinkShowSelectionMenu];
  }
}

- (void)blinkUpdateSelectionLoupe {
  if (!_draggingHandle) {
    return;
  }
  auto* region = [self selectionRegion];
  CGRect caret = CGRectNull;
  if ([self blinkRegionHasRange:region]) {
    const CGPoint extent = [self blinkSelectionDragExtent];
    const CGRect anchor = [self blinkRectForBound:region->anchor];
    const CGRect focus = [self blinkRectForBound:region->focus];
    const CGFloat toAnchor = hypot(extent.x - CGRectGetMidX(anchor),
                                   extent.y - CGRectGetMidY(anchor));
    const CGFloat toFocus =
        hypot(extent.x - CGRectGetMidX(focus), extent.y - CGRectGetMidY(focus));
    caret = toAnchor < toFocus ? anchor : focus;
  }
  if (!_selectionLoupe) {
    _selectionLoupe = [[BlinkerTextLoupe alloc] initWithView:self];
  }
  [_selectionLoupe moveToTouch:_handleDragLastTouch caretRect:caret];
}

// біля краю Blink прокручує сам, але межу треба подавати знову,
// бо палець нерухомий і дотиків нема
- (void)blinkUpdateSelectionAutoscroll {
  if (!_view) {
    return;
  }
  const CGPoint extent = [self blinkSelectionDragExtent];
  const CGRect bounds = self.bounds;
  const selection_geometry::Rect view{static_cast<float>(bounds.origin.x),
                                      static_cast<float>(bounds.origin.y),
                                      static_cast<float>(bounds.size.width),
                                      static_cast<float>(bounds.size.height)};
  if (!selection_geometry::InAutoscrollBelt(GeometryPoint(extent), view)) {
    [self blinkStopSelectionAutoscroll];
    return;
  }
  _view->StartAutoscrollForSelectionToPoint(gfx::PointF(extent.x, extent.y));
  if (_selectionAutoscrollTimer) {
    return;
  }
  BlinkerTraceSelection("autoscroll-start");
  __weak RenderWidgetUIView* weakSelf = self;
  _selectionAutoscrollTimer = [NSTimer
      scheduledTimerWithTimeInterval:1.0 / 30.0
                             repeats:YES
                               block:^(NSTimer* timer) {
                                 [weakSelf blinkSelectionAutoscrollTick];
                               }];
}

- (void)blinkSelectionAutoscrollTick {
  if (!_draggingHandle || !_view) {
    [self blinkStopSelectionAutoscroll];
    return;
  }
  [self blinkApplySelectionDragExtent];
}

- (void)blinkStopSelectionAutoscroll {
  if (!_selectionAutoscrollTimer) {
    return;
  }
  [_selectionAutoscrollTimer invalidate];
  _selectionAutoscrollTimer = nil;
  if (_view) {
    _view->StopAutoscroll();
  }
}

- (void)blinkDismissEditMenus {
  if (@available(iOS 16.0, *)) {
    // не base::apple::ObjCCast, бо шаблон назвав би клас iOS 16 поза @available
    for (id<UIInteraction> interaction in self.interactions) {
      if ([interaction isKindOfClass:[UIEditMenuInteraction class]]) {
        [(UIEditMenuInteraction*)interaction dismissMenu];
      }
    }
  }
  UIMenuController* menu = [UIMenuController sharedMenuController];
  if (@available(iOS 13.0, *)) {
    [menu hideMenu];
  } else {
    [menu setMenuVisible:NO animated:YES];
  }
}

// джерело kLongPress, бо з іншими редагування в стилі Mac може замінити
// виділення словом
- (void)blinkShowSelectionMenu {
  auto* region = [self selectionRegion];
  if (!_view || ![self blinkRegionHasRange:region]) {
    return;
  }
  CGRect selection = region->bounding_box.IsEmpty()
                         ? [self blinkSelectionBoundingRect]
                         : region->bounding_box.ToCGRect();
  const CGFloat x = CGRectGetMidX(selection);
  const CGFloat y =
      std::max(CGRectGetMinY(selection), CGRectGetMinY(self.bounds));
  _view->host()->ShowContextMenuAtPoint(gfx::ToRoundedPoint(gfx::PointF(x, y)),
                                        ui::mojom::MenuSourceType::kLongPress);
}

- (CGRect)blinkSelectionBoundingRect {
  auto* region = [self selectionRegion];
  if (![self blinkRegionHasRange:region]) {
    return CGRectNull;
  }
  return CGRectUnion([self blinkRectForBound:region->anchor],
                     [self blinkRectForBound:region->focus]);
}

- (void)blinkNoteLongPressSelection:(BOOL)hasRange {
  if (!hasRange || _draggingHandle || _longPressSelectionPending ||
      !g_touch_sequence_active || g_touch_sequence_moved ||
      ![self blinkDrawsOwnHandles]) {
    return;
  }
  if ([NSDate timeIntervalSinceReferenceDate] - _touchSequenceStartTime <
      kLongPressSelectionMinDelay) {
    return;
  }
  const content::TextInputManager::TextSelection* selection =
      [self textSelection];
  if (!selection || selection->selected_text().empty() ||
      selection->selected_text() == _selectedTextAtTouchStart) {
    return;
  }
  _longPressSelectionPending = YES;
  _hasLongPressDragAnchor = NO;
}

- (BOOL)blinkContinueLongPressSelection:(UITouch*)touch
                              withEvent:(UIEvent*)event {
  const CGPoint point = [touch locationInView:self];
  if (!_hasLongPressDragAnchor) {
    _hasLongPressDragAnchor = YES;
    _longPressDragAnchor = point;
    return YES;
  }
  const selection_geometry::Point delta{
      static_cast<float>(point.x - _longPressDragAnchor.x),
      static_cast<float>(point.y - _longPressDragAnchor.y)};
  if (std::hypot(delta.x, delta.y) < selection_geometry::kTapSlop) {
    return YES;
  }
  auto* region = [self selectionRegion];
  if (!_view || !_view->host()->delegate() ||
      ![self blinkRegionHasRange:region]) {
    _longPressSelectionPending = NO;
    return YES;
  }
  selection_geometry::Bound start;
  selection_geometry::Bound end;
  [self blinkOrderedBoundsFromRegion:region start:&start end:&end];
  const bool extendStart = selection_geometry::ExtendStartForLongPressDrag(
      GeometryPoint(_longPressDragAnchor), delta, start.bottom, end.bottom);
  [self blinkCancelTouchInRenderer:touch withEvent:event];
  [self blinkStartSelectionDrag:(extendStart ? 1 : 2)
                          touch:touch
                        atPoint:point];
  return YES;
}

- (void)blinkCancelTouchInRenderer:(UITouch*)touch withEvent:(UIEvent*)event {
  blink::WebTouchEvent cancel = input::WebTouchEventBuilder::Build(
      blink::WebInputEvent::Type::kTouchCancel, touch, event, self,
      _viewOffsetDuringTouchSequence);
  // стан точки будівник бере з фази UITouch, а вона ще "рух"
  // без цього Blink вважав би палець досі на екрані
  cancel.touches[0].state = blink::WebTouchPoint::State::kStateCancelled;
  _view->OnTouchEvent(std::move(cancel));
  _viewOffsetDuringTouchSequence.reset();
}

- (BOOL)blinkHasFocusedEditable {
  const ui::mojom::TextInputState* state = [self editState];
  return state && state->type != ui::TextInputType::TEXT_INPUT_TYPE_NONE;
}

- (CGRect)blinkCaretRect {
  auto* region = [self selectionRegion];
  if (!region) {
    return CGRectNull;
  }
  if (region->focus.edge_start() != region->anchor.edge_start()) {
    return CGRectNull;
  }
  const CGFloat height = region->focus.GetHeight();
  if (height <= 0) {
    return CGRectNull;
  }
  return CGRectMake(region->focus.edge_start_rounded().x(),
                    region->focus.edge_start_rounded().y(), 1, height);
}

- (void)refreshSelectionOverlay {
  self.tintColor = [BlinkerSelectionOverlay selectionTintColor];
  auto* region = [self selectionRegion];
  const BOOL hasRange = [self blinkRegionHasRange:region];
  [self blinkNoteLongPressSelection:hasRange];
  const BOOL wantCaret =
      [BlinkerSelectionOverlay isEnabled] && [self blinkHasFocusedEditable];
  const BOOL wantHandles = hasRange && [self blinkDrawsOwnHandles];

  if (!_selectionOverlay) {
    if (!wantCaret && !wantHandles) {
      return;
    }
    _selectionOverlay =
        [[BlinkerSelectionOverlay alloc] initWithFrame:self.bounds];
    _selectionOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_selectionOverlay];
  }
  // overlay тримаємо зверху, композитор переставляє subviews поки малює
  // сторінку
  if (_selectionOverlay.superview == self &&
      self.subviews.lastObject != _selectionOverlay) {
    [self bringSubviewToFront:_selectionOverlay];
  }

  [_selectionOverlay showCaretAtRect:wantCaret ? [self blinkCaretRect]
                                               : CGRectNull];

  if (wantHandles) {
    const CGRect anchorRect = [self blinkRectForBound:region->anchor];
    const CGRect focusRect = [self blinkRectForBound:region->focus];
    const BOOL anchorFirst = region->is_anchor_first;
    [_selectionOverlay showHandlesFrom:anchorFirst ? anchorRect : focusRect
                                    to:anchorFirst ? focusRect : anchorRect];
  } else {
    [_selectionOverlay hideHandles];
  }
  [self blinkUpdateSelectionLoupe];
}

- (CGRect)blinkRectForBound:(const gfx::SelectionBound&)bound {
  return CGRectMake(bound.edge_start_rounded().x(),
                    bound.edge_start_rounded().y(), 1,
                    std::max<CGFloat>(1, bound.GetHeight()));
}

- (BOOL)automaticallyPresentEditMenu {
  return YES;
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
  // UITextInteraction оновлює каретку і маркери по сповіщеннях
  // UITextInputDelegate
  // без delegate старі прямокутники висіли до жесту
  [input_delegate_ selectionWillChange:self];
  [input_delegate_ selectionDidChange:self];
  [self refreshSelectionOverlay];
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

// до iOS 17.4 UIKit читає UITextInputTraits з першого відповідача
// велику літеру визначаємо тут по тексту поля, позицій для UIKit нема
- (UITextAutocapitalizationType)autocapitalizationType {
  const ui::mojom::TextInputState* state = [self editState];
  if (!state) {
    return _extendedTextInputTraits.autocapitalizationType;
  }
  return [self blinkEffectiveAutocapForState:*state];
}

// Shift потрібен лише на початку речення. Клавіатура не бачить тексту
// (textInRange: порожній) і вважає початком кожну позицію.
- (UITextAutocapitalizationType)blinkEffectiveAutocapForState:
    (const ui::mojom::TextInputState&)state {
  const UITextAutocapitalizationType configured =
      _extendedTextInputTraits.autocapitalizationType;
  if (configured != UITextAutocapitalizationTypeSentences ||
      !state.value.has_value()) {
    return configured;
  }
  const std::u16string& value = *state.value;
  size_t caret = value.size();
  if (state.selection.IsValid()) {
    caret = std::min(static_cast<size_t>(state.selection.GetMin()), caret);
  }
  if (caret == 0) {
    return configured;
  }
  NSString* before = base::SysUTF16ToNSString(value.substr(0, caret));
  return [self blinkIsAtSentenceStartAfter:before]
             ? UITextAutocapitalizationTypeSentences
             : UITextAutocapitalizationTypeNone;
}

- (BOOL)blinkIsAtSentenceStartAfter:(NSString*)text {
  BOOL sawSpace = NO;
  for (NSInteger i = static_cast<NSInteger>(text.length) - 1; i >= 0; --i) {
    const unichar c = [text characterAtIndex:i];
    if (c == '\n' || c == '\r') {
      return YES;
    }
    if (c == ' ' || c == '\t') {
      sawSpace = YES;
      continue;
    }
    return sawSpace && (c == '.' || c == '!' || c == '?');
  }
  return YES;
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
  const BOOL hasSelectedText = [self selectedText].length > 0;
  // за цим методом iOS 16 вирішує, чи дати системну Paste без запиту дозволу
  const BOOL writable = _isEditable || [self blinkHasFocusedEditable];
  if (action == @selector(paste:)) {
    return writable && [UIPasteboard generalPasteboard].hasStrings;
  }
  if (action == @selector(cut:)) {
    return writable && hasSelectedText;
  }
  if (action == @selector(copy:)) {
    return hasSelectedText;
  }
  if (action == @selector(selectAll:)) {
    return YES;
  }
  if (action == @selector(blinkerLookUp:) ||
      action == @selector(blinkerShare:) ||
      action == @selector(blinkerSearchWeb:)) {
    return hasSelectedText;
  }
  const int extensionItems = BlinkerExtensionMenuSlotCount();
  for (int i = 0; i < 8; ++i) {
    if (action == kBlinkerExtensionItemSelectors[i]) {
      return i < extensionItems;
    }
  }
  return NO;
}

- (void)blinkerExtensionItem0:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(0);
}
- (void)blinkerExtensionItem1:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(1);
}
- (void)blinkerExtensionItem2:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(2);
}
- (void)blinkerExtensionItem3:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(3);
}
- (void)blinkerExtensionItem4:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(4);
}
- (void)blinkerExtensionItem5:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(5);
}
- (void)blinkerExtensionItem6:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(6);
}
- (void)blinkerExtensionItem7:(nullable id)sender {
  BlinkerExtensionMenuSlotActivate(7);
}

- (NSString*)blinkerSelectedTextForMenu {
  NSString* text = [self selectedText];
  return text.length > 0 ? text : nil;
}

// UIKit мовчки ігнорує показ з зайнятого контролера, тому шукаємо вільний
// по responder chain
- (UIViewController*)blinkerPresentingViewController {
  UIResponder* responder = self;
  while ((responder = responder.nextResponder)) {
    if ([responder isKindOfClass:[UIViewController class]]) {
      UIViewController* controller = (UIViewController*)responder;
      return controller.presentedViewController ?: controller;
    }
  }
  return nil;
}

- (void)blinkerLookUp:(nullable id)sender {
  NSString* text = [self blinkerSelectedTextForMenu];
  UIViewController* presenter = [self blinkerPresentingViewController];
  if (!text || !presenter) {
    return;
  }
  [presenter presentViewController:[[UIReferenceLibraryViewController alloc]
                                       initWithTerm:text]
                          animated:YES
                        completion:nil];
}

- (void)blinkerShare:(nullable id)sender {
  NSString* text = [self blinkerSelectedTextForMenu];
  UIViewController* presenter = [self blinkerPresentingViewController];
  if (!text || !presenter) {
    return;
  }
  UIActivityViewController* share =
      [[UIActivityViewController alloc] initWithActivityItems:@[ text ]
                                       applicationActivities:nil];
  // на iPad це popover, без якоря показ падає
  if (share.popoverPresentationController) {
    share.popoverPresentationController.sourceView = self;
    const CGRect anchor = [self blinkSelectionBoundingRect];
    share.popoverPresentationController.sourceRect =
        CGRectIsNull(anchor) ? CGRectMake(CGRectGetMidX(self.bounds),
                                          CGRectGetMidY(self.bounds), 1, 1)
                             : anchor;
  }
  [presenter presentViewController:share animated:YES completion:nil];
}

- (void)blinkerSearchWeb:(nullable id)sender {
  NSString* text = [self blinkerSelectedTextForMenu];
  if (text) {
    BlinkSearchSelectedText(text.UTF8String);
  }
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

// меню забирає першого відповідача, Blink губить фокус і ImeCommitText
// без віджета нічого не робить, тому вертаємо фокус і трохи чекаємо
- (void)paste:(nullable id)sender {
  if (!_view) {
    return;
  }
  NSString* text = [UIPasteboard generalPasteboard].string;
  if (text.length == 0) {
    return;
  }
  [self blinkCommitPastedText:text attempt:0];
}

- (BOOL)blinkHasActiveTextInput {
  return _view && _view->GetTextInputManager() &&
         _view->GetTextInputManager()->GetActiveWidget() != nullptr;
}

- (void)blinkCommitPastedText:(NSString*)text attempt:(int)attempt {
  if (!_view || text.length == 0) {
    return;
  }
  if (![self isFirstResponder] && self.window.isKeyWindow) {
    [self becomeFirstResponder];
  }
  if ([self blinkHasActiveTextInput]) {
    _markedText.clear();
    _view->ImeCommitText(base::SysNSStringToUTF16(text),
                         gfx::Range::InvalidRange(), 0);
    BlinkerTraceSelection("paste-ime");
    return;
  }
  static constexpr int kMaxPasteFocusAttempts = 60;
  static constexpr int64_t kPasteFocusRetryMs = 25;
  if (attempt >= kMaxPasteFocusAttempts) {
    if (_view->host()->delegate()) {
      _view->host()->delegate()->ExecuteEditCommand(
          "InsertText", base::SysNSStringToUTF16(text));
      BlinkerTraceSelection("paste-insert-text");
    }
    return;
  }
  __weak RenderWidgetUIView* weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, kPasteFocusRetryMs * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        [weakSelf blinkCommitPastedText:text attempt:attempt + 1];
      });
}

- (UIMenu*)editMenuForTextRange:(UITextRange*)range
               suggestedActions:(NSArray<UIMenuElement*>*)suggestedActions
    API_AVAILABLE(ios(16.0)) {
  return [UIMenu menuWithChildren:suggestedActions];
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

// фізична клавіатура до iOS 17.4, BEKeyEntry нема, UIPress в Chromium лише для
// tvOS
// тут тільки keydown і keyup з UIKey

- (BOOL)blinkSendPress:(UIPress*)press type:(blink::WebInputEvent::Type)type {
  if (!@available(iOS 13.4, *)) {
    return NO;
  }
  UIKey* key = press.key;
  if (!key || !_view) {
    return NO;
  }
  const ui::DomCode dom_code = ui::KeycodeConverter::UsbKeycodeToDomCode(
      0x070000 | static_cast<uint32_t>(key.keyCode));
  const ui::KeyboardCode code =
      ui::DomCodeToUsLayoutNonLocatedKeyboardCode(dom_code);
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
  web_event.dom_code = static_cast<int>(dom_code);
  if (flags & UIKeyModifierAlphaShift) {
    web_event.SetModifiers(web_event.GetModifiers() |
                           blink::WebInputEvent::kCapsLockOn);
  }
  ui::DomKey dom_key;
  ui::KeyboardCode ignored;
  // недруковані клавіші йдуть з іменами (ArrowLeft), а не з символами UIKit
  // з приватної зони Unicode
  if (!ui::DomCodeToNonPrintableDomKey(dom_code, &dom_key, &ignored)) {
    NSString* characters = key.characters;
    if (characters.length != 1 || [characters characterAtIndex:0] < 0x20) {
      characters = key.charactersIgnoringModifiers;
    }
    if (characters.length == 1) {
      const char16_t ch = [characters characterAtIndex:0];
      dom_key = ui::DomKey::FromCharacter(ch);
      web_event.text[0] = ch;
    } else {
      dom_key = ui::DomKey::UNIDENTIFIED;
    }
    if (key.charactersIgnoringModifiers.length == 1) {
      web_event.unmodified_text[0] =
          [key.charactersIgnoringModifiers characterAtIndex:0];
    }
  }
  web_event.dom_key = static_cast<int>(dom_key);

  input::NativeWebKeyboardEvent native_event(web_event, _view->GetNativeView());
  _view->SendKeyEvent(native_event);
  return YES;
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses
           withEvent:(UIPressesEvent*)event {
  if (!@available(iOS 13.4, *)) {
    [super pressesBegan:presses withEvent:event];
    return;
  }
  for (UIPress* press in presses) {
    if (press.key) {
      g_hardware_keyboard_seen = YES;
      break;
    }
  }
  if (@available(iOS 17.4, *)) {
    // BrowserEngineKit вже доставляє їх через handleKeyEntry, інакше кожна
    // клавіша пішла б двічі
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

- (void)pressesCancelled:(NSSet<UIPress*>*)presses
               withEvent:(UIPressesEvent*)event {
  if (@available(iOS 17.4, *)) {
    [super pressesCancelled:presses withEvent:event];
    return;
  }
  for (UIPress* press in presses) {
    [self blinkSendPress:press type:blink::WebInputEvent::Type::kKeyUp];
  }
  [super pressesCancelled:presses withEvent:event];
}

- (NSArray<UIKeyCommand*>*)keyCommands {
  if (@available(iOS 13.4, *)) {
    return [super keyCommands];
  }
  if (_isEditable) {
    return [super keyCommands];
  }
  NSMutableArray<UIKeyCommand*>* commands = [NSMutableArray array];
  NSString* keys = @"abcdefghijklmnopqrstuvwxyz0123456789 ";
  for (NSUInteger i = 0; i < keys.length; ++i) {
    [commands addObject:[UIKeyCommand
        keyCommandWithInput:[keys substringWithRange:NSMakeRange(i, 1)]
              modifierFlags:0
                     action:@selector(blinkLegacyKeyCommand:)]];
  }
  for (NSString* key in @[UIKeyInputEscape, UIKeyInputLeftArrow,
                          UIKeyInputRightArrow, UIKeyInputUpArrow,
                          UIKeyInputDownArrow]) {
    [commands addObject:[UIKeyCommand keyCommandWithInput:key
                                         modifierFlags:0
                                                action:@selector(blinkLegacyKeyCommand:)]];
  }
  return commands;
}

- (void)blinkLegacyKeyCommand:(UIKeyCommand*)command {
  if (!_view || _isEditable) {
    return;
  }
  ui::DomKey key = ui::DomKey::UNIDENTIFIED;
  if ([command.input isEqualToString:UIKeyInputEscape]) {
    key = ui::DomKey::ESCAPE;
  } else if ([command.input isEqualToString:UIKeyInputLeftArrow]) {
    key = ui::DomKey::ARROW_LEFT;
  } else if ([command.input isEqualToString:UIKeyInputRightArrow]) {
    key = ui::DomKey::ARROW_RIGHT;
  } else if ([command.input isEqualToString:UIKeyInputUpArrow]) {
    key = ui::DomKey::ARROW_UP;
  } else if ([command.input isEqualToString:UIKeyInputDownArrow]) {
    key = ui::DomKey::ARROW_DOWN;
  } else if (command.input.length == 1) {
    key = ui::DomKey::FromCharacter([command.input characterAtIndex:0]);
  }
  const ui::DomCode code = ui::UsLayoutDomKeyToDomCode(key);
  for (auto type : {blink::WebInputEvent::Type::kRawKeyDown,
                    blink::WebInputEvent::Type::kKeyUp}) {
    blink::WebKeyboardEvent event(type, 0, ui::EventTimeForNow());
    event.dom_key = static_cast<int>(key);
    event.dom_code = static_cast<int>(code);
    event.windows_key_code = ui::DomCodeToUsLayoutNonLocatedKeyboardCode(code);
    _view->SendKeyEvent(input::NativeWebKeyboardEvent(event, _view->GetNativeView()));
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
  // позиції тут це прямокутники а не зсуви символів (див. BETextPosition),
  // довільний діапазон у підрядок не перевести
  return nil;
}

- (nullable NSString*)blinkTextBeforeCaret {
  const ui::mojom::TextInputState* state = [self editState];
  if (!state || !state->value.has_value()) {
    return nil;
  }
  const std::u16string& value = *state->value;
  size_t caret = value.size();
  if (state->selection.IsValid()) {
    caret = std::min(static_cast<size_t>(state->selection.GetMin()), caret);
  }
  if (caret == 0) {
    return nil;
  }
  return base::SysUTF16ToNSString(value.substr(0, caret));
}

- (void)replaceRange:(UITextRange*)range withText:(NSString*)text {
  if (_view && text.length == 0 && [self blinkIsCredentialField]) {
    // AutoFill спершу стирає старий вміст поля логіна чи пароля, діапазон
    // ми не знаємо, тож у такому полі стираємо все
    [self handleEditCommands:{"selectAll", "deleteBackward"}];
    return;
  }
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

  UITextSelectionRect* anchor = [[BETextSelectionHandles alloc]
      initWithCGRect:CGRectMake(region->anchor.edge_start_rounded().x(),
                                region->anchor.edge_start_rounded().y(), 1,
                                region->anchor.GetHeight())
             atStart:region->is_anchor_first
           direction:region->anchor_direction];
  UITextSelectionRect* focus = [[BETextSelectionHandles alloc]
      initWithCGRect:CGRectMake(region->focus.edge_start_rounded().x(),
                                region->focus.edge_start_rounded().y(), 1,
                                region->focus.GetHeight())
             atStart:!region->is_anchor_first
           direction:region->focus_direction];
  return region->is_anchor_first ? @[ anchor, focus ] : @[ focus, anchor ];
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

// iOS визначає, що вставляти з Passwords (логін чи пароль), коли фокус
// переходить на інший об'єкт. Поки перший відповідач той самий, нова
// textContentType між полями цього не міняє, і в поле пароля потрапляв логін.
// Тому фокус на мить віддається прихованому полю, рендерер цього не бачить.
- (void)restartInputSessionForCredentialField {
  if (!self.isFirstResponder || !_isEditable || !self.window) {
    return;
  }
  static UITextField* helper = nil;
  if (!helper) {
    helper = [[UITextField alloc] initWithFrame:CGRectMake(-10, -10, 1, 1)];
    helper.alpha = 0;
    helper.isAccessibilityElement = NO;
  }
  if (helper.superview != self.window) {
    [self.window addSubview:helper];
  }
  g_input_session_handoff = YES;
  g_input_session_handoff_deadline = CACurrentMediaTime() + 0.8;
  [helper becomeFirstResponder];
  [self becomeFirstResponder];
  g_input_session_handoff = NO;
  [self reloadInputViews];
}

- (BOOL)blinkIsCredentialField {
  NSString* type = _extendedTextInputTraits.textContentType;
  return _extendedTextInputTraits.secureTextEntry ||
         [type isEqualToString:UITextContentTypePassword] ||
         [type isEqualToString:UITextContentTypeUsername];
}

- (void)onUpdateTextInputState:(const ui::mojom::TextInputState&)state
                    withBounds:(CGRect)bounds {
  NSString* previousContentType =
      [_extendedTextInputTraits.textContentType copy];
  const BOOL traitsChanged =
      [_extendedTextInputTraits updateFromTextInputState:state];
  if (![(previousContentType ?: @"")
          isEqualToString:(_extendedTextInputTraits.textContentType ?: @"")] &&
      state.type != ui::TextInputType::TEXT_INPUT_TYPE_NONE) {
    [self restartInputSessionForCredentialField];
  }
  if (@available(iOS 17.4, *)) {
  } else {
    // До 17.4 UIKit кешує traits, нові підхоплює тільки після reload.
    const UITextAutocapitalizationType autocap =
        [self blinkEffectiveAutocapForState:state];
    const BOOL autocapChanged = autocap != _blinkAppliedAutocap;
    if (!self.isFirstResponder) {
      _blinkAppliedAutocap = autocap;
    } else if (traitsChanged || (autocapChanged && ![self hasMarkedText])) {
      // reload обірвав би композицію
      _blinkAppliedAutocap = autocap;
      [self reloadInputViews];
      // Shift UIKit перераховує лише при зміні виділення
      __weak RenderWidgetUIView* weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        RenderWidgetUIView* strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isFirstResponder) {
          return;
        }
        [strongSelf->input_delegate_ selectionWillChange:strongSelf];
        [strongSelf->input_delegate_ selectionDidChange:strongSelf];
      });
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

- (void)attemptAccessoryOnlyRecovery {
  if (!g_enable_keyboard_recovery) {
    return;
  }
  if (g_keyboard_recovery_used) {
    return;
  }
  if (g_last_keyboard_height > kRealKeyboardMinHeight) {
    return;
  }
  // із зовнішньою клавіатурою програмної нема, це не збій
  // інакше рендерер втрачав би фокус за пів секунди
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

  // повтор стартує з keyboardDidHide, коли UIKit знесе стару сесію вводу
  g_keyboard_state = BlinkKeyboardDismissing;
  [self resignFirstResponder];
  [self performSelector:@selector(retryKeyboardAfterAccessoryOnlyFailure)
             withObject:nil
             afterDelay:0.65];
}

- (void)retryKeyboardAfterAccessoryOnlyFailure {
  g_keyboard_state = BlinkKeyboardPresenting;
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

    // глобальна сесія не має застрягти в Presenting, чистимо осиротілий
    // accessory view
    g_keyboard_state = BlinkKeyboardDismissing;
    [self resignFirstResponder];
    [self setIsEditable:NO];
  }
}

- (void)showKeyboard:(bool)has_text withBounds:(CGRect)bounds {
  // renderer view це поверхня сторінки а не DOM елемент у фокусі
  // якщо підганяти під межі тексту, вся сторінка зсувається
  [self rememberFocusedRectIfPlausible:bounds];
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  const BOOL ownsVisibleKeyboard =
      g_keyboard_owner == self && (g_keyboard_state == BlinkKeyboardPresenting ||
                                   g_keyboard_state == BlinkKeyboardVisible);
  if (!ownsVisibleKeyboard &&
      (g_touch_sequence_moved || now - g_last_scroll_touch_end < 0.30)) {
    [self setIsEditable:NO];
    return;
  }
  if (![self isFirstResponder] &&
      (CGRectIsEmpty(bounds) || bounds.size.width < 2 ||
       bounds.size.height < 2)) {
    [self setIsEditable:NO];
    return;
  }

  // після Done рендерер якийсь час не може сам відкрити клавіатуру
  // дотик користувача це знімає
  if (g_keyboard_user_dismissed &&
      now - g_keyboard_dismiss_time < kKeyboardDismissCooldown) {
    return;
  }
  if (g_keyboard_user_dismissed) {
    g_keyboard_user_dismissed = NO;
  }

  // вже перший відповідач, тому зміни тексту лише оновлюють зсув
  // повторний показ дає хибну нульову висоту
  const BOOL ownsKeyboard = g_keyboard_owner == self;
  if (([self isFirstResponder] && _isEditable) ||
      (ownsKeyboard && (g_keyboard_state == BlinkKeyboardPresenting ||
                        g_keyboard_state == BlinkKeyboardVisible))) {
    [self refreshRelocationAfterTextCommit];
    [self setIsEditable:YES];
    return;
  }
  [self presentKeyboardForNewFocusSession];
}

- (void)presentKeyboardForNewFocusSession {
  if (g_system_hidden_owner == self) {
    g_system_hidden_owner = nil;
  }
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
  g_keyboard_owner = self;
  // UIKit синхронно питає UITextInput в becomeFirstResponder, тому editable
  // ставимо заздалегідь
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
  g_keyboard_user_dismissed = YES;
  g_keyboard_dismiss_time = [NSDate timeIntervalSinceReferenceDate];

  [self hideKeyboard];
}

- (void)hideKeyboard {
  if (g_system_hidden_owner == self) {
    g_system_hidden_owner = nil;
  }
  g_keyboard_state = BlinkKeyboardDismissing;
  [self setIsEditable:NO];
  if (!self.window.isKeyWindow || self.window.hidden) {
    [self resignFirstResponder];
  }
  [self reloadInputViews];
  // сторінка лишається key responder, порожній inputView ховає програмну
  // клавіатуру, а скорочення поза полями працюють
  g_keyboard_state = BlinkKeyboardHidden;
  if (g_keyboard_owner == self) {
    g_keyboard_owner = nil;
  }
}

@end
#pragma clang diagnostic pop
