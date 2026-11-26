// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/shell_web_contents_view_delegate.h"

#import <UIKit/UIKit.h>

#include <memory>
#include <string>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/command_line.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/notimplemented.h"
#include "build/build_config.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/common/referrer.h"
#include "content/shell/browser/blinker_link_preview_ios.h"
#include "content/shell/common/blinker_low_memory.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "ui/base/page_transition_types.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_ui_strings.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/browser/shell_web_contents_view_delegate_creator.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/shell_switches.h"
#include "skia/ext/skia_utils_ios.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/blink/public/common/context_menu_data/edit_flags.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom-shared.h"

enum {
  ShellContextMenuItemCutTag = 0,
  ShellContextMenuItemCopyTag,
  ShellContextMenuItemCopyLinkTag,
  ShellContextMenuItemPasteTag,
  ShellContextMenuItemDeleteTag,
  ShellContextMenuItemOpenLinkTag,
  ShellContextMenuItemLookUpTag,
  ShellContextMenuItemShareTag,
  ShellContextMenuItemSearchWebTag,
};

extern "C" void BlinkSearchSelectedText(const char* utf8);

extern "C" bool BlinkerSelectionDragActive();

extern "C" void BlinkOpenURLInNewTab(const char* spec, bool background);
extern "C" void BlinkSaveImageToPhotos(UIImage* image);

static NSString* MenuL(const char* english) {
  return base::SysUTF8ToNSString(content::BlinkerLocalizedUTF8(english));
}

static content::BlinkerContextMenuTarget BlinkerTargetFromParams(
    const content::ContextMenuParams& params) {
  content::BlinkerContextMenuTarget target;
  target.page_url = params.page_url;
  target.frame_url = params.frame_url;
  target.link_url = params.unfiltered_link_url;
  target.src_url = params.src_url;
  target.selection_text = base::UTF16ToUTF8(params.selection_text);
  target.editable = params.is_editable;
  switch (params.media_type) {
    case blink::mojom::ContextMenuDataMediaType::kImage:
      target.media_type = "image";
      break;
    case blink::mojom::ContextMenuDataMediaType::kVideo:
      target.media_type = "video";
      break;
    case blink::mojom::ContextMenuDataMediaType::kAudio:
      target.media_type = "audio";
      break;
    default:
      target.media_type = "none";
      break;
  }
  return target;
}

// До iOS 16 UIMenuController питає view сторінки, відповідає по селекторах
namespace {

std::vector<content::BlinkerContextMenuEntry>& ExtensionMenuSlots() {
  static base::NoDestructor<std::vector<content::BlinkerContextMenuEntry>>
      slots;
  return *slots;
}

content::BlinkerContextMenuTarget& ExtensionMenuTarget() {
  static base::NoDestructor<content::BlinkerContextMenuTarget> target;
  return *target;
}

base::WeakPtr<content::WebContents>& ExtensionMenuContents() {
  static base::NoDestructor<base::WeakPtr<content::WebContents>> contents;
  return *contents;
}

}  // namespace

extern "C" int BlinkerExtensionMenuSlotCount() {
  return static_cast<int>(ExtensionMenuSlots().size());
}

extern "C" const char* BlinkerExtensionMenuSlotTitle(int index) {
  const auto& slots = ExtensionMenuSlots();
  if (index < 0 || static_cast<size_t>(index) >= slots.size()) {
    return nullptr;
  }
  return slots[index].title.c_str();
}

extern "C" void BlinkerTraceSelection(const char* event) {
  BLINKER_DIAGF("SELECTION: %s", event);
}

extern "C" void BlinkerExtensionMenuSlotActivate(int index) {
  const auto& slots = ExtensionMenuSlots();
  if (index < 0 || static_cast<size_t>(index) >= slots.size()) {
    return;
  }
  content::BlinkerActivateContextMenuItem(slots[index].key,
                                          ExtensionMenuTarget(),
                                          ExtensionMenuContents().get());
}

