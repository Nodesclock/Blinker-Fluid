// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_URL_LOADER_FACTORY_H_
#define CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_URL_LOADER_FACTORY_H_

#include "base/memory/self_deleting.h"
#include "content/public/browser/frame_tree_node_id.h"
#include "content/public/browser/global_routing_id.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/cpp/self_deleting_url_loader_factory.h"

namespace content {

class WebContents;

class BlinkerExtensionURLLoaderFactory
    : public network::SelfDeletingURLLoaderFactory {
 public:
  // frame_tree_node_id задається для фабрики навігації, щоб міст знав вкладку
  static mojo::PendingRemote<network::mojom::URLLoaderFactory> Create(
      FrameTreeNodeId frame_tree_node_id = FrameTreeNodeId());
  static mojo::PendingRemote<network::mojom::URLLoaderFactory> CreateForFrame(
      GlobalRenderFrameHostId frame_id);

  BlinkerExtensionURLLoaderFactory(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> factory_receiver,
      FrameTreeNodeId frame_tree_node_id,
      GlobalRenderFrameHostId frame_id,
      base::SelfDeletingPassKey key);

  BlinkerExtensionURLLoaderFactory(const BlinkerExtensionURLLoaderFactory&) =
      delete;
  BlinkerExtensionURLLoaderFactory& operator=(
      const BlinkerExtensionURLLoaderFactory&) = delete;

 private:
  ~BlinkerExtensionURLLoaderFactory() override;

  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation)
      override;

  WebContents* CallerWebContents() const;

  const FrameTreeNodeId frame_tree_node_id_;
  const GlobalRenderFrameHostId frame_id_;
};

}  // namespace content

#endif  // CONTENT_SHELL_BROWSER_BLINKER_EXTENSION_URL_LOADER_FACTORY_H_
