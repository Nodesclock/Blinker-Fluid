// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_web_contents_view_delegate.h"

#import <UIKit/UIKit.h>
#import <LinkPresentation/LinkPresentation.h>

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

static UIViewController* BlinkPreviewController(NSURL* url, BOOL image) {
  UIViewController* controller = [[UIViewController alloc] init];
  controller.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
  controller.preferredContentSize = CGSizeMake(340, image ? 420 : 220);
  if (!url) {
    return controller;
  }
  if (image) {
    UIImageView* imageView = [[UIImageView alloc] initWithFrame:controller.view.bounds];
    imageView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [controller.view addSubview:imageView];
    [[[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        UIImage* loaded = data.length ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
          imageView.image = loaded;
        });
      }] resume];
    return controller;
  }

  LPLinkView* linkView = [[LPLinkView alloc] initWithURL:url];
  linkView.frame = CGRectInset(controller.view.bounds, 14, 14);
  linkView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [controller.view addSubview:linkView];
  LPMetadataProvider* provider = [[LPMetadataProvider alloc] init];
  [provider startFetchingMetadataForURL:url
                      completionHandler:^(LPLinkMetadata* metadata,
                                          NSError* error) {
    if (!metadata) {
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      linkView.metadata = metadata;
    });
  }];
  return controller;
}

// A hidden button used only for creating context menus. The only way to
// programmatically trigger a context menu on iOS is to trigger the primary
// action of a button that shows a context menu as its primary action.
@interface ContextMenuHiddenButton : UIButton

// The frame determines the position at which the context menu is shown.
+ (instancetype)buttonWithFrame:(CGRect)frame
              contextMenuParams:(content::ContextMenuParams)params
                 forWebContents:(content::WebContents*)webContents;
@end

@implementation ContextMenuHiddenButton {
  content::ContextMenuParams _params;
  base::WeakPtr<content::WebContents> _webContents;
}

+ (instancetype)buttonWithFrame:(CGRect)frame
              contextMenuParams:(content::ContextMenuParams)params
                 forWebContents:(content::WebContents*)webContents {
  ContextMenuHiddenButton* button =
      [ContextMenuHiddenButton buttonWithType:UIButtonTypeSystem];
  button.hidden = YES;
  button.userInteractionEnabled = NO;
  button.contextMenuInteractionEnabled = YES;
  button.showsMenuAsPrimaryAction = YES;
  button.frame = frame;
  button.layer.zPosition = CGFLOAT_MIN;
  button->_params = params;
  button->_webContents = webContents->GetWeakPtr();
  return button;
}

- (UIContextMenuConfiguration*)contextMenuInteraction:
                                   (UIContextMenuInteraction*)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
  GURL previewURL = _params.has_image_contents && _params.src_url.is_valid()
                        ? _params.src_url
                        : _params.unfiltered_link_url;
  NSURL* nsPreviewURL =
      previewURL.is_valid()
          ? [NSURL URLWithString:
                       base::SysUTF8ToNSString(previewURL.spec())]
          : nil;
  BOOL previewImage = _params.has_image_contents && _params.src_url.is_valid();
  UIContextMenuConfiguration* config = [UIContextMenuConfiguration
      configurationWithIdentifier:nil
                  previewProvider:^UIViewController* {
                    return BlinkPreviewController(nsPreviewURL, previewImage);
                  }
                   actionProvider:^UIMenu* _Nullable(
                       NSArray<UIMenuElement*>* _Nonnull suggestedActions) {
                     return [self buildContextMenuItems];
                   }];
  [super contextMenuInteraction:interaction
      configurationForMenuAtLocation:location];
  return config;
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

