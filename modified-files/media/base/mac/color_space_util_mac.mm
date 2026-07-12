// Copyright 2020 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "media/base/mac/color_space_util_mac.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <simd/simd.h>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/memory/scoped_policy.h"
#include "base/no_destructor.h"
#include "third_party/skia/modules/skcms/skcms.h"
#include "ui/gfx/mac/color_space_util.h"

namespace media {

namespace {
// CVBufferCopyAttachment() is iOS 15+/macOS 12+; at a 14.0 deployment target
// it is weak-imported and NULL on iOS 14. Fall back to the older
// CVBufferGetAttachment(), which returns a non-owned reference, and retain it
// to match the +1 ownership CVBufferCopyAttachment would have given.
base::apple::ScopedCFTypeRef<CFTypeRef> CopyCVBufferAttachment(
    CVImageBufferRef image_buffer,
    CFStringRef key) {
  if (__builtin_available(iOS 15, macOS 12, *)) {
    return base::apple::ScopedCFTypeRef<CFTypeRef>(
        CVBufferCopyAttachment(image_buffer, key, /*attachmentMode=*/nullptr));
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return base::apple::ScopedCFTypeRef<CFTypeRef>(
      CVBufferGetAttachment(image_buffer, key, /*attachmentMode=*/nullptr),
      base::scoped_policy::RETAIN);
#pragma clang diagnostic pop
}
}  // namespace

gfx::ColorSpace GetImageBufferColorSpace(CVImageBufferRef image_buffer) {
  base::apple::ScopedCFTypeRef<CFTypeRef> color_primaries(
      CopyCVBufferAttachment(image_buffer, kCVImageBufferColorPrimariesKey));
  base::apple::ScopedCFTypeRef<CFTypeRef> transfer_function(
      CopyCVBufferAttachment(image_buffer, kCVImageBufferTransferFunctionKey));
  base::apple::ScopedCFTypeRef<CFTypeRef> gamma_level(
      CopyCVBufferAttachment(image_buffer, kCVImageBufferGammaLevelKey));
  base::apple::ScopedCFTypeRef<CFTypeRef> ycbcr_matrix(
      CopyCVBufferAttachment(image_buffer, kCVImageBufferYCbCrMatrixKey));

  return gfx::ColorSpaceFromCVImageBufferKeys(
      color_primaries.get(), transfer_function.get(), gamma_level.get(),
      ycbcr_matrix.get());
}

gfx::ColorSpace GetFormatDescriptionColorSpace(
    CMFormatDescriptionRef format_description) {
  return gfx::ColorSpaceFromCVImageBufferKeys(
      CMFormatDescriptionGetExtension(
          format_description, kCMFormatDescriptionExtension_ColorPrimaries),
      CMFormatDescriptionGetExtension(
          format_description, kCMFormatDescriptionExtension_TransferFunction),
      CMFormatDescriptionGetExtension(format_description,
                                      kCMFormatDescriptionExtension_GammaLevel),
      CMFormatDescriptionGetExtension(
          format_description, kCMFormatDescriptionExtension_YCbCrMatrix));
}

// Converts a gfx::ColorSpace to individual kCVImageBuffer* keys.
bool GetImageBufferColorValues(const gfx::ColorSpace& color_space,
                               CFStringRef* out_primaries,
                               CFStringRef* out_transfer,
                               CFStringRef* out_matrix) {
  return gfx::ColorSpaceToCVImageBufferKeys(
      color_space,
      /*prefer_srgb_trfn=*/false, out_primaries, out_transfer, out_matrix);
}

}  // namespace media
