// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_SHELL_COMMON_BLINKER_ERROR_PAGE_H_
#define CONTENT_SHELL_COMMON_BLINKER_ERROR_PAGE_H_

#include <functional>
#include <string>
#include <string_view>

#include "content/shell/common/blinker_dino_game.h"

namespace content {

struct BlinkerErrorText {
  const char* title;
  const char* detail;
};

// Коди з net/base/net_error_list.h, тут лиш числа щоб тест не тягнув net
inline BlinkerErrorText BlinkerErrorTextFor(int code, int http_status) {
  if (http_status >= 400) {
    return {"This page isn't working",
            "The server couldn't complete the request."};
  }
  switch (code) {
    case -106:
      return {"No internet connection",
              "Check your WiFi or mobile data and try again."};
    case -105:
    case -137:
      return {"This site can't be found",
              "Check the address for typos. If Secure DNS is on, the DNS "
              "provider might be unreachable or blocking this site."};
    case -7:
    case -118:
      return {"This site took too long to respond",
              "The server might be busy or down. Try again in a moment."};
    case -20:
      return {"This page was blocked",
              "The content blocker or an extension stopped it from loading."};
    case -310:
      return {"This page isn't working",
              "It redirected too many times. Clearing this site's cookies "
              "might help."};
    case -130:
    case -111:
    case -120:
    case -121:
      return {"The proxy isn't responding",
              "Check Tor and Proxy in Blinker Fluid settings."};
    case -6:
      return {"File not found",
              "It might have been moved, renamed or deleted."};
    case -301:
    case -302:
      return {"This link can't be opened",
              "Blinker Fluid doesn't know how to open this kind of address."};
  }
  if (code <= -200 && code > -300) {
    return {"Your connection isn't private",
            "The site's security certificate couldn't be verified, so "
            "Blinker Fluid stopped loading it."};
  }
  if (code == -107 || code == -113 || code == -117 || code == -123 ||
      code == -141 || code == -148 || code == -159) {
    return {"Secure connection failed",
            "The site uses an unsupported or broken encryption setup."};
  }
  if (code <= -100 && code > -200) {
    return {"This site can't be reached",
            "The server refused or dropped the connection."};
  }
  return {"This page couldn't load", "Something went wrong while loading it."};
}

inline std::string BlinkerErrorPageEscape(std::string_view text) {
  std::string out;
  for (char c : text) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      case '\'': out += "&#39;"; break;
      default: out.push_back(c);
    }
  }
  return out;
}

// Зі сторінкою гру ділить лише window.blinkerDino
inline constexpr char kBlinkerDinoLayoutScript[] = R"JS(
(function () {
  var root = document.documentElement;
  var wrap = document.querySelector('.interstitial-wrapper');
  var HEIGHT = 150;
  var started = false;
  function layout() {
    var game = window.blinkerDino;
    if (!started || !game) {
      return;
    }
    var landscape = innerWidth > innerHeight;
    var scale = 1;
    root.classList.toggle('arcade', landscape);
    if (landscape) {
      scale = Math.max(1, Math.min(innerHeight * 0.62 / HEIGHT, innerWidth / 420));
      var top = Math.max(8, Math.round((innerHeight - HEIGHT * scale) / 2));
      wrap.style.width = Math.min(700, Math.round(innerWidth / scale)) + 'px';
      wrap.style.setProperty('--top', top + 'px');
      wrap.style.top = top + 'px';
    } else {
      wrap.style.width = '';
      wrap.style.top = '';
    }
    game.adjustDimensions();
    var container = document.querySelector('.runner-container');
    if (container) {
      container.style.transform = landscape ? 'scale(' + scale + ')' : '';
    }
  }
  function start(event) {
    if (started || !wrap.contains(event.target)) {
      return;
    }
    started = true;
    layout();
  }
  document.addEventListener('touchstart', start, true);
  document.addEventListener('pointerdown', start, true);
  document.addEventListener('keydown', function (event) {
    if (event.keyCode === 32 || event.keyCode === 38) {
      started = true;
      layout();
    }
  }, true);
  addEventListener('resize', layout);
  addEventListener('orientationchange', function () { setTimeout(layout, 120); });
})();
)JS";

inline constexpr char kBlinkerDinoStyle[] =
    ".interstitial-wrapper{position:relative;max-width:600px;height:150px;"
    "margin:0 auto 14px}"
    ".icon{display:inline-block}.icon-offline{visibility:hidden;width:0;"
    "height:0}"
    ".runner-container{direction:ltr;height:150px;max-width:600px;"
    "overflow:hidden;position:absolute;top:0;left:0;right:0;margin:0 auto;"
    "width:44px;transform-origin:top center;-webkit-user-select:none;"
    "-webkit-tap-highlight-color:transparent}"
    ".runner-canvas{height:150px;max-width:600px;opacity:1;overflow:hidden;"
    "position:absolute;top:0;z-index:10;image-rendering:pixelated}"
    ".controller{height:100vh;left:0;position:absolute;top:0;width:100vw;"
    "z-index:9}"
    "#offline-resources,.hidden{display:none}"
    ".offline-runner-live-region{position:absolute;clip-path:polygon(0 0,0 0,"
    "0 0);overflow:hidden}"
    "@keyframes intro{from{width:44px}to{width:100%}}"
    ".hint{text-align:center;font-size:13px;margin:0 0 14px}"
    "#retry{display:none}"
    "html.inverted{background:#fff;filter:invert(1);"
    "transition:filter 1.5s cubic-bezier(.65,.05,.36,1)}"
    "@media (prefers-color-scheme:dark){.runner-canvas{filter:invert(1)}"
    "html.inverted{background:var(--bg);filter:invert(0)}}"
    "@media (max-height:480px){main{padding-top:14px}}"
    "html.arcade .text,html.arcade .hint,html.arcade .buttons{display:none}"
    "html.arcade,html.arcade body{overflow:hidden;height:100%}"
    "html.arcade .interstitial-wrapper{position:fixed;left:0;right:0;"
    "margin:0 auto;max-width:none}"
    "html.arcade .controller{left:calc(50% - 50vw);top:calc(0px - var(--top))}"
    "html.arcade #retry{display:block;position:fixed;top:12px;right:14px;"
    "z-index:20}";