- (UIAction*)makeMenuItem:(NSString*)title menuTag:(NSInteger)tag {
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

- (UIMenu*)buildContextMenuItems {
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
  UIButton* __strong button_;
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

  // -[UIControl performPrimaryAction] is the only public way to raise a context
  // menu programmatically, and it is iOS 17.4+, NOT 17.0 as this guard used to
  // say. On 17.0-17.3 the guard passed and the selector did not exist, so every
  // long-press raised "unrecognized selector" and aborted the process; below
  // 17.0 nothing happened at all, which is why long-press Copy / Paste / Copy
  // Link has never worked for anyone on iOS 15 or 16.
  if (@available(iOS 17.4, *)) {
    [hidden_button_->button_ removeFromSuperview];
    hidden_button_->button_ =
        [ContextMenuHiddenButton buttonWithFrame:frame
                               contextMenuParams:params
                                  forWebContents:web_contents_];
    [view addSubview:hidden_button_->button_];
    [hidden_button_->button_ performPrimaryAction];
    return;
  }

  // Everything below 17.4 gets the same commands as an action sheet. It is not
  // the system context menu, but it is the difference between having Copy,
  // Paste and Copy Link and not having them at all.
  ShowContextMenuFallback(view, params);
}

void ShellWebContentsViewDelegate::ShowContextMenuFallback(
    UIView* view,
    const ContextMenuParams& params) {
  UIViewController* presenter = view.window.rootViewController;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  if (!presenter) {
    return;
  }

  UIAlertController* sheet = [UIAlertController
      alertControllerWithTitle:nil
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  // The menu outlives the page it was built for, so hold the contents weakly
  // and re-check it in every handler (see makeMenuItem: for the same reason).
  base::WeakPtr<WebContents> weak_contents = web_contents_->GetWeakPtr();
  const GURL link_url = params.link_url;
  const int edit_flags = params.edit_flags;

  auto add = ^(NSString* title, void (^action)(WebContents*)) {
    [sheet addAction:[UIAlertAction
                         actionWithTitle:title
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* a) {
                                   if (WebContents* c = weak_contents.get()) {
                                     action(c);
                                   }
                                 }]];
  };

  if (!params.unfiltered_link_url.is_empty()) {
    NSString* spec = [NSString
        stringWithUTF8String:params.unfiltered_link_url.spec().c_str()];
    NSURL* previewURL = spec.length ? [NSURL URLWithString:spec] : nil;
    if (previewURL) {
      [sheet addAction:[UIAlertAction
                           actionWithTitle:@"Preview Link"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction* a) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
          [presenter presentViewController:
                         BlinkPreviewController(previewURL, NO)
                                    animated:YES
                                  completion:nil];
        });
      }]];
    }
    add(@"Open Link", ^(WebContents* c) {
      c->GetController().LoadURLWithParams(
          NavigationController::LoadURLParams(link_url));
    });
    if (spec.length) {
      [sheet addAction:[UIAlertAction
                           actionWithTitle:@"Copy Link"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction* a) {
                                     [UIPasteboard generalPasteboard].string =
                                         spec;
                                   }]];
    }
  }

  if (params.has_image_contents && params.src_url.is_valid()) {
    NSString* imageSpec =
        [NSString stringWithUTF8String:params.src_url.spec().c_str()];
    NSURL* imageURL = imageSpec.length ? [NSURL URLWithString:imageSpec] : nil;
    if (imageURL) {
      [sheet addAction:[UIAlertAction
                           actionWithTitle:@"Preview Image"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction* a) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
          [presenter presentViewController:
                         BlinkPreviewController(imageURL, YES)
                                    animated:YES
                                  completion:nil];
        });
      }]];
      [sheet addAction:[UIAlertAction
                           actionWithTitle:@"Copy Image Link"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction* a) {
        [UIPasteboard generalPasteboard].string = imageSpec;
      }]];
    }
  }

  if (params.is_editable) {
    if (edit_flags & blink::ContextMenuDataEditFlags::kCanCut) {
      add(@"Cut", ^(WebContents* c) { c->Cut(); });
    }
    if (edit_flags & blink::ContextMenuDataEditFlags::kCanPaste) {
      add(@"Paste", ^(WebContents* c) { c->Paste(); });
    }
    if (edit_flags & blink::ContextMenuDataEditFlags::kCanDelete) {
      add(@"Delete", ^(WebContents* c) { c->Delete(); });
    }
  }
  // Copy applies to a selection whether or not the field is editable.
  if ((edit_flags & blink::ContextMenuDataEditFlags::kCanCopy) ||
      !params.selection_text.empty()) {
    add(@"Copy", ^(WebContents* c) { c->Copy(); });
  }

  // An action sheet with nothing but Cancel is just a stray tap.
  if (sheet.actions.count == 0) {
    return;
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // Required on iPad, where an action sheet must have an anchor.
  sheet.popoverPresentationController.sourceView = view;
  sheet.popoverPresentationController.sourceRect =
      CGRectMake(params.x, params.y, 1, 1);

  [presenter presentViewController:sheet animated:YES completion:nil];
}

}  // namespace content
