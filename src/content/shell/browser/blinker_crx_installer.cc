// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_crx_installer.h"

#include <stdint.h>

#include <vector>

#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "net/base/filename_util.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"
#include "base/strings/string_number_conversions.h"
#include "base/values.h"
#include "components/crx_file/crx_verifier.h"
#include "third_party/zlib/google/zip.h"

namespace content {

namespace {

constexpr int64_t kMaxCrxBytes = 128 * 1024 * 1024;
constexpr int64_t kMaxManifestBytes = 4 * 1024 * 1024;

// CRX3 це Cr24, версія, довжина заголовка, заголовок, далі ZIP
constexpr int64_t kCrxPrefixBytes = 12;

bool ZipOffsetOf(const base::FilePath& crx_path, int64_t* offset) {
  base::File file(crx_path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  if (!file.IsValid()) {
    return false;
  }
  uint8_t prefix[kCrxPrefixBytes];
  if (file.ReadAtCurrentPos(base::as_writable_byte_span(prefix)) !=
      kCrxPrefixBytes) {
    return false;
  }
  if (prefix[0] != 'C' || prefix[1] != 'r' || prefix[2] != '2' ||
      prefix[3] != '4') {
    return false;
  }
  const uint32_t version = static_cast<uint32_t>(prefix[4]) |
                           (static_cast<uint32_t>(prefix[5]) << 8) |
                           (static_cast<uint32_t>(prefix[6]) << 16) |
                           (static_cast<uint32_t>(prefix[7]) << 24);
  if (version != 3) {
    return false;
  }
  const uint32_t header_size = static_cast<uint32_t>(prefix[8]) |
                               (static_cast<uint32_t>(prefix[9]) << 8) |
                               (static_cast<uint32_t>(prefix[10]) << 16) |
                               (static_cast<uint32_t>(prefix[11]) << 24);
  const int64_t length = file.GetLength();
  const int64_t start = kCrxPrefixBytes + static_cast<int64_t>(header_size);
  if (length <= start || start < kCrxPrefixBytes) {
    return false;
  }
  *offset = start;
  return true;
}

bool ExtractZip(const base::FilePath& crx_path,
                int64_t offset,
                const base::FilePath& zip_path) {
  base::File in(crx_path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  base::File out(zip_path,
                 base::File::FLAG_CREATE_ALWAYS | base::File::FLAG_WRITE);
  if (!in.IsValid() || !out.IsValid()) {
    return false;
  }
  if (in.Seek(base::File::FROM_BEGIN, offset) != offset) {
    return false;
  }
  std::vector<uint8_t> buffer(64 * 1024);
  for (;;) {
    const std::optional<size_t> read =
        in.ReadAtCurrentPos(base::span(buffer));
    if (!read.has_value()) {
      return false;
    }
    if (*read == 0) {
      return true;
    }
    if (!out.WriteAtCurrentPosAndCheck(base::span(buffer).first(*read))) {
      return false;
    }
  }
}

bool ReadManifestName(const base::FilePath& dir, std::string* name) {
  std::string json;
  if (!base::ReadFileToStringWithMaxSize(dir.Append("manifest.json"), &json,
                                         kMaxManifestBytes)) {
    return false;
  }
  std::optional<base::DictValue> manifest =
      base::JSONReader::ReadDict(json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!manifest) {
    return false;
  }
  if (const std::string* value = manifest->FindString("name")) {
    *name = *value;
  }
  return true;
}

}  // namespace

BlinkerCrxInstallResult BlinkerInstallCrx(
    const base::FilePath& crx_path,
    const base::FilePath& extensions_dir) {
  BlinkerCrxInstallResult result;

  const std::optional<int64_t> size = base::GetFileSize(crx_path);
  if (!size.has_value() || *size <= kCrxPrefixBytes) {
    result.error = "not a readable file";
    return result;
  }
  if (*size > kMaxCrxBytes) {
    result.error = "larger than 128MB";
    return result;
  }

  // Без publisher proof, його має тільки Web Store. Підпис автора
  // все одно обов'язковий
  std::string public_key;
  std::string crx_id;
  const crx_file::VerifierResult verified = crx_file::Verify(
      crx_path, crx_file::VerifierFormat::CRX3, /*required_key_hashes=*/{},
      /*required_file_hash=*/{}, &public_key, &crx_id,
      /*compressed_verified_contents=*/nullptr);
  if (verified != crx_file::VerifierResult::OK_FULL) {
    result.error = base::StrCat(
        {"signature check failed (", base::NumberToString(static_cast<int>(
                                          verified)),
         ")"});
    return result;
  }
  if (crx_id.empty()) {
    result.error = "no extension id";
    return result;
  }

  int64_t offset = 0;
  if (!ZipOffsetOf(crx_path, &offset)) {
    result.error = "unrecognised CRX header";
    return result;
  }

  base::ScopedTempDir work;
  if (!work.CreateUniqueTempDirUnderPath(extensions_dir)) {
    result.error = "could not create a working directory";
    return result;
  }
  const base::FilePath zip_path = work.GetPath().Append("payload.zip");
  if (!ExtractZip(crx_path, offset, zip_path)) {
    result.error = "could not read the archive";
    return result;
  }
  const base::FilePath unpacked = work.GetPath().Append("unpacked");
  if (!base::CreateDirectory(unpacked)) {
    result.error = "could not create the unpack directory";
    return result;
  }
  // zip::Unzip сам відкидає записи поза каталогом і симлінки, для архіву з
  // мережі це важливо
  if (!zip::Unzip(zip_path, unpacked)) {
    result.error = "could not unpack the archive";
    return result;
  }
  if (!ReadManifestName(unpacked, &result.name)) {
    result.error = "no readable manifest.json inside";
    return result;
  }

  // id з ключа підпису, тому перевстановлення лягає в той самий каталог
  const base::FilePath target = extensions_dir.Append(crx_id);
  if (base::PathExists(target) && !base::DeletePathRecursively(target)) {
    result.error = "could not replace the installed copy";
    return result;
  }
  if (!base::Move(unpacked, target)) {
    result.error = "could not move the extension into place";
    return result;
  }

  result.ok = true;
  result.id = crx_id;
  if (result.name.empty()) {
    result.name = crx_id;
  }
  return result;
}

bool BlinkerIsCrxUrl(const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS() && !url.SchemeIsFile()) {
    return false;
  }
  const std::string path = base::ToLowerASCII(url.path());
  return path.size() > 4 && path.ends_with(".crx");
}

namespace {

BlinkerCrxInstallResult& LastResult() {
  static base::NoDestructor<BlinkerCrxInstallResult> result;
  return *result;
}

std::string Escape(std::string_view text) {
  std::string out;
  for (char c : text) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out += c;
    }
  }
  return out;
}

BlinkerCrxInstallResult InstallDownloadedCrx(base::FilePath downloaded) {
  BlinkerCrxInstallResult result;
  if (downloaded.empty()) {
    result.error = "download failed";
    return result;
  }
  const base::FilePath dir = BlinkerEnsureExtensionsDirectory();
  if (dir.empty()) {
    result.error = "no extensions directory";
  } else {
    result = BlinkerInstallCrx(downloaded, dir);
  }
  base::DeleteFile(downloaded);
  return result;
}

}  // namespace

