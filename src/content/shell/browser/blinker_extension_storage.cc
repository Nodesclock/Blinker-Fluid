// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extension_storage.h"

#include <algorithm>
#include <utility>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/path_service.h"
#include "base/strings/strcat.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "content/shell/common/blinker_diagnostics.h"
#include "content/shell/common/shell_paths.h"

namespace content {

namespace {

// Квоти як у Chrome
constexpr size_t kLocalQuotaBytes = 10u * 1024 * 1024;
constexpr size_t kUnlimitedQuotaBytes = 128u * 1024 * 1024;
constexpr size_t kSyncQuotaBytes = 102400u;
constexpr size_t kSyncQuotaBytesPerItem = 8192u;
constexpr size_t kSessionQuotaBytes = 10u * 1024 * 1024;

constexpr size_t kChangeLogLimit = 64;

constexpr base::TimeDelta kWatchTimeout = base::Seconds(25);

// Межа на файл області, на випадок битого чи підкинутого файла
constexpr size_t kMaxAreaFileBytes = kUnlimitedQuotaBytes + (1u * 1024 * 1024);

std::string Quoted(std::string_view value) {
  std::string out;
  base::EscapeJSONString(value, /*put_in_quotes=*/true, &out);
  return out;
}

std::string Serialize(const base::DictValue& dict) {
  std::optional<std::string> json = base::WriteJson(dict);
  return json.value_or("{}");
}

std::string ErrorReply(std::string_view message) {
  return base::StrCat({"{\"ok\":false,\"error\":", Quoted(message), "}"});
}

size_t ItemCost(std::string_view key, const base::Value& value) {
  std::optional<std::string> json = base::WriteJson(value);
  return key.size() + (json ? json->size() : 0u);
}

size_t TotalCost(const base::DictValue& items) {
  size_t total = 0;
  for (const auto [key, value] : items) {
    total += ItemCost(key, value);
  }
  return total;
}

// id стає частиною шляху, тому його треба перевірити
bool IsSafeId(std::string_view id) {
  if (id.empty() || id.size() > 128 || id == "." || id == "..") {
    return false;
  }
  for (char c : id) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    if (!ok) {
      return false;
    }
  }
  return true;
}

bool WriteAreaFile(const base::FilePath& path, const std::string& contents) {
  return base::CreateDirectory(path.DirName()) &&
         base::ImportantFileWriter::WriteFileAtomically(path, contents);
}

}  // namespace

BlinkerExtensionStorage::ExtensionData::ExtensionData() = default;
BlinkerExtensionStorage::ExtensionData::~ExtensionData() = default;
BlinkerExtensionStorage::Waiter::Waiter() = default;
BlinkerExtensionStorage::Waiter::Waiter(Waiter&&) = default;
BlinkerExtensionStorage::Waiter& BlinkerExtensionStorage::Waiter::operator=(
    Waiter&&) = default;
BlinkerExtensionStorage::Waiter::~Waiter() = default;

// static
BlinkerExtensionStorage& BlinkerExtensionStorage::GetInstance() {
  static base::NoDestructor<BlinkerExtensionStorage> instance;
  return *instance;
}

BlinkerExtensionStorage::BlinkerExtensionStorage()
    : file_task_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN})) {
  base::FilePath user_data;
  if (base::PathService::Get(SHELL_DIR_USER_DATA, &user_data)) {
    storage_root_ = user_data.Append("BlinkerExtensionStorage");
  }
}

BlinkerExtensionStorage::~BlinkerExtensionStorage() = default;

void BlinkerExtensionStorage::SetStorageRootForTesting(
    const base::FilePath& root) {
  storage_root_ = root;
  weak_factory_.InvalidateWeakPtrs();
  extensions_.clear();
  cleared_extensions_.clear();
}

BlinkerExtensionStorage::ExtensionData& BlinkerExtensionStorage::GetExtension(
    const std::string& id) {
  auto [it, inserted] = extensions_.try_emplace(id);
  if (inserted) {
    it->second.generation = next_generation_++;
  }
  return it->second;
}

