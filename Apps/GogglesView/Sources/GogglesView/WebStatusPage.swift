import Foundation

/// A read-only status page for a phone or tablet: one big tile per goggles, refreshed every 2 seconds
/// from `/status.json`. Everything from the feed is put on the page with `textContent`, never as markup,
/// so a feed name cannot inject anything.
enum WebStatusPage {
    static func html(token: String) -> String {
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>GogglesView status</title>
        <style>
        body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#111;color:#fff}
        h1{font-size:15px;font-weight:600;margin:0;padding:10px 14px;opacity:.7}
        #g{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;padding:10px}
        .t{border-radius:14px;padding:14px;min-height:130px}
        .good{background:#1c7c3a}.warning{background:#b36b00}.bad{background:#a3201c}
        .n{font-size:30px;font-weight:700;margin:0 0 4px}.s{font-size:15px;opacity:.9}
        .m{display:flex;justify-content:space-between;font-size:22px;font-weight:600;margin-top:8px}
        .i{font-size:15px;font-weight:700;margin-top:6px}.o{font-size:13px;opacity:.85;margin-top:4px}
        #u{padding:6px 14px;font-size:12px;opacity:.6}
        </style></head><body><h1>GogglesView status</h1><div id="g"></div><div id="u"></div>
        <script>
        function el(c,t){var e=document.createElement('div');e.className=c;e.textContent=t;return e}
        async function tick(){
          try{
            var r=await fetch('/status.json\(q)',{cache:'no-store'});var d=await r.json();
            var g=document.getElementById('g');g.textContent='';
            d.feeds.forEach(function(f){
              var t=document.createElement('div');t.className='t '+f.health;
              t.appendChild(el('n',f.name));t.appendChild(el('s',f.status));
              var m=el('m','');m.appendChild(el('',f.fps!=null?f.fps+' fps':'-'));m.appendChild(el('',f.battery!=null?f.battery+'%':'-'));
              t.appendChild(m);
              if(f.issueText.length)t.appendChild(el('i',f.issueText.join(' · ')));
              var on=f.outputs.filter(function(o){return o.state!=='off'}).map(function(o){return o.name+(o.state==='waiting'?' (waiting)':o.state==='error'?'!':'')});
              t.appendChild(el('o',on.length?'Sending: '+on.join(', '):'Not sending'));
              g.appendChild(t);
            });
            if(!d.feeds.length)g.appendChild(el('s','No goggles open'));
            document.getElementById('u').textContent='Updated '+new Date(d.updated).toLocaleTimeString();
          }catch(e){document.getElementById('u').textContent='No connection to GogglesView'}
        }
        tick();setInterval(tick,2000);
        </script></body></html>
        """
    }
}
