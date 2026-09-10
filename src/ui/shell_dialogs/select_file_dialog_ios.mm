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
}

- (instancetype)initWithDialog:(base::WeakPtr<ui::SelectFileDialogImpl>)dialog
                viewController:(UIViewController*)viewController
            allowMultipleFiles:(bool)allowMultipleFiles
               fileUTTypeLists:(NSArray*)fileUTTypeLists
          allowsOtherFileTypes:(bool)allowsOtherFileTypes
                   isDirectory:(bool)isDirectory
                      mediaOnly:(bool)mediaOnly
                useMediaCapture:(bool)useMediaCapture;
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
                useMediaCapture:(bool)useMediaCapture {
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
  return self;
}

- (void)dealloc {
  _documentPickerController.delegate = nil;
  _imagePickerController.delegate = nil;
  if (@available(iOS 14.0, *)) {
    _photoPickerController.delegate = nil;
  }
}

- (void)showFilePickerMenu {
  // Follow the HTML intent directly, like Reynard: image/video inputs open the
  // actual Apple Photos picker; `capture` opens Camera; generic inputs open
  // Files. No intermediate Blinker-owned action sheet.
  if (_useMediaCapture && _mediaOnly &&
      [UIImagePickerController
          isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    [self showCameraPicker];
  } else if (_mediaOnly) {
    [self showPhotoPicker];
  } else {
    [self showDocumentPicker];
  }
}

- (void)showDocumentPicker {
  if (@available(iOS 14.0, *)) {
    NSArray* documentTypes = _isDirectory ? @[ UTTypeFolder ] : @[ UTTypeItem ];
    if (!_isDirectory && !_allowsOtherFileTypes) {
      documentTypes = _fileUTTypeLists;
    }
    _documentPickerController = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:documentTypes];
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
                       inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
  }
  _documentPickerController.allowsMultipleSelection = _allowMultipleFiles;

  _documentPickerController.delegate = self;

  [self presentController:_documentPickerController];
}

- (void)showPhotoPicker {
  if (@available(iOS 14.0, *)) {
    PHPickerConfiguration* configuration =
        [[PHPickerConfiguration alloc] initWithPhotoLibrary:
                                           [PHPhotoLibrary sharedPhotoLibrary]];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
      PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter
    ]];
    configuration.selectionLimit = _allowMultipleFiles ? 0 : 1;
    _photoPickerController =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    _photoPickerController.delegate = self;
    [self presentController:_photoPickerController];
    return;
  }

  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  _imagePickerController.mediaTypes = @[
    (__bridge NSString*)kUTTypeImage, (__bridge NSString*)kUTTypeMovie
  ];
  _imagePickerController.delegate = self;
  [self presentController:_imagePickerController];
}

- (void)showCameraPicker {
  _imagePickerController = [[UIImagePickerController alloc] init];
  _imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
  _imagePickerController.mediaTypes = @[
    (__bridge NSString*)kUTTypeImage, (__bridge NSString*)kUTTypeMovie
  ];
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
    resultURL = [self temporaryURLForFilename:@"photo.jpg"];
    if (![data writeToURL:resultURL atomically:YES]) {
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

- (void)picker:(PHPickerViewController*)picker
    didFinishPicking:(NSArray<PHPickerResult*>*)results API_AVAILABLE(ios(14)) {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count) {
    [self finishWithURLs:@[] cancelled:YES];
    return;
  }

  dispatch_group_t group = dispatch_group_create();
  NSMutableArray<NSURL*>* copiedURLs = [NSMutableArray array];
  for (PHPickerResult* result in results) {
    NSItemProvider* provider = result.itemProvider;
    NSString* type = provider.registeredTypeIdentifiers.firstObject;
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
          @synchronized(copiedURLs) {
            [copiedURLs addObject:destination];
          }
        }
      }
      dispatch_group_leave(group);
    }];
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    [self finishWithURLs:copiedURLs cancelled:copiedURLs.count == 0];
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
  for (const std::u16string& accept : file_types->accept_types) {
    std::string token = base::UTF16ToUTF8(accept);
    if (!base::StartsWith(token, "image/", base::CompareCase::INSENSITIVE_ASCII) &&
        !base::StartsWith(token, "video/", base::CompareCase::INSENSITIVE_ASCII)) {
      // Extension-only media accepts are handled by UTType conformance below.
      if (token.empty() || token.front() != '.') {
        media_only = false;
      }
    }
  }
  if (media_only && !file_uttype_lists.count) {
    media_only = false;
  }
  if (media_only) {
    for (id file_type in file_uttype_lists) {
      bool is_media = false;
      if (@available(iOS 14.0, *)) {
        UTType* ut = (UTType*)file_type;
        is_media = [ut conformsToType:UTTypeImage] ||
                   [ut conformsToType:UTTypeMovie];
      } else {
        CFStringRef ut = (__bridge CFStringRef)file_type;
        is_media = UTTypeConformsTo(ut, kUTTypeImage) ||
                   UTTypeConformsTo(ut, kUTTypeMovie);
      }
      if (!is_media) {
        media_only = false;
        break;
      }
    }
  }
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
                                useMediaCapture:file_types->use_media_capture];
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
