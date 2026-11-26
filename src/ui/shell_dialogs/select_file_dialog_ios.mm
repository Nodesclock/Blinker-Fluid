// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "ui/shell_dialogs/select_file_dialog_ios.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIDocumentPickerViewController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>

#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/memory/weak_ptr.h"
#include "base/notreached.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "ui/shell_dialogs/select_file_policy.h"
#include "ui/shell_dialogs/selected_file_info.h"

// Labels go through the shell's translation table. Weak, so a target that
// links this file without the shell still gets the English text.
extern "C" NSString* BlinkLocalizedString(NSString* english)
    __attribute__((weak_import));

static NSString* LocalizedLabel(NSString* english) {
  return BlinkLocalizedString ? BlinkLocalizedString(english) : english;
}

@interface NativeFileDialog
    : NSObject <UIDocumentPickerDelegate,
                UIImagePickerControllerDelegate,
                UINavigationControllerDelegate,
                PHPickerViewControllerDelegate> {
 @private
  base::WeakPtr<ui::SelectFileDialogImpl> _dialog;
  UIViewController* __weak _viewController;
  bool _allowMultipleFiles;
  UIDocumentPickerViewController* __strong _documentPickerController;
  UIImagePickerController* __strong _imagePickerController;
  PHPickerViewController* __strong _photoPickerController API_AVAILABLE(ios(14));
  NSArray* __strong _fileUTTypeLists;
  bool _allowsOtherFileTypes;
  bool _isDirectory;
  bool _mediaOnly;
  bool _useMediaCapture;
  bool _mediaAllowed;
  bool _wantsImages;
  bool _wantsVideos;
  bool _keepHEIC;
}

- (instancetype)initWithDialog:(base::WeakPtr<ui::SelectFileDialogImpl>)dialog
                viewController:(UIViewController*)viewController
            allowMultipleFiles:(bool)allowMultipleFiles
               fileUTTypeLists:(NSArray*)fileUTTypeLists
          allowsOtherFileTypes:(bool)allowsOtherFileTypes
                   isDirectory:(bool)isDirectory
                      mediaOnly:(bool)mediaOnly
                useMediaCapture:(bool)useMediaCapture
                   mediaAllowed:(bool)mediaAllowed
                    wantsImages:(bool)wantsImages
                    wantsVideos:(bool)wantsVideos
                       keepHEIC:(bool)keepHEIC;
- (void)dealloc;
- (void)showFilePickerMenu;
- (void)showDocumentPicker;
- (void)showPhotoPicker;
- (void)showCameraPicker;
- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls;
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller;
@end

@implementation NativeFileDialog

- (void)presentController:(UIViewController*)controller {
  UIViewController* presenter = _viewController;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  [presenter presentViewController:controller animated:YES completion:nil];
}

- (NSURL*)temporaryURLForFilename:(NSString*)filename {
  NSString* safeName = filename.length ? filename : @"upload";
  NSString* directory = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil]) {
    return nil;
  }
  return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:safeName]];
}

- (void)finishWithURLs:(NSArray<NSURL*>*)urls cancelled:(BOOL)cancelled {
  if (!_dialog) {
    return;
  }
  std::vector<base::FilePath> paths;
  for (NSURL* url in urls) {
    if (url.isFileURL) {
      paths.push_back(base::apple::NSStringToFilePath(url.path));
    }
  }
  _dialog->FileWasSelected(_allowMultipleFiles, cancelled, paths, 0);
}

- (instancetype)initWithDialog:(base::WeakPtr<ui::SelectFileDialogImpl>)dialog
                viewController:(UIViewController*)viewController
            allowMultipleFiles:(bool)allowMultipleFiles
               fileUTTypeLists:(NSArray*)fileUTTypeLists
          allowsOtherFileTypes:(bool)allowsOtherFileTypes
                   isDirectory:(bool)isDirectory
                      mediaOnly:(bool)mediaOnly
                useMediaCapture:(bool)useMediaCapture
                   mediaAllowed:(bool)mediaAllowed
                    wantsImages:(bool)wantsImages
                    wantsVideos:(bool)wantsVideos
                       keepHEIC:(bool)keepHEIC {
  if (!(self = [super init])) {
    return nil;
  }
  _dialog = dialog;
  _viewController = viewController;
  _allowMultipleFiles = allowMultipleFiles;
  _fileUTTypeLists = fileUTTypeLists;
  _allowsOtherFileTypes = allowsOtherFileTypes;
  _isDirectory = isDirectory;
  _mediaOnly = mediaOnly;
  _useMediaCapture = useMediaCapture;
  _mediaAllowed = mediaAllowed;
  _wantsImages = wantsImages;
  _wantsVideos = wantsVideos;
  _keepHEIC = keepHEIC;
  return self;
}