// A hidden button used only for creating context menus. The only way to
// programmatically trigger a context menu on iOS is to trigger the primary
// action of a button that shows a context menu as its primary action.
namespace {

// не даємо сторінці в картці відкривати вікна і показувати діалоги
class BlinkerPreviewHelper : public content::WebContentsObserver,
                             public content::WebContentsDelegate {
 public:
  BlinkerPreviewHelper(content::WebContents* contents,
                       base::RepeatingClosure painted,
                       base::RepeatingClosure resize)
      : content::WebContentsObserver(contents),
        painted_(std::move(painted)),
        resize_(std::move(resize)) {}

  void DidFirstVisuallyNonEmptyPaint() override { painted_.Run(); }
  void RenderViewReady() override { resize_.Run(); }
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override {
    resize_.Run();
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    resize_.Run();
  }
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override {
    painted_.Run();
  }

  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> callback) override {
    return nullptr;
  }
  bool IsWebContentsCreationOverridden(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      content::mojom::WindowContainerType window_container_type,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url) override {
    return true;
  }
  void CanDownload(const GURL& url,
                   const std::string& request_method,
                   base::OnceCallback<void(bool)> callback) override {
    std::move(callback).Run(false);
  }

 private:
  base::RepeatingClosure painted_;
  base::RepeatingClosure resize_;
};

constexpr net::NetworkTrafficAnnotationTag kLinkDownloadAnnotation =
    net::DefineNetworkTrafficAnnotation("blinker_link_download", R"(
      semantics {
        sender: "Blinker link menu"
        description: "Downloads the file a link points to."
        trigger: "The user chose Download Linked File after a long press."
        data: "The link address and the site's cookies."
        destination: WEBSITE
      }
      policy {
        cookies_allowed: YES
        cookies_store: "user"
        setting: "Only on request."
        policy_exception_justification: "Not implemented."
      })");

NSString* const kLinkPreviewsKey = @"BlinkLinkPreviews";

// На 1 ГБ картка може коштувати вкладку, тому там вимкнено
bool LinkPreviewsEnabled() {
  id value = [[NSUserDefaults standardUserDefaults] objectForKey:kLinkPreviewsKey];
  return value ? [value boolValue] : !content::BlinkerLowMemoryDevice();
}

}  // namespace

@interface ContextMenuHiddenButton : UIButton <UIEditMenuInteractionDelegate>

// The frame determines the position at which the context menu is shown.
+ (instancetype)buttonWithFrame:(CGRect)frame
              contextMenuParams:(content::ContextMenuParams)params
                 forWebContents:(content::WebContents*)webContents;
- (void)presentSystemEditMenuInView:(UIView*)view atPoint:(CGPoint)point;
- (void)presentLegacyEditMenuInView:(UIView*)view;
- (void)presentLinkSheetInView:(UIView*)view;
@end

