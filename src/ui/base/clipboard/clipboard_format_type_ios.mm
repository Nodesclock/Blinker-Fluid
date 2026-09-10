// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "ui/base/clipboard/clipboard_format_type.h"

#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "ui/base/clipboard/clipboard_constants.h"

namespace ui {

namespace {

enum class StandardClipboardType {
  kFileUrl,
  kUrl,
  kPlainText,
  kHtml,
  kSvg,
  kRtf,
  kPng,
  kImage,
};

NSString* StandardClipboardTypeIdentifier(StandardClipboardType type) {
  if (@available(iOS 14.0, *)) {
    switch (type) {
      case StandardClipboardType::kFileUrl:
        return UTTypeFileURL.identifier;
      case StandardClipboardType::kUrl:
        return UTTypeURL.identifier;
      case StandardClipboardType::kPlainText:
        return UTTypePlainText.identifier;
      case StandardClipboardType::kHtml:
        return UTTypeHTML.identifier;
      case StandardClipboardType::kSvg:
        return UTTypeSVG.identifier;
      case StandardClipboardType::kRtf:
        return UTTypeRTF.identifier;
      case StandardClipboardType::kPng:
        return UTTypePNG.identifier;
      case StandardClipboardType::kImage:
        return UTTypeImage.identifier;
    }
  }

  switch (type) {
    case StandardClipboardType::kFileUrl:
      return (__bridge NSString*)kUTTypeFileURL;
    case StandardClipboardType::kUrl:
      return (__bridge NSString*)kUTTypeURL;
    case StandardClipboardType::kPlainText:
      return (__bridge NSString*)kUTTypePlainText;
    case StandardClipboardType::kHtml:
      return (__bridge NSString*)kUTTypeHTML;
    case StandardClipboardType::kSvg:
      return (__bridge NSString*)kUTTypeScalableVectorGraphics;
    case StandardClipboardType::kRtf:
      return (__bridge NSString*)kUTTypeRTF;
    case StandardClipboardType::kPng:
      return (__bridge NSString*)kUTTypePNG;
    case StandardClipboardType::kImage:
      return (__bridge NSString*)kUTTypeImage;
  }
  return nil;
}

}  // namespace

struct ClipboardFormatType::ObjCStorage {
  // A Uniform Type identifier string.
  NSString* uttype;
};

// ClipboardFormatType implementation.
ClipboardFormatType::ClipboardFormatType()
    : objc_storage_(std::make_unique<ObjCStorage>()) {}

ClipboardFormatType::ClipboardFormatType(NSString* native_format)
    : ClipboardFormatType() {
  objc_storage_->uttype = native_format;
}

ClipboardFormatType::ClipboardFormatType(const ClipboardFormatType& other)
    : ClipboardFormatType() {
  objc_storage_->uttype = other.objc_storage_->uttype;
}

ClipboardFormatType& ClipboardFormatType::operator=(
    const ClipboardFormatType& other) {
  if (this != &other) {
    objc_storage_->uttype = other.objc_storage_->uttype;
  }
  return *this;
}

bool ClipboardFormatType::operator==(const ClipboardFormatType& other) const {
  return [objc_storage_->uttype isEqualToString:other.objc_storage_->uttype];
}

ClipboardFormatType::~ClipboardFormatType() = default;

std::string ClipboardFormatType::Serialize() const {
  return base::SysNSStringToUTF8(objc_storage_->uttype);
}

NSString* ClipboardFormatType::ToNSString() const {
  return objc_storage_->uttype;
}

// static
ClipboardFormatType ClipboardFormatType::Deserialize(
    std::string_view serialization) {
  return ClipboardFormatType(base::SysUTF8ToNSString(serialization));
}

std::string ClipboardFormatType::GetName() const {
  return Serialize();
}

bool ClipboardFormatType::operator<(const ClipboardFormatType& other) const {
  return [objc_storage_->uttype compare:other.objc_storage_->uttype] ==
         NSOrderedAscending;
}

std::string ClipboardFormatType::WebCustomFormatName(int index) {
  return base::StrCat(
      {"org.w3.web-custom-format.type-", base::NumberToString(index)});
}

// static
const ClipboardFormatType& ClipboardFormatType::WebCustomFormatMap() {
  static base::NoDestructor<ClipboardFormatType> type(
      @"org.w3.web-custom-format.map");
  return *type;
}

// static
ClipboardFormatType ClipboardFormatType::CustomPlatformType(
    std::string_view format_string) {
  CHECK(base::IsStringASCII(format_string));
  return ClipboardFormatType::Deserialize(format_string);
}

// Various predefined ClipboardFormatTypes.

// static
const ClipboardFormatType& ClipboardFormatType::FilenamesType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kFileUrl));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::UrlType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kUrl));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::PlainTextType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kPlainText));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::HtmlType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kHtml));
  return *type;
}

const ClipboardFormatType& ClipboardFormatType::SvgType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kSvg));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::RtfType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kRtf));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::PngType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kPng));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::BitmapType() {
  static base::NoDestructor<ClipboardFormatType> type(
      StandardClipboardTypeIdentifier(StandardClipboardType::kImage));
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::WebKitSmartPasteType() {
  static base::NoDestructor<ClipboardFormatType> type(
      kUTTypeWebKitWebSmartPaste);
  return *type;
}

// static
const ClipboardFormatType& ClipboardFormatType::DataTransferCustomType() {
  static base::NoDestructor<ClipboardFormatType> type(
      kUTTypeChromiumDataTransferCustomData);
  return *type;
}

}  // namespace ui
