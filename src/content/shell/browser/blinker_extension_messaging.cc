// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/shell/browser/blinker_extension_messaging.h"

#include "base/json/string_escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/strcat.h"
#include "content/shell/browser/blinker_extension_api.h"
#include "content/shell/browser/blinker_web_extension.h"

namespace content {

namespace {

std::string Quoted(std::string_view value) {
  std::string out;
  base::EscapeJSONString(value, /*put_in_quotes=*/true, &out);
  return out;
}

// Через JSON, як MessageFromV8 у messaging_util.cc. undefined стає null
constexpr char kWireJs[] =
    "const RECEIVER_GONE='Could not establish connection. Receiving end does "
    "not exist.';"
    "const PORT_CLOSED='The message port closed before a response was "
    "received.';"
    "const NOT_SERIALIZABLE='Could not serialize message.';"
    "const PORT_DEAD='Attempting to use a disconnected port object';"
    "const toWire=(m)=>{try{const s=JSON.stringify(m===undefined?null:m);"
    "return typeof s==='string'?s:null;}catch(e){return null;}};"
    "const fromWire=(s)=>{try{return JSON.parse(s);}catch(e){return null;}};"
    "const report=(e)=>{try{console.error('Error in event handler:',e);}"
    "catch(x){}};"
    "const listenerApi=(list,onAdd)=>({"
    "addListener:(fn)=>{if(typeof fn!=='function'||list.indexOf(fn)>=0)"
    "return;list.push(fn);if(onAdd)onAdd();},"
    "removeListener:(fn)=>{const i=list.indexOf(fn);if(i>=0)list.splice(i,1);},"
    "hasListener:(fn)=>list.indexOf(fn)>=0,"
    "hasListeners:()=>list.length>0});";

// За правилами one_time_message_handler.cc. pending значить що відповідь
// буде пізніше
constexpr char kReplyJs[] =
    "const awaitReply=(post,cb)=>{const record=new Promise((resolve)=>{"
    "let done=false;const finish=(r)=>{if(done)return;done=true;"
    "clearTimeout(guard);resolve(r||{closed:true});};"
    "const guard=setTimeout(()=>finish({closed:true}),300000);"
    "try{post(finish);}catch(e){finish({noReceiver:true});}});"
    "if(typeof cb==='function'){record.then((r)=>{"
    "const err=r.noReceiver?RECEIVER_GONE:r.error!==undefined?"
    "String(r.error):r.closed?PORT_CLOSED:null;"
    "if(err)c.runtime.lastError={message:err};"
    "try{cb(err?undefined:fromWire(r.payload));}finally{if(err)"
    "delete c.runtime.lastError;}});return undefined;}"
    "return record.then((r)=>{if(r.noReceiver)throw new Error(RECEIVER_GONE);"
    "if(r.error!==undefined)throw new Error(String(r.error));"
    "return r.closed?undefined:fromWire(r.payload);});};"
    "const replyChannel=(finish)=>{const ch=new MessageChannel();"
    "ch.port1.onmessage=(ev)=>{finish(ev.data);try{ch.port1.close();}"
    "catch(e){}};"
    "try{ch.port1.addEventListener('close',()=>finish({closed:true}));}"
    "catch(e){}return ch;};"
    "const dispatchMessage=(fns,message,sender,respond)=>{"
    "if(!fns.length){respond({noReceiver:true});return;}"
    "let replied=false,pending=false;"
    "const reply=(r)=>{if(replied)return;replied=true;respond(r);};"
    "const sendResponse=(v)=>{if(replied)return;const s=toWire(v);"
    "if(s===null){reply({error:NOT_SERIALIZABLE});"
    "throw new TypeError(NOT_SERIALIZABLE);}reply({payload:s});};"
    "for(const fn of fns){let r;"
    "try{r=fn(message,sender,sendResponse);}catch(e){report(e);continue;}"
    "if(r===true){pending=true;}"
    "else if(r&&typeof r.then==='function'){pending=true;"
    "r.then(sendResponse,(e)=>reply({error:"
    "Object.prototype.toString.call(e)==='[object Error]'?String(e.message):"
    "\"A runtime.onMessage listener's promise rejected without an Error\"}));"
    "}}"
    "if(replied)return;"
    "if(pending)respond({pending:true});else reply({closed:true});};";

// close від MessagePort значить, що інший бік зник, touch тримає воркер
// живим поки ходять повідомлення
constexpr char kPortJs[] =
    "const makePort=(mp,name,sender,touch)=>{"
    "const msgFns=[],discFns=[];let live=true;"
    "const port={name:name===undefined||name===null?'':String(name),"
    "onMessage:listenerApi(msgFns),onDisconnect:listenerApi(discFns),"
    "postMessage:(m)=>{if(!live)throw new Error(PORT_DEAD);const s=toWire(m);"
    "if(s===null)throw new Error(NOT_SERIALIZABLE);"
    "try{mp.postMessage({kind:'msg',data:s});}catch(e){}if(touch)touch();},"
    "disconnect:()=>{if(!live)return;live=false;"
    "try{mp.postMessage({kind:'disconnect'});}catch(e){}"
    "try{mp.close();}catch(e){}}};"
    "if(sender)port.sender=sender;"
    "const end=(error)=>{if(!live)return;live=false;try{mp.close();}catch(e){}"
    "if(error)c.runtime.lastError={message:error};"
    "try{for(const fn of discFns.slice()){try{fn(port);}catch(e){report(e);}}}"
    "finally{if(error)delete c.runtime.lastError;}};"
    "mp.onmessage=(ev)=>{const m=ev.data;if(!m||!live)return;"
    "if(m.kind==='msg'){if(touch)touch();const v=fromWire(m.data);"
    "for(const fn of msgFns.slice()){try{fn(v,port);}catch(e){report(e);}}"
    "return;}"
    "if(m.kind==='disconnect')end(m.noListener?RECEIVER_GONE:m.error);};"
    "try{mp.addEventListener('close',()=>end());}catch(e){}"
    "return port;};"
    "const opener=(name,touch,start)=>{const ch=new MessageChannel();"
    "const port=makePort(ch.port1,name,null,touch);"
    "const refuse=()=>{try{ch.port2.postMessage("
    "{kind:'disconnect',noListener:true});}catch(e){}};"
    "start(ch.port2,refuse);return port;};"
    "const receiveOpen=(fns,name,sender,mp,touch)=>{"
    "if(!fns.length){try{mp.postMessage({kind:'disconnect',noListener:true});"
    "mp.close();}catch(e){}return;}"
    "try{mp.postMessage({kind:'accept'});}catch(e){}"
    "const port=makePort(mp,name,sender,touch);"
    "for(const fn of fns.slice()){try{fn(port);}catch(e){report(e);}}};";

// Порт живе поки є хоч один одержувач, інакше RECEIVER_GONE. Клієнт без
// шіму не відповідає, тому за ACK_MS він вважається відсутнім
constexpr char kRouteJs[] =
    "const ACK_MS=5000;"
    "const deliverOnce=(sends)=>new Promise((resolve)=>{"
    "if(!sends.length){resolve({noReceiver:true});return;}"
    "let left=sends.length,closed=false,done=false;"
    "const settle=(r)=>{if(done)return;r=r||{closed:true};"
    "if(!r.closed&&!r.noReceiver){done=true;resolve(r);return;}"
    "closed=closed||!!r.closed;"
    "if(--left<=0){done=true;resolve(closed?{closed:true}:{noReceiver:true});}"
    "};"
    "for(const send of sends){const ch=new MessageChannel();"
    "let once=false,acked=false;"
    "const one=(r)=>{if(once)return;once=true;clearTimeout(timer);"
    "try{ch.port1.close();}catch(e){}settle(r);};"
    "const timer=setTimeout(()=>{if(!acked)one({noReceiver:true});},ACK_MS);"
    "ch.port1.onmessage=(ev)=>{const r=ev.data;"
    "if(r&&r.pending){acked=true;clearTimeout(timer);return;}one(r);};"
    "try{ch.port1.addEventListener('close',()=>one({closed:true}));}"
    "catch(e){}"
    "try{send(ch.port2);}catch(e){one({noReceiver:true});}}});"
    "const openPort=(up,opens)=>{"
    "const ends=new Map();let accepted=false,over=false;"
    "const finish=()=>{if(over)return;over=true;"
    "try{up.postMessage(accepted?{kind:'disconnect'}:"
    "{kind:'disconnect',noListener:true});}catch(e){}"
    "try{up.close();}catch(e){}};"
    "const drop=(end)=>{const timer=ends.get(end);if(timer===undefined)return;"
    "clearTimeout(timer);ends.delete(end);try{end.close();}catch(e){}"
    "if(!ends.size)finish();};"
    "const shut=()=>{if(over)return;over=true;"
    "for(const [end,timer] of ends){clearTimeout(timer);"
    "try{end.postMessage({kind:'disconnect'});end.close();}catch(e){}}"
    "ends.clear();try{up.close();}catch(e){}};"
    "const chans=opens.map(()=>new MessageChannel());"
    "for(const ch of chans){const end=ch.port1;"
    "ends.set(end,setTimeout(()=>drop(end),ACK_MS));"
    "end.onmessage=(ev)=>{const m=ev.data;if(!m||over)return;"
    "clearTimeout(ends.get(end));"
    "if(m.kind==='accept'){if(!accepted){accepted=true;"
    "try{up.postMessage({kind:'accept'});}catch(e){}}return;}"
    "if(m.kind==='msg'){try{up.postMessage(m);}catch(e){}return;}"
    "if(m.kind==='disconnect')drop(end);};"
    "try{end.addEventListener('close',()=>drop(end));}catch(e){}}"
    "opens.forEach((open,i)=>{try{open(chans[i].port2);}"
    "catch(e){drop(chans[i].port1);}});"
    "if(!opens.length){finish();return;}"
    "up.onmessage=(ev)=>{const m=ev.data;if(!m||over)return;"
    "if(m.kind==='msg'){for(const end of ends.keys()){"
    "try{end.postMessage(m);}catch(e){}}return;}"
    "if(m.kind==='disconnect')shut();};"
    "try{up.addEventListener('close',shut);}catch(e){}};";

// Повідомлення до воркера йдуть по черзі, тому порядок зберігається
constexpr char kFindWorkerJs[] =
    "const findWorker=(deadline)=>navigator.serviceWorker.getRegistration()"
    ".then((reg)=>{"
    "if(reg){const active=reg.active||navigator.serviceWorker.controller;"
    "if(active)return active;"
    "const pending=reg.waiting||reg.installing;"
    "if(pending)return new Promise((res)=>{const on=()=>{"
    "if(pending.state==='activated'||pending.state==='activating'){"
    "pending.removeEventListener('statechange',on);"
    "res(reg.active||pending);}};"
    "pending.addEventListener('statechange',on);on();});}"
    "if(Date.now()>deadline)"
    "throw new Error(reg?'worker never activated':'no registration');"
    "return new Promise((r)=>setTimeout(r,150))"
    ".then(()=>findWorker(deadline));});"
    "let workerQueue=Promise.resolve();"
    "const toWorker=(msg,transfer)=>{const run=()=>Promise.all("
    "[findWorker(Date.now()+4000),msg]).then(([w,m])=>{"
    "w.postMessage(Object.assign({__blinker:ID},m),transfer||[]);});"
    "const p=workerQueue.then(run,run);workerQueue=p.catch(()=>{});return p;};"
    "let lastPing=0;"
    "const pingWorker=()=>{const now=Date.now();if(now-lastPing<10000)return;"
    "lastPing=now;toWorker({kind:'keepalive'}).catch(()=>{});};";

constexpr char kArgsJs[] =
    "const SEND_SIGNATURE='optional string extensionId, any message, optional "
    "object options, optional function callback';"
    "const TABS_SEND_SIGNATURE='integer tabId, any message, optional object "
    "options, optional function callback';"
    "const invocationError=(name,signature,why)=>new TypeError("
    "'Error in invocation of '+name+'('+signature+'): '+why);"
    "const sendArgs=(args,name,signature)=>{"
    "const list=Array.prototype.slice.call(args);"
    "while(list.length>1&&list[list.length-1]===undefined)list.pop();"
    "let id=null,message=null,options=null,callback;"
    "if(list.length&&typeof list[list.length-1]==='function')"
    "callback=list.pop();"
    "if(list.length===1){message=list[0];}"
    "else if(list.length===2){if(typeof list[0]==='string'||list[0]===null||"
    "list[0]===undefined){id=list[0];message=list[1];}"
    "else{message=list[0];options=list[1];}}"
    "else if(list.length===3){id=list[0];message=list[1];options=list[2];}"
    "else throw invocationError(name,signature,'No matching signature.');"
    "const wire=toWire(message);"
    "if(wire===null)throw invocationError(name,signature,NOT_SERIALIZABLE);"
    "return {extensionId:id===undefined?null:id,wire:wire,options:options,"
    "callback:callback};};"
    "const tabsArgs=(args,name,signature)=>{"
    "const list=Array.prototype.slice.call(args);let callback;"
    "while(list.length>2&&list[list.length-1]===undefined)list.pop();"
    "if(list.length&&typeof list[list.length-1]==='function')"
    "callback=list.pop();"
    "if(list.length<2||list.length>3||!Number.isInteger(list[0]))"
    "throw invocationError(name,signature,'No matching signature.');"
    "const options=list[2]||{};const wire=toWire(list[1]);"
    "if(wire===null)throw invocationError(name,signature,NOT_SERIALIZABLE);"
    "return {wire:wire,callback:callback,target:{tabId:list[0],"
    "frameId:options.frameId,documentId:options.documentId}};};"
    "const connectArgs=(args)=>{let id=null,info=args[0];"
    "if(typeof args[0]==='string'||((args[0]===null||args[0]===undefined)&&"
    "args.length>1)){id=args[0]===undefined?null:args[0];info=args[1];}"
    "const name=info&&info.name!==undefined&&info.name!==null?"
    "String(info.name):'';"
    "return {extensionId:id,name:name};};"
    "const connectTarget=(tabId,info)=>{if(!Number.isInteger(tabId))"
    "throw invocationError('tabs.connect',"
    "'integer tabId, optional object connectInfo','No matching signature.');"
    "info=info||{};"
    "return {name:info.name===undefined||info.name===null?'':"
    "String(info.name),target:{tabId:tabId,frameId:info.frameId,"
    "documentId:info.documentId}};};";

// Міст з воркером створюється при першому використанні, розширення без
// повідомлень нічого не платить
std::string ContentWorldShim(std::string_view extension_id,
                             std::string_view token,
                             bool user_script) {
  return base::StrCat({
      "(()=>{const ID=", Quoted(extension_id), ",TOK=", Quoted(token),
      ",US=", user_script ? "true" : "false",
      ",ORIGIN='", kBlinkerExtensionScheme, "://'+ID",
      ",BRIDGE=ORIGIN+'/", kBlinkerBridgePath, "';",
      "const c=globalThis.chrome=globalThis.chrome||{};",
      "c.runtime=c.runtime||{};",
      "if(c.runtime.sendMessage)return;",
      "c.runtime.id=c.runtime.id||ID;",
      "c.runtime.getURL=c.runtime.getURL||((p)=>ORIGIN+'/'+",
      "String(p||'').replace(/^\\//,''));",
      "c.runtime.lastError=undefined;",
      kWireJs,
      kReplyJs,
      kPortJs,
      kArgsJs,
      "const incoming=[],connectFns=[];",
      // Браузер сам вставляє скрипти у світ розширення і звідси підсуває їм
      // повідомлення, як ніби воно прийшло від розширення
      "Object.defineProperty(c.runtime,'__blinkerDeliverLocal',{value:(m,cb)=>",
      "dispatchMessage(incoming.slice(),m,{id:ID},cb||(()=>{}))});",
      "let framePromise=null;",
      "c.runtime.__blinkerBridgeState='idle';",

      // Сторінка може вирвати iframe мосту з DOM, тому перевіряємо щоразу
      "const frameAlive=(f)=>!!(f&&f.isConnected&&f.contentWindow);",
      "const ensureFrame=(depth)=>{",
      "if(framePromise){return framePromise.then((f)=>{",
      "if(frameAlive(f))return f;",
      "framePromise=null;",
      "if((depth||0)>2)throw new Error('bridge frame kept detaching');",
      "return ensureFrame((depth||0)+1);},(err)=>{framePromise=null;",
      "if((depth||0)>2)throw err;return ensureFrame((depth||0)+1);});}",
      "c.runtime.__blinkerBridgeState='loading';",
      "framePromise=new Promise((resolve,reject)=>{",
      "const f=document.createElement('iframe');",
      "f.setAttribute('aria-hidden','true');",
      "f.name='__blinker_bridge';",
      "f.style.cssText='display:none!important;width:0;height:0;border:0';",
      "f.src=BRIDGE;",
      "let settled=false;",
      "const go=()=>{if(settled)return;settled=true;",
      "c.runtime.__blinkerBridgeState='ready';resolve(f);};",
      // Реєструємось лиш на ready. onload буває ще на початковому about:blank,
      // і init з ORIGIN тоді губився
      "const register=()=>{try{const bc=new MessageChannel();",
      "bc.port1.onmessage=(ev)=>{const d=ev.data||{};",
      "const port=ev.ports&&ev.ports[0];if(!port)return;",
      "if(d.kind==='deliver'){dispatchMessage(incoming.slice(),",
      "fromWire(d.payload),d.sender||{id:ID},(r)=>{",
      "try{port.postMessage(r);}catch(err){}});return;}",
      "if(d.kind==='open')receiveOpen(connectFns,d.name,d.sender||{id:ID},",
      "port,touch);};",
      "f.contentWindow.postMessage({__blinker:ID,tok:TOK,kind:'init'},",
      "ORIGIN,[bc.port2]);}catch(err){}};",
      "const onReady=(e)=>{const d=e.data;",
      "if(d&&d.__blinker===ID&&d.kind==='ready'&&e.source===f.contentWindow){",
      "register();go();}};",
      "window.addEventListener('message',onReady);",
      "f.onload=go;",
      "f.onerror=()=>reject(new Error('bridge frame failed to load'));",
      "setTimeout(()=>{if(!settled)",
      "reject(new Error('bridge frame timeout'));},5000);",
      "const attach=()=>{(document.documentElement||document.body)",
      ".appendChild(f);};",
      "if(document.documentElement||document.body)attach();",
      "else document.addEventListener('DOMContentLoaded',attach,{once:true});",
      "});return framePromise;};",
      "const toBridge=(msg,transfer)=>ensureFrame().then((f)=>{",
      "f.contentWindow.postMessage(Object.assign(",
      "{__blinker:ID,tok:TOK,userScript:US},msg),ORIGIN,transfer||[]);});",
      "let lastPing=0;",
      "const touch=()=>{const now=Date.now();if(now-lastPing<10000)return;",
      "lastPing=now;toBridge({kind:'keepalive'}).catch(()=>{});};",

      "c.runtime.sendMessage=function(){",
      "const a=sendArgs(arguments,'runtime.sendMessage',SEND_SIGNATURE);",
      "return awaitReply((finish)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){",
      "finish({noReceiver:true});return;}",
      "const ch=replyChannel(finish);",
      "toBridge({kind:'send',payload:a.wire,origin:location.origin,",
      "url:location.href},[ch.port2]).catch(()=>finish({noReceiver:true}));",
      "},a.callback);};",
      "c.runtime.connect=function(){const a=connectArgs(arguments);",
      "return opener(a.name,touch,(down,refuse)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){refuse();return;}",
      "toBridge({kind:'connect',name:a.name,origin:location.origin,",
      "url:location.href},[down]).catch(refuse);});};",
      // Реєстрація обробника піднімає міст, інакше розширення не дістанеться
      // до світу що тільки слухає
      "const raise=()=>{ensureFrame().catch(()=>{});};",
      "c.runtime.onMessage=c.runtime.onMessage||listenerApi(incoming,raise);",
      "c.runtime.onConnect=c.runtime.onConnect||listenerApi(connectFns,raise);",
      "c.runtime.onConnectExternal=c.runtime.onConnectExternal||",
      "listenerApi([]);",
      "c.runtime.onMessageExternal=c.runtime.onMessageExternal||",
      "listenerApi([]);",
      "})();",
  });
}

}  // namespace

std::string BlinkerExtensionBridgeDocument(std::string_view extension_id,
                                           std::string_view token,
                                           int tab_id,
                                           int frame_id,
                                           std::string_view document_id) {
  // Від батька приймаємо тільки з TOK, назад у вікно йде лише ready
  return base::StrCat({
      "<!doctype html><meta charset=utf-8><title>blinker bridge</title>"
      "<script>(()=>{const ID=", Quoted(extension_id),
      ",TOK=", Quoted(token), ",TAB=", base::NumberToString(tab_id),
      ",FRAME=", base::NumberToString(frame_id), ",DOC=", Quoted(document_id),
      ";",
      "const ORIGIN='", kBlinkerExtensionScheme, "://'+ID;",
      "const API=ORIGIN+'/", kBlinkerApiPath, "';",
      kWireJs,
      kRouteJs,
      kFindWorkerJs,
      "const worlds=[];",
      "const matches=(t)=>!!t&&t.tabId===TAB&&",
      "(t.frameId===undefined||t.frameId===null||t.frameId===FRAME)&&",
      "(t.documentId===undefined||t.documentId===null||t.documentId===DOC);",
      // sender.tab свіжий як в Chrome, але не частіше раз на 250 мс
      "let tabAt=0,tabNow=Promise.resolve(null);",
      "const senderTab=()=>{const now=Date.now();if(now-tabAt>250){tabAt=now;",
      "tabNow=tabNow.then(()=>fetch(API,{method:'POST',",
      "body:JSON.stringify({ns:'runtime',op:'bridgeSender'})}))",
      ".then((r)=>r.json()).then((r)=>(r&&r.ok&&r.tab)||null)",
      ".catch(()=>null);}return tabNow;};",
      "const senderFor=(d)=>senderTab().then((tab)=>{",
      "const s={id:ID,url:d.url,origin:d.origin};",
      "if(tab){s.tab=tab;s.frameId=FRAME;s.documentId=DOC;",
      "s.documentLifecycle='active';}return s;});",

      "window.addEventListener('message',(e)=>{const d=e.data;",
      "if(!d||d.__blinker!==ID||d.tok!==TOK)return;",
      "const port=e.ports&&e.ports[0];",
      "if(d.kind==='init'){if(port)worlds.push(port);return;}",
      "if(d.kind==='keepalive'){pingWorker();return;}",
      "if(!port)return;",
      "if(d.kind==='send'){toWorker(senderFor(d).then((s)=>({kind:'message',",
      "payload:d.payload,sender:s,userScript:!!d.userScript})),[port])",
      ".catch(()=>{try{port.postMessage({noReceiver:true});}catch(err){}});",
      "return;}",
      "if(d.kind==='connect'){toWorker(senderFor(d).then((s)=>({",
      "kind:'connect',name:d.name,sender:s,userScript:!!d.userScript})),",
      "[port]).catch(()=>{try{port.postMessage(",
      "{kind:'disconnect',noListener:true});port.close();}catch(err){}});}});",

      "if(navigator.serviceWorker){",
      "navigator.serviceWorker.addEventListener('message',(e)=>{",
      "const d=e.data;",
      "if(!d||d.__blinker!==ID)return;",
      "const port=e.ports&&e.ports[0];if(!port)return;",
      "const here=matches(d.target)&&worlds.length>0;",
      "if(d.kind==='deliver'){if(!here){",
      "try{port.postMessage({noReceiver:true});}catch(err){}return;}",
      "try{port.postMessage({pending:true});}catch(err){}",
      "deliverOnce(worlds.map((w)=>(mp)=>w.postMessage({kind:'deliver',",
      "payload:d.payload,sender:d.sender},[mp]))).then((r)=>{",
      "try{port.postMessage(r);}catch(err){}});return;}",
      "if(d.kind==='open'){if(!here){try{port.postMessage(",
      "{kind:'disconnect',noListener:true});port.close();}catch(err){}",
      "return;}",
      "openPort(port,worlds.map((w)=>(mp)=>w.postMessage({kind:'open',",
      "name:d.name,sender:d.sender},[mp])));}});",
      "try{navigator.serviceWorker.startMessages();}catch(e){}}",

      // Токена тут навмисно нема
      "try{parent.postMessage({__blinker:ID,kind:'ready'},'*');}catch(e){}",
      "})();</script>",
  });
}

std::string BlinkerExtensionWorkerShim(std::string_view extension_id) {
  // Воркер розподіляє повідомлення, тому що тільки він бачить всі контексти
  // через clients.matchAll. \n в кінці, щоб шім не злипся
  return base::StrCat({
      "(()=>{try{const ID=", Quoted(extension_id), ";",
      "const ORIGIN='", kBlinkerExtensionScheme, "://'+ID;",
      "if(typeof self.chrome==='undefined')self.chrome={};",
      "const c=self.chrome;c.runtime=c.runtime||{};c.runtime.id=ID;",
      "c.runtime.getURL=c.runtime.getURL||((p)=>ORIGIN+'/'+",
      "String(p||'').replace(/^\\//,''));",
      "c.runtime.lastError=undefined;",
      kWireJs,
      kReplyJs,
      kPortJs,
      kRouteJs,
      kArgsJs,
      "const msgFns=[],userMsgFns=[],connFns=[],userConnFns=[],extFns=[];",
      "c.runtime.onMessage=c.runtime.onMessage||listenerApi(msgFns);",
      "c.runtime.onUserScriptMessage=c.runtime.onUserScriptMessage||",
      "listenerApi(userMsgFns);",
      "c.runtime.onConnect=c.runtime.onConnect||listenerApi(connFns);",
      "c.runtime.onUserScriptConnect=listenerApi(userConnFns);",
      "c.runtime.onConnectExternal=listenerApi([]);",
      "c.runtime.onMessageExternal=listenerApi(extFns);",
      // Повідомлення з externally_connectable приходить в обгортці моста і йде
      // лише в onMessageExternal
      "const externalOf=(payload)=>{try{const m=fromWire(payload);",
      "return m&&typeof m==='object'&&m.__blinkerExternal===ID?m:null;}",
      "catch(e){return null;}};",
      "const SELF={id:ID,origin:ORIGIN,",
      "url:String((self.location&&self.location.href)||'')};",
      "const isBridge=(x)=>!!x.url&&",
      "x.url.split(/[?#]/)[0].endsWith('/", kBlinkerBridgePath, "');",
      "const clientsExcept=(skip)=>self.clients.matchAll({type:'window',",
      "includeUncontrolled:true}).then((cs)=>{const pages=[],bridges=[];",
      "for(const x of cs){if(!x||(skip&&x.id===skip))continue;",
      "(isBridge(x)?bridges:pages).push(x);}",
      "return {pages:pages,bridges:bridges};});",
      "const routeMessage=(payload,sender,o)=>clientsExcept(o.from)",
      ".then((cl)=>{",
      "const post=(x,extra)=>(port)=>x.postMessage(Object.assign(",
      "{__blinker:ID,kind:'deliver',payload:payload,sender:sender},extra),",
      "[port]);",
      "if(o.target)return deliverOnce(cl.bridges.map((x)=>",
      "post(x,{target:o.target})));",
      "const sends=cl.pages.map((x)=>post(x,{userScript:!!o.userScript}));",
      "if(o.from!==undefined)sends.unshift((port)=>dispatchMessage(",
      "(o.userScript?userMsgFns:msgFns).slice(),fromWire(payload),sender,",
      "(r)=>{try{port.postMessage(r);}catch(e){}}));",
      "return deliverOnce(sends);});",
      "const routeConnect=(up,name,sender,o)=>clientsExcept(o.from)",
      ".then((cl)=>{",
      "const open=(x,extra)=>(port)=>x.postMessage(Object.assign(",
      "{__blinker:ID,kind:'open',name:name,sender:sender},extra),[port]);",
      "if(o.target){openPort(up,cl.bridges.map((x)=>",
      "open(x,{target:o.target})));return;}",
      "const opens=cl.pages.map((x)=>open(x,{userScript:!!o.userScript}));",
      "if(o.from!==undefined)opens.unshift((port)=>receiveOpen(",
      "o.userScript?userConnFns:connFns,name,sender,port,null));",
      "openPort(up,opens);}).catch(()=>openPort(up,[]));",

      "c.runtime.sendMessage=function(){",
      "const a=sendArgs(arguments,'runtime.sendMessage',SEND_SIGNATURE);",
      "return awaitReply((finish)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){",
      "finish({noReceiver:true});return;}",
      "routeMessage(a.wire,SELF,{}).then(finish,",
      "()=>finish({noReceiver:true}));},a.callback);};",
      "c.runtime.connect=function(){const a=connectArgs(arguments);",
      "return opener(a.name,null,(down,refuse)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){refuse();return;}",
      "routeConnect(down,a.name,SELF,{});});};",
      "c.tabs=c.tabs||{};",
      "c.tabs.sendMessage=function(){",
      "const a=tabsArgs(arguments,'tabs.sendMessage',TABS_SEND_SIGNATURE);",
      "return awaitReply((finish)=>{routeMessage(a.wire,SELF,",
      "{target:a.target}).then(finish,()=>finish({noReceiver:true}));},",
      "a.callback);};",
      "c.tabs.connect=function(tabId,info){const t=connectTarget(tabId,info);",
      "return opener(t.name,null,(down)=>routeConnect(down,t.name,SELF,",
      "{target:t.target}));};",

      // Без waitUntil воркер глухне посеред роботи. Тримаємо до 270 с, бо
      // подія довша за п'ять хвилин зупиняє воркер
      "const keepAlive=(event,ms)=>{try{if(!event||!event.waitUntil)return;",
      "event.waitUntil(new Promise((r)=>setTimeout(r,ms)));}catch(e){}};",
      "const hold=(event,p)=>{try{if(!event||!event.waitUntil)return;",
      "event.waitUntil(Promise.race([p,",
      "new Promise((r)=>setTimeout(r,270000))]));}catch(e){}};",
      "self.addEventListener('message',(event)=>{const d=event.data;",
      "if(!d||d.__blinker!==ID)return;",
      "keepAlive(event,30000);",
      "const port=event.ports&&event.ports[0];",
      "const o={from:(event.source&&event.source.id)||'',",
      "userScript:!!d.userScript,target:d.target||null};",
      "const ex=d.kind==='message'&&port?externalOf(d.payload):null;",
      "if(ex){hold(event,new Promise((done)=>dispatchMessage(extFns.slice(),",
      "ex.message,{url:ex.url,origin:ex.origin,tab:d.sender&&d.sender.tab},",
      "(r)=>{if(r&&r.pending)return;try{port.postMessage(r);}catch(e){}",
      "done();})));return;}",
      "if(d.kind==='message'&&port){hold(event,",
      "routeMessage(d.payload,d.sender||{id:ID},o).then(",
      "(r)=>{try{port.postMessage(r);}catch(e){}},",
      "()=>{try{port.postMessage({noReceiver:true});}catch(e){}}));return;}",
      "if(d.kind==='connect'&&port)",
      "routeConnect(port,d.name,d.sender||{id:ID},o);});",
      "}catch(err){try{console.error('Blinker: the worker messaging shim '",
      "+'failed to install: '+((err&&err.stack)||err));}catch(e2){}}",
      "})();\n",
  });
}

std::string BlinkerExtensionUserScriptMessagingShim(
    std::string_view extension_id,
    std::string_view token) {
  return ContentWorldShim(extension_id, token, /*user_script=*/true);
}

std::string BlinkerExtensionContentMessagingShim(std::string_view extension_id,
                                                 std::string_view token) {
  return ContentWorldShim(extension_id, token, /*user_script=*/false);
}

std::string BlinkerExtensionExternalPageShim() {
  // Усі розширення на сторінці ділять цей шім. Без підтвердження від моста
  // за 1.5 с вважаємо, що розширення нема
  return
      "(()=>{const w=window;w.chrome=w.chrome||{};"
      "const r=w.chrome.runtime=w.chrome.runtime||{};"
      "if(r.__blinkerExternal)return;r.__blinkerExternal=true;"
      "const waiting=new Map();let seq=0;"
      "w.addEventListener('message',(e)=>{const d=e.data;"
      "if(e.source!==w||!d)return;"
      "const p=waiting.get(d.seq);if(!p)return;"
      "if(d.__blinkerExtAck===1){clearTimeout(p.timer);return;}"
      "if(d.__blinkerExtRes!==1)return;"
      "waiting.delete(d.seq);clearTimeout(p.timer);p.resolve(d);});"
      "r.sendMessage=function(...args){"
      "const cb=typeof args[args.length-1]==='function'?args.pop():null;"
      "const id=args[0],message=args[1];"
      "if(typeof id!=='string'||args.length<2){throw new TypeError("
      "'Error in invocation of runtime.sendMessage(optional string "
      "extensionId, any message, optional object options, optional function "
      "callback): No matching signature.');}"
      "const run=()=>new Promise((resolve)=>{const n=++seq;"
      "const timer=setTimeout(()=>{waiting.delete(n);resolve({error:"
      "'Could not establish connection. Receiving end does not exist.'});},"
      "1500);waiting.set(n,{resolve,timer});"
      "try{w.postMessage({__blinkerExtReq:1,seq:n,extId:id,message:message},"
      "'*');}catch(x){waiting.delete(n);clearTimeout(timer);"
      "resolve({error:String((x&&x.message)||x)});}});"
      "if(cb){run().then((d)=>{if(d.error){r.lastError={message:d.error};"
      "try{cb();}finally{r.lastError=undefined;}}else{cb(d.response);}});"
      "return;}"
      "return run().then((d)=>{if(d.error)throw new Error(d.error);"
      "return d.response;});};"
      "r.connect=function(){throw new Error("
      "'runtime.connect is not available to web pages here.');};"
      "})();";
}

std::string BlinkerExtensionExternalBridge(std::string_view extension_id) {
  return base::StrCat({
      "(()=>{const ID=", Quoted(extension_id), ";",
      "window.addEventListener('message',(e)=>{const d=e.data;",
      "if(e.source!==window||!d||d.__blinkerExtReq!==1||d.extId!==ID)return;",
      "window.postMessage({__blinkerExtAck:1,seq:d.seq},'*');",
      "let done=false;const finish=(x)=>{if(done)return;done=true;",
      "window.postMessage(Object.assign({__blinkerExtRes:1,seq:d.seq},x),",
      "'*');};",
      "try{chrome.runtime.sendMessage({__blinkerExternal:ID,message:d.message,",
      "url:location.href,origin:location.origin},(response)=>{",
      "const err=chrome.runtime.lastError;",
      "finish(err?{error:err.message}:{response:response});});}",
      "catch(x){finish({error:String((x&&x.message)||x)});}});})();",
  });
}

std::string BlinkerExtensionPageMessagingShim(std::string_view extension_id) {
  // Те саме походження що й воркер, тому без мосту
  return base::StrCat({
      "(()=>{const ID=", Quoted(extension_id), ";",
      "const ORIGIN='", kBlinkerExtensionScheme, "://'+ID;",
      "const c=globalThis.chrome=globalThis.chrome||{};",
      "c.runtime=c.runtime||{};",
      "if(c.runtime.sendMessage||!navigator.serviceWorker)return;",
      kWireJs,
      kReplyJs,
      kPortJs,
      kArgsJs,
      kFindWorkerJs,
      "const msgFns=[],userMsgFns=[],connFns=[],userConnFns=[];",
      "c.runtime.onMessage=listenerApi(msgFns);",
      "c.runtime.onUserScriptMessage=listenerApi(userMsgFns);",
      "c.runtime.onConnect=listenerApi(connFns);",
      "c.runtime.onUserScriptConnect=listenerApi(userConnFns);",
      "c.runtime.onConnectExternal=listenerApi([]);",
      "c.runtime.onMessageExternal=listenerApi([]);",
      "let tabOnce=null;",
      "const sender=()=>{if(!tabOnce)tabOnce=Promise.resolve().then(()=>",
      "c.tabs&&c.tabs.getCurrent?c.tabs.getCurrent():undefined)",
      ".catch(()=>undefined);",
      "return tabOnce.then((tab)=>{const s={id:ID,url:location.href,",
      "origin:ORIGIN};if(tab){s.tab=tab;if(window.top===window)s.frameId=0;}",
      "return s;});};",
      "const send=(msg,transfer)=>toWorker(sender().then((s)=>",
      "Object.assign({sender:s},msg)),transfer);",

      "c.runtime.sendMessage=function(){",
      "const a=sendArgs(arguments,'runtime.sendMessage',SEND_SIGNATURE);",
      "return awaitReply((finish)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){",
      "finish({noReceiver:true});return;}",
      "const ch=replyChannel(finish);",
      "send({kind:'message',payload:a.wire},[ch.port2])",
      ".catch(()=>finish({noReceiver:true}));},a.callback);};",
      "c.runtime.connect=function(){const a=connectArgs(arguments);",
      "return opener(a.name,pingWorker,(down,refuse)=>{",
      "if(a.extensionId!==null&&a.extensionId!==ID){refuse();return;}",
      "send({kind:'connect',name:a.name},[down]).catch(refuse);});};",
      "if(c.tabs){",
      "c.tabs.sendMessage=function(){",
      "const a=tabsArgs(arguments,'tabs.sendMessage',TABS_SEND_SIGNATURE);",
      "return awaitReply((finish)=>{const ch=replyChannel(finish);",
      "send({kind:'message',payload:a.wire,target:a.target},[ch.port2])",
      ".catch(()=>finish({noReceiver:true}));},a.callback);};",
      "c.tabs.connect=function(tabId,info){const t=connectTarget(tabId,info);",
      "return opener(t.name,pingWorker,(down,refuse)=>",
      "send({kind:'connect',name:t.name,target:t.target},[down])",
      ".catch(refuse));};}",

      "navigator.serviceWorker.addEventListener('message',(e)=>{",
      "const d=e.data;",
      "if(!d||d.__blinker!==ID)return;",
      "const port=e.ports&&e.ports[0];if(!port)return;",
      "if(d.kind==='deliver'){dispatchMessage(",
      "(d.userScript?userMsgFns:msgFns).slice(),fromWire(d.payload),",
      "d.sender||{id:ID},(r)=>{try{port.postMessage(r);}catch(err){}});",
      "return;}",
      "if(d.kind==='open')receiveOpen(d.userScript?userConnFns:connFns,",
      "d.name,d.sender||{id:ID},port,pingWorker);});",
      "try{navigator.serviceWorker.startMessages();}catch(e){}",
      "})();",
  });
}

}  // namespace content
