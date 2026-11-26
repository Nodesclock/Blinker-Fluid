// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/shell/browser/blinker_link_preview_ios.h"

#include <algorithm>

// Визначено в shell_platform_delegate_ios.mm. На iOS 12 бере PNG зі збірки
extern "C" UIImage* BlinkMenuSymbol(NSString* name);

namespace {

constexpr CGFloat kMargin = 16;
constexpr CGFloat kGap = 14;
constexpr CGFloat kRowHeight = 44;
constexpr CGFloat kGroupGap = 8;
constexpr CGFloat kMenuWidth = 254;
constexpr CGFloat kCornerRadius = 14;

UIColor* PreviewLabelColor() {
  if (@available(iOS 13.0, *)) {
    return UIColor.labelColor;
  }
  return UIColor.blackColor;
}

UIColor* PreviewSecondaryColor() {
  if (@available(iOS 13.0, *)) {
    return UIColor.secondaryLabelColor;
  }
  return [UIColor colorWithWhite:0.45 alpha:1.0];
}

UIColor* PreviewSeparatorColor() {
  if (@available(iOS 13.0, *)) {
    return UIColor.separatorColor;
  }
  return [UIColor colorWithWhite:0.0 alpha:0.15];
}

UIColor* PreviewFillColor(CGFloat alpha) {
  if (@available(iOS 13.0, *)) {
    return [UIColor.labelColor colorWithAlphaComponent:alpha];
  }
  return [UIColor colorWithWhite:0.0 alpha:alpha];
}

UIColor* PreviewCardColor() {
  if (@available(iOS 13.0, *)) {
    return UIColor.systemBackgroundColor;
  }
  return UIColor.whiteColor;
}

UIBlurEffect* MenuBlur() {
  if (@available(iOS 13.0, *)) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
  }
  return [UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight];
}

UIBlurEffect* BackdropBlur() {
  if (@available(iOS 13.0, *)) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
  }
  return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

}  // namespace

@implementation BlinkerLinkPreviewItem
+ (instancetype)itemWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                       action:(dispatch_block_t)action {
  BlinkerLinkPreviewItem* item = [[BlinkerLinkPreviewItem alloc] init];
  item.title = title;
  item.image = symbol.length ? BlinkMenuSymbol(symbol) : nil;
  item.action = action;
  return item;
}
@end

@interface BlinkerPreviewMenuRow : UIControl
@property(nonatomic, strong) BlinkerLinkPreviewItem* item;
@property(nonatomic, strong) UILabel* label;
@property(nonatomic, strong) UIImageView* icon;
@end

@implementation BlinkerPreviewMenuRow
- (instancetype)initWithItem:(BlinkerLinkPreviewItem*)item {
  if ((self = [super initWithFrame:CGRectZero])) {
    _item = item;
    _label = [[UILabel alloc] init];
    _label.text = item.title;
    _label.font = [UIFont systemFontOfSize:17];
    _label.textColor = PreviewLabelColor();
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_label];
    _icon = [[UIImageView alloc] initWithImage:item.image];
    _icon.contentMode = UIViewContentModeCenter;
    _icon.tintColor = PreviewLabelColor();
    [self addSubview:_icon];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = item.title;
    self.accessibilityTraits = UIAccessibilityTraitButton;
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGSize size = self.bounds.size;
  const CGFloat iconWidth = _icon.image ? 28 : 0;
  _icon.frame = CGRectMake(size.width - 16 - iconWidth, 0, iconWidth,
                           size.height);
  _label.frame = CGRectMake(16, 0, size.width - 32 - iconWidth - 8,
                            size.height);
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  self.backgroundColor =
      highlighted ? PreviewFillColor(0.12) : UIColor.clearColor;
}
@end

@implementation BlinkerLinkPreviewController {
  UIVisualEffectView* _backdrop;
  UIView* _dim;
  UIView* _cardShadow;
  UIView* _card;
  UIActivityIndicatorView* _spinner;
  UIVisualEffectView* _menu;
  UIScrollView* _menuScroll;
  UILabel* _header;
  NSMutableArray<UIView*>* _menuParts;
  CGFloat _menuContentHeight;
  CGFloat _menuWidth;
  CGSize _laidOutSize;
  BOOL _shown;
  BOOL _dismissing;
}

