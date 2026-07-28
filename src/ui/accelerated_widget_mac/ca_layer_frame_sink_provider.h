// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef UI_ACCELERATED_WIDGET_MAC_CA_LAYER_FRAME_SINK_PROVIDER_H_
#define UI_ACCELERATED_WIDGET_MAC_CA_LAYER_FRAME_SINK_PROVIDER_H_

#include <UIKit/UIKit.h>

#include "build/build_config.h"
#include "ui/gfx/native_ui_types.h"

#if !BUILDFLAG(IS_IOS_TVOS)
#include <BrowserEngineKit/BrowserEngineKit.h>
#endif  // !BUILDFLAG(IS_IOS_TVOS)

namespace ui {
class CALayerFrameSink;
}

// iOS-15 port: BELayerHierarchyHostingView is a BrowserEngineKit class that
// only exists on iOS 17.4+. On iOS 15 it is nil, which makes this class (and its
// subclass RenderWidgetUIView, the web-content view) un-realizable by the ObjC
// runtime -> the view is nil -> viewHandle is 0 -> null surface handle -> viz
// renders OFFSCREEN (gray screen). Base on a plain UIView (which is what
// BELayerHierarchyHostingView is anyway) so the view exists and provides a valid
// accelerated widget; the GPU's CALayer is attached in-process instead of via
// the BEK layer hierarchy.
@interface CALayerFrameSinkProvider : UIView

- (id)init;
- (ui::CALayerFrameSink*)frameSink;
- (gfx::AcceleratedWidget)viewHandle;
// iOS-15 port: attach the GPU's rendered CALayer as the on-screen content and
// keep it sized to this view's bounds across layout/rotation.
- (void)attachContentLayer:(CALayer*)layer;
+ (CALayerFrameSinkProvider*)lookupByHandle:(uint64_t)viewHandle;
@end

#endif  // UI_ACCELERATED_WIDGET_MAC_CA_LAYER_FRAME_SINK_PROVIDER_H_