BlinkerExtensionStorage::AreaData& BlinkerExtensionStorage::GetArea(
    const std::string& id,
    Area area) {
  AreaData& data = GetExtension(id).areas[area];
  EnsureLoaded(id, area, &data);
  return data;
}

base::FilePath BlinkerExtensionStorage::FileForArea(const std::string& id,
                                                    Area area) const {
  const char* name = nullptr;
  switch (area) {
    case Area::kLocal:
      name = "local.json";
      break;
    case Area::kSync:
      name = "sync.json";
      break;
    case Area::kSession:
    case Area::kManaged:
      return base::FilePath();
  }
  if (storage_root_.empty()) {
    return base::FilePath();
  }
  return storage_root_.Append(id).AppendASCII(name);
}

void BlinkerExtensionStorage::EnsureLoaded(const std::string& id,
                                           Area area,
                                           AreaData* data) {
  if (data->loaded) {
    return;
  }
  data->loaded = true;  // спершу, щоб невдале читання давало пусто, а не повтор
  const base::FilePath path = FileForArea(id, area);
  if (path.empty() || cleared_extensions_.contains(id)) {
    return;
  }
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents, kMaxAreaFileBytes)) {
    return;
  }
  std::optional<base::DictValue> parsed =
      base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  if (parsed) {
    data->items = std::move(*parsed);
  }
}

void BlinkerExtensionStorage::ScheduleFlush(const std::string& id,
                                            Area area,
                                            AreaData* data) {
  const base::FilePath path = FileForArea(id, area);
  if (path.empty()) {
    return;
  }
  ++data->revision;
  if (!data->flush_timer.IsRunning()) {
    data->flush_timer.Start(
        FROM_HERE, base::Seconds(1),
        base::BindOnce(&BlinkerExtensionStorage::QueueWrite,
                       weak_factory_.GetWeakPtr(), id, area));
  }
}

void BlinkerExtensionStorage::QueueWrite(const std::string& id, Area area) {
  auto extension = extensions_.find(id);
  if (extension == extensions_.end()) {
    return;
  }
  AreaData& data = extension->second.areas.at(area);
  data.flush_timer.Stop();
  if (data.revision == data.saved_revision ||
      data.revision == data.queued_revision) {
    return;
  }
  const base::FilePath path = FileForArea(id, area);
  if (path.empty()) {
    return;
  }
  data.queued_revision = data.revision;
  file_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&WriteAreaFile, path, Serialize(data.items)),
      base::BindOnce(&BlinkerExtensionStorage::OnWriteComplete,
                     weak_factory_.GetWeakPtr(), id,
                     extension->second.generation, area, data.revision));
}

void BlinkerExtensionStorage::OnWriteComplete(const std::string& id,
                                              uint64_t generation,
                                              Area area,
                                              uint64_t revision,
                                              bool success) {
  auto extension = extensions_.find(id);
  if (extension == extensions_.end() ||
      extension->second.generation != generation) {
    return;
  }
  AreaData& data = extension->second.areas.at(area);
  if (success) {
    data.saved_revision = std::max(data.saved_revision, revision);
  } else {
    if (data.queued_revision == revision) {
      data.queued_revision = 0;
    }
    BLINKER_DIAG("EXT_STORAGE: atomic write failed");
  }
}

void BlinkerExtensionStorage::FlushPendingWrites(
    base::OnceCallback<void(bool)> callback) {
  for (auto& [id, extension] : extensions_) {
    for (auto& [area, data] : extension.areas) {
      QueueWrite(id, area);
    }
  }
  file_task_runner_->PostTaskAndReply(
      FROM_HERE, base::DoNothing(),
      base::BindOnce(&BlinkerExtensionStorage::FinishFlush,
                     weak_factory_.GetWeakPtr(), std::move(callback)));
}

void BlinkerExtensionStorage::FinishFlush(
    base::OnceCallback<void(bool)> callback) {
  for (const auto& [id, extension] : extensions_) {
    for (const auto& [area, data] : extension.areas) {
      if (data.revision != data.saved_revision) {
        std::move(callback).Run(false);
        return;
      }
    }
  }
  std::move(callback).Run(true);
}