- (void)dealloc {
  _documentPickerController.delegate = nil;
  _imagePickerController.delegate = nil;
  if (@available(iOS 14.0, *)) {
    _photoPickerController.delegate = nil;
  }
}

// A site that takes images or videos (or anything) gets the same three
// choices as in Safari. Folders and non-media accepts go straight to Files,
// and `capture` goes straight to the camera.
- (BOOL)cameraAvailable {
  NSBundle* bundle = NSBundle.mainBundle;
  if (![UIImagePickerController
          isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    return NO;
  }
  // Without these strings iOS kills the app when the camera opens.
  if (![bundle objectForInfoDictionaryKey:@"NSCameraUsageDescription"]) {
    return NO;
  }
  if (_wantsVideos &&
      ![bundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"]) {
    _wantsVideos = false;
    if (!_wantsImages) {
      return NO;
    }
  }
  return YES;
}

- (void)showFilePickerMenu {
  if (_isDirectory || !_mediaAllowed) {
    [self showDocumentPicker];
    return;
  }
  const BOOL camera = [self cameraAvailable];
  if (_useMediaCapture && _mediaOnly && camera) {
    [self showCameraPicker];
    return;
  }

  UIAlertController* sheet =
      [UIAlertController alertControllerWithTitle:nil
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleActionSheet];
  __weak NativeFileDialog* weakSelf = self;
  [sheet addAction:[UIAlertAction
                       actionWithTitle:LocalizedLabel(@"Photo Library")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction*) {
                                 [weakSelf showPhotoPicker];
                               }]];
  if (camera) {
    [sheet addAction:[UIAlertAction
                         actionWithTitle:LocalizedLabel(
                                             _wantsVideos && _wantsImages
                                                 ? @"Take Photo or Video"
                                                 : (_wantsVideos
                                                        ? @"Record Video"
                                                        : @"Take Photo"))
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction*) {
                                   [weakSelf showCameraPicker];
                                 }]];
  }
  [sheet addAction:[UIAlertAction
                       actionWithTitle:LocalizedLabel(@"Choose File")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction*) {
                                 [weakSelf showDocumentPicker];
                               }]];
  [sheet addAction:[UIAlertAction
                       actionWithTitle:LocalizedLabel(@"Cancel")
                                 style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction*) {
                                 [weakSelf finishWithURLs:@[] cancelled:YES];
                               }]];

  // iPad shows the sheet as a popover and needs an anchor.
  UIViewController* presenter = _viewController;
  while (presenter.presentedViewController) {
    presenter = presenter.presentedViewController;
  }
  UIPopoverPresentationController* popover = sheet.popoverPresentationController;
  if (popover) {
    popover.sourceView = presenter.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                    CGRectGetMidY(presenter.view.bounds), 1, 1);
    popover.permittedArrowDirections = 0;
  }
  [self presentController:sheet];
}

- (void)showDocumentPicker {
  // Files are picked as copies. A file opened in place stays outside the app
  // sandbox, so the page saw its name but read 0 bytes (NotReadableError).
  // Folders cannot be copied and keep the open mode.
  if (@available(iOS 14.0, *)) {
    NSArray* documentTypes = _isDirectory ? @[ UTTypeFolder ] : @[ UTTypeItem ];
    if (!_isDirectory && !_allowsOtherFileTypes) {
      documentTypes = _fileUTTypeLists;
    }
    _documentPickerController = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:documentTypes
                            asCopy:!_isDirectory];
  } else {
    NSArray* documentTypes = _isDirectory
                                 ? @[ (__bridge NSString*)kUTTypeFolder ]
                                 : @[ (__bridge NSString*)kUTTypeItem ];
    if (!_isDirectory && !_allowsOtherFileTypes) {
      documentTypes = _fileUTTypeLists;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _documentPickerController = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:documentTypes
                       inMode:_isDirectory ? UIDocumentPickerModeOpen
                                           : UIDocumentPickerModeImport];
#pragma clang diagnostic pop
  }
  _documentPickerController.allowsMultipleSelection = _allowMultipleFiles;

  _documentPickerController.delegate = self;

  [self presentController:_documentPickerController];
}

