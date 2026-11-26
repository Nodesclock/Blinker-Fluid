// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_CRX_INSTALLER_H_
#define CONTENT_SHELL_BROWSER_BLINKER_CRX_INSTALLER_H_

#include <stddef.h>

#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"

class GURL;

namespace content {

class BrowserContext;

struct BlinkerCrxInstallResult {
  bool ok = false;
  std::string id;
  std::string name;
  std::string error;
};

// Блокує, тому тільки на потоці з дозволом на файловий I/O
BlinkerCrxInstallResult BlinkerInstallCrx(
    const base::FilePath& crx_path,
    const base::FilePath& extensions_dir);

size_t BlinkerInstallPendingCrx(const base::FilePath& dir);

bool BlinkerIsCrxUrl(const GURL& url);

// Лише на UI потоці, там же і `callback`
void BlinkerDownloadAndInstallCrx(
    BrowserContext* browser_context,
    const GURL& url,
    base::OnceCallback<void(BlinkerCrxInstallResult)> callback);

inline constexpr char kBlinkerInstallHost[] = "install";

std::string BlinkerCrxInstallResultPage();

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_CRX_INSTALLER_H_
