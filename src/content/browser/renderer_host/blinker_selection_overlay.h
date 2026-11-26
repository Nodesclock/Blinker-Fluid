// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_OVERLAY_H_
#define CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_OVERLAY_H_

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, BlinkerCaretStyle) {
  BlinkerCaretStyleDefault = 0,
  BlinkerCaretStyleRainbow = 1,
};

// caret-color дає лише один колір, тому каретку рушія ховаємо
// (ShellRenderFrameObserver::SetEngineCaretHidden) і малюємо свою
@interface BlinkerSelectionOverlay : UIView

+ (BlinkerCaretStyle)currentStyle;

+ (BOOL)isEnabled;

+ (BlinkerCaretStyle)readStyleFromPreferences;

+ (UIColor*)selectionTintColor;

- (void)showCaretAtRect:(CGRect)rect;

- (void)hideCaret;

// до iOS 17 UITextInteraction дає тільки жести, маркери малюємо самі як WebKit
- (void)showHandlesFrom:(CGRect)startRect to:(CGRect)endRect;

- (void)hideHandles;

@end

@interface BlinkerTextLoupe : NSObject

- (instancetype)initWithView:(UIView*)view NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)moveToTouch:(CGPoint)touch caretRect:(CGRect)caretRect;

- (void)dismiss;

@end

#endif  // CONTENT_BROWSER_RENDERER_HOST_BLINKER_SELECTION_OVERLAY_H_
