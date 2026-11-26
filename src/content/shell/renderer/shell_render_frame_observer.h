// Copyright 2020 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_RENDERER_SHELL_RENDER_FRAME_OBSERVER_H_
#define CONTENT_SHELL_RENDERER_SHELL_RENDER_FRAME_OBSERVER_H_

#include <optional>

#include "content/public/renderer/render_frame_observer.h"
#include "content/shell/common/blinker_script_executor.mojom.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "third_party/blink/public/web/web_document.h"

namespace content {

class ShellRenderFrameObserver : public RenderFrameObserver,
                                 public mojom::BlinkerScriptExecutor {
 public:
  explicit ShellRenderFrameObserver(RenderFrame* frame);
  ~ShellRenderFrameObserver() override;

  ShellRenderFrameObserver(const ShellRenderFrameObserver&) = delete;
  ShellRenderFrameObserver& operator=(const ShellRenderFrameObserver&) = delete;

  static ShellRenderFrameObserver* ForFrame(RenderFrame* frame);

  // Blink кличе RunScriptsAtDocumentIdle десятки разів на секунду
  bool FirstInjectionForWindow(int run_at);

  void SetEngineCaretHidden(bool hidden) override;

 private:
  void Execute(int32_t world_id,
               const GURL& document_url,
               const std::vector<std::string>& sources,
               ExecuteCallback callback) override;
  void InsertCSS(const GURL& document_url,
                 const std::string& key,
                 const std::string& css,
                 bool user_origin,
                 InsertCSSCallback callback) override;
  void RemoveCSS(const GURL& document_url,
                 const std::string& key,
                 bool user_origin,
                 RemoveCSSCallback callback) override;

  std::optional<blink::WebDocument> TargetDocument(const GURL& document_url);

  // RenderFrameObserver implementation.
  void OnDestruct() override;
  void DidClearWindowObject() override;
  void DidCreateNewDocument() override;
  void OnInterfaceRequestForFrame(
      const std::string& interface_name,
      mojo::ScopedMessagePipeHandle* interface_pipe) override;

  mojo::ReceiverSet<mojom::BlinkerScriptExecutor> script_receivers_;
  unsigned injected_mask_ = 0;
  bool engine_caret_hidden_ = false;
};

}  // namespace content

#endif  // CONTENT_SHELL_RENDERER_SHELL_RENDER_FRAME_OBSERVER_H_