- (instancetype)init {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    _menuParts = [NSMutableArray array];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  self.view.accessibilityViewIsModal = YES;

  _backdrop = [[UIVisualEffectView alloc] initWithEffect:nil];
  _backdrop.frame = self.view.bounds;
  _backdrop.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_backdrop];
  _dim = [[UIView alloc] initWithFrame:self.view.bounds];
  _dim.autoresizingMask = _backdrop.autoresizingMask;
  _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
  _dim.alpha = 0;
  [self.view addSubview:_dim];
  // Жест на фоні, а не на всьому view, бо забирав би дотики в рядків
  [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                 initWithTarget:self
                                         action:@selector(backdropTapped:)]];

  if (_previewView) {
    _cardShadow = [[UIView alloc] init];
    _cardShadow.layer.shadowColor = UIColor.blackColor.CGColor;
    _cardShadow.layer.shadowOpacity = 0.28;
    _cardShadow.layer.shadowRadius = 22;
    _cardShadow.layer.shadowOffset = CGSizeMake(0, 6);
    _card = [[UIView alloc] init];
    _card.backgroundColor = PreviewCardColor();
    _card.layer.cornerRadius = kCornerRadius;
    if (@available(iOS 13.0, *)) {
      _card.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _card.clipsToBounds = YES;
    _card.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _previewView.userInteractionEnabled = NO;
    _previewView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_card addSubview:_previewView];
    UIActivityIndicatorViewStyle style;
    if (@available(iOS 13.0, *)) {
      style = UIActivityIndicatorViewStyleMedium;
    } else {
      style = UIActivityIndicatorViewStyleGray;
    }
    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:style];
    _spinner.hidesWhenStopped = YES;
    [_card addSubview:_spinner];
    [_cardShadow addSubview:_card];
    [self.view addSubview:_cardShadow];
    UITapGestureRecognizer* tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(cardTapped:)];
    [_cardShadow addGestureRecognizer:tap];
    _cardShadow.isAccessibilityElement = YES;
    _cardShadow.accessibilityLabel = _headerText;
    _cardShadow.accessibilityTraits = UIAccessibilityTraitButton;
  }

  _menu = [[UIVisualEffectView alloc] initWithEffect:MenuBlur()];
  _menu.layer.cornerRadius = kCornerRadius;
  if (@available(iOS 13.0, *)) {
    _menu.layer.cornerCurve = kCACornerCurveContinuous;
  }
  _menu.clipsToBounds = YES;
  _menuScroll = [[UIScrollView alloc] init];
  _menuScroll.showsHorizontalScrollIndicator = NO;
  _menuScroll.alwaysBounceVertical = NO;
  _menuScroll.delaysContentTouches = NO;
  [_menu.contentView addSubview:_menuScroll];
  [self.view addSubview:_menu];
  [self buildMenu];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(dismissPreview)
             name:UIApplicationWillResignActiveNotification
           object:nil];
}

