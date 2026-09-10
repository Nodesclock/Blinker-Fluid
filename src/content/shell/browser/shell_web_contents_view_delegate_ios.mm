// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_web_contents_view_delegate.h"

#import <UIKit/UIKit.h>

#include <memory>

#include "base/apple/foundation_util.h"
#include "base/command_line.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/notimplemented.h"
#include "build/build_config.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/shell/browser/shell_web_contents_view_delegate_creator.h"
#include "content/shell/common/shell_switches.h"
#include "third_party/blink/public/common/context_menu_data/edit_flags.h"

enum {
  ShellContextMenuItemCutTag = 0,
  ShellContextMenuItemCopyTag,
  ShellContextMenuItemCopyLinkTag,
  ShellContextMenuItemPasteTag,
  ShellContextMenuItemDeleteTag,
  ShellContextMenuItemOpenLinkTag
};

// A hidden button used only for creating context menus. The only way to
// programmatically trigger a context menu on iOS is to trigger the primary
// action of a button that shows a context menu as its primary action.
@interface ContextMenuHiddenButton : UIButton <UIEditMenuInteractionDelegate>

// The frame determines the position at which the context menu is shown.
+ (instancetype)buttonWithFrame:(CGRect)frame
              contextMenuParams:(content::ContextMenuParams)params
                 forWebContents:(content::WebContents*)webContents;
- (void)presentSystemEditMenuInView:(UIView*)view atPoint:(CGPoint)point;
- (void)presentLegacyEditMenuInView:(UIView*)view;
@end

@implementation ContextMenuHiddenButton {
  content::ContextMenuParams _params;
  base::WeakPtr<content::WebContents> _webContents;
  UIEditMenuInteraction* _editMenuInteraction API_AVAILABLE(ios(16.0));
  __weak UIView* _interactionView;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (@available(iOS 16.0, *)) {
    if (_editMenuInteraction && _interactionView) {
      [_interactionView removeInteraction:_editMenuInteraction];
    }
  }
}

+ (instancetype)buttonWithFrame:(CGRect)frame
              contextMenuParams:(content::ContextMenuParams)params
                 forWebContents:(content::WebContents*)webContents {
  ContextMenuHiddenButton* button =
      [ContextMenuHiddenButton buttonWithType:UIButtonTypeSystem];
  button.hidden = YES;
  button.userInteractionEnabled = NO;
  button.frame = frame;
  button.layer.zPosition = CGFLOAT_MIN;
  button->_params = params;
  button->_webContents = webContents->GetWeakPtr();
  return button;
}

- (UIContextMenuConfiguration*)contextMenuInteraction:
                                   (UIContextMenuInteraction*)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
  UIContextMenuConfiguration* config = [UIContextMenuConfiguration
      configurationWithIdentifier:nil
                  previewProvider:nil
                   actionProvider:^UIMenu* _Nullable(
                       NSArray<UIMenuElement*>* _Nonnull suggestedActions) {
                     return [self buildContextMenuItems];
                   }];
  [super contextMenuInteraction:interaction
      configurationForMenuAtLocation:location];
  return config;
}

- (BOOL)canBecomeFirstResponder {
  return YES;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
  const int flags = _params.edit_flags;
  if (action == @selector(cut:)) {
    return _params.is_editable &&
           (flags & blink::ContextMenuDataEditFlags::kCanCut);
  }
  if (action == @selector(copy:)) {
    return (flags & blink::ContextMenuDataEditFlags::kCanCopy) ||
           !_params.selection_text.empty();
  }
  if (action == @selector(paste:)) {
    return _params.is_editable &&
           (flags & blink::ContextMenuDataEditFlags::kCanPaste);
  }
  if (action == @selector(delete:)) {
    return _params.is_editable &&
           (flags & blink::ContextMenuDataEditFlags::kCanDelete);
  }
  if (action == @selector(blinkOpenLink:) ||
      action == @selector(blinkCopyLink:)) {
    return !_params.unfiltered_link_url.is_empty();
  }
  return NO;
}

- (void)cut:(id)sender {
  if (_webContents) _webContents->Cut();
}
- (void)copy:(id)sender {
  if (_webContents) _webContents->Copy();
}
- (void)paste:(id)sender {
  if (_webContents) _webContents->Paste();
}
- (void)delete:(id)sender {
  if (_webContents) _webContents->Delete();
}
- (void)blinkOpenLink:(id)sender {
  if (!_webContents) return;
  content::NavigationController::LoadURLParams params(_params.link_url);
  _webContents->GetController().LoadURLWithParams(params);
}
- (void)blinkCopyLink:(id)sender {
  NSString* spec = base::SysUTF8ToNSString(_params.link_url.spec());
  if (spec.length) [UIPasteboard generalPasteboard].string = spec;
}

