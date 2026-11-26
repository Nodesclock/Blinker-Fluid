// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_API_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_API_H_

#include <string>
#include <string_view>
#include <vector>

#include "url/gurl.h"

#include "base/functional/callback.h"
#include "base/values.h"
#include "content/public/browser/global_routing_id.h"

namespace content {

class NavigationHandle;
class RenderFrameHost;
class Shell;
class WebContents;

// content не вміє ставити нативну прив'язку в service worker, тому API
// іде як POST на __blinker_api, з чужого походження ще й з токеном світу

inline constexpr char kBlinkerApiPath[] = "__blinker_api";

struct BlinkerApiCaller {
  std::string extension_id;
  int tab_id = -1;
  // Сторінка чи воркер самого розширення, веб сторінка це не підробить
  bool from_extension_origin = false;
  bool unlimited_storage = false;
  GlobalRenderFrameHostId frame_id;
};

// Асинхронно, бо watch сховища чекає змін
void BlinkerHandleExtensionApiCall(
    const BlinkerApiCaller& caller,
    std::string_view request_json,
    base::OnceCallback<void(std::string)> callback);

int BlinkerTabIdForWebContents(WebContents* contents);

// Як у ExtensionApiFrameIdMap, головний фрейм 0, решта FrameTreeNodeId
int BlinkerApiFrameId(RenderFrameHost* frame);
std::string BlinkerApiDocumentId(RenderFrameHost* frame);

// для попапу дії це жест користувача, який дає activeTab
void BlinkerNoteExtensionPageOpened(const GURL& page, WebContents* over);

// Попап і налаштування розширення відкриваються окремою вкладкою над тією, що
// була на екрані. |page| запам'ятовує цю вкладку, бо для розширення вона і є
// активною, а після закриття попапу екран вертається на неї.
void BlinkerSetExtensionPageOpener(WebContents* page, WebContents* opener);
// nullptr, якщо |page| не відкривали над вкладкою чи та вже закрита.
WebContents* BlinkerExtensionPageOpener(WebContents* page);

void BlinkerNoteTabNavigated(WebContents* contents,
                             NavigationHandle* navigation);

// Для window.open Shell з'являється вже після WebContents, тоді і слати
// tabs.onCreated
void BlinkerNoteTabShellCreated(WebContents* contents);

void BlinkerNoteTabFavicon(WebContents* contents, const GURL& icon);

void BlinkerRestoreExtensionApiState();

void BlinkerWebNavigationStarted(NavigationHandle* navigation);
void BlinkerWebNavigationFinished(NavigationHandle* navigation);
void BlinkerWebNavigationParsed(RenderFrameHost* frame);
void BlinkerWebNavigationLoaded(RenderFrameHost* frame, const GURL& url);
void BlinkerWebNavigationFailed(RenderFrameHost* frame, int error_code);
void BlinkerWebNavigationFrameDeleted(RenderFrameHost* frame);
void BlinkerWebNavigationFramesReplaced(RenderFrameHost* old_frame);
void BlinkerWebNavigationTargetCreated(RenderFrameHost* source,
                                       WebContents* target,
                                       const GURL& url);

void BlinkerNotifyExtensionTabEvent(WebContents* contents,
                                    std::string_view event);

// Однаковий масштаб події не дає, як і в ZoomController
void BlinkerNotifyZoomChanged(WebContents* contents,
                              int old_percent,
                              int new_percent);

// Меню довгого натиску будується в ObjC (на iOS 14 і 15 через view
// сторінки), тому сховище пунктів тут

struct BlinkerContextMenuTarget {
  BlinkerContextMenuTarget();
  BlinkerContextMenuTarget(const BlinkerContextMenuTarget&);
  ~BlinkerContextMenuTarget();

  GURL page_url;
  GURL frame_url;
  GURL link_url;
  GURL src_url;
  std::string selection_text;
  bool editable = false;
  std::string media_type = "none";
};

struct BlinkerContextMenuEntry {
  BlinkerContextMenuEntry();
  BlinkerContextMenuEntry(const BlinkerContextMenuEntry&);
  ~BlinkerContextMenuEntry();

  std::string key;
  std::string title;
  std::string parent_title;
  bool checked = false;
  bool checkable = false;
};

std::vector<BlinkerContextMenuEntry> BlinkerContextMenuItemsFor(
    const BlinkerContextMenuTarget& target);

// будить service worker розширення, якщо він спить
void BlinkerActivateContextMenuItem(const std::string& key,
                                    const BlinkerContextMenuTarget& target,
                                    WebContents* contents);

// chrome.idle вважає фон відсутністю користувача, на телефоні так і є
bool BlinkerBrowserIsBackgrounded();

void BlinkerSetBrowserBackgrounded(bool backgrounded);

void BlinkerFlushStorageForBackground(base::OnceCallback<void(bool)> callback);

void BlinkerWakeExtensionWorker(const std::string& extension_id);

void BlinkerPostExtensionEvent(const std::string& extension_id,
                               const std::string& name,
                               base::ListValue args);

std::string BlinkerExtensionBadgeText(const std::string& extension_id);
std::string BlinkerExtensionActionTitle(const std::string& extension_id);

void BlinkerActivateExtensionAction(const std::string& extension_id,
                                    WebContents* contents);

void BlinkerFireExtensionCommand(const std::string& extension_id,
                                 const std::string& command,
                                 WebContents* contents);

// Визначено в shell_platform_delegate_ios.mm. icon_path може бути пустим,
// buttons це до двох назв через \n
extern "C" void BlinkShowExtensionNotification(const char* extension_id,
                                               const char* notification_id,
                                               const char* source_name,
                                               const char* title,
                                               const char* message,
                                               const char* icon_path,
                                               const char* buttons);

extern "C" void BlinkActivateShell(Shell* shell);

// Ховає банер, не кажучи розширенню, коли воно саме стирає сповіщення
extern "C" void BlinkHideExtensionNotification(const char* extension_id,
                                               const char* notification_id);

void BlinkerNotificationActivated(const std::string& extension_id,
                                  const std::string& notification_id,
                                  int button_index);

// by_user false, коли банер зник за таймаутом, звідси різниця в
// chrome.notifications.onClosed
void BlinkerNotificationDismissed(const std::string& extension_id,
                                  const std::string& notification_id,
                                  bool by_user);

// Лише для воркера і сторінок розширення, не для content scripts
std::string BlinkerExtensionPrivilegedApiShim(std::string_view extension_id,
                                              std::string_view token);

// Додає тільки відсутнє до поверхні з blinker_extension_api_tables.h,
// тому йде після всіх інших шімів
std::string BlinkerExtensionApiSurfaceShim();

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_API_H_
