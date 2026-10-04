/// Pagina del telecomando per il telefono: un solo file, nessuna libreria, nessuna richiesta esterna (funziona senza internet).
let remoteHTML = #"""
<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#1c1c1e"><meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-capable" content="yes"><title>Dolly Projector</title>
<style>
:root{--bg:#1c1c1e;--card:#262628;--card2:#2f2f32;--line:rgba(255,255,255,.09);--tx:#f5f5f7;--mut:#a1a1a6;--acc:#0a84ff;--cue:#e0392e}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}html,body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
body{padding:max(14px,env(safe-area-inset-top)) 14px max(24px,env(safe-area-inset-bottom));max-width:520px;margin:0 auto}
h1{font-size:1.05rem;margin:0;display:flex;align-items:center;gap:8px}.dot{width:9px;height:9px;border-radius:50%;background:#30d158}.dot.off{background:var(--cue)}
header{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px;margin-bottom:12px}
.mut{color:var(--mut);font-size:.85rem}.now b{display:block;font-size:1.15rem;margin:2px 0 8px;overflow-wrap:anywhere}.badge{display:inline-block;font-size:.72rem;font-weight:700;padding:3px 9px;border-radius:999px;background:var(--card2);color:var(--mut)}.badge.live{background:rgba(224,57,46,.18);color:#ff6b5e}
.pv{width:100%;aspect-ratio:16/9;background:#000;border-radius:10px;display:block;object-fit:contain;margin:10px 0}.pv.hide{display:none}
.bar{display:flex;align-items:center;gap:10px;font:600 .8rem ui-monospace,Menlo,monospace;color:var(--mut)}input[type=range]{flex:1;accent-color:var(--acc);height:28px}
.ctl{display:flex;justify-content:center;align-items:center;gap:16px;margin:10px 0 4px}button{font:inherit;color:var(--tx);border:0;background:var(--card2);border-radius:999px;cursor:pointer}
.round{width:56px;height:56px;font-size:1.3rem}.big{width:78px;height:78px;background:var(--acc);font-size:1.8rem}.btn{padding:11px 18px;font-weight:600}.btn.on{background:var(--acc)}
.row{display:flex;gap:10px;align-items:center}.row>*{flex:0 0 auto}.row input[type=range]{flex:1}
.gap{border-color:rgba(224,57,46,.5);text-align:center}.gap .t{font:700 2rem ui-monospace,Menlo,monospace;margin:4px 0 10px}.gap .row{justify-content:center}
ul{list-style:none;margin:0;padding:0}li{display:flex;align-items:center;gap:10px;padding:12px 10px;border-radius:12px;cursor:pointer}li+li{margin-top:2px}li.on{background:rgba(224,57,46,.14)}li.bad{opacity:.45}li small{color:var(--mut);display:block}li .n{flex:1;min-width:0;overflow-wrap:anywhere}
.login{margin-top:20vh;text-align:center}.login input{font:700 2rem ui-monospace,Menlo,monospace;text-align:center;letter-spacing:.4em;width:9em;padding:12px;border-radius:14px;border:1px solid var(--line);background:var(--card);color:var(--tx);margin:16px 0}.err{color:#ff6b5e;min-height:1.4em}
[hidden]{display:none!important}
</style></head><body>
<div id="login" class="login" hidden><h1 style="justify-content:center">Dolly Projector</h1><p class="mut">Inserisci il PIN mostrato sul Mac</p>
<input id="pin" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="one-time-code" aria-label="PIN"><div><button class="btn on" id="go">Entra</button></div><p class="err" id="err"></p></div>
<div id="app" hidden>
<header><h1><span class="dot" id="dot"></span>Dolly Projector</h1><span class="mut" id="sname"></span></header>
<div class="card now"><span class="badge" id="badge">—</span><b id="title">Nessun film</b><img class="pv hide" id="pv" alt="">
<div class="bar"><span id="tc">0:00</span><input type="range" id="seek" min="0" max="1000" value="0"><span id="td">0:00</span></div>
<div class="ctl"><button class="round" id="prev" aria-label="Precedente">⏮</button><button class="round big" id="toggle" aria-label="Play/Pausa">▶</button><button class="round" id="next" aria-label="Successivo">⏭</button></div>
<div class="ctl" style="margin-top:6px"><button class="btn" id="stop">Stop</button><button class="btn" id="loop">Ripeti film</button></div></div>
<div class="card gap" id="gapcard" hidden><div class="mut" id="gaplab"></div><div class="t" id="gapt">0:00</div><div class="row"><button class="btn" id="skip">Salta</button><button class="btn" id="more">+1 min</button></div></div>
<div class="card"><div class="row"><span>🔈</span><input type="range" id="vol" min="0" max="130" value="100"><button class="btn" id="mute">Muto</button></div></div>
<div class="card"><div class="mut" style="margin-bottom:6px">Scena</div><ul id="list"></ul></div></div>
<script>
(function(){'use strict';
var $=function(i){return document.getElementById(i)},tok=null,st=null,seeking=false,volDrag=false,busy=false,pvT=0,KEY='dolly-remote-token';
try{tok=localStorage.getItem(KEY)}catch(e){}
function fmt(s){s=Math.max(0,Math.round(s||0));var h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return(h?h+':'+(m<10?'0':''):'')+m+':'+(x<10?'0':'')+x}
function api(path,body){return fetch(path,{method:body?'POST':'GET',headers:{'X-Token':tok||'','Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'}).then(function(r){if(r.status===401){logout();throw 0}return r})}
function cmd(o){return api('/api/cmd',o).then(function(){setTimeout(poll,120)}).catch(function(){})}
function logout(){tok=null;try{localStorage.removeItem(KEY)}catch(e){}show(false)}
function show(on){$('login').hidden=on;$('app').hidden=!on;if(!on)$('pin').focus()}
$('go').onclick=function(){var p=$('pin').value;$('err').textContent='';fetch('/api/login',{method:'POST',body:JSON.stringify({pin:p})}).then(function(r){return r.json().then(function(j){return[r.status,j]})}).then(function(a){
 if(a[0]===200&&a[1].token){tok=a[1].token;try{localStorage.setItem(KEY,tok)}catch(e){}show(true);poll()}else $('err').textContent=a[0]===429?'Troppi tentativi, aspetta un minuto.':'PIN errato.'}).catch(function(){$('err').textContent='Il Mac non risponde.'})};
$('pin').onkeydown=function(e){if(e.key==='Enter')$('go').onclick()};
$('toggle').onclick=function(){cmd({a:'toggle'})};$('prev').onclick=function(){cmd({a:'prev'})};$('next').onclick=function(){cmd({a:'next'})};$('stop').onclick=function(){cmd({a:'stop'})};
$('skip').onclick=function(){cmd({a:'skipgap'})};$('more').onclick=function(){cmd({a:'extend',v:60})};
$('mute').onclick=function(){cmd({a:'set',p:'mute',v:!(st&&st.props&&st.props.mute===true)})};
$('loop').onclick=function(){if(!st||st.idx<0)return;var it=st.items[st.idx];cmd({a:'setitem',i:st.idx,loop:(it&&it.loop!==0)?0:-1})};
$('seek').oninput=function(){seeking=true;$('tc').textContent=fmt(this.value/1000*(st&&st.dur||0))};
$('seek').onchange=function(){var d=st&&st.dur||0;cmd({a:'seek',v:this.value/1000*d,m:'absolute'});setTimeout(function(){seeking=false},400)};
$('vol').oninput=function(){volDrag=true;cmd({a:'set',p:'volume',v:+this.value})};$('vol').onchange=function(){setTimeout(function(){volDrag=false},400)};
function render(s){st=s;var m=s.mode,it=s.items&&s.items[s.idx];
 $('sname').textContent=s.name||'';$('dot').className='dot'+(s.ok?'':' off');
 $('badge').textContent=m==='playing'?(s.pause?'IN PAUSA':'IN ONDA'):m==='gap'?'NERO':m==='wait'?'INTERVALLO':'FERMO';$('badge').className='badge'+(m==='playing'&&!s.pause?' live':'');
 $('title').textContent=(m==='idle'||!it)?(s.items&&s.items[s.sel]?'Pronto: '+s.items[s.sel].name:'Nessun film'):(it.name||it.text||'');
 $('toggle').textContent=(m==='playing'&&!s.pause)?'⏸':'▶';
 if(!seeking){$('tc').textContent=fmt(s.time);$('td').textContent=fmt(s.dur);$('seek').value=s.dur>0?Math.round(s.time/s.dur*1000):0}
 $('seek').disabled=m!=='playing';
 var g=m==='gap'||m==='wait';$('gapcard').hidden=!g;if(g){$('gaplab').textContent=s.label||(m==='wait'?'Intervallo':'Nero');$('gapt').textContent=fmt(s.left);$('more').hidden=m!=='wait'}
 if(!volDrag&&s.props&&typeof s.props.volume==='number')$('vol').value=s.props.volume;$('mute').className='btn'+(s.props&&s.props.mute===true?' on':'');
 $('loop').className='btn'+(it&&it.loop!==0?' on':'');$('loop').hidden=!(m==='playing'&&it&&it.kind==='film');
 var ul=$('list'),html='';(s.items||[]).forEach(function(x,i){var t=x.kind==='film'?x.name:x.kind==='nero'?'Nero · '+x.secs+' s':(x.text||'Intervallo')+' · '+fmt(x.secs);
  html+='<li data-i="'+i+'" class="'+((m==='playing'||m==='gap'||m==='wait')&&i===s.idx?'on':'')+(x.ok?'':' bad')+'"><span class="n">'+t.replace(/[<>&]/g,'')+'</span>'+(x.loop!==0&&x.kind==='film'?'<small>ripeti</small>':'')+'</li>'});
 if(ul.dataset.h!==html){ul.innerHTML=html;ul.dataset.h=html}
 if(m==='playing'&&Date.now()-pvT>1200){pvT=Date.now();api('/api/preview').then(function(r){if(r.status!==200)throw 0;return r.blob()}).then(function(b){var im=$('pv');im.src=URL.createObjectURL(b);im.classList.remove('hide')}).catch(function(){})}
 if(m!=='playing')$('pv').classList.add('hide')}
$('list').onclick=function(e){var li=e.target.closest('li');if(!li)return;cmd({a:'play',i:+li.dataset.i})};
function poll(){if(!tok||busy)return;busy=true;api('/api/state').then(function(r){return r.json()}).then(function(s){busy=false;$('dot').className='dot';render(s)}).catch(function(){busy=false;$('dot').className='dot off'})}
if(tok){show(true);poll()}else show(false);setInterval(poll,700);
})();
</script></body></html>
"""#
