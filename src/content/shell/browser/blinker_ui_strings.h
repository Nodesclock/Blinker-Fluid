// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_UI_STRINGS_H_
#define CONTENT_SHELL_BROWSER_BLINKER_UI_STRINGS_H_

#include <string>
#include <string_view>

namespace content {

std::string BlinkerLocalizedUTF8(std::string_view english);

std::string BlinkerInterfaceLanguage();

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_UI_STRINGS_H_
