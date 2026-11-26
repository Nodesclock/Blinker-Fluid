// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_STORAGE_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_STORAGE_H_

#include <stdint.h>

#include <deque>
#include <map>
#include <set>
#include <string>
#include <string_view>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "base/values.h"

namespace content {

// Стан належить UI, файлові операції йдуть однією чергою
class BlinkerExtensionStorage {
 public:
  static BlinkerExtensionStorage& GetInstance();

  BlinkerExtensionStorage(const BlinkerExtensionStorage&) = delete;
  BlinkerExtensionStorage& operator=(const BlinkerExtensionStorage&) = delete;

  using ResponseCallback = base::OnceCallback<void(std::string json)>;

  void HandleRequest(const std::string& extension_id,
                     bool unlimited,
                     std::string_view request_json,
                     ResponseCallback callback);

  void ClearExtension(const std::string& extension_id);

  void SetStorageRootForTesting(const base::FilePath& root);

  void FlushPendingWrites(base::OnceCallback<void(bool)> callback);

 private:
  friend class base::NoDestructor<BlinkerExtensionStorage>;
  friend class BlinkerExtensionStorageTest;
  BlinkerExtensionStorage();
  ~BlinkerExtensionStorage();

  enum class Area { kLocal, kSync, kSession, kManaged };

  struct AreaData {
    base::DictValue items;
    bool loaded = false;
    uint64_t revision = 0;
    uint64_t queued_revision = 0;
    uint64_t saved_revision = 0;
    base::OneShotTimer flush_timer;
  };

  struct ChangeEntry {
    uint64_t seq = 0;
    std::string area;
    base::DictValue changes;
  };

  struct ExtensionData {
    ExtensionData();
    ~ExtensionData();
    std::map<Area, AreaData> areas;
    std::deque<ChangeEntry> change_log;
    uint64_t seq = 0;
    uint64_t generation = 0;
  };

  struct Waiter {
    Waiter();
    Waiter(Waiter&&);
    Waiter& operator=(Waiter&&);
    ~Waiter();
    std::string extension_id;
    uint64_t since = 0;
    ResponseCallback callback;
  };

  ExtensionData& GetExtension(const std::string& id);
  AreaData& GetArea(const std::string& id, Area area);

  void EnsureLoaded(const std::string& id, Area area, AreaData* data);
  void ScheduleFlush(const std::string& id, Area area, AreaData* data);
  void QueueWrite(const std::string& id, Area area);
  void OnWriteComplete(const std::string& id,
                       uint64_t generation,
                       Area area,
                       uint64_t revision,
                       bool success);
  void FinishFlush(base::OnceCallback<void(bool)> callback);

  void RecordChange(const std::string& id, Area area, base::DictValue changes);
  void NotifyWaiters(const std::string& id);
  void OnWaiterTimeout(uint64_t waiter_id);

  base::FilePath FileForArea(const std::string& id, Area area) const;

  std::map<std::string, ExtensionData> extensions_;
  std::set<std::string> cleared_extensions_;
  std::map<uint64_t, Waiter> waiters_;
  uint64_t next_waiter_id_ = 1;
  uint64_t next_generation_ = 1;
  base::FilePath storage_root_;
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;

  base::WeakPtrFactory<BlinkerExtensionStorage> weak_factory_{this};
};

std::string BlinkerExtensionStorageShim(std::string_view extension_id,
                                        std::string_view token);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_STORAGE_H_
