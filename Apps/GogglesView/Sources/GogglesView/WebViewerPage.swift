import Foundation

/// The self-contained viewer page served at `/`. No external assets: the player is the browser's
/// native HLS support (Safari on iPad, iPhone and Mac). Everything it requests (playlist, segments,
/// manifest, icon) carries the access token in the query string.
enum WebViewerPage {
    static let background = "#1a1612"
    static let text = "#ebe7df"
    static let accent = "#d9461f"

    static func manifest(token: String) -> String {
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?")
        let json: [String: Any] = [
            "name": "GogglesView",
            "short_name": "Goggles",
            "description": "Live view from DJI Goggles 3",
            "start_url": "/" + q,
            "scope": "/",
            "display": "fullscreen",
            "background_color": background,
            "theme_color": background,
            "icons": [
                ["src": "icon-180.png" + q, "sizes": "180x180", "type": "image/png"],
                ["src": "icon-512.png" + q, "sizes": "512x512", "type": "image/png", "purpose": "any"],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func html(token: String) -> String {
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?") // percent-encoded alphanumerics only: safe in attributes and JS strings
        return #"""
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>GogglesView</title>
        <meta name="theme-color" content="#1a1612">
        <meta name="color-scheme" content="dark">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="GogglesView">
        <meta name="apple-mobile-web-app-status-bar-style" content="black">
        <link rel="manifest" href="manifest.webmanifest\#(q)">
        <link rel="apple-touch-icon" href="icon-180.png\#(q)">
        <link rel="icon" type="image/png" href="icon-180.png\#(q)">
        <style>
        :root{--bg:#1a1612;--fg:#ebe7df;--accent:#d9461f;--muted:#8a8378;--line:rgba(235,231,223,.35);--panel:rgba(26,22,18,.78)}
        *{box-sizing:border-box}
        html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;overscroll-behavior:none}
        #stage{position:relative;width:100vw;height:100vh;height:100dvh;overflow:hidden;background:var(--bg);-webkit-tap-highlight-color:transparent;touch-action:manipulation;user-select:none;-webkit-user-select:none}
        #v{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:var(--bg)}
        #top{position:absolute;top:0;left:0;right:0;display:flex;align-items:center;gap:10px;padding:max(10px,env(safe-area-inset-top)) max(14px,env(safe-area-inset-right)) 10px max(14px,env(safe-area-inset-left));pointer-events:none}
        #dot{width:10px;height:10px;border-radius:50%;background:var(--muted)}
        .live #dot{background:var(--accent);animation:pulse 1.6s ease-in-out infinite}
        @keyframes pulse{50%{opacity:.35}}
        #badge{font-weight:600;letter-spacing:.08em;font-size:13px}
        #lat{font-size:13px;color:var(--muted);font-variant-numeric:tabular-nums}
        #msg{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;text-align:center;padding:24px;pointer-events:none}
        #msg[hidden]{display:none}
        #msgtext{font-size:20px}
        #bar{position:absolute;right:0;bottom:0;display:flex;gap:10px;padding:10px max(14px,env(safe-area-inset-right)) max(12px,env(safe-area-inset-bottom)) 10px}
        button{font:inherit;color:var(--fg);background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 16px;min-height:44px;cursor:pointer}
        button[hidden]{display:none}
        button:focus-visible,#stage:focus-visible{outline:3px solid var(--fg);outline-offset:2px}
        #retry,#msg button{pointer-events:auto}
        #back{border-color:var(--accent)}
        @media (prefers-reduced-motion:reduce){.live #dot{animation:none}*{transition:none!important;scroll-behavior:auto!important}}
        </style></head>
        <body>
        <div id="stage" tabindex="0" role="button" aria-label="Live video. Tap to freeze or resume." aria-pressed="false">
        <video id="v" muted autoplay playsinline webkit-playsinline preload="auto" disablepictureinpicture aria-label="Live FPV video"></video>
        <div id="top" aria-live="polite"><span id="dot" aria-hidden="true"></span><span id="badge">CONNECTING</span><span id="lat"></span></div>
        <div id="msg" role="status"><div id="msgtext">Connecting</div><button id="retry" type="button" hidden>Retry</button></div>
        <div id="bar">
        <button id="back" type="button" hidden aria-label="Jump back to the live edge">Back to live</button>
        <button id="fs" type="button" aria-label="Toggle full screen">Full screen</button>
        </div>
        </div>
        <script>
        (function(){
        var Q='\#(q)',URL_='live.m3u8'+Q;
        function $(i){return document.getElementById(i)}
        var stage=$('stage'),v=$('v'),badge=$('badge'),lat=$('lat'),msg=$('msg'),msgtext=$('msgtext'),retry=$('retry'),back=$('back'),fs=$('fs');
        var state='connecting',failures=0,timer=null,frozen=false,lastTime=-1,lastProgress=Date.now(),since=Date.now(),wake=null;
        var TEXT={waiting:'Waiting for the stream',connecting:'Connecting',live:'',ended:'Stream ended',frozen:'Paused. Tap to resume'};
        var BADGE={waiting:'WAITING',connecting:'CONNECTING',live:'LIVE',ended:'ENDED',frozen:'PAUSED'};
        function set(s){
          state=s;since=Date.now();
          stage.classList.toggle('live',s==='live');
          badge.textContent=BADGE[s];
          msgtext.textContent=TEXT[s];
          msg.hidden=(s==='live');
          retry.hidden=(s!=='ended');
          if(s!=='live'&&s!=='frozen')lat.textContent='';
        }
        function edge(){var r=v.seekable;return(r&&r.length)?r.end(r.length-1):null}
        function behind(){var e=edge();return e===null?0:Math.max(0,e-v.currentTime)}
        function goLive(){var e=edge();if(e!==null)v.currentTime=Math.max(0,e-1);v.play().catch(function(){})}
        function schedule(){
          clearTimeout(timer);
          var d=Math.min(8000,1000*Math.pow(1.6,failures));failures++;
          timer=setTimeout(connect,d);
        }
        function fail(s){if(frozen)return;set(s||'ended');schedule()}
        function connect(){
          clearTimeout(timer);
          if(frozen)return;
          if(state!=='ended'&&state!=='live')set('connecting');
          fetch(URL_,{cache:'no-store'}).then(function(r){
            if(r.status===404){if(state!=='ended')set('waiting');schedule();return}
            if(!r.ok){fail();return}
            lastProgress=Date.now();lastTime=-1;
            v.src=URL_;v.load();
            var p=v.play();if(p&&p.catch)p.catch(function(){});
          }).catch(function(){fail()});
        }
        v.addEventListener('playing',function(){if(frozen)return;failures=0;lastProgress=Date.now();set('live');requestWake()});
        v.addEventListener('waiting',function(){if(!frozen&&state==='live'){set('connecting')}});
        v.addEventListener('error',function(){fail()});
        v.addEventListener('ended',function(){fail()});
        v.addEventListener('timeupdate',function(){if(v.currentTime!==lastTime){lastTime=v.currentTime;lastProgress=Date.now()}});
        setInterval(function(){
          if(frozen)return;
          var now=Date.now();
          if(state==='live'&&now-lastProgress>7000)fail();
          else if(state==='connecting'&&now-since>12000&&v.src)fail();
          if(state==='live'){var b=behind();lat.textContent=b.toFixed(1)+' s behind';back.hidden=b<6}
          else back.hidden=true;
        },500);
        function toggleFreeze(){
          if(frozen){frozen=false;stage.setAttribute('aria-pressed','false');set('connecting');goLive();if(!v.src)connect()}
          else if(state==='live'){frozen=true;stage.setAttribute('aria-pressed','true');v.pause();set('frozen');lat.textContent='';back.hidden=true}
        }
        stage.addEventListener('click',function(e){if(e.target.closest('button'))return;toggleFreeze()});
        stage.addEventListener('keydown',function(e){if(e.target===stage&&(e.key===' '||e.key==='Enter')){e.preventDefault();toggleFreeze()}});
        back.addEventListener('click',function(e){e.stopPropagation();goLive()});
        retry.addEventListener('click',function(e){e.stopPropagation();failures=0;connect()});
        function fsEl(){return document.fullscreenElement||document.webkitFullscreenElement}
        var canFs=!!(stage.requestFullscreen||stage.webkitRequestFullscreen||v.webkitEnterFullscreen);
        if(!canFs)fs.hidden=true;
        fs.addEventListener('click',function(e){
          e.stopPropagation();
          if(fsEl()){(document.exitFullscreen||document.webkitExitFullscreen).call(document);return}
          if(stage.requestFullscreen)stage.requestFullscreen().catch(function(){});
          else if(stage.webkitRequestFullscreen)stage.webkitRequestFullscreen();
          else if(v.webkitEnterFullscreen)v.webkitEnterFullscreen(); // iPhone: only the video element can go fullscreen
        });
        function requestWake(){try{if(navigator.wakeLock&&!wake)navigator.wakeLock.request('screen').then(function(l){wake=l;l.addEventListener('release',function(){wake=null})}).catch(function(){})}catch(x){}}
        document.addEventListener('visibilitychange',function(){
          if(document.visibilityState!=='visible'||frozen)return;
          requestWake();
          lastProgress=Date.now();
          if(state!=='live')connect(); else if(v.paused)v.play().catch(function(){});
        });
        window.addEventListener('online',function(){if(!frozen){failures=0;connect()}});
        if(!v.canPlayType('application/vnd.apple.mpegurl')){
          set('ended');msgtext.textContent='This browser cannot play HLS. Use Safari, or open live.m3u8 in VLC.';retry.hidden=true;
        }else connect();
        })();
        </script>
        </body></html>
        """#
    }
}