- (NSArray<NSString*>*)cameraMediaTypes {
  NSMutableArray<NSString*>* types = [NSMutableArray array];
  if (_wantsImages || !_wantsVideos) {
    [types addObject:(__bridge NSString*)kUTTypeImage];
  }
  if (_wantsVideos) {
    [types addObject:(__bridge NSString*)kUTTypeMovie];
  }
  return types;
}

- (void)showPhotoPicker {
  if (@available(iOS 14.0, *)) {
    PHPickerConfiguration* configuration =
        [[PHPickerConfiguration alloc] initWithPhotoLibrary:
                                           [PHPhotoLibrary sharedPhotoLibrary]];
    NSMutableArray<PHPickerFilter*>* filters = [NSMutableArray array];
    if (_wantsImages || !_wantsVideos) {
      [filters addObject:PHPickerFilter.imagesFilter];
    }
    if (_wantsVideos) {
      [filters addObject:PHPickerFilter.videosFilter];
    }
    configuration.filter = filters.count > 1
                               ? [PHPickerFilter anyFilterMatchingSubfilters:filters]
                               : filters.firstObject;
    configuration.selectionLimit = _allowMultipleFiles ? 0 : 1;
    // Let Photos hand over formats other apps understand (HEIC as JPEG).
    configuration.preferredAssetRepresentationMode =
        _keepHEIC ? PHPickerConfigurationAssetRepresentationModeCurrent
                  : PHPickerConfigurationAssetRepresentationModeCompatible;
    _photoPickerController =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    _photoPickerController.delegate = self;
    [self presentController:_photoPickerController];
    return;
  }

  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  _imagePickerController.mediaTypes = [self cameraMediaTypes];
  _imagePickerController.delegate = self;
  [self presentController:_imagePickerController];
}

- (void)showCameraPicker {
  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
  NSArray<NSString*>* available = [UIImagePickerController
      availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  NSMutableArray<NSString*>* types = [[self cameraMediaTypes] mutableCopy];
  [types filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                               NSString* type, NSDictionary*) {
           return [available containsObject:type];
         }]];
  _imagePickerController.mediaTypes =
      types.count ? types : @[ (__bridge NSString*)kUTTypeImage ];
  _imagePickerController.delegate = self;
  [self presentController:_imagePickerController];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  [self finishWithURLs:urls cancelled:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  [self finishWithURLs:@[] cancelled:YES];
}

- (void)imagePickerController:(UIImagePickerController*)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id>*)info {
  NSURL* mediaURL = info[UIImagePickerControllerMediaURL];
  NSURL* resultURL = nil;
  if (mediaURL) {
    resultURL = [self temporaryURLForFilename:mediaURL.lastPathComponent];
    if (resultURL) {
      [[NSFileManager defaultManager] copyItemAtURL:mediaURL
                                              toURL:resultURL
                                              error:nil];
    }
  } else {
    UIImage* image = info[UIImagePickerControllerOriginalImage];
    NSData* data = UIImageJPEGRepresentation(image, 0.92);
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    resultURL = [self temporaryURLForFilename:
                          [NSString stringWithFormat:@"IMG_%@.jpg",
                                                     [formatter stringFromDate:NSDate.date]]];
    if (!data || !resultURL || ![data writeToURL:resultURL atomically:YES]) {
      resultURL = nil;
    }
  }
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWithURLs:resultURL ? @[ resultURL ] : @[]
               cancelled:resultURL == nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWithURLs:@[] cancelled:YES];
}

// A Live Photo registers a bundle type first, which is not a file a site can
// use. Take the first plain image or movie type instead.
- (NSString*)usableTypeForProvider:(NSItemProvider*)provider API_AVAILABLE(ios(14)) {
  for (NSString* identifier in provider.registeredTypeIdentifiers) {
    UTType* type = [UTType typeWithIdentifier:identifier];
    if ([type conformsToType:UTTypeImage] || [type conformsToType:UTTypeMovie]) {
      return identifier;
    }
  }
  return provider.registeredTypeIdentifiers.firstObject;
}