std::string BlinkerCrxInstallResultPage() {
  const BlinkerCrxInstallResult& result = LastResult();
  std::string body;
  if (result.id.empty() && result.error.empty()) {
    body = "<h1>Nothing installed yet</h1><p>Open a link to a .crx file, or "
           "put one in the BlinkerExtensions folder.</p>";
  } else if (result.ok) {
    body = base::StrCat({"<h1 class=ok>Extension installed</h1><p class=name>",
                         Escape(result.name), "</p><p class=id>", result.id,
                         "</p><p>It is active now. Reload a page to see it "
                         "run.</p>"});
  } else {
    body = base::StrCat({"<h1 class=bad>Could not install</h1><p>",
                         Escape(result.error),
                         "</p><p>A .crx must carry a valid signature from "
                         "whoever built it.</p>"});
  }
  return base::StrCat({
      "<!doctype html><meta charset=utf-8>"
      "<meta name=viewport content=\"width=device-width,initial-scale=1\">"
      "<title>Blinker extensions</title>"
      "<style>body{font:16px -apple-system;margin:0;padding:28px 20px;"
      "color:#1b1b1b;background:#f6f6f6}"
      "h1{font-size:20px;margin:0 0 14px}"
      ".ok{color:#116a2e}.bad{color:#9c2222}"
      ".name{font-weight:600;font-size:18px;margin:0 0 4px}"
      ".id{font-family:ui-monospace,Menlo,monospace;font-size:12px;"
      "color:#666;margin:0 0 16px;word-break:break-all}"
      "p{line-height:1.45}"
      "@media(prefers-color-scheme:dark){body{background:#151515;color:#eee}"
      ".id{color:#999}.ok{color:#5fd07f}.bad{color:#ff8a8a}}</style>",
      body});
}

