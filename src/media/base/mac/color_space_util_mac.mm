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

// CVBufferCopyAttachment() лише з iOS 15. CVBufferGetAttachment()
// вертає не свою ссилку, тому RETAIN
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

base::apple::ScopedCFTypeRef<CFDictionaryRef>
GetImageBufferPixelFormatDescription(CVImageBufferRef image_buffer) {
  // CoreVideo does not expose the YUV range as a separate image-buffer
  // attachment. For CVPixelBuffers, the range is described by the pixel
  // format.
  if (!image_buffer || CFGetTypeID(image_buffer) != CVPixelBufferGetTypeID()) {
    return base::apple::ScopedCFTypeRef<CFDictionaryRef>();
  }

  return base::apple::ScopedCFTypeRef<CFDictionaryRef>(
      CVPixelFormatDescriptionCreateWithPixelFormatType(
          nullptr, CVPixelBufferGetPixelFormatType(image_buffer)));
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
  const auto pixel_format_description =
      GetImageBufferPixelFormatDescription(image_buffer);
  const CFTypeRef component_range =
      pixel_format_description
          ? CFDictionaryGetValue(pixel_format_description.get(),
                                 kCVPixelFormatComponentRange)
          : nullptr;
  return gfx::ColorSpaceFromCVImageBufferKeys(
      color_primaries.get(), transfer_function.get(), gamma_level.get(),
      ycbcr_matrix.get(), component_range);
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
          format_description, kCMFormatDescriptionExtension_YCbCrMatrix),
      CMFormatDescriptionGetExtension(
          format_description, kCMFormatDescriptionExtension_FullRangeVideo));
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
