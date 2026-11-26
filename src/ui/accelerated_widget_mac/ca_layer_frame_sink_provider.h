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

// BELayerHierarchyHostingView тільки з iOS 17.4, без нього viz малює offscreen.
// Тому звичайний UIView, CALayer з GPU чіпляємо в процесі
@interface CALayerFrameSinkProvider : UIView

- (id)init;
- (ui::CALayerFrameSink*)frameSink;
- (gfx::AcceleratedWidget)viewHandle;
- (void)attachContentLayer:(CALayer*)layer;
+ (CALayerFrameSinkProvider*)lookupByHandle:(uint64_t)viewHandle;
@end

#endif  // UI_ACCELERATED_WIDGET_MAC_CA_LAYER_FRAME_SINK_PROVIDER_H_