@implementation ContextMenuHiddenButton {
  content::ContextMenuParams _params;
  base::WeakPtr<content::WebContents> _webContents;
  UIEditMenuInteraction* _editMenuInteraction API_AVAILABLE(ios(16.0));
  __weak UIView* _interactionView;
  // Не чистимо при закритті, бо дія може прийти ще під час анімації
  __weak UIView* _rendererView;
  std::unique_ptr<content::WebContents> _preview;
  std::unique_ptr<BlinkerPreviewHelper> _previewHelper;
  __weak BlinkerLinkPreviewController* _previewController;
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

// Меню забирає перший респондент і contenteditable губить виділення,
// тому фокус вертаємо перед вставкою
- (void)restoreRendererFocus {
  if (_rendererView && ![_rendererView isFirstResponder]) {
    [_rendererView becomeFirstResponder];
  }
}

- (void)cut:(id)sender {
  [self restoreRendererFocus];
  if (_webContents) _webContents->Cut();
}
- (void)copy:(id)sender {
  [self restoreRendererFocus];
  if (_webContents) _webContents->Copy();
}
- (void)paste:(id)sender {
  [self restoreRendererFocus];
  [self pasteIntoRenderer];
}
- (void)delete:(id)sender {
  [self restoreRendererFocus];
  if (_webContents) _webContents->Delete();
}

// Через view вставка іде по IME, так працює і в захищених полях
- (void)pasteIntoRenderer {
  if (_rendererView && [_rendererView respondsToSelector:@selector(paste:)]) {
    [_rendererView paste:nil];
    return;
  }
  if (_webContents) {
    _webContents->Paste();
  }
}
- (NSString*)selectionTextForMenu {
  if (_params.selection_text.empty()) {
    return nil;
  }
  NSString* text = base::SysUTF16ToNSString(_params.selection_text);
  return text.length ? text : nil;
}

- (UIViewController*)presentingViewControllerForMenu {
  UIResponder* responder = _rendererView ?: (UIResponder*)self;
  while ((responder = responder.nextResponder)) {
    if ([responder isKindOfClass:[UIViewController class]]) {
      UIViewController* controller = (UIViewController*)responder;
      // UIKit мовчки ігнорує показ з контролера що вже щось показує
      return controller.presentedViewController ?: controller;
    }
  }
  return nil;
}

- (void)lookUpSelection {
  NSString* text = [self selectionTextForMenu];
  UIViewController* presenter = [self presentingViewControllerForMenu];
  if (!text || !presenter) {
    return;
  }
  UIReferenceLibraryViewController* dictionary =
      [[UIReferenceLibraryViewController alloc] initWithTerm:text];
  [presenter presentViewController:dictionary animated:YES completion:nil];
}

- (void)searchWebForSelection {
  NSString* text = [self selectionTextForMenu];
  if (text.length) {
    BlinkSearchSelectedText(text.UTF8String);
  }
}

- (void)shareSelection {
  NSString* text = [self selectionTextForMenu];
  UIViewController* presenter = [self presentingViewControllerForMenu];
  if (!text || !presenter) {
    return;
  }
  UIActivityViewController* share =
      [[UIActivityViewController alloc] initWithActivityItems:@[ text ]
                                       applicationActivities:nil];
  // на iPad popover без якоря падає
  if (share.popoverPresentationController && _rendererView) {
    share.popoverPresentationController.sourceView = _rendererView;
    share.popoverPresentationController.sourceRect = self.frame;
  }
  [presenter presentViewController:share animated:YES completion:nil];
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
    _rendererView = view;
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
  return [self buildContextMenuItemsWithSuggestions:suggestedActions];
}

// Системна Paste без запиту дозволу, бо тому що це дія користувача
- (UIMenuElement*)systemPasteCommandIn:(NSArray<UIMenuElement*>*)elements
    API_AVAILABLE(ios(16.0)) {
  if (!_rendererView || ![_rendererView isFirstResponder]) {
    return nil;
  }
  for (UIMenuElement* element in elements) {
    if ([element isKindOfClass:[UICommand class]] &&
        ((UICommand*)element).action == @selector(paste:)) {
      const UIMenuElementAttributes unusable =
          UIMenuElementAttributesDisabled | UIMenuElementAttributesHidden;
      return (((UICommand*)element).attributes & unusable) ? nil : element;
    }
    if ([element isKindOfClass:[UIMenu class]]) {
      UIMenuElement* nested =
          [self systemPasteCommandIn:((UIMenu*)element).children];
      if (nested) {
        return nested;
      }
    }
  }
  return nil;
}

- (void)editMenuInteraction:(UIEditMenuInteraction*)interaction
    willDismissMenuForConfiguration:(UIEditMenuConfiguration*)configuration
                           animator:(id<UIEditMenuInteractionAnimating>)animator
    API_AVAILABLE(ios(16.0)) {
  if (_webContents) {
    _webContents->NotifyContextMenuClosed(_params.link_followed);
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
  _interactionView = view;
  _rendererView = view;
  [self becomeFirstResponder];
  NSMutableArray<UIMenuItem*>* customItems = [NSMutableArray array];
  // До iOS 16 ці три реалізовані у view сторінки, тут тільки реєстрація
  if (!_params.selection_text.empty()) {
    [customItems addObject:[[UIMenuItem alloc]
                               initWithTitle:MenuL("Look Up")
                                      action:@selector(blinkerLookUp:)]];
    [customItems addObject:[[UIMenuItem alloc]
                               initWithTitle:MenuL("Search Web")
                                      action:@selector(blinkerSearchWeb:)]];
    [customItems addObject:[[UIMenuItem alloc]
                               initWithTitle:MenuL("Share...")
                                      action:@selector(blinkerShare:)]];
  }
  if (!_params.unfiltered_link_url.is_empty()) {
    [customItems addObject:[[UIMenuItem alloc] initWithTitle:MenuL("Open Link")
                                                      action:@selector(blinkOpenLink:)]];
    [customItems addObject:[[UIMenuItem alloc] initWithTitle:MenuL("Copy Link")
                                                      action:@selector(blinkCopyLink:)]];
  }

  // UIMenuItem має лише назву і селектор, тому слот на селектор
  // не більше восьми
  ExtensionMenuSlots() = content::BlinkerContextMenuItemsFor(
      BlinkerTargetFromParams(_params));
  ExtensionMenuTarget() = BlinkerTargetFromParams(_params);
  ExtensionMenuContents() =
      _webContents ? _webContents->GetWeakPtr()
                   : base::WeakPtr<content::WebContents>();
  if (ExtensionMenuSlots().size() > 8) {
    ExtensionMenuSlots().resize(8);
  }
  static const SEL kSlotSelectors[8] = {
      @selector(blinkerExtensionItem0:), @selector(blinkerExtensionItem1:),
      @selector(blinkerExtensionItem2:), @selector(blinkerExtensionItem3:),
      @selector(blinkerExtensionItem4:), @selector(blinkerExtensionItem5:),
      @selector(blinkerExtensionItem6:), @selector(blinkerExtensionItem7:)};
  for (size_t i = 0; i < ExtensionMenuSlots().size(); ++i) {
    const content::BlinkerContextMenuEntry& entry = ExtensionMenuSlots()[i];
    std::string label = entry.parent_title.empty()
                            ? entry.title
                            : entry.parent_title + " \u203A " + entry.title;
    if (entry.checkable) {
      label = (entry.checked ? "\u2713 " : "\u2003") + label;
    }
    NSString* title = base::SysUTF8ToNSString(label);
    if (!title.length) {
      continue;
    }
    [customItems addObject:[[UIMenuItem alloc] initWithTitle:title
                                                     action:kSlotSelectors[i]]];
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
    [menu setTargetRect:targetRect inView:view];
    [menu setMenuVisible:YES animated:YES];
  }
}

- (void)presentLinkSheetInView:(UIView*)view {
  _rendererView = view;
  UIViewController* presenter = [self presentingViewControllerForMenu];
  if (!presenter || !_webContents) {
    if (_webContents) {
      _webContents->NotifyContextMenuClosed(_params.link_followed);
    }
    return;
  }
  const GURL link = _params.link_url;
  const GURL image =
      _params.media_type == blink::mojom::ContextMenuDataMediaType::kImage
          ? _params.src_url
          : GURL();
  const bool live = link.SchemeIsHTTPOrHTTPS() && LinkPreviewsEnabled();
  if (!live && image.is_valid()) {
    __weak ContextMenuHiddenButton* weakSelf = self;
    __block BOOL presented = NO;
    void (^show)(UIImage*) = ^(UIImage* picture) {
      if (presented) {
        return;
      }
      presented = YES;
      [weakSelf presentPreviewInView:view picture:picture];
    };
    [self fetchImage:show];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     show(nil);
                   });
    return;
  }
  [self presentPreviewInView:view picture:nil];
}

