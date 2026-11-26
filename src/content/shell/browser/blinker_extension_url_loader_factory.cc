// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extension_url_loader_factory.h"

#include <optional>
#include <string>
#include <utility>

#include "base/byte_size.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "content/shell/browser/blinker_crx_installer.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_extension_messaging.h"
#include "content/shell/browser/blinker_extension_storage.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/network/public/cpp/data_element.h"
#include "services/network/public/cpp/resource_request_body.h"
#include "mojo/public/cpp/system/data_pipe.h"
#include "mojo/public/cpp/system/data_pipe_utils.h"
#include "content/public/browser/file_url_loader.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/shell/browser/blinker_web_extension.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/filename_util.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_version.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace content {

namespace {

void FailRequest(mojo::PendingRemote<network::mojom::URLLoaderClient> client,
                 int error_code) {
  mojo::Remote<network::mojom::URLLoaderClient> remote(std::move(client));
  remote->OnComplete(network::URLLoaderCompletionStatus(error_code));
}

void ServeBytes(mojo::PendingRemote<network::mojom::URLLoaderClient> client,
                const std::string& body,
                const std::string& mime_type,
                bool service_worker_script = false,
                bool allow_cross_origin_read = true) {
  mojo::Remote<network::mojom::URLLoaderClient> remote(std::move(client));

  mojo::ScopedDataPipeProducerHandle producer;
  mojo::ScopedDataPipeConsumerHandle consumer;
  const MojoCreateDataPipeOptions options{
      sizeof(MojoCreateDataPipeOptions), MOJO_CREATE_DATA_PIPE_FLAG_NONE, 1,
      static_cast<uint32_t>(std::max<size_t>(body.size() + 1, 1024))};
  if (mojo::CreateDataPipe(&options, producer, consumer) != MOJO_RESULT_OK ||
      !mojo::BlockingCopyFromString(body, producer)) {
    remote->OnComplete(
        network::URLLoaderCompletionStatus(net::ERR_INSUFFICIENT_RESOURCES));
    return;
  }
  producer.reset();

  auto head = network::mojom::URLResponseHead::New();
  head->mime_type = mime_type;
  head->charset = "utf-8";
  // Builder тримає string_view до Build(), тимчасовий рядок помер би раніше
  const std::string content_type = mime_type + "; charset=utf-8";
  net::HttpResponseHeaders::Builder builder(net::HttpVersion(1, 1), "200 OK");
  builder.AddHeader("Content-Type", content_type)
      .AddHeader("Cache-Control", "no-store");
  if (allow_cross_origin_read) {
    builder.AddHeader("Access-Control-Allow-Origin", "*");
  }
  if (service_worker_script) {
    // Воркер реєструється зі scope кореня, а скрипт глибше. Без
    // Service-Worker-Allowed реєстрація падає з kErrorSecurity
    builder.AddHeader("Service-Worker-Allowed", "/");
  }
  head->headers = builder.Build();
  head->content_length = static_cast<int64_t>(body.size());
  remote->OnReceiveResponse(std::move(head), std::move(consumer), std::nullopt);
  network::URLLoaderCompletionStatus status(net::OK);
  status.decoded_body_length = base::ByteSize(body.size());
  remote->OnComplete(status);
}

// Директива має бути першою інструкцією, перед нею лише пробіли
// і коментарі
bool HasUseStrictPrologue(std::string_view script) {
  size_t i = 0;
  while (i < script.size()) {
    const std::string_view rest = script.substr(i);
    if (base::IsAsciiWhitespace(rest.front())) {
      ++i;
      continue;
    }
    if (rest.starts_with("//")) {
      const size_t end = script.find('\n', i);
      i = (end == std::string_view::npos) ? script.size() : end + 1;
      continue;
    }
    if (rest.starts_with("/*")) {
      const size_t end = script.find("*/", i + 2);
      i = (end == std::string_view::npos) ? script.size() : end + 2;
      continue;
    }
    return rest.starts_with("\"use strict\"") || rest.starts_with("'use strict'");
  }
  return false;
}

std::string BackgroundApiShim(const BlinkerWebExtension& extension) {
  return base::StrCat(
      {BlinkerExtensionBaseShim(extension),
       BlinkerExtensionStorageShim(extension.id, extension.messaging_token),
       "\n",
       BlinkerExtensionPrivilegedApiShim(extension.id,
                                         extension.messaging_token),
       BlinkerExtensionWorkerShim(extension.id),
       BlinkerExtensionApiSurfaceShim()});
}

// Для відповідей що приходять пізніше. Якщо закрити канал URLLoader одразу,
// рендерер вважає запит перерваним
class BlinkerAsyncURLLoader : public network::mojom::URLLoader {
 public:
  static base::WeakPtr<BlinkerAsyncURLLoader> Create(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client) {
    auto* self = new BlinkerAsyncURLLoader(std::move(loader),
                                             std::move(client));
    return self->weak_factory_.GetWeakPtr();
  }

