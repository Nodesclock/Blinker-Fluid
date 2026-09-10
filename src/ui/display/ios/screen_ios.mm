// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <UIKit/UIKit.h>

#include "base/apple/foundation_util.h"
#include "base/check.h"
#include "base/notimplemented.h"
#include "base/task/single_thread_task_runner.h"
#include "build/ios_buildflags.h"
#include "ui/display/display.h"
#include "ui/display/display_features.h"
#include "ui/display/screen_base.h"
#include "ui/display/util/display_util.h"
#include "ui/gfx/native_ui_types.h"

namespace display {
namespace {
class ScreenNotification {
 public:
  virtual void ScreenChanged() = 0;
};
}  // namespace
}  // namespace display

@interface ScreenObserver : NSObject {
  raw_ptr<display::ScreenNotification, DanglingUntriaged> _notifier;
}
- (void)mainScreenChanged;
@end

@implementation ScreenObserver

- (instancetype)initWithNotifier:(display::ScreenNotification*)notifier {
  if ((self = [super init])) {
    _notifier = notifier;
    NSNotificationCenter* defaultCenter = [NSNotificationCenter defaultCenter];
#if !BUILDFLAG(IS_IOS_TVOS)
    [defaultCenter addObserver:self
                      selector:@selector(mainScreenChanged)
                          name:UIDeviceOrientationDidChangeNotification
                        object:nil];
#endif
    [defaultCenter addObserver:self
                      selector:@selector(mainScreenChanged)
                          name:UIWindowDidBecomeKeyNotification
                        object:nil];
  }

  return self;
}

- (void)mainScreenChanged {
  if (!base::SingleThreadTaskRunner::HasCurrentDefault()) {
    return;
  }
  // This notification comes before UIScreen can change its bounds so post a
  // task so the update occurs after the UIScreen has been updated.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&display::ScreenNotification::ScreenChanged,
                                base::Unretained(_notifier)));
}

@end

namespace display {
namespace {

// Return all screens associated with scenes of the application.
NSArray<UIScreen*>* GetAllActiveScreens() {
#if BUILDFLAG(IS_IOS_APP_EXTENSION)
  return [NSArray<UIScreen*> array];
#else
  if (@available(iOS 13.0, *)) {
  NSMutableSet<UIScreen*>* screens = [NSMutableSet set];
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    auto* window_scene = base::apple::ObjCCastStrict<UIWindowScene>(scene);
    for (UIWindow* window in window_scene.windows) {
      if (UIScreen* screen = window.screen) {
        [screens addObject:screen];
      }
    }
  }
  return [screens allObjects];
  }
  return UIScreen.screens;
#endif
}

UIInterfaceOrientation GetActiveInterfaceOrientation() {
#if BUILDFLAG(IS_IOS_APP_EXTENSION)
  return UIInterfaceOrientationUnknown;
#else
  if (@available(iOS 13.0, *)) {
    UIWindow* fallback = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
      UIWindowScene* window_scene =
          base::apple::ObjCCast<UIWindowScene>(scene);
      if (!window_scene ||
          window_scene.activationState == UISceneActivationStateUnattached) {
        continue;
      }
      for (UIWindow* window in window_scene.windows) {
        fallback = fallback ?: window;
        if (window.isKeyWindow) {
          return window_scene.interfaceOrientation;
        }
      }
    }
    return fallback.windowScene.interfaceOrientation;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
#endif
}

class ScreenIos : public ScreenBase, public ScreenNotification {
 public:
  ScreenIos() {
    observer_ = [[ScreenObserver alloc] initWithNotifier:this];
    ScreenChanged();
  }

  ScreenIos(const ScreenIos&) = delete;
  ScreenIos& operator=(const ScreenIos&) = delete;