void BlinkerDownloadAndInstallCrx(
    BrowserContext* browser_context,
    const GURL& url,
    base::OnceCallback<void(BlinkerCrxInstallResult)> callback) {
  if (url.SchemeIsFile()) {
    base::FilePath local;
    if (!net::FileURLToFilePath(url, &local)) {
      BlinkerCrxInstallResult result;
      result.error = "not a readable file";
      LastResult() = result;
      std::move(callback).Run(result);
      return;
    }
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
        base::BindOnce(
            [](base::FilePath local) {
              const base::FilePath dir = BlinkerEnsureExtensionsDirectory();
              BlinkerCrxInstallResult result;
              if (dir.empty()) {
                result.error = "no extensions directory";
                return result;
              }
              return BlinkerInstallCrx(local, dir);
            },
            std::move(local)),
        base::BindOnce(
            [](base::OnceCallback<void(BlinkerCrxInstallResult)> cb,
               BlinkerCrxInstallResult result) {
              LastResult() = result;
              std::move(cb).Run(result);
            },
            std::move(callback)));
    return;
  }

  StoragePartition* partition =
      browser_context ? browser_context->GetDefaultStoragePartition() : nullptr;
  if (!partition) {
    BlinkerCrxInstallResult result;
    result.error = "no network context";
    LastResult() = result;
    std::move(callback).Run(result);
    return;
  }

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = url;
  // Пакет не підресурс сторінки, тому без кук і referrer
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->redirect_mode = network::mojom::RedirectMode::kFollow;

  auto loader = network::SimpleURLLoader::Create(
      std::move(request),
      net::DefineNetworkTrafficAnnotation("blinker_crx_download", R"(
        semantics {
          sender: "Blinker extension installer"
          description:
            "Downloads a browser extension package (.crx) that the user "
            "tapped a link to, so it can be verified and installed."
          trigger: "The user opens a link to a .crx file."
          data: "None beyond the URL the user opened."
          destination: OTHER
        }
        policy {
          cookies_allowed: NO
          setting: "Do not open links to .crx files."
        })"));
  loader->SetTimeoutDuration(base::Seconds(120));
  network::SimpleURLLoader* raw = loader.get();
  raw->DownloadToTempFile(
      partition->GetURLLoaderFactoryForBrowserProcess().get(),
      base::BindOnce(
          [](std::unique_ptr<network::SimpleURLLoader> owned,
             base::OnceCallback<void(BlinkerCrxInstallResult)> callback,
             base::FilePath path) {
            base::ThreadPool::PostTaskAndReplyWithResult(
                FROM_HERE,
                {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                base::BindOnce(&InstallDownloadedCrx, std::move(path)),
                base::BindOnce(
                    [](base::OnceCallback<void(BlinkerCrxInstallResult)> cb,
                       BlinkerCrxInstallResult result) {
                      LastResult() = result;
                      std::move(cb).Run(result);
                    },
                    std::move(callback)));
          },
          std::move(loader), std::move(callback)),
      64 * 1024 * 1024);
}

size_t BlinkerInstallPendingCrx(const base::FilePath& dir) {
  if (!base::DirectoryExists(dir)) {
    return 0;
  }
  size_t installed = 0;
  std::vector<base::FilePath> pending;
  base::FileEnumerator files(dir, /*recursive=*/false,
                             base::FileEnumerator::FILES);
  for (base::FilePath path = files.Next(); !path.empty();
       path = files.Next()) {
    if (path.MatchesExtension(FILE_PATH_LITERAL(".crx"))) {
      pending.push_back(path);
    }
  }
  for (const base::FilePath& crx : pending) {
    const BlinkerCrxInstallResult result = BlinkerInstallCrx(crx, dir);
    if (result.ok) {
      base::Move(crx, crx.AddExtension(FILE_PATH_LITERAL(".installed")));
      ++installed;
    } else {
      base::Move(crx, crx.AddExtension(FILE_PATH_LITERAL(".failed")));
    }
  }
  return installed;
}

}  // namespace content