  BlinkerAsyncURLLoader(const BlinkerAsyncURLLoader&) = delete;
  BlinkerAsyncURLLoader& operator=(const BlinkerAsyncURLLoader&) = delete;

  void Respond(const std::string& body,
               const std::string& mime_type = "application/json") {
    mojo::ScopedDataPipeProducerHandle producer;
    mojo::ScopedDataPipeConsumerHandle consumer;
    const MojoCreateDataPipeOptions options{
        sizeof(MojoCreateDataPipeOptions), MOJO_CREATE_DATA_PIPE_FLAG_NONE, 1,
        static_cast<uint32_t>(std::max<size_t>(body.size() + 1, 1024))};
    if (mojo::CreateDataPipe(&options, producer, consumer) != MOJO_RESULT_OK ||
        !mojo::BlockingCopyFromString(body, producer)) {
      client_->OnComplete(
          network::URLLoaderCompletionStatus(net::ERR_INSUFFICIENT_RESOURCES));
      delete this;
      return;
    }
    producer.reset();

    auto head = network::mojom::URLResponseHead::New();
    head->mime_type = mime_type;
    head->charset = "utf-8";
    const std::string content_type = mime_type + "; charset=utf-8";
    head->headers =
        net::HttpResponseHeaders::Builder(net::HttpVersion(1, 1), "200 OK")
            .AddHeader("Access-Control-Allow-Origin", "*")
            .AddHeader("Cache-Control", "no-store")
            .AddHeader("Content-Type", content_type)
            .Build();
    head->content_length = static_cast<int64_t>(body.size());
    client_->OnReceiveResponse(std::move(head), std::move(consumer),
                               std::nullopt);
    network::URLLoaderCompletionStatus status(net::OK);
    status.decoded_body_length = base::ByteSize(body.size());
    client_->OnComplete(status);
    delete this;
  }

  void Fail(int error_code) {
    client_->OnComplete(network::URLLoaderCompletionStatus(error_code));
    delete this;
  }

 private:
  BlinkerAsyncURLLoader(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client)
      : receiver_(this, std::move(loader)), client_(std::move(client)) {
    receiver_.set_disconnect_handler(base::BindOnce(
        [](BlinkerAsyncURLLoader* self) { delete self; }, this));
    client_.set_disconnect_handler(base::BindOnce(
        [](BlinkerAsyncURLLoader* self) { delete self; }, this));
  }
  ~BlinkerAsyncURLLoader() override = default;

  void FollowRedirect(
      network::HttpRequestHeadersUpdateParams headers_update_params,
      const std::optional<GURL>& new_url) override {}
  void SetPriority(net::RequestPriority priority,
                   int32_t intra_priority_value) override {}

  mojo::Receiver<network::mojom::URLLoader> receiver_;
  mojo::Remote<network::mojom::URLLoaderClient> client_;
  base::WeakPtrFactory<BlinkerAsyncURLLoader> weak_factory_{this};
};

std::optional<std::string> ReadCss(const base::FilePath& path) {
  std::string css;
  if (!base::ReadFileToStringWithMaxSize(path, &css, 8 * 1024 * 1024)) {
    return std::nullopt;
  }
  return css;
}

void ServeLocalizedCss(base::WeakPtr<BlinkerAsyncURLLoader> loader,
                       const std::string& extension_id,
                       std::optional<std::string> css) {
  if (!loader) {
    return;
  }
  const BlinkerWebExtension* extension =
      BlinkerWebExtensionRegistry::GetInstance().FindExtension(extension_id);
  if (!css || !extension) {
    loader->Fail(net::ERR_FILE_NOT_FOUND);
    return;
  }
  loader->Respond(BlinkerLocalizeCss(*extension, std::move(*css)), "text/css");
}

bool ReadRequestBody(const network::ResourceRequest& request,
                     std::string* out) {
  if (!request.request_body) {
    return false;
  }
  const std::vector<network::DataElement>* elements =
      request.request_body->elements();
  if (!elements || elements->size() != 1) {
    return false;
  }
  const network::DataElementBytes* bytes =
      (*elements)[0].TryAs<network::DataElementBytes>();
  if (!bytes) {
    return false;
  }
  *out = std::string(bytes->AsStringView());
  return true;
}

}  // namespace

