// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_MESSAGING_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_MESSAGING_H_

#include <string>
#include <string_view>

namespace content {

// Content script і воркер в різних origin, тому їх з'єднує прихований
// iframe розширення

inline constexpr char kBlinkerBridgePath[] = "__blinker_bridge.html";

// Міст приймає повідомлення батька лише з токеном, якого сторінка не знає
std::string BlinkerExtensionBridgeDocument(std::string_view extension_id,
                                           std::string_view token,
                                           int tab_id,
                                           int frame_id,
                                           std::string_view document_id);

// Додається перед скриптом воркера, іншої точки впорскування нема
std::string BlinkerExtensionWorkerShim(std::string_view extension_id);

// Тільки канал повідомлень, бо в USER_SCRIPT може бути чужий код
std::string BlinkerExtensionUserScriptMessagingShim(
    std::string_view extension_id,
    std::string_view token);

std::string BlinkerExtensionContentMessagingShim(std::string_view extension_id,
                                                 std::string_view token);

std::string BlinkerExtensionPageMessagingShim(std::string_view extension_id);

std::string BlinkerExtensionExternalPageShim();
std::string BlinkerExtensionExternalBridge(std::string_view extension_id);

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_MESSAGING_H_