- (void)buildMenu {
  _menuWidth = kMenuWidth;
  UIFont* rowFont = [UIFont systemFontOfSize:17];
  for (BlinkerLinkPreviewItem* item in _items) {
    const CGFloat text =
        ceil([item.title sizeWithAttributes:@{NSFontAttributeName : rowFont}]
                 .width);
    _menuWidth = std::max<CGFloat>(_menuWidth, text + 16 + 8 + 28 + 16);
  }
  CGFloat y = 0;
  if (!_previewView && _headerText.length) {
    _header = [[UILabel alloc] init];
    _header.text = _headerText;
    _header.font = [UIFont systemFontOfSize:13];
    _header.textColor = PreviewSecondaryColor();
    _header.numberOfLines = 2;
    _header.lineBreakMode = NSLineBreakByTruncatingMiddle;
    const CGSize fit =
        [_header sizeThatFits:CGSizeMake(_menuWidth - 32, CGFLOAT_MAX)];
    _header.frame = CGRectMake(16, 11, _menuWidth - 32, ceil(fit.height));
    [_menuScroll addSubview:_header];
    y = CGRectGetMaxY(_header.frame) + 11;
    [_menuParts addObject:_header];
  }
  const CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
  BOOL first = YES;
  for (BlinkerLinkPreviewItem* item in _items) {
    if (!first || y > 0) {
      UIView* line = [[UIView alloc] init];
      const CGFloat height = item.startsGroup && !first ? kGroupGap : hairline;
      line.backgroundColor = item.startsGroup && !first
                                 ? PreviewFillColor(0.08)
                                 : PreviewSeparatorColor();
      line.frame = CGRectMake(0, y, _menuWidth, height);
      line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
      [_menuScroll addSubview:line];
      y += height;
    }
    BlinkerPreviewMenuRow* row = [[BlinkerPreviewMenuRow alloc] initWithItem:item];
    row.frame = CGRectMake(0, y, _menuWidth, kRowHeight);
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addTarget:self
                  action:@selector(rowTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [_menuScroll addSubview:row];
    y += kRowHeight;
    first = NO;
  }
  _menuContentHeight = y;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  const CGSize size = self.view.bounds.size;
  if (CGSizeEqualToSize(size, _laidOutSize)) {
    return;
  }
  _laidOutSize = size;
  [self layoutForSize:size];
}

- (void)layoutForSize:(CGSize)size {
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const CGFloat top = std::max<CGFloat>(safe.top, 20) + 8;
  const CGFloat bottom = size.height - std::max<CGFloat>(safe.bottom, 8) - 8;
  const CGFloat left = safe.left + kMargin;
  const CGFloat right = size.width - safe.right - kMargin;
  const CGFloat available = bottom - top;
  const CGFloat menuWidth = std::min<CGFloat>(_menuWidth, right - left);
  CGFloat menuHeight = std::min(_menuContentHeight, available);
  CGRect menuFrame;

  if (_previewView) {
    const BOOL sideBySide = size.width > size.height && size.width >= 560;
    CGRect cardFrame;
    if (sideBySide) {
      const CGFloat maxWidth = right - left - kMargin - menuWidth;
      CGSize card = CGSizeMake(maxWidth, available);
      card = [self fitContent:card];
      cardFrame = CGRectMake(left + (maxWidth - card.width) / 2,
                             top + (available - card.height) / 2, card.width,
                             card.height);
      menuFrame = CGRectMake(right - menuWidth, top, menuWidth, menuHeight);
    } else {
      const CGFloat maxWidth = std::min<CGFloat>(right - left, 560);
      const CGFloat menuShare = std::min(
          _menuContentHeight,
          std::max<CGFloat>(available * 0.5, available - kGap - 240));
      CGFloat maxHeight = available - kGap - menuShare;
      CGSize card = CGSizeMake(maxWidth, std::min(maxHeight, maxWidth * 1.3));
      card = [self fitContent:card];
      card.height = std::max<CGFloat>(card.height, 120);
      menuHeight =
          std::min(_menuContentHeight, available - kGap - card.height);
      const CGFloat total = card.height + kGap + menuHeight;
      const CGFloat y = top + std::max<CGFloat>(0, (available - total) / 2);
      cardFrame = CGRectMake((size.width - card.width) / 2, y, card.width,
                             card.height);
      const BOOL leading = _touchPoint.x < size.width / 2;
      const CGFloat menuX = leading ? CGRectGetMinX(cardFrame)
                                    : CGRectGetMaxX(cardFrame) - menuWidth;
      menuFrame = CGRectMake(std::clamp(menuX, left, right - menuWidth),
                             CGRectGetMaxY(cardFrame) + kGap, menuWidth,
                             menuHeight);
    }
    _cardShadow.frame = cardFrame;
    _cardShadow.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:_cardShadow.bounds
                                   cornerRadius:kCornerRadius]
            .CGPath;
    _card.frame = _cardShadow.bounds;
    _previewView.frame = _card.bounds;
    _spinner.center = CGPointMake(CGRectGetMidX(_card.bounds),
                                  CGRectGetMidY(_card.bounds));
    if (_onPreviewLayout) {
      _onPreviewLayout(_card.bounds.size);
    }
  } else {
    const CGFloat x = std::clamp(_touchPoint.x - menuWidth / 2, left,
                                 std::max(left, right - menuWidth));
    CGFloat y = _touchPoint.y + 16;
    if (y + menuHeight > bottom) {
      y = _touchPoint.y - 16 - menuHeight;
    }
    y = std::clamp(y, top, std::max(top, bottom - menuHeight));
    menuFrame = CGRectMake(x, y, menuWidth, menuHeight);
  }
  _menu.frame = menuFrame;
  _menuScroll.frame = _menu.contentView.bounds;
  _menuScroll.contentSize = CGSizeMake(menuWidth, _menuContentHeight);
  _menuScroll.scrollEnabled = _menuContentHeight > menuHeight + 0.5;
  for (UIView* part in _menuScroll.subviews) {
    CGRect frame = part.frame;
    frame.size.width = part == _header ? menuWidth - 32 : menuWidth;
    part.frame = frame;
  }
}

