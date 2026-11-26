// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/browser/renderer_host/blinker_selection_overlay.h"

#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>

#include "content/browser/renderer_host/blinker_selection_geometry.h"
#include "content/shell/common/blinker_selection_color.h"

extern "C" void BlinkerTraceSelection(const char* event);

namespace {

namespace geometry = content::blinker_selection;

// iOS малює каретку 2pt, а Blink 1px, накриваємо каретку движка під нами
constexpr CGFloat kCaretWidth = 2.0;

constexpr CFTimeInterval kCaretBlinkPeriod = 1.0;
constexpr CFTimeInterval kRainbowPeriod = 6.0;

NSString* const kCaretBlinkAnimationKey = @"blinkerCaretBlink";
NSString* const kRainbowAnimationKey = @"blinkerRainbow";

UIColor* RGB(uint32_t hex) {
  return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                         green:((hex >> 8) & 0xFF) / 255.0
                          blue:(hex & 0xFF) / 255.0
                         alpha:1.0];
}

CAKeyframeAnimation* RainbowAnimation() {
  const uint32_t colors[] = {0xff3b30, 0xff9500, 0xffcc00, 0x34c759,
                             0x0a84ff, 0xbf5af2, 0xff3b30};
  NSMutableArray* values = [NSMutableArray array];
  for (uint32_t hex : colors) {
    [values addObject:(id)RGB(hex).CGColor];
  }
  CAKeyframeAnimation* animation =
      [CAKeyframeAnimation animationWithKeyPath:@"backgroundColor"];
  animation.values = values;
  animation.duration = kRainbowPeriod;
  animation.repeatCount = HUGE_VALF;
  animation.removedOnCompletion = NO;
  return animation;
}

// через CFPreferences, бо NSUserDefaults не бачить значень у plist застосунку
NSString* ReadSelectionPreference(BOOL synchronize) {
  if (synchronize) {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  }
  NSString* result = @"";
  CFPropertyListRef value = CFPreferencesCopyAppValue(
      CFSTR("BlinkSelectionColor"), kCFPreferencesCurrentApplication);
  if (value) {
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
      result = [(__bridge NSString*)value copy];
    }
    CFRelease(value);
  }
  return result;
}

constexpr CGFloat kHandleBarWidth = 2.0;
constexpr CGFloat kHandleKnobDiameter = geometry::kKnobDiameter;

constexpr CGFloat kLoupeWidth = 120.0;
constexpr CGFloat kLoupeHeight = 44.0;
constexpr CGFloat kLoupeZoom = 1.25;
constexpr CGFloat kLoupeGap = 28.0;
constexpr NSTimeInterval kLoupeFadeDuration = 0.12;
// знімок дорогий, а палець на ProMotion рухається 120 раз на секунду,
// тому між знімками лупа тільки їздить
constexpr CFTimeInterval kLoupeSnapshotInterval = 1.0 / 30.0;

}  // namespace

@implementation BlinkerSelectionOverlay {
  CALayer* _caretLayer;
  BOOL _caretVisible;
  CGRect _caretFrame;
  // звичайні шари, а не view, щоб не брали участі в hit test
  CALayer* _startBar;
  CALayer* _startKnob;
  CALayer* _endBar;
  CALayer* _endKnob;
  BOOL _handlesVisible;
}

static NSString* g_selection_preference = @"";

+ (void)refreshPreference:(BOOL)synchronize {
  g_selection_preference = ReadSelectionPreference(synchronize);
}

+ (NSString*)selectionPreference {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [self refreshPreference:YES];
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                      [self refreshPreference:YES];
                    }];
    // Settings пише в NSUserDefaults цього процесу, диск синхронізувати не
    // треба
    [center addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                      [self refreshPreference:NO];
                    }];
  });
  return g_selection_preference;
}

+ (BlinkerCaretStyle)currentStyle {
  return [[self selectionPreference]
             isEqualToString:@(content::kBlinkerSelectionRainbow)]
             ? BlinkerCaretStyleRainbow
             : BlinkerCaretStyleDefault;
}

+ (BlinkerCaretStyle)readStyleFromPreferences {
  return [ReadSelectionPreference(YES)
             isEqualToString:@(content::kBlinkerSelectionRainbow)]
             ? BlinkerCaretStyleRainbow
             : BlinkerCaretStyleDefault;
}

