// Copyright 2024 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_BROWSER_RENDERER_HOST_RENDER_WIDGET_HOST_VIEW_IOS_UIVIEW_H_
#define CONTENT_BROWSER_RENDERER_HOST_RENDER_WIDGET_HOST_VIEW_IOS_UIVIEW_H_

#import <BrowserEngineKit/BrowserEngineKit.h>
#import <UIKit/UIKit.h>

@class BlinkerSelectionOverlay;
@class BlinkerTextLoupe;
@class IOSExtendedTextInputTraits;

#include "base/memory/weak_ptr.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_ios.h"
#include "third_party/blink/public/mojom/input/input_handler.mojom-forward.h"
#include "ui/accelerated_widget_mac/ca_layer_frame_sink_provider.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/vector2d_f.h"

inline constexpr CGFloat kInputAccessoryToolbarBottomMargin = 8;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
@interface RenderWidgetUIView
    : CALayerFrameSinkProvider <BETextInput, UITextInput,
                                UITextInteractionDelegate> {
  base::WeakPtr<content::RenderWidgetHostViewIOS> _view;
  IOSExtendedTextInputTraits* _extendedTextInputTraits;
  // Остання віддана клавіатурі велика літера, -1 до першої
  NSInteger _blinkAppliedAutocap;
  id<BETextInputDelegate> be_text_input_delegate_;
  __weak id<UITextInputDelegate> input_delegate_;
  BETextInteraction* text_interaction_;
  // замість text_interaction_ нижче iOS 17.4
  UITextInteraction* _legacyTextInteraction;
  UITextInteractionMode _legacyTextInteractionMode;
  BlinkerSelectionOverlay* _selectionOverlay;
  BlinkerTextLoupe* _selectionLoupe;
  int _draggingHandle;
  UITouch* _handleDragTouch;
  CGPoint _handleDragOffset;
  CGPoint _handleDragLastTouch;
  NSTimer* _selectionAutoscrollTimer;
  BOOL _longPressSelectionPending;
  NSHashTable<UITouch*>* _cancelledTouches;
  BOOL _hasLongPressDragAnchor;
  CGPoint _longPressDragAnchor;
  NSTimeInterval _touchSequenceStartTime;
  std::u16string _selectedTextAtTouchStart;
  BOOL _isEditable;
  UIView* _inputAccessoryContainerView;
  UIBarButtonItem* _previousAccessoryButton;
  UIBarButtonItem* _nextAccessoryButton;
  std::u16string _markedText;
  std::optional<input::NativeWebKeyboardEvent> _currentKeyDownEvent;
  std::optional<gfx::Vector2dF> _viewOffsetDuringTouchSequence;
  CGFloat _keyboardHeight;
}

- (instancetype)initWithWidget:
    (base::WeakPtr<content::RenderWidgetHostViewIOS>)view;

- (void)onUpdateTextInputState:(const ui::mojom::TextInputState&)state
                    withBounds:(CGRect)bounds;
- (void)showKeyboard:(bool)has_text withBounds:(CGRect)bounds;
- (void)hideKeyboard;
- (void)selectionDidChange;
- (void)refreshSelectionOverlay;
- (CGFloat)keyboardHeight;

- (BETextInteraction*)textInteraction API_AVAILABLE(ios(17.4));
- (void)updateView:(UIScrollView*)view;
- (void)removeView;
@end
#pragma clang diagnostic pop

#endif  // CONTENT_BROWSER_RENDERER_HOST_RENDER_WIDGET_HOST_VIEW_IOS_UIVIEW_H_