// Кнопки працюють з документа помилки, бо reload у ньому вантажить
// ту саму адресу знову
inline std::string BlinkerErrorPageHtml(
    int code,
    int http_status,
    std::string_view error_name,
    std::string_view host,
    bool main_frame,
    std::string_view lang,
    const std::function<std::string(std::string_view)>& tr) {
  const BlinkerErrorText text = BlinkerErrorTextFor(code, http_status);
  const std::string title = BlinkerErrorPageEscape(tr(text.title));
  const std::string detail = BlinkerErrorPageEscape(tr(text.detail));
  std::string code_line = BlinkerErrorPageEscape(error_name);
  if (http_status >= 400) {
    code_line = "HTTP " + std::to_string(http_status);
  }
  const bool rtl = lang == "ar";
  const bool dino = main_frame && http_status < 400;
  std::string html =
      "<!doctype html><html lang=\"" + BlinkerErrorPageEscape(lang) +
      "\" dir=\"" + (rtl ? "rtl" : "ltr") +
      "\"><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width, "
      "initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\">"
      "<title>" +
      title +
      "</title><style>"
      ":root{--bg:#f6f6f7;--fg:#1c1c1e;--muted:#6b6b70;--card:#fff;"
      "--line:#e2e2e6;--button:#1c1c1e;--button-fg:#fff}"
      "@media (prefers-color-scheme:dark){:root{--bg:#0e0e10;--fg:#f2f2f4;"
      "--muted:#9a9aa0;--card:#1f1f23;--line:#2c2c31;--button:#f2f2f4;"
      "--button-fg:#111}}"
      "html,body{margin:0;background:var(--bg);color:var(--fg);"
      "font:16px -apple-system,system-ui,sans-serif}"
      "main{max-width:520px;margin:0 auto;padding:18vh 24px 32px}"
      ".icon-box{width:44px;height:44px;border-radius:12px;"
      "background:var(--card);border:1px solid var(--line);display:flex;"
      "align-items:center;justify-content:center;font-size:22px;"
      "margin-bottom:22px}"
      "h1{font-size:24px;line-height:1.25;margin:0 0 10px;font-weight:650}"
      "p{margin:0 0 6px;color:var(--muted);line-height:1.45}"
      ".host{color:var(--fg);font-weight:600;word-break:break-all}"
      ".code{font:12px ui-monospace,Menlo,monospace;color:var(--muted);"
      "margin-top:14px}"
      ".buttons{display:flex;gap:10px;margin-top:26px;flex-wrap:wrap}"
      "button{font:inherit;font-weight:600;border-radius:12px;padding:12px "
      "20px;border:1px solid var(--line);background:var(--card);"
      "color:var(--fg)}"
      "button.primary{background:var(--button);color:var(--button-fg);"
      "border-color:var(--button)}"
      ".frame main{padding:16px}.frame h1{font-size:17px}" +
      std::string(dino ? kBlinkerDinoStyle : "") +
      "</style></head><body class=\"" + std::string(main_frame ? "" : "frame") +
      "\"><main>";
  if (dino) {
    html += "<div class=\"interstitial-wrapper\"><div class=\"icon "
            "icon-offline\"></div></div><p class=\"hint\">" +
            BlinkerErrorPageEscape(tr("Tap the dinosaur to play")) + "</p>";
  } else {
    html += "<div class=\"icon-box\" aria-hidden=\"true\">!</div>";
  }
  html += "<div class=\"text\"><h1>" + title + "</h1>";
  if (!host.empty()) {
    html += "<p class=\"host\">" + BlinkerErrorPageEscape(host) + "</p>";
  }
  html += "<p>" + detail + "</p><p class=\"code\">" + code_line + "</p></div>";
  if (main_frame) {
    html += "<div class=\"buttons\"><button class=\"primary\" "
            "onclick=\"location.reload()\">" +
            BlinkerErrorPageEscape(tr("Try Again")) +
            "</button><button id=\"back\" hidden "
            "onclick=\"history.back()\">" +
            BlinkerErrorPageEscape(tr("Go Back")) +
            "</button></div><script>if(history.length>1)"
            "document.getElementById('back').hidden=false</script>";
  }
  html += "</main>";
  if (dino) {
    html += "<div id=\"offline-resources\"><img "
            "id=\"offline-resources-1x\" src=\"" +
            std::string(kBlinkerDinoSprite1x) +
            "\"><img id=\"offline-resources-2x\" src=\"" +
            std::string(kBlinkerDinoSprite2x) +
            "\"></div><button id=\"retry\" class=\"primary\" "
            "onclick=\"location.reload()\">" +
            BlinkerErrorPageEscape(tr("Try Again")) + "</button><script>" +
            std::string(kBlinkerDinoScript) + "</script><script>" +
            std::string(kBlinkerDinoLayoutScript) + "</script>";
  }
  html += "</body></html>";
  return html;
}

}  // namespace content

#endif  // CONTENT_SHELL_COMMON_BLINKER_ERROR_PAGE_H_
