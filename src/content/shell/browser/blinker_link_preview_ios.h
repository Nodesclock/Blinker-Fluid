// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_LINK_PREVIEW_IOS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_LINK_PREVIEW_IOS_H_

#import <UIKit/UIKit.h>

@interface BlinkerLinkPreviewItem : NSObject
+ (instancetype)itemWithTitle:(NSString*)title
                       symbol:(NSString*)symbol
                       action:(dispatch_block_t)action;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, strong) UIImage* image;
@property(nonatomic, copy) dispatch_block_t action;
@property(nonatomic, assign) BOOL startsGroup;
@end

// Показувати з UIModalPresentationOverFullScreen без анімації,
// контролер анімує себе сам
@interface BlinkerLinkPreviewController : UIViewController
@property(nonatomic, strong) UIView* previewView;
@property(nonatomic, assign) CGSize previewContentSize;
@property(nonatomic, copy) NSString* headerText;
@property(nonatomic, copy) NSArray<BlinkerLinkPreviewItem*>* items;
@property(nonatomic, assign) CGPoint touchPoint;
@property(nonatomic, copy) dispatch_block_t onPreviewTap;
// Раз після зникнення, ще до дії пункту
@property(nonatomic, copy) dispatch_block_t onDismiss;
@property(nonatomic, copy) void (^onPreviewLayout)(CGSize size);
- (void)setPreviewLoading:(BOOL)loading;
- (void)dismissPreview;
@end

#endif  // CONTENT_SHELL_BROWSER_BLINKER_LINK_PREVIEW_IOS_H_