- (void)presentPreviewInView:(UIView*)view picture:(UIImage*)picture {
  UIViewController* presenter = [self presentingViewControllerForMenu];
  if (!presenter || !_webContents || !view.window) {
    if (_webContents) {
      _webContents->NotifyContextMenuClosed(_params.link_followed);
    }
    return;
  }
  const GURL link = _params.link_url;
  const GURL image =
      _params.media_type == blink::mojom::ContextMenuDataMediaType::kImage
          ? _params.src_url
          : GURL();
  const GURL shown = link.is_valid() ? link : image;
  const bool canPreview = link.SchemeIsHTTPOrHTTPS();
  const bool live = canPreview && LinkPreviewsEnabled();
  NSString* header =
      shown.SchemeIs("data") || shown.SchemeIs("blob")
          ? nil
          : base::SysUTF8ToNSString(shown.is_valid() ? shown.spec() : "");
  if (header.length > 300) {
    header = [[header substringToIndex:300] stringByAppendingString:@"..."];
  }
  base::WeakPtr<content::WebContents> contents = _webContents;
  const GURL followed = _params.link_followed;
  const content::Referrer referrer(_params.page_url, _params.referrer_policy);
  __weak ContextMenuHiddenButton* weakSelf = self;

  NSMutableArray<BlinkerLinkPreviewItem*>* items = [NSMutableArray array];
  __block BOOL newGroup = NO;
  void (^add)(const char*, NSString*, dispatch_block_t) =
      ^(const char* name, NSString* symbol, dispatch_block_t run) {
        BlinkerLinkPreviewItem* item =
            [BlinkerLinkPreviewItem itemWithTitle:MenuL(name)
                                           symbol:symbol
                                           action:run];
        item.startsGroup = newGroup;
        newGroup = NO;
        [items addObject:item];
      };
  if (canPreview) {
    const std::string spec = link.spec();
    add("Open in New Tab", @"plus.square.on.square", ^{
      BlinkOpenURLInNewTab(spec.c_str(), false);
    });
    add("Open in Background", @"square.on.square", ^{
      BlinkOpenURLInNewTab(spec.c_str(), true);
    });
    add("Download Linked File", @"arrow.down.circle", ^{
      if (!contents) {
        return;
      }
      content::DownloadManager* manager =
          contents->GetBrowserContext()->GetDownloadManager();
      if (!manager) {
        return;
      }
      auto download = std::make_unique<download::DownloadUrlParameters>(
          link, kLinkDownloadAnnotation);
      download->set_referrer(referrer.url);
      download->set_referrer_policy(
          content::Referrer::ReferrerPolicyForUrlRequest(referrer.policy));
      manager->DownloadUrl(std::move(download));
    });
    newGroup = YES;
  }
  if (link.is_valid() && !link.SchemeIs("javascript")) {
    NSString* linkText = base::SysUTF8ToNSString(link.spec());
    add("Copy Link", @"doc.on.doc", ^{
      if (linkText.length) {
        UIPasteboard.generalPasteboard.string = linkText;
      }
    });
  }
  if (canPreview) {
    NSURL* shareURL = [NSURL URLWithString:base::SysUTF8ToNSString(link.spec())];
    add("Share Link", @"square.and.arrow.up", ^{
      [weakSelf shareItems:shareURL ? @[ shareURL ] : @[]];
    });
  }
  newGroup = items.count > 0;
  if (image.is_valid() && !image.SchemeIs("javascript")) {
    add("Save to Photos", @"square.and.arrow.down", ^{
      [weakSelf fetchImage:^(UIImage* fetched) {
        BlinkSaveImageToPhotos(fetched);
      }];
    });
    add("Copy Image", @"photo.on.rectangle", ^{
      [weakSelf fetchImage:^(UIImage* fetched) {
        if (fetched) {
          UIPasteboard.generalPasteboard.image = fetched;
        }
      }];
    });
    if (image.SchemeIsHTTPOrHTTPS()) {
      const std::string spec = image.spec();
      add("Open Image in New Tab", @"photo", ^{
        BlinkOpenURLInNewTab(spec.c_str(), false);
      });
    }
  }
  newGroup = items.count > 0;
  const content::BlinkerContextMenuTarget target =
      BlinkerTargetFromParams(_params);
  for (const content::BlinkerContextMenuEntry& entry :
       content::BlinkerContextMenuItemsFor(target)) {
    std::string label = entry.parent_title.empty()
                            ? entry.title
                            : entry.parent_title + " › " + entry.title;
    if (entry.checkable) {
      label = (entry.checked ? "✓ " : "") + label;
    }
    NSString* name = base::SysUTF8ToNSString(label);
    if (!name.length) {
      continue;
    }
    const std::string key = entry.key;
    BlinkerLinkPreviewItem* item = [BlinkerLinkPreviewItem
        itemWithTitle:name
               symbol:@"puzzlepiece"
               action:^{
                 content::BlinkerActivateContextMenuItem(key, target,
                                                         contents.get());
               }];
    item.startsGroup = newGroup;
    newGroup = NO;
    [items addObject:item];
  }
  if (canPreview) {
    newGroup = YES;
    add(live ? "Hide Preview" : "Show Preview", live ? @"eye.slash" : @"eye", ^{
      [[NSUserDefaults standardUserDefaults] setBool:!live
                                              forKey:kLinkPreviewsKey];
    });
  }

  BlinkerLinkPreviewController* controller =
      [[BlinkerLinkPreviewController alloc] init];
  controller.items = items;
  controller.headerText = header;
  controller.touchPoint = [view convertPoint:self.frame.origin toView:nil];
  if (live) {
    controller.previewView = [self startLivePreview:link referrer:referrer];
  } else if (picture) {
    UIImageView* imageView = [[UIImageView alloc] initWithImage:picture];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    controller.previewView = imageView;
    controller.previewContentSize = picture.size;
  }
  if (live) {
    controller.onPreviewTap = ^{
      if (!contents) {
        return;
      }
      content::NavigationController::LoadURLParams load(link);
      load.referrer = referrer;
      load.transition_type = ui::PAGE_TRANSITION_LINK;
      contents->GetController().LoadURLWithParams(load);
    };
    controller.onPreviewLayout = ^(CGSize size) {
      [weakSelf resizeLivePreview];
    };
  }
  controller.onDismiss = ^{
    if (contents) {
      contents->NotifyContextMenuClosed(followed);
    }
    [weakSelf stopLivePreview];
  };
  _previewController = controller;
  [presenter presentViewController:controller animated:NO completion:nil];
  if (live) {
    [controller setPreviewLoading:YES];
  }
}