// static
mojo::PendingRemote<network::mojom::URLLoaderFactory>
BlinkerExtensionURLLoaderFactory::Create(FrameTreeNodeId frame_tree_node_id) {
  mojo::PendingRemote<network::mojom::URLLoaderFactory> remote;
  base::MakeSelfDeleting<BlinkerExtensionURLLoaderFactory>(
      remote.InitWithNewPipeAndPassReceiver(), frame_tree_node_id,
      GlobalRenderFrameHostId());
  return remote;
}

// static
mojo::PendingRemote<network::mojom::URLLoaderFactory>
BlinkerExtensionURLLoaderFactory::CreateForFrame(
    GlobalRenderFrameHostId frame_id) {
  mojo::PendingRemote<network::mojom::URLLoaderFactory> remote;
  base::MakeSelfDeleting<BlinkerExtensionURLLoaderFactory>(
      remote.InitWithNewPipeAndPassReceiver(), FrameTreeNodeId(), frame_id);
  return remote;
}

BlinkerExtensionURLLoaderFactory::BlinkerExtensionURLLoaderFactory(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> factory_receiver,
    FrameTreeNodeId frame_tree_node_id,
    GlobalRenderFrameHostId frame_id,
    base::SelfDeletingPassKey key)
    : network::SelfDeletingURLLoaderFactory(std::move(factory_receiver), key),
      frame_tree_node_id_(frame_tree_node_id),
      frame_id_(frame_id) {}

WebContents* BlinkerExtensionURLLoaderFactory::CallerWebContents() const {
  if (frame_tree_node_id_) {
    return WebContents::FromFrameTreeNodeId(frame_tree_node_id_);
  }
  RenderFrameHost* frame = RenderFrameHost::FromID(frame_id_);
  return frame ? WebContents::FromRenderFrameHost(frame) : nullptr;
}

BlinkerExtensionURLLoaderFactory::~BlinkerExtensionURLLoaderFactory() = default;