- (void)presentSystemEditMenuInView:(UIView*)view atPoint:(CGPoint)point {
  if (@available(iOS 16.0, *)) {
    _interactionView = view;
    _editMenuInteraction =
        [[UIEditMenuInteraction alloc] initWithDelegate:self];
    [view addInteraction:_editMenuInteraction];
    UIEditMenuConfiguration* configuration =
        [UIEditMenuConfiguration configurationWithIdentifier:nil
                                                  sourcePoint:point];
    [_editMenuInteraction presentEditMenuWithConfiguration:configuration];
  }
}

- (UIMenu*)editMenuInteraction:(UIEditMenuInteraction*)interaction
           menuForConfiguration:(UIEditMenuConfiguration*)configuration
                suggestedActions:(NSArray<UIMenuElement*>*)suggestedActions
    API_AVAILABLE(ios(16.0)) {
  return [self buildContextMenuItems];
}

- (void)editMenuInteraction:(UIEditMenuInteraction*)interaction
    willDismissMenuForConfiguration:(UIEditMenuConfiguration*)configuration
                           animator:(id<UIEditMenuInteractionAnimating>)animator
    API_AVAILABLE(ios(16.0)) {
  if (_webContents) {
    _webContents->NotifyContextMenuClosed(_params.link_followed,
                                          _params.impression);
  }
  if (_interactionView) {
    [_interactionView removeInteraction:interaction];
  }
  _editMenuInteraction = nil;
  _interactionView = nil;
}

- (void)presentLegacyEditMenuInView:(UIView*)view {
  self.hidden = NO;
  self.alpha = 0.01;
  self.userInteractionEnabled = NO;
  [self becomeFirstResponder];
  NSMutableArray<UIMenuItem*>* customItems = [NSMutableArray array];
  if (!_params.unfiltered_link_url.is_empty()) {
    [customItems addObject:[[UIMenuItem alloc] initWithTitle:@"Open Link"
                                                      action:@selector(blinkOpenLink:)]];
    [customItems addObject:[[UIMenuItem alloc] initWithTitle:@"Copy Link"
                                                      action:@selector(blinkCopyLink:)]];
  }
  UIMenuController* menu = [UIMenuController sharedMenuController];
  menu.menuItems = customItems;
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(legacyMenuDidHide:)
             name:UIMenuControllerDidHideMenuNotification
           object:menu];
  const CGRect targetRect = CGRectInset(self.frame, -1, -1);
  if (@available(iOS 13.0, *)) {
    [menu showMenuFromView:view rect:targetRect];
  } else {
    // iOS 12's native edit menu uses the older two-step presentation API.
    [menu setTargetRect:targetRect inView:view];
    [menu setMenuVisible:YES animated:YES];
  }
}

- (void)legacyMenuDidHide:(NSNotification*)notification {
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIMenuControllerDidHideMenuNotification
                                                object:notification.object];
  if (_webContents) {
    _webContents->NotifyContextMenuClosed(_params.link_followed,
                                          _params.impression);
  }
}

- (void)contextMenuInteraction:(UIContextMenuInteraction*)interaction
       willEndForConfiguration:(UIContextMenuConfiguration*)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
  [super contextMenuInteraction:interaction
        willEndForConfiguration:configuration
                       animator:animator];
  if (_webContents) {
    _webContents->NotifyContextMenuClosed(_params.link_followed,
                                          _params.impression);
  }
}

- (UIAction*)makeMenuItem:(NSString*)title
                  menuTag:(NSInteger)tag API_AVAILABLE(ios(13.0)) {
  auto menuActionHandler = ^(UIAction* action) {
    // The menu item is invoked well after the menu was built, so the page it
    // was built for may already be gone (navigation, tab close, a purge under
    // memory pressure). _webContents is a WeakPtr and operator-> CHECK-fails on
    // an invalidated one, so an unguarded Cut/Copy/Paste here takes the whole
    // browser down. Every branch below needs the page, except Copy Link, which
    // only needs the URL captured in _params.
    if (tag != ShellContextMenuItemCopyLinkTag && !self->_webContents) {
      return;
    }
    switch (tag) {
      case ShellContextMenuItemCutTag:
        self->_webContents->Cut();
        break;
      case ShellContextMenuItemCopyTag:
        self->_webContents->Copy();
        break;
#if BUILDFLAG(IS_IOS_TVOS)
        TVOS_NOT_YET_IMPLEMENTED();
#else
      case ShellContextMenuItemCopyLinkTag: {
        // -[UIPasteboard setString:] raises NSInvalidArgumentException on nil,
        // and +stringWithUTF8String: returns nil for any spec that is not valid
        // UTF-8 — so an odd link would abort the process rather than fail to
        // copy.
        NSString* spec = [NSString
            stringWithUTF8String:self->_params.link_url.spec().c_str()];
        if (spec.length) {
          [UIPasteboard generalPasteboard].string = spec;
        }
        break;
      }
#endif
      case ShellContextMenuItemPasteTag:
        self->_webContents->Paste();
        break;
      case ShellContextMenuItemDeleteTag:
        self->_webContents->Delete();
        break;
      case ShellContextMenuItemOpenLinkTag: {
        content::NavigationController::LoadURLParams params(
            self->_params.link_url);
        self->_webContents->GetController().LoadURLWithParams(params);
        break;
      }
    }
  };

  UIAction* menu = [UIAction actionWithTitle:title
                                       image:nil
                                  identifier:nil
                                     handler:menuActionHandler];
  return menu;
}