// Окремий WebContents з тим самим профілем, в історію не потрапляє
- (UIView*)startLivePreview:(const GURL&)url
                   referrer:(const content::Referrer&)referrer {
  [self stopLivePreview];
  _preview = content::WebContents::Create(
      content::WebContents::CreateParams(_webContents->GetBrowserContext()));
  __weak ContextMenuHiddenButton* weakSelf = self;
  _previewHelper = std::make_unique<BlinkerPreviewHelper>(
      _preview.get(), base::BindRepeating(^{
        ContextMenuHiddenButton* strongSelf = weakSelf;
        if (strongSelf) {
          [strongSelf->_previewController setPreviewLoading:NO];
        }
      }),
      base::BindRepeating(^{
        [weakSelf resizeLivePreview];
      }));
  _preview->SetDelegate(_previewHelper.get());
  _preview->SetAudioMuted(true);
  content::NavigationController::LoadURLParams load(url);
  load.referrer = referrer;
  load.transition_type = ui::PAGE_TRANSITION_LINK;
  _preview->GetController().LoadURLWithParams(load);
  UIView* page = _preview->GetNativeView().Get();
  page.backgroundColor = UIColor.whiteColor;
  return page;
}

- (void)resizeLivePreview {
  if (!_preview) {
    return;
  }
  UIView* page = _preview->GetNativeView().Get();
  const CGSize size = page.bounds.size;
  content::RenderWidgetHostView* rwhv = _preview->GetRenderWidgetHostView();
  if (rwhv && size.width > 0 && size.height > 0) {
    rwhv->SetBounds(
        gfx::Rect(0, 0, lround(size.width), lround(size.height)));
  }
}

