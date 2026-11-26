// Copyright 2020 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/renderer/shell_render_frame_observer.h"

#include <map>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "content/public/common/content_switches.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/renderer/render_frame.h"
#include "content/public/renderer/render_frame_observer.h"
#include "content/shell/common/render_frame_test_helper.mojom.h"
#include "content/shell/common/shell_switches.h"
#include "content/shell/renderer/render_frame_test_helper.h"
#include "third_party/blink/public/web/web_testing_support.h"
#include "third_party/blink/public/mojom/script/script_evaluation_params.mojom.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "url/url_constants.h"

namespace content {

namespace {

std::map<RenderFrame*, ShellRenderFrameObserver*>& ObserversByFrame() {
  static base::NoDestructor<std::map<RenderFrame*, ShellRenderFrameObserver*>>
      map;
  return *map;
}

}  // namespace

ShellRenderFrameObserver::ShellRenderFrameObserver(RenderFrame* render_frame)
    : RenderFrameObserver(render_frame) {
  ObserversByFrame()[render_frame] = this;
}

ShellRenderFrameObserver::~ShellRenderFrameObserver() {
  if (RenderFrame* frame = render_frame()) {
    ObserversByFrame().erase(frame);
  }
}

ShellRenderFrameObserver* ShellRenderFrameObserver::ForFrame(
    RenderFrame* frame) {
  const auto it = ObserversByFrame().find(frame);
  return it == ObserversByFrame().end() ? nullptr : it->second;
}

bool ShellRenderFrameObserver::FirstInjectionForWindow(int run_at) {
  if (run_at < 0 || run_at > 7) {
    return true;
  }
  const unsigned bit = 1u << run_at;
  if ((injected_mask_ & bit) != 0) {
    return false;
  }
  injected_mask_ |= bit;
  return true;
}

void ShellRenderFrameObserver::DidCreateNewDocument() {
  injected_mask_ = 0;
  engine_caret_hidden_ = false;
}

void ShellRenderFrameObserver::SetEngineCaretHidden(bool hidden) {
  if (hidden == engine_caret_hidden_) {
    return;
  }
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  if (!frame) {
    return;
  }
  blink::WebDocument document = frame->GetDocument();
  if (document.IsNull()) {
    return;
  }
  // Стиль з !important перебиває сторінку. caret-color успадковується,
  // тож * доходить і до полів у shadow DOM
  const blink::WebStyleSheetKey key =
      blink::WebString::FromUtf8("blinker-engine-caret");
  if (hidden) {
    constexpr char kHiddenCaretCss[] =
        "* { caret-color: transparent !important; }";
    document.InsertStyleSheet(blink::WebString::FromUtf8(kHiddenCaretCss), &key,
                              blink::WebCssOrigin::kUser);
  } else {
    document.RemoveInsertedStyleSheet(key, blink::WebCssOrigin::kUser);
  }
  engine_caret_hidden_ = hidden;
}

std::optional<blink::WebDocument> ShellRenderFrameObserver::TargetDocument(
    const GURL& document_url) {
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  if (!frame || frame->GetDocument().IsNull()) {
    return std::nullopt;
  }
  GURL url(frame->GetDocument().Url());
  if (url.is_empty()) {
    url = GURL(url::kAboutBlankURL);
  }
  if (url != document_url) {
    return std::nullopt;
  }
  return frame->GetDocument();
}

void ShellRenderFrameObserver::InsertCSS(const GURL& document_url,
                                         const std::string& key,
                                         const std::string& css,
                                         bool user_origin,
                                         InsertCSSCallback callback) {
  std::optional<blink::WebDocument> document = TargetDocument(document_url);
  if (!document) {
    std::move(callback).Run("The target document changed before injection");
    return;
  }
  const blink::WebStyleSheetKey sheet_key = blink::WebString::FromUtf8(key);
  document->InsertStyleSheet(
      blink::WebString::FromUtf8(css), &sheet_key,
      user_origin ? blink::WebCssOrigin::kUser : blink::WebCssOrigin::kAuthor);
  std::move(callback).Run(std::nullopt);
}

void ShellRenderFrameObserver::RemoveCSS(const GURL& document_url,
                                         const std::string& key,
                                         bool user_origin,
                                         RemoveCSSCallback callback) {
  std::optional<blink::WebDocument> document = TargetDocument(document_url);
  if (!document) {
    std::move(callback).Run("The target document changed before injection");
    return;
  }
  document->RemoveInsertedStyleSheet(
      blink::WebString::FromUtf8(key),
      user_origin ? blink::WebCssOrigin::kUser : blink::WebCssOrigin::kAuthor);
  std::move(callback).Run(std::nullopt);
}

void ShellRenderFrameObserver::Execute(
    int32_t world_id,
    const GURL& document_url,
    const std::vector<std::string>& sources,
    ExecuteCallback callback) {
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  if (!frame || !TargetDocument(document_url)) {
    std::move(callback).Run(std::nullopt,
                            "The target document changed before injection", "");
    return;
  }
  if (world_id < ISOLATED_WORLD_ID_GLOBAL ||
      world_id > ISOLATED_WORLD_ID_MAX || sources.empty()) {
    std::move(callback).Run(std::nullopt, "Invalid script execution request", "");
    return;
  }

  std::vector<blink::WebScriptSource> scripts;
  for (const std::string& source : sources) {
    scripts.emplace_back(blink::WebString::FromUtf8(source));
  }
  const std::string document_id = frame->GetDocument().Token().ToString();
  frame->RequestExecuteScript(
      world_id, scripts, blink::mojom::UserActivationOption::kDoNotActivate,
      blink::mojom::EvaluationTiming::kSynchronous,
      blink::mojom::LoadEventBlockingOption::kDoNotBlock,
      base::BindOnce(
          [](ExecuteCallback callback, std::string document_id,
             std::optional<base::Value> result, base::TimeTicks start_time) {
            std::optional<std::string> error;
            if (!result) {
              error = start_time.is_null() ? "The target document was destroyed"
                                          : "Script execution failed";
            }
            std::move(callback).Run(std::move(result), error, document_id);
          },
          std::move(callback), document_id),
      blink::BackForwardCacheAware::kPossiblyDisallow,
      blink::mojom::WantResultOption::kWantResult,
      blink::mojom::PromiseResultOption::kAwait,
      /*script_injector_id=*/blink::WebString());
}

void ShellRenderFrameObserver::OnDestruct() {
  delete this;
}

void ShellRenderFrameObserver::DidClearWindowObject() {
  // Новий window значить нові світи, все впорскнуте зникло зі старим контекстом
  injected_mask_ = 0;
  auto& cmd = *base::CommandLine::ForCurrentProcess();
  if (cmd.HasSwitch(switches::kExposeInternalsForTesting)) {
    blink::WebTestingSupport::InjectInternalsObject(
        render_frame()->GetWebFrame());
  }
}

void ShellRenderFrameObserver::OnInterfaceRequestForFrame(
    const std::string& interface_name,
    mojo::ScopedMessagePipeHandle* interface_pipe) {
  if (interface_name == mojom::BlinkerScriptExecutor::Name_) {
    script_receivers_.Add(
        this, mojo::PendingReceiver<mojom::BlinkerScriptExecutor>(
                  std::move(*interface_pipe)));
    return;
  }
  if (interface_name == mojom::RenderFrameTestHelper::Name_) {
    RenderFrameTestHelper::Create(
        *render_frame(), mojo::PendingReceiver<mojom::RenderFrameTestHelper>(
                             std::move(*interface_pipe)));
    return;
  }
}

}  // namespace content
