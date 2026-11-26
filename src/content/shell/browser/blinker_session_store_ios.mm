// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_session_store.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <memory>

#include "base/files/file_path.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_entry_restore_context.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "net/base/filename_util.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "third_party/blink/public/common/page_state/page_state.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace content {

namespace {

constexpr int kMaxBackEntries = 24;
constexpr int kMaxForwardEntries = 6;
// Стан сторінки це кілька КБ, але буває форма на мегабайт
constexpr size_t kMaxStateBytes = 64 * 1024;
constexpr size_t kStateBudgetPerTab = 256 * 1024;

NSString* SessionsDirectory() {
  NSURL* support = [[NSFileManager.defaultManager
      URLsForDirectory:NSApplicationSupportDirectory
             inDomains:NSUserDomainMask] firstObject];
  if (!support) {
    return nil;
  }
  NSString* dir =
      [support.path stringByAppendingPathComponent:@"BlinkerSessions"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  return dir;
}

// Усі збірки на телефоні ділять один контейнер, тому файл на кожен
// bundle id
NSString* StoreFile(NSString* kind) {
  NSString* dir = SessionsDirectory();
  NSString* bundle = NSBundle.mainBundle.bundleIdentifier ?: @"app";
  return dir ? [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@-%@.plist", kind,
                                                   bundle]]
             : nil;
}

dispatch_queue_t WriteQueue() {
  static dispatch_queue_t queue = dispatch_queue_create(
      "com.nodesclock.blinker.sessions", DISPATCH_QUEUE_SERIAL);
  return queue;
}

void WriteLater(NSString* path, id plist) {
  if (!path) {
    return;
  }
  NSData* data = [NSPropertyListSerialization
      dataWithPropertyList:plist
                    format:NSPropertyListBinaryFormat_v1_0
                   options:0
                     error:nil];
  if (!data) {
    return;
  }
  dispatch_async(WriteQueue(), ^{
    [data writeToFile:path atomically:YES];
  });
}

id ReadPlist(NSString* path) {
  NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
  return data ? [NSPropertyListSerialization propertyListWithData:data
                                                          options:0
                                                           format:nil
                                                            error:nil]
              : nil;
}

bool KeepEntryURL(const GURL& url) {
  return url.is_valid() && (url.SchemeIsHTTPOrHTTPS() || url.IsAboutBlank() ||
                            BlinkerIsSavedPageURL(url));
}

NSDictionary* SerializeContents(WebContents* contents) {
  if (!contents) {
    return nil;
  }
  NavigationController& controller = contents->GetController();
  NavigationEntry* last = controller.GetLastCommittedEntry();
  const int count = controller.GetEntryCount();
  const int current = controller.GetLastCommittedEntryIndex();
  if (!last || last->IsInitialEntry() || count <= 0 || current < 0 ||
      !KeepEntryURL(last->GetURL())) {
    return nil;
  }
  const int first = std::max(0, current - kMaxBackEntries);
  const int end = std::min(count, current + kMaxForwardEntries + 1);
  std::vector<bool> with_state(end - first, false);
  size_t budget = kStateBudgetPerTab;
  for (int distance = 0; distance < end - first; ++distance) {
    const int candidates[2] = {current - distance, current + distance};
    for (int k = 0; k < (distance == 0 ? 1 : 2); ++k) {
      const int index = candidates[k];
      if (index < first || index >= end) {
        continue;
      }
      NavigationEntry* entry = controller.GetEntryAtIndex(index);
      if (!entry || entry->GetHasPostData()) {
        continue;
      }
      const size_t size = entry->GetPageState().ToEncodedData().size();
      if (size && size <= kMaxStateBytes && size <= budget) {
        with_state[index - first] = true;
        budget -= size;
      }
    }
  }
  NSMutableArray* entries = [NSMutableArray array];
  NSInteger new_index = -1;
  for (int i = first; i < end; ++i) {
    NavigationEntry* entry = controller.GetEntryAtIndex(i);
    if (!entry || !KeepEntryURL(entry->GetURL())) {
      continue;
    }
    if (i == current) {
      new_index = static_cast<NSInteger>(entries.count);
    }
    NSMutableDictionary* item = [NSMutableDictionary dictionary];
    item[@"url"] = base::SysUTF8ToNSString(entry->GetURL().spec());
    item[@"title"] = base::SysUTF16ToNSString(entry->GetTitle());
    if (entry->GetIsOverridingUserAgent()) {
      item[@"desktop"] = @YES;
    }
    if (with_state[i - first]) {
      const std::string state = entry->GetPageState().ToEncodedData();
      item[@"state"] = [NSData dataWithBytes:state.data() length:state.size()];
    }
    [entries addObject:item];
  }
  if (new_index < 0 || !entries.count) {
    return nil;
  }
  return @{@"index" : @(new_index), @"entries" : entries, @"v" : @2};
}

NSString* CurrentURLOfRecord(NSDictionary* record) {
  NSArray* entries = record[@"entries"];
  NSInteger index = [record[@"index"] integerValue];
  if (![entries isKindOfClass:NSArray.class] || index < 0 ||
      index >= static_cast<NSInteger>(entries.count)) {
    return nil;
  }
  NSDictionary* entry = entries[index];
  return [entry isKindOfClass:NSDictionary.class] ? entry[@"url"] : nil;
}

bool RestoreRecord(WebContents* contents, NSDictionary* record) {
  if (!contents || ![record isKindOfClass:NSDictionary.class]) {
    return false;
  }
  NavigationController& controller = contents->GetController();
  NavigationEntry* last = controller.GetLastCommittedEntry();
  // Restore дописує до наявних записів, тому лиш у свіжу вкладку
  if (controller.GetEntryCount() != 1 || !last || !last->IsInitialEntry() ||
      controller.GetPendingEntry()) {
    return false;
  }
  NSArray* items = record[@"entries"];
  NSInteger index = [record[@"index"] integerValue];
  if (![items isKindOfClass:NSArray.class] || !items.count || index < 0 ||
      index >= static_cast<NSInteger>(items.count)) {
    return false;
  }
  // До версії 2 писалась звільнена пам'ять, такий стан не берем
  const bool state_ok = [record[@"v"] integerValue] >= 2;
  std::unique_ptr<NavigationEntryRestoreContext> restore_context =
      NavigationEntryRestoreContext::Create();
  std::vector<std::unique_ptr<NavigationEntry>> entries;
  int selected = -1;
  for (NSInteger i = 0; i < static_cast<NSInteger>(items.count); ++i) {
    NSDictionary* item = items[i];
    if (![item isKindOfClass:NSDictionary.class] ||
        ![item[@"url"] isKindOfClass:NSString.class]) {
      continue;
    }
    GURL url(base::SysNSStringToUTF8(item[@"url"]));
    if (url.SchemeIsFile()) {
      url = BlinkerRebaseSavedPageURL(url);
    }
    if (!KeepEntryURL(url)) {
      continue;
    }
    if (i == index) {
      selected = static_cast<int>(entries.size());
    }
    std::unique_ptr<NavigationEntry> entry =
        NavigationController::CreateNavigationEntry(
            url, Referrer(), std::nullopt, std::nullopt,
            ui::PAGE_TRANSITION_RELOAD, false, std::string(),
            contents->GetBrowserContext(), nullptr);
    if ([item[@"title"] isKindOfClass:NSString.class]) {
      entry->SetTitle(base::SysNSStringToUTF16(item[@"title"]));
    }
    NSData* state = item[@"state"];
    if (state_ok && [state isKindOfClass:NSData.class] && state.length) {
      entry->SetPageState(
          blink::PageState::CreateFromEncodedData(std::string(
              static_cast<const char*>(state.bytes), state.length)),
          restore_context.get());
    }
    entry->SetIsOverridingUserAgent([item[@"desktop"] boolValue]);
    entries.push_back(std::move(entry));
  }
  if (selected < 0 || entries.empty()) {
    return false;
  }
  controller.Restore(selected, RestoreType::kRestored, &entries);
  controller.LoadIfNecessary();
  return true;
}

NSArray* LoadedTabs() {
  static NSArray* tabs = [] {
    NSDictionary* root = ReadPlist(StoreFile(@"TabSessions"));
    NSArray* list = [root isKindOfClass:NSDictionary.class] ? root[@"tabs"]
                                                             : nil;
    return [list isKindOfClass:NSArray.class] ? list : @[];
  }();
  return tabs;
}

NSDictionary* LoadedRecordForURL(NSString* url) {
  for (NSDictionary* tab in LoadedTabs()) {
    if ([tab isKindOfClass:NSDictionary.class] &&
        [tab[@"url"] isEqual:url] &&
        [tab[@"session"] isKindOfClass:NSDictionary.class]) {
      return tab[@"session"];
    }
  }
  return nil;
}

}  // namespace