- (void)stopLivePreview {
  if (!_preview) {
    return;
  }
  [_preview->GetNativeView().Get() removeFromSuperview];
  _preview->SetDelegate(nullptr);
  _previewHelper.reset();
  _preview.reset();
}

- (void)shareItems:(NSArray*)items {
  UIViewController* presenter = [self presentingViewControllerForMenu];
  if (!items.count || !presenter) {
    return;
  }
  UIActivityViewController* share =
      [[UIActivityViewController alloc] initWithActivityItems:items
                                       applicationActivities:nil];
  if (share.popoverPresentationController && _rendererView) {
    share.popoverPresentationController.sourceView = _rendererView;
    share.popoverPresentationController.sourceRect = self.frame;
  }
  [presenter presentViewController:share animated:YES completion:nil];
}

- (void)fetchImage:(void (^)(UIImage*))done {
  if (!_webContents ||
      _params.media_type != blink::mojom::ContextMenuDataMediaType::kImage ||
      !_params.src_url.is_valid()) {
    done(nil);
    return;
  }
  _webContents->DownloadImage(
      _params.src_url, false, gfx::Size(), 0, false,
      base::BindOnce(^(int id, int status, const GURL& url,
                       const std::vector<SkBitmap>& bitmaps,
                       const std::vector<gfx::Size>& sizes) {
        const SkBitmap* best = nullptr;
        for (const SkBitmap& bitmap : bitmaps) {
          if (!best || bitmap.width() > best->width()) {
            best = &bitmap;
          }
        }
        UIImage* picture = nil;
        if (best && !best->drawsNothing()) {
          base::apple::ScopedCFTypeRef<CGColorSpaceRef> space(
              CGColorSpaceCreateDeviceRGB());
          picture =
              skia::SkBitmapToUIImageWithColorSpace(*best, 1.0, space.get());
        }
        done(picture);
      }));
}