+ (UIColor*)selectionTintColor {
  uint32_t rgb = 0;
  if (!content::BlinkerSelectionRgb(
          [[self selectionPreference] UTF8String] ?: "", &rgb)) {
    return RGB(0xff3b30);
  }
  return RGB(rgb);
}

+ (BOOL)isEnabled {
  return [self currentStyle] != BlinkerCaretStyleDefault;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (!self) {
    return nil;
  }
  self.backgroundColor = [UIColor clearColor];
  self.opaque = NO;
  self.userInteractionEnabled = NO;

  _caretLayer = [CALayer layer];
  _caretLayer.backgroundColor = RGB(0xff3b30).CGColor;
  _caretLayer.cornerRadius = kCaretWidth / 2.0;
  _caretLayer.hidden = YES;
  // без цього неявна анімація тягла б каретку через сторінку
  _caretLayer.actions = @{
    @"position" : [NSNull null],
    @"bounds" : [NSNull null],
    @"hidden" : [NSNull null],
    @"opacity" : [NSNull null],
    @"backgroundColor" : [NSNull null],
  };
  [self.layer addSublayer:_caretLayer];
  return self;
}

- (void)dealloc {
  [_caretLayer removeAllAnimations];
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  return NO;
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  // Core Animation знімає анімації з шару поза вікном, і каретка застигла б
  if (self.window && _caretVisible) {
    [self startCaretAnimations];
  }
}

- (void)showCaretAtRect:(CGRect)rect {
  if (CGRectIsNull(rect) || CGRectIsEmpty(rect) || rect.size.height <= 0) {
    [self hideCaret];
    return;
  }
  const CGRect caretFrame =
      CGRectMake(CGRectGetMinX(rect) - (kCaretWidth - rect.size.width) / 2.0,
                 CGRectGetMinY(rect), kCaretWidth, rect.size.height);
  if (_caretVisible && CGRectEqualToRect(caretFrame, _caretFrame)) {
    return;
  }
  _caretFrame = caretFrame;
  _caretLayer.frame = caretFrame;
  _caretVisible = YES;
  _caretLayer.hidden = NO;
  [self startCaretAnimations];
}

- (void)hideCaret {
  if (!_caretVisible) {
    return;
  }
  _caretVisible = NO;
  _caretFrame = CGRectNull;
  _caretLayer.hidden = YES;
  [_caretLayer removeAnimationForKey:kCaretBlinkAnimationKey];
  [_caretLayer removeAnimationForKey:kRainbowAnimationKey];
}