void BlinkerSaveTabSessions(
    const std::vector<std::pair<WebContents*, std::string>>& tabs) {
  NSMutableArray* list = [NSMutableArray array];
  for (const auto& [contents, url_spec] : tabs) {
    NSString* url = base::SysUTF8ToNSString(url_spec);
    NSDictionary* record = SerializeContents(contents);
    if (record && ![CurrentURLOfRecord(record) isEqual:url]) {
      record = nil;
    }
    if (!record) {
      record = LoadedRecordForURL(url);
    }
    if (record) {
      [list addObject:@{@"url" : url, @"session" : record}];
    }
  }
  WriteLater(StoreFile(@"TabSessions"), @{@"version" : @1, @"tabs" : list});
}

bool BlinkerRestoreTabSession(WebContents* contents, const GURL& url) {
  NSString* key = base::SysUTF8ToNSString(url.spec());
  NSDictionary* record = LoadedRecordForURL(key);
  if (!record || ![CurrentURLOfRecord(record) isEqual:key]) {
    return false;
  }
  return RestoreRecord(contents, record);
}

void BlinkerDeleteTabSessions() {
  NSString* path = StoreFile(@"TabSessions");
  if (path) {
    dispatch_async(WriteQueue(), ^{
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    });
  }
}

void BlinkerFlushSessionWrites() {
  dispatch_sync(WriteQueue(), ^{
                });
}