- (void)legacyMenuDidHide:(NSNotification*)notification {
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIMenuControllerDidHideMenuNotification
                                                object:notification.object];
  if (_webContents) {
    _webContents->NotifyContextMenuClosed(_params.link_followed);
  }
}

- (UIAction*)makeMenuItem:(NSString*)title
                  menuTag:(NSInteger)tag API_AVAILABLE(ios(13.0)) {
  auto menuActionHandler = ^(UIAction* action) {
    // Пункт викликають після побудови меню, WeakPtr вже може бути мертвий
    // і розіменування падає на CHECK
    const bool needsPage = tag != ShellContextMenuItemCopyLinkTag &&
                           tag != ShellContextMenuItemLookUpTag &&
                           tag != ShellContextMenuItemShareTag &&
                           tag != ShellContextMenuItemSearchWebTag;
    if (needsPage && !self->_webContents) {
      return;
    }
    if (needsPage) {
      [self restoreRendererFocus];
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
        // setString кидає виняток на nil, а stringWithUTF8String вертає nil
        // для биттого UTF8
        NSString* spec = [NSString
            stringWithUTF8String:self->_params.link_url.spec().c_str()];
        if (spec.length) {
          [UIPasteboard generalPasteboard].string = spec;
        }
        break;
      }
#endif
      case ShellContextMenuItemPasteTag:
        [self pasteIntoRenderer];
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
      case ShellContextMenuItemLookUpTag:
        [self lookUpSelection];
        break;
      case ShellContextMenuItemShareTag:
        [self shareSelection];
        break;
      case ShellContextMenuItemSearchWebTag:
        [self searchWebForSelection];
        break;
    }
  };

  UIAction* menu = [UIAction actionWithTitle:title
                                       image:nil
                                  identifier:nil
                                     handler:menuActionHandler];
  return menu;
}