// Sites that did not ask for HEIC mostly cannot read it, so Safari sends a
// JPEG there. Same here, orientation is kept by UIImage.
- (NSURL*)jpegCopyIfHEIC:(NSURL*)url {
  NSString* extension = url.pathExtension.lowercaseString;
  if (_keepHEIC ||
      !([extension isEqualToString:@"heic"] || [extension isEqualToString:@"heif"])) {
    return url;
  }
  NSURL* converted = nil;
  @autoreleasepool {
    UIImage* image = [UIImage imageWithContentsOfFile:url.path];
    NSData* data = image ? UIImageJPEGRepresentation(image, 0.9) : nil;
    NSString* base = [url.lastPathComponent stringByDeletingPathExtension];
    NSURL* destination =
        [self temporaryURLForFilename:[base stringByAppendingString:@".jpg"]];
    if (data && destination && [data writeToURL:destination atomically:YES]) {
      converted = destination;
    }
  }
  if (!converted) {
    return url;
  }
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  return converted;
}

- (void)picker:(PHPickerViewController*)picker
    didFinishPicking:(NSArray<PHPickerResult*>*)results API_AVAILABLE(ios(14)) {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count) {
    [self finishWithURLs:@[] cancelled:YES];
    return;
  }

  // One slot per result so the files reach the page in the order picked.
  NSMutableArray* slots = [NSMutableArray arrayWithCapacity:results.count];
  for (NSUInteger i = 0; i < results.count; ++i) {
    [slots addObject:NSNull.null];
  }
  dispatch_group_t group = dispatch_group_create();
  for (NSUInteger i = 0; i < results.count; ++i) {
    NSItemProvider* provider = results[i].itemProvider;
    NSString* type = [self usableTypeForProvider:provider];
    if (!type) {
      continue;
    }
    dispatch_group_enter(group);
    [provider loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL* url, NSError*) {
      if (url) {
        NSURL* destination = [self temporaryURLForFilename:url.lastPathComponent];
        if (destination && [[NSFileManager defaultManager] copyItemAtURL:url
                                                                   toURL:destination
                                                                   error:nil]) {
          NSURL* ready = [self jpegCopyIfHEIC:destination];
          @synchronized(slots) {
            slots[i] = ready;
          }
        }
      }
      dispatch_group_leave(group);
    }];
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    NSMutableArray<NSURL*>* urls = [NSMutableArray array];
    for (id slot in slots) {
      if ([slot isKindOfClass:NSURL.class]) {
        [urls addObject:slot];
      }
    }
    [self finishWithURLs:urls cancelled:urls.count == 0];
  });
}

@end