void BlinkerDeleteLegacyClosedTabs() {
  NSString* path = StoreFile(@"RecentlyClosed");
  if (path) {
    dispatch_async(WriteQueue(), ^{
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    });
  }
}

bool BlinkerIsSavedPageURL(const GURL& url) {
  base::FilePath path;
  if (!url.SchemeIsFile() || !net::FileURLToFilePath(url, &path) ||
      path.ReferencesParent()) {
    return false;
  }
  const std::string value = path.value();
  const std::string home = base::SysNSStringToUTF8(NSHomeDirectory());
  // /var на iOS це посилання на /private/var, шлях буває в обох видах
  return !home.empty() &&
         (base::StartsWith(value, home + "/") ||
          base::StartsWith(value, "/private" + home + "/")) &&
         value.find("/MyFiles/Downloads/") != std::string::npos &&
         base::EndsWith(value, ".mhtml", base::CompareCase::INSENSITIVE_ASCII);
}

GURL BlinkerRebaseSavedPageURL(const GURL& url) {
  base::FilePath path;
  if (!url.SchemeIsFile() || !net::FileURLToFilePath(url, &path) ||
      path.ReferencesParent()) {
    return GURL();
  }
  NSString* old_path = base::SysUTF8ToNSString(path.value());
  NSFileManager* files = NSFileManager.defaultManager;
  if (BlinkerIsSavedPageURL(url) && [files fileExistsAtPath:old_path]) {
    return url;
  }
  // Шлях контейнера міняється, а все від Library/ лишається
  const NSRange library = [old_path rangeOfString:@"/Library/"];
  if (library.location == NSNotFound) {
    return GURL();
  }
  NSString* moved = [NSHomeDirectory()
      stringByAppendingString:[old_path substringFromIndex:library.location]];
  if (![files fileExistsAtPath:moved]) {
    return GURL();
  }
  const GURL rebased = net::FilePathToFileURL(
      base::FilePath(base::SysNSStringToUTF8(moved)));
  return BlinkerIsSavedPageURL(rebased) ? rebased : GURL();
}

}  // namespace content
