import Foundation

/// The control page served at `/control`. Dark, touch-first, no external assets. Everything that comes from
/// the app is put on the page with `textContent`, never as markup.
enum WebControlPage {
    static var manifest: String {
        let json: [String: Any] = [
            "name": "GogglesView Control", "short_name": "Control", "start_url": "/control", "scope": "/",
            "display": "standalone", "background_color": WebViewerPage.background, "theme_color": WebViewerPage.background,
            "icons": [["src": "/control-icon-180.png", "sizes": "180x180", "type": "image/png"],
                      ["src": "/control-icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"]],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Shown without a valid token (also the way in for a home-screen app, which does not share Safari's cookies).
    static func login(code: Int) -> HTTPReply {
        let page = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="dark"><title>GogglesView Control</title>
        <style>body{margin:0;padding:24px 16px;font:17px -apple-system,system-ui,sans-serif;background:#1a1612;color:#ebe7df}
        input,button{font:inherit;padding:14px;border-radius:12px;border:1px solid #555;background:#26201a;color:inherit;width:100%;box-sizing:border-box;margin-top:12px}
        button{background:#d9461f;border:0;font-weight:600}</style></head><body>
        <h1>GogglesView Control</h1><p>Enter the control token shown in GogglesView Settings > Outputs, or scan the control QR code again.</p>
        <form method="get" action="/control"><input name="c" type="password" autocomplete="off" placeholder="Control token" aria-label="Control token"><button>Open</button></form>
        </body></html>
        """
        return HTTPReply(code: code, type: "text/html; charset=utf-8", body: Data(page.utf8))
    }

    static let html = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="color-scheme" content="dark">
    <meta name="theme-color" content="#1a1612">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="GV Control">
    <link rel="manifest" href="/control.webmanifest">
    <link rel="apple-touch-icon" href="/control-icon-180.png">
    <title>GogglesView Control</title>
    <style>
    :root{--bg:#1a1612;--card:#26201a;--line:#3a3128;--fg:#ebe7df;--dim:#9a9184;--good:#2e9b50;--warn:#d98a00;--bad:#d1352f;--acc:#d9461f}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);font:16px -apple-system,system-ui,sans-serif;-webkit-user-select:none;user-select:none;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
    header{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 14px;display:flex;flex-wrap:wrap;gap:10px 18px;align-items:center}
    #clock{font:700 28px ui-monospace,Menlo,monospace}
    .pill{padding:6px 12px;border-radius:99px;font-weight:600;font-size:14px;background:var(--card);border:1px solid var(--line)}
    .good{background:var(--good);border-color:var(--good)}.warning{background:var(--warn);border-color:var(--warn);color:#000}.bad{background:var(--bad);border-color:var(--bad)}.none{color:var(--dim)}
    #lost{display:none;background:var(--bad);text-align:center;font-weight:700;padding:10px}
    main{padding:12px;display:grid;gap:12px}
    h2{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--dim);margin:8px 2px 0}
    #feeds{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}
    .tile{background:var(--card);border:2px solid var(--line);border-radius:16px;padding:12px;display:grid;gap:8px}
    .tile.good{border-color:var(--good)}.tile.warning{border-color:var(--warn)}.tile.bad{border-color:var(--bad)}
    .tile .top{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
    .name{font-size:24px;font-weight:700}.st{color:var(--dim)}
    .thumb{width:100%;aspect-ratio:16/9;background:#000;border-radius:10px;object-fit:contain;display:block}
    .nums{display:flex;gap:14px;flex-wrap:wrap;font-weight:600;font-variant-numeric:tabular-nums}
    .iss{color:var(--warn);font-weight:700}
    .rec{color:#ff6b63;font-weight:700}
    .btns{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}
    button{font:inherit;font-weight:600;min-height:56px;border-radius:14px;border:1px solid var(--line);background:#352c23;color:var(--fg);padding:8px 10px;touch-action:manipulation}
    button:active{filter:brightness(1.4)}button:disabled{opacity:.35}
    button.arm{background:var(--bad);border-color:var(--bad)}
    button.on{background:var(--acc);border-color:var(--acc)}
    .row{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:8px}
    .chips{display:flex;flex-wrap:wrap;gap:8px}
    .chip{padding:8px 14px;border-radius:99px;border:1px solid var(--line);background:var(--card);font-weight:600}
    .chip.on{background:var(--good);border-color:var(--good)}.chip.waiting{background:var(--warn);border-color:var(--warn);color:#000}.chip.error{background:var(--bad);border-color:var(--bad)}
    #log{background:var(--card);border:1px solid var(--line);border-radius:14px;max-height:280px;overflow:auto;padding:6px 12px;font-size:14px;-webkit-user-select:text;user-select:text}
    #log div{padding:4px 0;border-bottom:1px solid var(--line)}#log time{color:var(--dim);margin-right:8px;font-variant-numeric:tabular-nums}#log .f{color:#ff8b84}
    #msg{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom));padding:14px;border-radius:14px;background:#000;border:1px solid var(--line);font-weight:600;display:none;z-index:9;text-align:center}
    #help{color:var(--dim);font-size:13px;padding:0 4px 24px}
    </style></head><body>
    <div id="lost" role="alert">Connection lost - retrying</div>
    <header>
      <div id="clock" aria-label="Clock">--:--:--</div>
      <div class="pill" id="up" aria-label="Time since GogglesView started">up 0:00:00</div>
      <div class="pill none" id="health" aria-label="Overall health">no goggles</div>
      <div class="pill none" id="away" aria-label="Away mode">Away off</div>
      <div class="pill" id="link" aria-label="Link to GogglesView">link ok</div>
    </header>
    <main>
      <h2>Goggles</h2><div id="feeds"></div>
      <h2>Event</h2>
      <div class="row">
        <button id="hdmi"></button>
        <button id="awayBtn"></button>
        <button id="prevBtn"></button>
        <button id="test">Send test alert</button>
      </div>
      <h2>Outputs</h2><div class="chips" id="outs"></div>
      <h2>Log</h2><div id="log" aria-live="polite"></div>
      <div id="help">Plain HTTP on your local network, with no encryption: use it only on a network you trust. Actions that stop something need a second tap.</div>
    </main>
    <div id="msg" role="status"></div>
    <script>
    "use strict";
    var S=null,tiles={},fails=0,armed=null,armT=0;
    function $(i){return document.getElementById(i)}
    function mk(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!==undefined)e.textContent=txt;return e}
    function hms(s){s=Math.max(0,Math.floor(s));var h=Math.floor(s/3600),m=Math.floor(s/60)%60,x=s%60;return h+":"+(m<10?"0":"")+m+":"+(x<10?"0":"")+x}
    function t2(ms){return new Date(ms).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",second:"2-digit"})}
    var mt=0;function toast(t,bad){var m=$("msg");m.textContent=t;m.style.display="block";m.style.borderColor=bad?"#d1352f":"#2e9b50";clearTimeout(mt);mt=setTimeout(function(){m.style.display="none"},3500)}
    async function act(action,feed,confirm){
      try{
        var b={action:action};if(feed!==undefined)b.feed=feed;if(confirm)b.confirm=true;
        var r=await fetch("/api/action",{method:"POST",headers:{"Content-Type":"application/json","X-GV-Control":"1"},body:JSON.stringify(b),credentials:"same-origin"});
        var d=await r.json();toast(d.message||("Error "+r.status),!d.ok);poll();
      }catch(e){toast("No connection to GogglesView",true)}
    }
    // Destructive actions: the first tap arms the button for 3 s, the second sends confirm.
    function tap(btn,action,feed,destructive,label){
      if(!destructive){act(action,feed,false);return}
      if(armed===btn){clearTimeout(armT);armed=null;btn.classList.remove("arm");btn.textContent=label;act(action,feed,true);return}
      if(armed){armed.classList.remove("arm");armed.textContent=armed._label}
      armed=btn;btn._label=label;btn.classList.add("arm");btn.textContent="Tap again to confirm";
      clearTimeout(armT);armT=setTimeout(function(){if(armed===btn){btn.classList.remove("arm");btn.textContent=label;armed=null}},3000);
    }
    function bind(btn,action,feed,destructive,label){btn.onclick=function(){tap(btn,action,feed,destructive,label)}}
    function setLabel(btn,t){if(armed!==btn&&btn.textContent!==t)btn.textContent=t}
    function tile(i){
      var t=tiles[i];if(t)return t;
      t={el:mk("div","tile")};
      var top=mk("div","top");t.name=mk("div","name");t.st=mk("div","st");top.append(t.name,t.st);
      t.img=mk("img","thumb");t.img.alt="Live thumbnail";t.img.onerror=function(){t.img.style.visibility="hidden"};t.img.onload=function(){t.img.style.visibility="visible"};
      t.nums=mk("div","nums");t.iss=mk("div","iss");t.rec=mk("div","rec");
      var bt=mk("div","btns");
      t.b={rec:mk("button"),rep:mk("button","",""),mk:mk("button"),shot:mk("button"),rc:mk("button")};
      t.b.rep.textContent="Save replay";t.b.mk.textContent="Marker";t.b.shot.textContent="Screenshot";t.b.rc.textContent="Reconnect";
      bind(t.b.rep,"replay.save",i,false);bind(t.b.mk,"marker.add",i,false);bind(t.b.shot,"screenshot",i,false);bind(t.b.rc,"reconnect",i,true,"Reconnect");
      bt.append(t.b.rec,t.b.rep,t.b.mk,t.b.shot,t.b.rc);
      t.el.append(top,t.img,t.nums,t.iss,t.rec,bt);$("feeds").appendChild(t.el);tiles[i]=t;return t;
    }
    function render(){
      var d=S;if(!d)return;
      $("up").textContent="up "+hms(d.uptime);
      var h=$("health");h.className="pill "+d.health;h.textContent=d.health==="none"?"no goggles":d.health==="good"?"all good":d.health==="warning"?"attention":"problem";
      var a=$("away");a.className="pill "+(d.away?"good":"none");a.textContent=d.away?"Away on":"Away off";
      var seen={};
      d.feeds.forEach(function(f){
        seen[f.index]=1;var t=tile(f.index);
        t.el.className="tile "+f.health;t.name.textContent=f.name;t.st.textContent=f.status;
        var n=[];if(f.fps!==undefined)n.push(f.fps+" fps");if(f.kbps!==undefined)n.push(f.kbps+" kbps");if(f.dropped!==undefined)n.push(f.dropped+" dropped");if(f.battery!==undefined)n.push("battery "+f.battery+"%");
        t.nums.textContent=n.join("   ")||"-";
        t.iss.textContent=f.issueText.join(" · ");
        t.rec.textContent=f.recording?"REC "+hms(f.elapsed):"";
        if(armed!==t.b.rec)bind(t.b.rec,f.recording?"record.stop":"record.start",f.index,f.recording,f.recording?"Stop recording":"Start recording");
        setLabel(t.b.rec,f.recording?"Stop recording":"Start recording");
        t.b.rec.disabled=!f.live&&!f.recording;t.b.rep.disabled=!f.live;t.b.shot.disabled=!f.live;t.b.mk.disabled=!f.recording;
        t.live=f.live;
      });
      Object.keys(tiles).forEach(function(k){if(!seen[k]){tiles[k].el.remove();delete tiles[k]}});
      var hd=$("hdmi");bind(hd,d.hdmiShown?"outputs.hide":"outputs.show",undefined,d.hdmiShown,d.hdmiShown?"Hide HDMI outputs":"Show HDMI outputs");setLabel(hd,d.hdmiShown?"Hide HDMI outputs":"Show HDMI outputs");hd.classList.toggle("on",d.hdmiShown);
      var ab=$("awayBtn");bind(ab,d.away?"away.off":"away.on",undefined,d.away,d.away?"Away mode: turn off":"Away mode: turn on");setLabel(ab,d.away?"Away mode: turn off":"Away mode: turn on");ab.classList.toggle("on",d.away);
      var pb=$("prevBtn");bind(pb,"preview.on",undefined,false);pb.textContent=d.previewAvailable?"Preview on this Mac":"Preview toggle unavailable";pb.disabled=!d.previewAvailable;
      bind($("test"),"alerts.test",undefined,false);
      var o=$("outs");o.textContent="";
      d.outputs.forEach(function(c){o.appendChild(mk("div","chip "+c.state,c.name+(c.state==="waiting"?" (waiting)":c.state==="error"?" !":"")))});
      if(!d.outputs.length)o.appendChild(mk("div","chip","none"));
      var l=$("log");l.textContent="";
      d.log.slice(0,50).forEach(function(e){var r=mk("div",e.ok?"":"f");r.append(mk("time","",t2(e.t)),document.createTextNode(e.who+" - "+e.text));l.appendChild(r)});
      if(!d.log.length)l.appendChild(mk("div","","Nothing yet"));
    }
    var busy=false;
    async function poll(){
      if(busy)return;busy=true;
      try{
        var r=await fetch("/api/state",{cache:"no-store",credentials:"same-origin"});
        if(r.status===401){$("lost").textContent="Signed out - open the control link again";$("lost").style.display="block";$("link").textContent="signed out";$("link").className="pill bad";busy=false;return}
        S=await r.json();fails=0;$("lost").style.display="none";$("link").textContent="link ok";$("link").className="pill good";render();
      }catch(e){fails++;$("lost").textContent="Connection lost - retrying";$("lost").style.display="block";$("link").textContent="connection lost";$("link").className="pill bad"}
      busy=false;
    }
    function thumbs(){Object.keys(tiles).forEach(function(k){var t=tiles[k];if(t.live){var n=new Image();n.onload=function(){t.img.src=n.src;t.img.style.visibility="visible"};n.src="/api/thumb/"+k+".jpg?"+Date.now()}else t.img.style.visibility="hidden"})}
    setInterval(function(){$("clock").textContent=new Date().toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",second:"2-digit"})},500);
    poll();setInterval(poll,1000);setInterval(thumbs,2000);
    </script></body></html>
    """#
}