- (UIMenu*)buildContextMenuItems API_AVAILABLE(ios(13.0)) {
  bool hasLink = !_params.unfiltered_link_url.is_empty();
  bool hasSelection = !_params.selection_text.empty();
  bool isEditable = _params.is_editable;

  NSMutableArray* menuItems = [[NSMutableArray alloc] init];
  if (hasLink) {
    [menuItems addObject:[self makeMenuItem:@"Go to the Link"
                                    menuTag:ShellContextMenuItemOpenLinkTag]];
#if BUILDFLAG(IS_IOS_TVOS)
    TVOS_NOT_YET_IMPLEMENTED();
#else
    [menuItems addObject:[self makeMenuItem:@"Copy Link"
                                    menuTag:ShellContextMenuItemCopyLinkTag]];
#endif
  }

  if (isEditable) {
    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanCut) {
      [menuItems addObject:[self makeMenuItem:@"Cut"
                                      menuTag:ShellContextMenuItemCutTag]];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanCopy) {
      [menuItems addObject:[self makeMenuItem:@"Copy"
                                      menuTag:ShellContextMenuItemCopyTag]];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanPaste) {
      [menuItems addObject:[self makeMenuItem:@"Paste"
                                      menuTag:ShellContextMenuItemPasteTag]];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanDelete) {
      [menuItems addObject:[self makeMenuItem:@"Delete"
                                      menuTag:ShellContextMenuItemDeleteTag]];
    }
  } else if (hasSelection) {
    [menuItems addObject:[self makeMenuItem:@"Copy"
                                    menuTag:ShellContextMenuItemCopyTag]];
  }

  NSString* title =
      hasLink ? [NSString
                    stringWithUTF8String:self->_params.link_url.spec().c_str()]
              : @"";
  return [UIMenu menuWithTitle:title children:menuItems];
}

@end

namespace content {

namespace {

gfx::NativeView GetContentNativeView(WebContents* web_contents) {
  RenderWidgetHostView* rwhv = web_contents->GetRenderWidgetHostView();
  if (!rwhv) {
    return gfx::NativeView();
  }
  return rwhv->GetNativeView();
}

}  // namespace

class ShellWebContentsUIButtonHolder {
 public:
  ContextMenuHiddenButton* __strong button_;
};

std::unique_ptr<WebContentsViewDelegate> CreateShellWebContentsViewDelegate(
    WebContents* web_contents) {
  return std::make_unique<ShellWebContentsViewDelegate>(web_contents);
}

ShellWebContentsViewDelegate::ShellWebContentsViewDelegate(
    WebContents* web_contents)
    : web_contents_(web_contents) {
  DCHECK(web_contents_);  // Avoids 'unused private field' build error.
  hidden_button_ = std::make_unique<ShellWebContentsUIButtonHolder>();
}

ShellWebContentsViewDelegate::~ShellWebContentsViewDelegate() {}

void ShellWebContentsViewDelegate::ShowContextMenu(
    RenderFrameHost& render_frame_host,
    const ContextMenuParams& params) {
  if (switches::IsRunWebTestsSwitchPresent()) {
    return;
  }

  UIView* view = base::apple::ObjCCastStrict<UIView>(
      GetContentNativeView(web_contents_).Get());
  CGRect frame = CGRectMake(params.x, params.y, 0, 0);

  [hidden_button_->button_ removeFromSuperview];
  hidden_button_->button_ =
      [ContextMenuHiddenButton buttonWithFrame:frame
                             contextMenuParams:params
                                forWebContents:web_contents_];
  [view addSubview:hidden_button_->button_];

  // UIEditMenuInteraction is Apple's native replacement for the old edit
  // menu. Unlike the former action-sheet emulation it has the system's normal
  // compact appearance, placement, animation, accessibility and keyboard
  // behavior on every iOS 16+ release.
  if (@available(iOS 16.0, *)) {
    [hidden_button_->button_ presentSystemEditMenuInView:view
                                                 atPoint:frame.origin];
    return;
  }

  // iOS 14-15 use the native legacy editing menu. UIMenuController is
  // deprecated on newer systems, but it is the Apple-provided control for
  // these OS releases and is preferable to imitating it with an action sheet.
  [hidden_button_->button_ presentLegacyEditMenuInView:view];
}

}  // namespace content