void BlinkerExtensionStorage::RecordChange(const std::string& id,
                                           Area area,
                                           base::DictValue changes) {
  if (changes.empty()) {
    return;
  }
  const char* area_name = area == Area::kLocal     ? "local"
                          : area == Area::kSync    ? "sync"
                          : area == Area::kSession ? "session"
                                                   : "managed";
  ExtensionData& ext = GetExtension(id);
  ChangeEntry entry;
  entry.seq = ++ext.seq;
  entry.area = area_name;
  entry.changes = std::move(changes);
  ext.change_log.push_back(std::move(entry));
  while (ext.change_log.size() > kChangeLogLimit) {
    ext.change_log.pop_front();
  }
  NotifyWaiters(id);
}

void BlinkerExtensionStorage::NotifyWaiters(const std::string& id) {
  ExtensionData& ext = GetExtension(id);
  std::vector<uint64_t> ready;
  for (const auto& [waiter_id, waiter] : waiters_) {
    if (waiter.extension_id == id && waiter.since < ext.seq) {
      ready.push_back(waiter_id);
    }
  }
  for (uint64_t waiter_id : ready) {
    auto it = waiters_.find(waiter_id);
    if (it == waiters_.end()) {
      continue;
    }
    Waiter waiter = std::move(it->second);
    waiters_.erase(it);

    // Якщо watcher відстав більше, ніж пам'ятає лог, кажемо про це
    const bool gap = !ext.change_log.empty() &&
                     ext.change_log.front().seq > waiter.since + 1;
    base::ListValue events;
    if (!gap) {
      for (const ChangeEntry& entry : ext.change_log) {
        if (entry.seq <= waiter.since) {
          continue;
        }
        base::DictValue event;
        event.Set("area", entry.area);
        event.Set("changes", entry.changes.Clone());
        events.Append(std::move(event));
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("seq", static_cast<double>(ext.seq));
    reply.Set("reset", gap);
    reply.Set("events", std::move(events));
    std::move(waiter.callback).Run(Serialize(reply));
  }
}

void BlinkerExtensionStorage::OnWaiterTimeout(uint64_t waiter_id) {
  auto it = waiters_.find(waiter_id);
  if (it == waiters_.end()) {
    return;
  }
  Waiter waiter = std::move(it->second);
  waiters_.erase(it);
  base::DictValue reply;
  reply.Set("ok", true);
  reply.Set("seq", static_cast<double>(GetExtension(waiter.extension_id).seq));
  reply.Set("reset", false);
  reply.Set("events", base::ListValue());
  std::move(waiter.callback).Run(Serialize(reply));
}

void BlinkerExtensionStorage::ClearExtension(const std::string& extension_id) {
  if (!IsSafeId(extension_id)) {
    return;
  }
  extensions_.erase(extension_id);
  cleared_extensions_.insert(extension_id);
  std::vector<ResponseCallback> callbacks;
  for (auto it = waiters_.begin(); it != waiters_.end();) {
    if (it->second.extension_id == extension_id) {
      callbacks.push_back(std::move(it->second.callback));
      it = waiters_.erase(it);
    } else {
      ++it;
    }
  }
  if (!storage_root_.empty()) {
    file_task_runner_->PostTask(FROM_HERE,
                                base::GetDeletePathRecursivelyCallback(
                                    storage_root_.Append(extension_id)));
  }
  for (auto& callback : callbacks) {
    std::move(callback).Run(ErrorReply("Extension storage was removed"));
  }
}

void BlinkerExtensionStorage::HandleRequest(const std::string& extension_id,
                                            bool unlimited,
                                            std::string_view request_json,
                                            ResponseCallback callback) {
  if (!IsSafeId(extension_id)) {
    std::move(callback).Run(ErrorReply("bad extension id"));
    return;
  }
  std::optional<base::DictValue> request =
      base::JSONReader::ReadDict(request_json, base::JSON_PARSE_RFC);
  if (!request) {
    std::move(callback).Run(ErrorReply("malformed request"));
    return;
  }
  const std::string* op = request->FindString("op");
  if (!op) {
    std::move(callback).Run(ErrorReply("missing op"));
    return;
  }

  // Спершу питаємо номер, щоб пізній слухач не отримав всю історію
  if (*op == "seq") {
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("seq", static_cast<double>(GetExtension(extension_id).seq));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (*op == "watch") {
    Waiter waiter;
    waiter.extension_id = extension_id;
    waiter.since =
        static_cast<uint64_t>(request->FindDouble("since").value_or(0));
    waiter.callback = std::move(callback);
    const uint64_t waiter_id = next_waiter_id_++;
    waiters_[waiter_id] = std::move(waiter);
    NotifyWaiters(extension_id);
    if (waiters_.count(waiter_id)) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE,
          base::BindOnce(&BlinkerExtensionStorage::OnWaiterTimeout,
                         weak_factory_.GetWeakPtr(), waiter_id),
          kWatchTimeout);
    }
    return;
  }

  const std::string* area_name = request->FindString("area");
  Area area = Area::kLocal;
  if (area_name) {
    if (*area_name == "sync") {
      area = Area::kSync;
    } else if (*area_name == "session") {
      area = Area::kSession;
    } else if (*area_name == "managed") {
      area = Area::kManaged;
    } else if (*area_name != "local") {
      std::move(callback).Run(ErrorReply("unknown storage area"));
      return;
    }
  }

  size_t quota = kLocalQuotaBytes;
  switch (area) {
    case Area::kLocal:
      quota = unlimited ? kUnlimitedQuotaBytes : kLocalQuotaBytes;
      break;
    case Area::kSync:
      quota = kSyncQuotaBytes;
      break;
    case Area::kSession:
      quota = kSessionQuotaBytes;
      break;
    case Area::kManaged:
      quota = 0;
      break;
  }

  AreaData& data = GetArea(extension_id, area);

  const auto collect_keys = [&request](std::vector<std::string>* keys) -> bool {
    const base::Value* value = request->Find("keys");
    if (!value || value->is_none()) {
      return false;
    }
    if (const std::string* one = value->GetIfString()) {
      keys->push_back(*one);
      return true;
    }
    if (const base::ListValue* list = value->GetIfList()) {
      for (const base::Value& entry : *list) {
        if (const std::string* key = entry.GetIfString()) {
          keys->push_back(*key);
        }
      }
      return true;
    }
    if (const base::DictValue* dict = value->GetIfDict()) {
      for (const auto [key, unused] : *dict) {
        keys->push_back(std::string(key));
      }
      return true;
    }
    return false;
  };

  if (*op == "get") {
    std::vector<std::string> keys;
    const bool subset = collect_keys(&keys);
    const base::DictValue* defaults = nullptr;
    if (const base::Value* value = request->Find("keys")) {
      defaults = value->GetIfDict();
    }
    base::DictValue out;
    if (!subset) {
      out = data.items.Clone();
    } else {
      for (const std::string& key : keys) {
        if (const base::Value* stored = data.items.Find(key)) {
          out.Set(key, stored->Clone());
        } else if (defaults) {
          if (const base::Value* fallback = defaults->Find(key)) {
            out.Set(key, fallback->Clone());
          }
        }
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("items", std::move(out));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (*op == "bytes") {
    std::vector<std::string> keys;
    const bool subset = collect_keys(&keys);
    size_t bytes = 0;
    if (!subset) {
      bytes = TotalCost(data.items);
    } else {
      for (const std::string& key : keys) {
        if (const base::Value* stored = data.items.Find(key)) {
          bytes += ItemCost(key, *stored);
        }
      }
    }
    base::DictValue reply;
    reply.Set("ok", true);
    reply.Set("bytes", static_cast<double>(bytes));
    reply.Set("quota", static_cast<double>(quota));
    std::move(callback).Run(Serialize(reply));
    return;
  }

  if (area == Area::kManaged) {
    // Managed область у Chrome задає адмін, тут його нема, тому запис
    // відхиляємо
    std::move(callback).Run(ErrorReply("managed storage is read-only"));
    return;
  }

  if (*op == "set") {
    const base::DictValue* items = request->FindDict("items");
    if (!items) {
      std::move(callback).Run(ErrorReply("set needs items"));
      return;
    }
    // Квота по результату, не по різниці, тому перезапис великого ключа
    // малим завжди проходить
    base::DictValue next = data.items.Clone();
    for (const auto [key, value] : *items) {
      if (area == Area::kSync &&
          ItemCost(key, value) > kSyncQuotaBytesPerItem) {
        std::move(callback).Run(
            ErrorReply("QUOTA_BYTES_PER_ITEM quota exceeded"));
        return;
      }
      next.Set(key, value.Clone());
    }
    if (TotalCost(next) > quota) {
      std::move(callback).Run(ErrorReply("QUOTA_BYTES quota exceeded"));
      return;
    }

    base::DictValue changes;
    for (const auto [key, value] : *items) {
      const base::Value* old = data.items.Find(key);
      if (old && *old == value) {
        continue;  // Chrome не повідомляє про запис, що нічого не змінив
      }
      base::DictValue change;
      if (old) {
        change.Set("oldValue", old->Clone());
      }
      change.Set("newValue", value.Clone());
      changes.Set(key, std::move(change));
    }
    data.items = std::move(next);
    ScheduleFlush(extension_id, area, &data);
    RecordChange(extension_id, area, std::move(changes));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (*op == "remove") {
    std::vector<std::string> keys;
    if (!collect_keys(&keys)) {
      std::move(callback).Run(ErrorReply("remove needs keys"));
      return;
    }
    base::DictValue changes;
    for (const std::string& key : keys) {
      const base::Value* old = data.items.Find(key);
      if (!old) {
        continue;
      }
      base::DictValue change;
      change.Set("oldValue", old->Clone());
      changes.Set(key, std::move(change));
      data.items.Remove(key);
    }
    ScheduleFlush(extension_id, area, &data);
    RecordChange(extension_id, area, std::move(changes));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  if (*op == "clear") {
    base::DictValue changes;
    for (const auto [key, value] : data.items) {
      base::DictValue change;
      change.Set("oldValue", value.Clone());
      changes.Set(key, std::move(change));
    }
    data.items.clear();
    ScheduleFlush(extension_id, area, &data);
    RecordChange(extension_id, area, std::move(changes));
    std::move(callback).Run("{\"ok\":true}");
    return;
  }

  std::move(callback).Run(ErrorReply("unknown op"));
}

std::string BlinkerExtensionStorageShim(std::string_view extension_id,
                                        std::string_view token) {
  return base::StrCat({
      "(()=>{const ID=",
      Quoted(extension_id),
      ",TOK=",
      Quoted(token),
      ",EP='",
      kBlinkerExtensionScheme,
      "://'+ID+'/",
      kBlinkerApiPath,
      "';",
      "const c=globalThis.chrome=globalThis.chrome||{};",
      "if(c.storage&&c.storage.__blinkerBrowserBacked)return;",
      "c.runtime=c.runtime||{};",
      // Тіло простим рядком, щоб POST з content script був простим CORS запитом
      // без preflight
      "const rpc=(payload)=>fetch(EP,{method:'POST',",
      "body:JSON.stringify(Object.assign({tok:TOK,ns:'storage'},payload))})",
      ".then((r)=>r.json());",
      // Помилку колбек бачить лише поки виконується, щоб lastError не тік
      // в наступний виклик
      "const call=(payload,extract,cb)=>{",
      "const p=Promise.resolve().then(()=>rpc(payload)).then((r)=>{",
      "if(!r||!r.ok)throw new Error((r&&r.error)||'storage unavailable');",
      "return extract?extract(r):undefined;});",
      "if(typeof cb!=='function')return p;",
      "const invoke=(value,err)=>{",
      "if(err)c.runtime.lastError={message:String((err&&err.message)||err)};",
      "else delete c.runtime.lastError;",
      "try{cb(value);}finally{delete c.runtime.lastError;}};",
      "p.then((value)=>invoke(value),(err)=>invoke(undefined,err));",
      "return undefined;};",

      "const listeners=[];let watching=false,seq=0;",
      "const dispatch=(area,changes)=>{",
      "for(const fn of listeners.slice()){",
      "try{fn(changes,area);}catch(e){}}",
      "const a=c.storage&&c.storage[area];",
      "if(a&&a.onChanged&&a.onChanged.__listeners){",
      "for(const fn of a.onChanged.__listeners.slice()){",
      "try{fn(changes);}catch(e){}}}};",
      // Довге опитування. Прихована вкладка його не тримає і добирає
      // пропущене за номером
      "let parked=false;",
      "const hidden=()=>typeof document!=='undefined'&&document.hidden;",
      "if(typeof document!=='undefined')document.addEventListener(",
      "'visibilitychange',()=>{if(parked&&!document.hidden){parked=false;",
      "pump();}});",
      "const pump=()=>{if(hidden()){parked=true;return;}",
      "rpc({op:'watch',since:seq}).then((r)=>{",
      "if(r&&r.ok){seq=r.seq||seq;",
      "for(const ev of (r.events||[]))dispatch(ev.area,ev.changes);",
      "setTimeout(pump,0);}else{setTimeout(pump,2000);}})",
      ".catch(()=>setTimeout(pump,2000));};",
      "const startWatch=()=>{if(watching)return;watching=true;",
      "rpc({op:'seq'}).then((r)=>{if(r&&r.ok)seq=r.seq||0;pump();})",
      ".catch(()=>pump());};",

      "const makeArea=(area)=>{const self={",
      "get:(keys,cb)=>{if(typeof keys==='function'){cb=keys;keys=null;}",
      "return call({op:'get',area:area,keys:keys===undefined?null:keys},",
      "(r)=>(r&&r.items)||{},cb);},",
      "set:(items,cb)=>call({op:'set',area:area,items:items||{}},null,cb),",
      "remove:(keys,cb)=>call({op:'remove',area:area,keys:keys},null,cb),",
      "clear:(cb)=>call({op:'clear',area:area},null,cb),",
      "getBytesInUse:(keys,cb)=>{if(typeof keys==='function'){cb=keys;",
      "keys=null;}",
      "return call({op:'bytes',area:area,keys:keys===undefined?null:keys},",
      "(r)=>(r&&r.bytes)||0,cb);},",
      "getKeys:(cb)=>call({op:'get',area:area,keys:null},",
      "(r)=>Object.keys((r&&r.items)||{}),cb),",
      "setAccessLevel:(o,cb)=>{if(cb)cb();return Promise.resolve();},",
      "onChanged:{__listeners:[],",
      "addListener:(fn)=>{if(typeof fn==='function'){",
      "self.onChanged.__listeners.push(fn);startWatch();}},",
      "removeListener:(fn)=>{const l=self.onChanged.__listeners;",
      "const i=l.indexOf(fn);if(i>=0)l.splice(i,1);},",
      "hasListener:(fn)=>self.onChanged.__listeners.indexOf(fn)>=0}};",
      "return self;};",

      "const local=makeArea('local');",
      "c.storage={__blinkerBrowserBacked:true,",
      "local:local,sync:makeArea('sync'),session:makeArea('session'),",
      "managed:makeArea('managed'),",
      "onChanged:{addListener:(fn)=>{if(typeof fn==='function'){",
      "listeners.push(fn);startWatch();}},",
      "removeListener:(fn)=>{const i=listeners.indexOf(fn);",
      "if(i>=0)listeners.splice(i,1);},",
      "hasListener:(fn)=>listeners.indexOf(fn)>=0}};",
      "local.QUOTA_BYTES=10485760;",
      "c.storage.sync.QUOTA_BYTES=102400;",
      "c.storage.sync.QUOTA_BYTES_PER_ITEM=8192;",
      "c.storage.session.QUOTA_BYTES=10485760;",
      "})();",
  });
}

}  // namespace content
