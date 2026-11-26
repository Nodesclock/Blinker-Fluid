// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef CONTENT_SHELL_BROWSER_BLINKER_FILTER_SUBSCRIPTIONS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_FILTER_SUBSCRIPTIONS_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/scoped_refptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network
namespace content {
class BrowserContext;

// Живе на UI. Диск і компіляція правил на одному worker_, тому пізніше
// вимкнення чи видалення перебиває раніше поставлений reload
class BlinkerFilterSubscriptions {
 public:
  struct List {
    List();
    List(const List&);
    List(List&&);
    List& operator=(const List&);
    List& operator=(List&&);
    ~List();
    std::string id;
    std::string name;
    GURL url;
    bool enabled = true;
    bool force_update = false;
    base::Time updated;
    base::Time attempted;
    std::string status;
  };
  static BlinkerFilterSubscriptions& GetInstance();
  void Start(BrowserContext* context, const base::FilePath& documents);
  bool ready() const { return ready_; }
  bool can_update() const { return !!factory_; }
  const std::vector<List>& lists() const { return lists_; }
  std::string Add(const GURL& url, std::string name);
  void SetEnabled(const std::string& id, bool enabled);
  void Remove(const std::string& id);
  void Refresh(bool force);

 private:
  friend class base::NoDestructor<BlinkerFilterSubscriptions>;
  BlinkerFilterSubscriptions();
  ~BlinkerFilterSubscriptions();
  void Loaded(base::DictValue state);
  void Save();
  void Reload();
  void Downloaded(std::string id, std::optional<std::string> body);
  void Installed(std::string id, bool success);
  List* Find(const std::string& id);
  base::FilePath CachePath(const std::string& id) const;

  bool started_ = false;
  bool ready_ = false;
  base::FilePath directory_;
  std::vector<List> lists_;
  scoped_refptr<base::SequencedTaskRunner> worker_;
  scoped_refptr<network::SharedURLLoaderFactory> factory_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  std::string downloading_;
  base::RepeatingTimer timer_;
};
}  // namespace content
#endif