  void ScreenChanged() override {
    UIScreen* screen = GetAllActiveScreens().firstObject;
    if (!screen) {
      return;
    }

    const int64_t display_id = 0;
    // UIScreen.bounds is expressed in the screen's fixed portrait coordinate
    // space on modern iOS. Chromium's Display bounds, however, feed the Web
    // `screen.width/height` APIs and must describe the current interface
    // orientation. Keeping 430x932 here while the web view is 932x430 makes
    // fullscreen sites (notably YouTube) lay out only the left half of the
    // landscape renderer surface.
    UIInterfaceOrientation interface_orientation =
        GetActiveInterfaceOrientation();
    CGSize display_size = screen.bounds.size;
    const CGFloat short_edge = MIN(display_size.width, display_size.height);
    const CGFloat long_edge = MAX(display_size.width, display_size.height);
    if (UIInterfaceOrientationIsLandscape(interface_orientation)) {
      display_size = CGSizeMake(long_edge, short_edge);
    } else if (UIInterfaceOrientationIsPortrait(interface_orientation)) {
      display_size = CGSizeMake(short_edge, long_edge);
    }
    Display display(display_id,
                    gfx::Rect(0, 0, lround(display_size.width),
                              lround(display_size.height)));
    CGFloat scale = [screen scale];

    if (Display::HasForceDeviceScaleFactor()) {
      scale = Display::GetForcedDeviceScaleFactor();
    }
    display.set_device_scale_factor(scale);

    // Left unset, the Display keeps its 60Hz default and viz paces BeginFrames
    // at 60 on a ProMotion panel. CADisableMinimumFrameDurationOnPhone in the
    // Info.plist only lifts the cap; the rate still has to be asked for.
    if (screen.maximumFramesPerSecond > 0) {
      display.set_display_frequency(
          static_cast<float>(screen.maximumFramesPerSecond));
    }

#if !BUILDFLAG(IS_IOS_TVOS)
    Display::Rotation rotation = Display::ROTATE_0;
    switch (interface_orientation) {
      case UIInterfaceOrientationPortrait:
      case UIInterfaceOrientationUnknown:
        rotation = Display::ROTATE_0;
        break;
      case UIInterfaceOrientationPortraitUpsideDown:
        rotation = Display::ROTATE_180;
        break;
      case UIInterfaceOrientationLandscapeLeft:
        rotation = Display::ROTATE_90;
        break;
      case UIInterfaceOrientationLandscapeRight:
        rotation = Display::ROTATE_270;
        break;
    }
    display.set_rotation(rotation);
    display.set_touch_support(Display::TouchSupport::AVAILABLE);
    display.set_accelerometer_support(Display::AccelerometerSupport::AVAILABLE);
    AddInternalDisplayId(display_id);
#endif

    ProcessDisplayChanged(display, true /* is_primary */);
  }

  gfx::Point GetCursorScreenPoint() override {
    NOTIMPLEMENTED();
    return gfx::Point(0, 0);
  }

  bool IsWindowUnderCursor(gfx::NativeWindow window) override {
    NOTIMPLEMENTED();
    return false;
  }

  gfx::NativeWindow GetWindowAtScreenPoint(const gfx::Point& point) override {
    NOTIMPLEMENTED();
    return gfx::NativeWindow();
  }

  int GetNumDisplays() const override {
    return std::max(static_cast<int>([GetAllActiveScreens() count]), 1);
  }

 private:
  ScreenObserver* __strong observer_;
};

}  // namespace

// static
gfx::NativeWindow Screen::GetWindowForView(gfx::NativeView view) {
  return gfx::NativeWindow(view.Get().window);
}

Screen* CreateNativeScreen() {
  return new ScreenIos;
}

float GetInternalDisplayDeviceScaleFactor() {
#if BUILDFLAG(IS_IOS_APP_EXTENSION)
  return 1.0f;
#else
  UIScreen* screen = GetAllActiveScreens().firstObject;
  return screen ? screen.scale : 1.0f;
#endif
}

}  // namespace display