namespace ui {

SelectFileDialogImpl::SelectFileDialogImpl(
    Listener* listener,
    std::unique_ptr<ui::SelectFilePolicy> policy)
    : SelectFileDialog(listener, std::move(policy)) {}

bool SelectFileDialogImpl::IsRunning(gfx::NativeWindow parent_window) const {
  return listener_;
}

void SelectFileDialogImpl::ListenerDestroyed() {
  listener_ = nullptr;
}

void SelectFileDialogImpl::FileWasSelected(
    bool is_multi,
    bool was_cancelled,
    const std::vector<base::FilePath>& files,
    int index) {
  if (!listener_) {
    return;
  }

  if (was_cancelled || files.empty()) {
    listener_->FileSelectionCanceled();
  } else {
    if (is_multi) {
      listener_->MultiFilesSelected(FilePathListToSelectedFileInfoList(files));
    } else {
      listener_->FileSelected(SelectedFileInfo(files[0]), index);
    }
  }
}

void SelectFileDialogImpl::SelectFileImpl(
    SelectFileDialog::Type type,
    const std::u16string& title,
    const base::FilePath& default_path,
    const FileTypeInfo* file_types,
    int file_type_index,
    const base::FilePath::StringType& default_extension,
    gfx::NativeWindow gfx_window,
    const GURL* caller) {
  has_multiple_file_type_choices_ =
      SelectFileDialog::SELECT_OPEN_MULTI_FILE == type;
  bool allows_other_file_types = false;
  bool media_only = !file_types->accept_types.empty();
  bool directory = SelectFileDialog::SELECT_FOLDER == type ||
                   SelectFileDialog::SELECT_UPLOAD_FOLDER == type ||
                   SelectFileDialog::SELECT_EXISTING_FOLDER == type;
  NSMutableArray* file_uttype_lists = [NSMutableArray array];
  for (const auto& ext_list : file_types->extensions) {
    for (const base::FilePath::StringType& ext : ext_list) {
      id uttype = nil;
      if (@available(iOS 14.0, *)) {
        uttype =
            [UTType typeWithFilenameExtension:base::SysUTF8ToNSString(ext)];
      } else {
        base::apple::ScopedCFTypeRef<CFStringRef> legacy_uttype(
            UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassFilenameExtension,
                base::SysUTF8ToCFStringRef(ext).get(), nullptr));
        uttype = (__bridge NSString*)legacy_uttype.get();
      }
      if (!uttype) {
        continue;
      }

      if (![file_uttype_lists containsObject:uttype]) {
        [file_uttype_lists addObject:uttype];
      }
    }
  }
  // What the page accepts decides which pickers are offered. No accept list
  // means anything goes, so photos and the camera are offered as well. Only
  // the page's own tokens count: the extension list built from them also
  // holds containers like mp4 that audio/* pulls in.
  bool wants_images = false;
  bool wants_videos = false;
  bool all_media = !file_types->accept_types.empty();
  bool keep_heic = false;
  for (const std::u16string& accept : file_types->accept_types) {
    const std::string token = base::ToLowerASCII(base::UTF16ToUTF8(accept));
    bool is_image = base::StartsWith(token, "image/");
    bool is_video = base::StartsWith(token, "video/");
    if (token.size() > 1 && token.front() == '.') {
      NSString* extension = base::SysUTF8ToNSString(token.substr(1));
      if (@available(iOS 14.0, *)) {
        UTType* ut = [UTType typeWithFilenameExtension:extension];
        is_image = [ut conformsToType:UTTypeImage];
        is_video = [ut conformsToType:UTTypeMovie];
      } else {
        base::apple::ScopedCFTypeRef<CFStringRef> ut(
            UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassFilenameExtension,
                base::SysUTF8ToCFStringRef(token.substr(1)).get(), nullptr));
        is_image = ut && UTTypeConformsTo(ut.get(), kUTTypeImage);
        is_video = ut && UTTypeConformsTo(ut.get(), kUTTypeMovie);
      }
    }
    wants_images |= is_image;
    wants_videos |= is_video;
    all_media &= is_image || is_video;
    if (token.find("heic") != std::string::npos ||
        token.find("heif") != std::string::npos) {
      keep_heic = true;
    }
  }
  if (file_types->accept_types.empty()) {
    wants_images = wants_videos = true;
  }
  const bool media_allowed = wants_images || wants_videos;
  media_only = all_media;
  if (file_types->include_all_files || file_types->extensions.empty()) {
    allows_other_file_types = true;
  }

  UIViewController* controller = gfx_window.Get().rootViewController;
  native_file_dialog_ =
      [[NativeFileDialog alloc] initWithDialog:weak_factory_.GetWeakPtr()
                                viewController:controller
                            allowMultipleFiles:has_multiple_file_type_choices_
                               fileUTTypeLists:file_uttype_lists
                          allowsOtherFileTypes:allows_other_file_types
                                   isDirectory:directory
                                      mediaOnly:media_only
                                useMediaCapture:file_types->use_media_capture
                                   mediaAllowed:media_allowed
                                    wantsImages:wants_images
                                    wantsVideos:wants_videos
                                       keepHEIC:keep_heic];
  [native_file_dialog_ showFilePickerMenu];
}

SelectFileDialogImpl::~SelectFileDialogImpl() {
  // Clear |weak_factory_| beforehand, to ensure that no callbacks will be made
  // when we cancel the NSSavePanels.
  weak_factory_.InvalidateWeakPtrs();
}

bool SelectFileDialogImpl::HasMultipleFileTypeChoicesImpl() {
  return has_multiple_file_type_choices_;
}

SelectFileDialog* CreateSelectFileDialog(
    SelectFileDialog::Listener* listener,
    std::unique_ptr<SelectFilePolicy> policy) {
  return new SelectFileDialogImpl(listener, std::move(policy));
}

}  // namespace ui