- (CGSize)fitContent:(CGSize)box {
  if (_previewContentSize.width <= 0 || _previewContentSize.height <= 0) {
    return box;
  }
  const CGFloat scale =
      std::min(box.width / _previewContentSize.width,
               box.height / _previewContentSize.height);
  return CGSizeMake(floor(_previewContentSize.width * scale),
                    floor(_previewContentSize.height * scale));
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_shown) {
    return;
  }
  _shown = YES;
  UIImpactFeedbackGenerator* haptic = [[UIImpactFeedbackGenerator alloc]
      initWithStyle:UIImpactFeedbackStyleMedium];
  [haptic impactOccurred];
  _cardShadow.alpha = 0;
  _cardShadow.transform = CGAffineTransformMakeScale(0.88, 0.88);
  _menu.alpha = 0;
  _menu.transform = CGAffineTransformMakeScale(0.6, 0.6);
  [UIView animateWithDuration:0.22
                   animations:^{
                     self->_backdrop.effect = BackdropBlur();
                     self->_dim.alpha = 1;
                   }];
  [UIView animateWithDuration:0.42
                        delay:0
       usingSpringWithDamping:0.78
        initialSpringVelocity:0.4
                      options:UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self->_cardShadow.alpha = 1;
                     self->_cardShadow.transform = CGAffineTransformIdentity;
                   }
                   completion:nil];
  [UIView animateWithDuration:0.38
                        delay:0.04
       usingSpringWithDamping:0.8
        initialSpringVelocity:0.4
                      options:UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self->_menu.alpha = 1;
                     self->_menu.transform = CGAffineTransformIdentity;
                   }
                   completion:nil];
  UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,
                                  _previewView ? _cardShadow : _menu);
}

// Якщо прев'ю закрив хтось інший, прибирання однаково має статись
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  dispatch_block_t dismissed = self.onDismiss;
  self.onDismiss = nil;
  if (dismissed) {
    dismissed();
  }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:
           (id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [self dismissPreview];
}

- (void)setPreviewLoading:(BOOL)loading {
  if (loading) {
    [_spinner startAnimating];
    [_card bringSubviewToFront:_spinner];
  } else {
    [_spinner stopAnimating];
  }
}

- (void)backdropTapped:(UITapGestureRecognizer*)tap {
  const CGPoint point = [tap locationInView:self.view];
  if (CGRectContainsPoint(_menu.frame, point) ||
      (_cardShadow && CGRectContainsPoint(_cardShadow.frame, point))) {
    return;
  }
  [self dismissPreview];
}

- (void)cardTapped:(UITapGestureRecognizer*)tap {
  [self finishWithAction:_onPreviewTap];
}

- (void)rowTapped:(BlinkerPreviewMenuRow*)row {
  [self finishWithAction:row.item.action];
}

- (BOOL)accessibilityPerformEscape {
  [self dismissPreview];
  return YES;
}

- (void)dismissPreview {
  [self finishWithAction:nil];
}

- (void)finishWithAction:(dispatch_block_t)action {
  if (_dismissing) {
    return;
  }
  _dismissing = YES;
  self.view.userInteractionEnabled = NO;
  dispatch_block_t done = ^{
    dispatch_block_t dismissed = self.onDismiss;
    self.onDismiss = nil;
    if (dismissed) {
      dismissed();
    }
    if (action) {
      action();
    }
  };
  [UIView animateWithDuration:0.18
      animations:^{
        self->_backdrop.effect = nil;
        self->_dim.alpha = 0;
        self->_cardShadow.alpha = 0;
        self->_cardShadow.transform = CGAffineTransformMakeScale(0.95, 0.95);
        self->_menu.alpha = 0;
      }
      completion:^(BOOL finished) {
        UIViewController* presenter = self.presentingViewController;
        if (presenter && presenter.presentedViewController == self) {
          [presenter dismissViewControllerAnimated:NO completion:done];
        } else {
          done();
        }
      }];
}
@end