void BlinkerExtensionURLLoaderFactory::CreateLoaderAndStart(
    mojo::PendingReceiver<network::mojom::URLLoader> loader,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  BlinkerWebExtensionRegistry::ResolvedResource resource;
  if (!BlinkerWebExtensionRegistry::GetInstance().ResolveResource(
          request.url, request.request_initiator, &resource)) {
    // Відмова без причини, а не 404, щоб сторінка не випитала вміст розширення
    FailRequest(std::move(client), net::ERR_BLOCKED_BY_CLIENT);
    return;
  }

  if (resource.is_api_endpoint) {
    auto loader_ptr =
        BlinkerAsyncURLLoader::Create(std::move(loader), std::move(client));
    std::string body;
    if (!ReadRequestBody(request, &body)) {
      if (loader_ptr) {
        loader_ptr->Fail(net::ERR_INVALID_ARGUMENT);
      }
      return;
    }
    // Токен живе в ізольованому світі content script, сторінка його не бачить
    if (!resource.initiator_is_extension) {
      std::optional<base::DictValue> parsed =
          base::JSONReader::ReadDict(body, base::JSON_PARSE_RFC);
      const std::string* token = parsed ? parsed->FindString("tok") : nullptr;
      if (!token || resource.messaging_token.empty() ||
          *token != resource.messaging_token) {
        if (loader_ptr) {
          loader_ptr->Fail(net::ERR_BLOCKED_BY_CLIENT);
        }
        return;
      }
    }
    BlinkerApiCaller caller;
    caller.extension_id = resource.extension_id;
    caller.tab_id = BlinkerTabIdForWebContents(CallerWebContents());
    caller.from_extension_origin = resource.initiator_is_extension;
    caller.unlimited_storage = resource.unlimited_storage;
    caller.frame_id = frame_id_;
    BlinkerHandleExtensionApiCall(
        caller, body,
        base::BindOnce(
            [](base::WeakPtr<BlinkerAsyncURLLoader> loader,
               std::string json) {
              if (loader) {
                loader->Respond(json);
              }
            },
            loader_ptr));
    return;
  }

  if (resource.is_install_page) {
    ServeBytes(std::move(client), BlinkerCrxInstallResultPage(), "text/html",
               /*service_worker_script=*/false,
               /*allow_cross_origin_read=*/false);
    return;
  }

  // Міст повідомлень іде через фабрику навігації, вона знає вкладку
  if (resource.synthesized) {
    int tab_id = -1;
    int frame_id = -1;
    std::string document_id;
    if (WebContents* contents =
            frame_tree_node_id_
                ? WebContents::FromFrameTreeNodeId(frame_tree_node_id_)
                : nullptr) {
      tab_id = BlinkerTabIdForWebContents(contents);
      RenderFrameHost* bridge =
          contents->UnsafeFindFrameByFrameTreeNodeId(frame_tree_node_id_);
      if (RenderFrameHost* parent = bridge ? bridge->GetParent() : nullptr) {
        frame_id = BlinkerApiFrameId(parent);
        document_id = BlinkerApiDocumentId(parent);
      }
    }
    ServeBytes(std::move(client),
               BlinkerExtensionBridgeDocument(
                   resource.extension_id, resource.messaging_token, tab_id,
                   frame_id, document_id),
               // Без CORS, щоб fetch сторінки не прочитав токен в коді мосту
               "text/html", /*service_worker_script=*/false,
               /*allow_cross_origin_read=*/false);
    return;
  }

  if (resource.is_worker_shim) {
    const BlinkerWebExtension* extension =
        BlinkerWebExtensionRegistry::GetInstance().FindExtension(
            resource.extension_id);
    if (!extension) {
      FailRequest(std::move(client), net::ERR_FILE_NOT_FOUND);
      return;
    }
    ServeBytes(std::move(client), BackgroundApiShim(*extension),
               "text/javascript");
    return;
  }

  // API мають бути до коду розширення. Модулю шім дає перший import,
  // бо залежності виконуються раніше тіла
  if (resource.is_background_script) {
    std::string script;
    // Воркери великих розширень, як AdGuard чи LastPass, важать 8 або 9 МБ
    if (!base::ReadFileToStringWithMaxSize(resource.path, &script,
                                           12 * 1024 * 1024)) {
      FailRequest(std::move(client), net::ERR_FILE_NOT_FOUND);
      return;
    }
    const BlinkerWebExtension* extension =
        BlinkerWebExtensionRegistry::GetInstance().FindExtension(
            resource.extension_id);
    if (!extension) {
      FailRequest(std::move(client), net::ERR_FILE_NOT_FOUND);
      return;
    }
    // URL лишаємо той самий, від нього рахуються відносні import
    std::string prefix =
        extension->background_is_module
            ? base::StrCat({"import '/", kBlinkerWorkerShimPath, "';\n"})
            : BackgroundApiShim(*extension);
    // Код перед директивою робить скрипт нестрогим, тому "use strict" йде
    // першим
    if (!extension->background_is_module && HasUseStrictPrologue(script)) {
      prefix = base::StrCat({"\"use strict\";\n", prefix});
    }
    ServeBytes(std::move(client), base::StrCat({prefix, script}),
               "text/javascript", /*service_worker_script=*/true);
    return;
  }

  // Chrome підставляє __MSG_*__ у CSS розширення, тому читаємо тут
  if (resource.path.MatchesExtension(FILE_PATH_LITERAL(".css"))) {
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
        base::BindOnce(&ReadCss, resource.path),
        base::BindOnce(&ServeLocalizedCss,
                       BlinkerAsyncURLLoader::Create(std::move(loader),
                                                     std::move(client)),
                       resource.extension_id));
    return;
  }

  scoped_refptr<net::HttpResponseHeaders> headers =
      net::HttpResponseHeaders::Builder(net::HttpVersion(1, 1), "200 OK")
          .AddHeader("Access-Control-Allow-Origin", "*")
          .Build();

  network::ResourceRequest file_request = request;
  file_request.url = net::FilePathToFileURL(resource.path);
  CreateFileURLLoaderBypassingSecurityChecks(
      file_request, std::move(loader), std::move(client),
      /*observer=*/nullptr,
      /*allow_directory_listing=*/false, std::move(headers));
}

}  // namespace content