- (UIMenu*)buildContextMenuItemsWithSuggestions:
    (nullable NSArray<UIMenuElement*>*)suggestedActions
    API_AVAILABLE(ios(13.0)) {
  bool hasLink = !_params.unfiltered_link_url.is_empty();
  bool hasSelection = !_params.selection_text.empty();
  bool isEditable = _params.is_editable;

  NSMutableArray* menuItems = [[NSMutableArray alloc] init];
  if (hasLink) {
    [menuItems addObject:[self makeMenuItem:MenuL("Open Link")
                                    menuTag:ShellContextMenuItemOpenLinkTag]];
#if BUILDFLAG(IS_IOS_TVOS)
    TVOS_NOT_YET_IMPLEMENTED();
#else
    [menuItems addObject:[self makeMenuItem:MenuL("Copy Link")
                                    menuTag:ShellContextMenuItemCopyLinkTag]];
#endif
  }

  if (isEditable) {
    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanCut) {
      [menuItems addObject:[self makeMenuItem:MenuL("Cut")
                                      menuTag:ShellContextMenuItemCutTag]];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanCopy) {
      [menuItems addObject:[self makeMenuItem:MenuL("Copy")
                                      menuTag:ShellContextMenuItemCopyTag]];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanPaste) {
      UIMenuElement* paste = nil;
      if (@available(iOS 16.0, *)) {
        paste = [self systemPasteCommandIn:suggestedActions];
      }
      if (!paste) {
        paste = [self makeMenuItem:MenuL("Paste")
                           menuTag:ShellContextMenuItemPasteTag];
      }
      [menuItems addObject:paste];
    }

    if (_params.edit_flags & blink::ContextMenuDataEditFlags::kCanDelete) {
      [menuItems addObject:[self makeMenuItem:MenuL("Delete")
                                      menuTag:ShellContextMenuItemDeleteTag]];
    }
  } else if (hasSelection) {
    [menuItems addObject:[self makeMenuItem:MenuL("Copy")
                                    menuTag:ShellContextMenuItemCopyTag]];
  }

  if (hasSelection) {
    [menuItems addObject:[self makeMenuItem:MenuL("Look Up")
                                    menuTag:ShellContextMenuItemLookUpTag]];
    [menuItems addObject:[self makeMenuItem:MenuL("Search Web")
                                    menuTag:ShellContextMenuItemSearchWebTag]];
    [menuItems addObject:[self makeMenuItem:MenuL("Share...")
                                    menuTag:ShellContextMenuItemShareTag]];
  }

  const content::BlinkerContextMenuTarget target =
      BlinkerTargetFromParams(_params);
  NSMutableDictionary<NSString*, NSMutableArray*>* submenus =
      [NSMutableDictionary dictionary];
  NSMutableArray* submenuOrder = [NSMutableArray array];
  for (const content::BlinkerContextMenuEntry& entry :
       content::BlinkerContextMenuItemsFor(target)) {
    NSString* itemTitle = base::SysUTF8ToNSString(
        entry.checkable ? (entry.checked ? "\u2713 " + entry.title
                                         : "\u2003" + entry.title)
                        : entry.title);
    if (!itemTitle.length) {
      continue;
    }
    const std::string key = entry.key;
    base::WeakPtr<content::WebContents> contents = _webContents;
    UIAction* action = [UIAction
        actionWithTitle:itemTitle
                  image:nil
             identifier:nil
                handler:^(UIAction* unused) {
                  content::BlinkerActivateContextMenuItem(key, target,
                                                          contents.get());
                }];
    if (entry.parent_title.empty()) {
      [menuItems addObject:action];
      continue;
    }
    NSString* parent = base::SysUTF8ToNSString(entry.parent_title);
    if (!submenus[parent]) {
      submenus[parent] = [NSMutableArray array];
      [submenuOrder addObject:parent];
    }
    [submenus[parent] addObject:action];
  }
  for (NSString* parent in submenuOrder) {
    [menuItems addObject:[UIMenu menuWithTitle:parent
                                      children:submenus[parent]]];
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

class BlinkerExtensionInjector
    : public WebContentsObserver,
      public WebContentsUserData<BlinkerExtensionInjector> {
 public:
  ~BlinkerExtensionInjector() override = default;

  void DidFinishNavigation(NavigationHandle* navigation_handle) override {
    if (!navigation_handle || !navigation_handle->HasCommitted() ||
        !navigation_handle->IsInPrimaryMainFrame() ||
        navigation_handle->IsSameDocument()) {
      return;
    }
    BlinkerWebExtensionRegistry& registry =
        BlinkerWebExtensionRegistry::GetInstance();
    // Перша закомічена навігація найраніше де є browser context для воркерів
    registry.EnsureServiceWorkersRegistered(
        web_contents() ? web_contents()->GetBrowserContext() : nullptr);
    registry.InjectContentScripts(web_contents(),
                                  navigation_handle->GetURL());
  }

 private:
  friend class WebContentsUserData<BlinkerExtensionInjector>;
  explicit BlinkerExtensionInjector(WebContents* contents)
      : WebContentsObserver(contents),
        WebContentsUserData<BlinkerExtensionInjector>(*contents) {
    // Рендерер читає лише опублікований знімок, реєстр треба завантажити
    // до document_start першої сторінки
    BlinkerWebExtensionRegistry& registry =
        BlinkerWebExtensionRegistry::GetInstance();
    if (!registry.loaded()) {
      registry.LoadAll();
    }
  }

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(BlinkerExtensionInjector);

class ShellWebContentsUIButtonHolder {
 public:
  ContextMenuHiddenButton* __strong button_;
};

std::unique_ptr<WebContentsViewDelegate> CreateShellWebContentsViewDelegate(
    WebContents* web_contents) {
  BlinkerExtensionInjector::CreateForWebContents(web_contents);
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
  // Меню може прийти поки палець ще тягне межу, після руху view
  // покаже його сама
  if (BlinkerSelectionDragActive()) {
    web_contents_->NotifyContextMenuClosed(params.link_followed);
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

  const bool image =
      params.media_type == blink::mojom::ContextMenuDataMediaType::kImage &&
      params.src_url.is_valid();
  if ((!params.unfiltered_link_url.is_empty() || image) &&
      !params.is_editable && params.selection_text.empty()) {
    [hidden_button_->button_ presentLinkSheetInView:view];
    return;
  }

  if (@available(iOS 16.0, *)) {
    [hidden_button_->button_ presentSystemEditMenuInView:view
                                                 atPoint:frame.origin];
    return;
  }

  // iOS 14 і 15 лишаємо на старому меню, імітація через action sheet гірша
  [hidden_button_->button_ presentLegacyEditMenuInView:view];
}

}  // namespace content
