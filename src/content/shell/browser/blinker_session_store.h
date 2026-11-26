// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_SESSION_STORE_H_
#define CONTENT_SHELL_BROWSER_BLINKER_SESSION_STORE_H_

#include <string>
#include <utility>
#include <vector>

class GURL;

namespace content {

class BrowserContext;
class WebContents;

void BlinkerSaveTabSessions(
    const std::vector<std::pair<WebContents*, std::string>>& tabs);

// Вкладка має бути свіжа, без жодної навігації
bool BlinkerRestoreTabSession(WebContents* contents, const GURL& url);

void BlinkerDeleteTabSessions();

// Чекає, доки ляжуть на диск відкладені записи, перед _exit
void BlinkerFlushSessionWrites();

// Файл від старших версій лишав би на диску адреси закритих сторінок
void BlinkerDeleteLegacyClosedTabs();

bool BlinkerIsSavedPageURL(const GURL& url);

// Після перевстановлення шлях контейнера інший, тому переносимо файл
GURL BlinkerRebaseSavedPageURL(const GURL& url);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_SESSION_STORE_H_