// блимання щоразу зі світлої фази, тому переміщена каретка одразу видна
- (void)startCaretAnimations {
  if (![_caretLayer animationForKey:kRainbowAnimationKey]) {
    [_caretLayer addAnimation:RainbowAnimation() forKey:kRainbowAnimationKey];
  }
  CAKeyframeAnimation* blink =
      [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
  blink.values = @[ @1.0, @0.0 ];
  // дискретна анімація хоче на одну мітку часу більше ніж значень
  blink.keyTimes = @[ @0.0, @0.5, @1.0 ];
  blink.calculationMode = kCAAnimationDiscrete;
  blink.duration = kCaretBlinkPeriod;
  blink.repeatCount = HUGE_VALF;
  blink.removedOnCompletion = NO;
  [_caretLayer removeAnimationForKey:kCaretBlinkAnimationKey];
  [_caretLayer addAnimation:blink forKey:kCaretBlinkAnimationKey];
}

- (void)ensureHandleLayers {
  if (_startBar) {
    return;
  }
  UIColor* tint = [BlinkerSelectionOverlay selectionTintColor];
  NSDictionary* noImplicitAnimations = @{
    @"position" : [NSNull null],
    @"bounds" : [NSNull null],
    @"hidden" : [NSNull null],
    @"backgroundColor" : [NSNull null],
  };
  CALayer* (^makeLayer)(BOOL) = ^CALayer*(BOOL round) {
    CALayer* layer = [CALayer layer];
    layer.backgroundColor = tint.CGColor;
    layer.hidden = YES;
    layer.actions = noImplicitAnimations;
    if (round) {
      layer.cornerRadius = kHandleKnobDiameter / 2.0;
    } else {
      layer.cornerRadius = kHandleBarWidth / 2.0;
    }
    [self.layer addSublayer:layer];
    return layer;
  };
  _startBar = makeLayer(NO);
  _startKnob = makeLayer(YES);
  _endBar = makeLayer(NO);
  _endKnob = makeLayer(YES);
}

- (void)showHandlesFrom:(CGRect)startRect to:(CGRect)endRect {
  if (CGRectIsNull(startRect) || CGRectIsNull(endRect) ||
      startRect.size.height <= 0 || endRect.size.height <= 0) {
    [self hideHandles];
    return;
  }
  [self ensureHandleLayers];
  [self applyHandleColor];

  const CGFloat halfKnob = kHandleKnobDiameter / 2.0;
  _startBar.frame =
      CGRectMake(CGRectGetMinX(startRect) - kHandleBarWidth / 2.0,
                 CGRectGetMinY(startRect), kHandleBarWidth,
                 startRect.size.height);
  _startKnob.frame = CGRectMake(CGRectGetMinX(startRect) - halfKnob,
                                CGRectGetMinY(startRect) - kHandleKnobDiameter,
                                kHandleKnobDiameter, kHandleKnobDiameter);
  _endBar.frame = CGRectMake(CGRectGetMinX(endRect) - kHandleBarWidth / 2.0,
                             CGRectGetMinY(endRect), kHandleBarWidth,
                             endRect.size.height);
  _endKnob.frame =
      CGRectMake(CGRectGetMinX(endRect) - halfKnob, CGRectGetMaxY(endRect),
                 kHandleKnobDiameter, kHandleKnobDiameter);

  if (!_handlesVisible) {
    _handlesVisible = YES;
    for (CALayer* layer in @[ _startBar, _startKnob, _endBar, _endKnob ]) {
      layer.hidden = NO;
    }
  }
}

- (void)applyHandleColor {
  const BOOL rainbow = [BlinkerSelectionOverlay currentStyle] ==
                       BlinkerCaretStyleRainbow;
  UIColor* tint = [BlinkerSelectionOverlay selectionTintColor];
  for (CALayer* layer in @[ _startBar, _startKnob, _endBar, _endKnob ]) {
    layer.backgroundColor = tint.CGColor;
    if (rainbow && ![layer animationForKey:kRainbowAnimationKey]) {
      [layer addAnimation:RainbowAnimation() forKey:kRainbowAnimationKey];
    } else if (!rainbow) {
      [layer removeAnimationForKey:kRainbowAnimationKey];
    }
  }
}

- (void)hideHandles {
  if (!_handlesVisible) {
    return;
  }
  _handlesVisible = NO;
  for (CALayer* layer in @[ _startBar, _startKnob, _endBar, _endKnob ]) {
    layer.hidden = YES;
  }
}

@end

@implementation BlinkerTextLoupe {
  __weak UIView* _view;
  UITextLoupeSession* _systemSession API_AVAILABLE(ios(17.0));
  // зовнішній view несе тінь, внутрішній обрізає знімок по заокругленню
  UIView* _legacyLoupe;
  UIView* _legacyClip;
  UIView* _legacySnapshot;
  CFTimeInterval _legacySnapshotTime;
}

- (instancetype)initWithView:(UIView*)view {
  self = [super init];
  if (self) {
    _view = view;
  }
  return self;
}

- (void)dealloc {
  [self dismiss];
}

- (void)moveToTouch:(CGPoint)touch caretRect:(CGRect)caretRect {
  UIView* view = _view;
  if (!view || !view.window) {
    return;
  }
  if (@available(iOS 17.0, *)) {
    if (!_systemSession) {
      _systemSession = [UITextLoupeSession beginLoupeSessionAtPoint:touch
                                            fromSelectionWidgetView:nil
                                                             inView:view];
      BlinkerTraceSelection(_systemSession ? "loupe-system" : "loupe-failed");
    }
    [_systemSession moveToPoint:touch
                  withCaretRect:caretRect
                  trackingCaret:!CGRectIsNull(caretRect)];
    return;
  }
  [self moveLegacyLoupeToTouch:touch caretRect:caretRect inView:view];
}

- (void)moveLegacyLoupeToTouch:(CGPoint)touch
                     caretRect:(CGRect)caretRect
                        inView:(UIView*)view {
  UIWindow* window = view.window;
  const CGRect line = CGRectIsNull(caretRect) || CGRectIsEmpty(caretRect)
                          ? CGRectMake(touch.x, touch.y - 10.0, 1.0, 20.0)
                          : caretRect;
  const CGRect visible =
      UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
  const geometry::Rect bounds{static_cast<float>(visible.origin.x),
                              static_cast<float>(visible.origin.y),
                              static_cast<float>(visible.size.width),
                              static_cast<float>(visible.size.height)};
  const float top = static_cast<float>(std::min(CGRectGetMinY(line), touch.y));
  const geometry::Point center{static_cast<float>(touch.x),
                               static_cast<float>(CGRectGetMidY(line))};
  const geometry::Rect frame =
      geometry::LoupeFrame(center, top, static_cast<float>(CGRectGetMaxY(line)),
                           bounds, kLoupeWidth, kLoupeHeight, kLoupeGap);
  const geometry::Rect source =
      geometry::LoupeSource(center, kLoupeWidth, kLoupeHeight, kLoupeZoom);

  if (!_legacyLoupe) {
    [self buildLegacyLoupeInWindow:window];
    BlinkerTraceSelection("loupe-legacy");
  }
  _legacyLoupe.frame =
      [view convertRect:CGRectMake(frame.x, frame.y, frame.width, frame.height)
                 toView:window];
  const CFTimeInterval now = CACurrentMediaTime();
  if (_legacySnapshot && now - _legacySnapshotTime < kLoupeSnapshotInterval) {
    return;
  }
  _legacySnapshotTime = now;

  // знімок робить render server, тому видно й IOSurface шари
  UIView* snapshot = [view
      resizableSnapshotViewFromRect:CGRectMake(source.x, source.y, source.width,
                                               source.height)
                 afterScreenUpdates:NO
                      withCapInsets:UIEdgeInsetsZero];
  if (!snapshot) {
    return;
  }
  [_legacySnapshot removeFromSuperview];
  _legacySnapshot = snapshot;
  snapshot.userInteractionEnabled = NO;
  snapshot.transform = CGAffineTransformMakeScale(kLoupeZoom, kLoupeZoom);
  snapshot.center = CGPointMake(CGRectGetMidX(_legacyClip.bounds),
                                CGRectGetMidY(_legacyClip.bounds));
  [_legacyClip addSubview:snapshot];
}

- (void)buildLegacyLoupeInWindow:(UIWindow*)window {
  const CGRect bounds = CGRectMake(0, 0, kLoupeWidth, kLoupeHeight);
  const CGFloat radius = kLoupeHeight / 2.0;

  _legacyLoupe = [[UIView alloc] initWithFrame:bounds];
  _legacyLoupe.userInteractionEnabled = NO;
  _legacyLoupe.layer.shadowColor = [UIColor blackColor].CGColor;
  _legacyLoupe.layer.shadowOpacity = 0.25;
  _legacyLoupe.layer.shadowRadius = 10.0;
  _legacyLoupe.layer.shadowOffset = CGSizeMake(0, 3);
  _legacyLoupe.layer.shadowPath =
      [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius]
          .CGPath;

  _legacyClip = [[UIView alloc] initWithFrame:bounds];
  _legacyClip.userInteractionEnabled = NO;
  _legacyClip.clipsToBounds = YES;
  _legacyClip.layer.cornerRadius = radius;
  _legacyClip.layer.borderWidth = 1.0 / window.screen.scale;
  _legacyClip.layer.borderColor =
      [UIColor colorWithWhite:0.5 alpha:0.35].CGColor;
  if (@available(iOS 13.0, *)) {
    _legacyClip.backgroundColor = [UIColor systemBackgroundColor];
  } else {
    _legacyClip.backgroundColor = [UIColor whiteColor];
  }
  [_legacyLoupe addSubview:_legacyClip];

  _legacyLoupe.alpha = 0.0;
  [window addSubview:_legacyLoupe];
  UIView* loupe = _legacyLoupe;
  [UIView animateWithDuration:kLoupeFadeDuration
                   animations:^{
                     loupe.alpha = 1.0;
                   }];
}

- (void)dismiss {
  if (@available(iOS 17.0, *)) {
    [_systemSession invalidate];
    _systemSession = nil;
  }
  UIView* loupe = _legacyLoupe;
  _legacyLoupe = nil;
  _legacyClip = nil;
  _legacySnapshot = nil;
  if (!loupe) {
    return;
  }
  [UIView animateWithDuration:kLoupeFadeDuration
      animations:^{
        loupe.alpha = 0.0;
      }
      completion:^(BOOL finished) {
        [loupe removeFromSuperview];
      }];
}

@end
