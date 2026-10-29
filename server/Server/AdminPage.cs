// 관리자 페이지 화면. 데이터는 /_ahna/admin/api/* 에서 받아 그립니다.
static class AdminPage
{
    public static string Html(string nonce) => """
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>아나 관리</title>
<style>
:root{--bg:#eef1f5;--s:#fff;--t:#1b1b1b;--m:#5c5c5c;--a:#005fb8;--b:#e3e6ea;--ok:#0f7b0f;--warn:#b25e00;--bad:#c42b1c;--chip:#f3f5f8}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1c;--s:#272727;--t:#f0f0f0;--m:#c5c5c5;--a:#4cc2ff;--b:#3a3a3a;--ok:#6ccb5f;--warn:#fcb84b;--bad:#ff99a4;--chip:#323232}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--t);font-family:system-ui,'Malgun Gothic',sans-serif;word-break:keep-all}
main{max-width:980px;margin:0 auto;padding:28px 16px 60px}h1{font-size:26px;margin:0}h2{font-size:17px;margin:0 0 12px}
header{display:flex;align-items:center;gap:12px;margin-bottom:20px}header .sp{flex:1}
.card{background:var(--s);border:1px solid var(--b);border-radius:12px;padding:18px;margin-bottom:16px}
.muted{color:var(--m);font-size:14px}button{font:inherit;border:1px solid var(--b);background:var(--chip);color:var(--t);border-radius:8px;padding:7px 12px;cursor:pointer}
button.primary{background:var(--a);border-color:var(--a);color:#fff}@media(prefers-color-scheme:dark){button.primary{color:#000}}
button.danger{color:var(--bad)}button:disabled{opacity:.5;cursor:default}
input[type=password],input[type=number],input[type=text]{font:inherit;padding:8px 10px;border:1px solid var(--b);border-radius:8px;background:var(--s);color:var(--t)}
.row{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.dev{border-top:1px solid var(--b);padding:14px 0;display:grid;grid-template-columns:1fr auto;gap:8px 16px}.dev:first-of-type{border-top:0}
.name{font-weight:600;font-size:16px}.tag{display:inline-block;font-size:12px;padding:2px 8px;border-radius:99px;background:var(--chip);color:var(--m);margin-left:6px;vertical-align:2px}
.on{color:var(--ok)}.off{color:var(--m)}.blk{color:var(--bad)}.over{color:var(--warn);font-weight:600}
.use{display:flex;gap:16px;flex-wrap:wrap;font-size:14px;color:var(--m)}.use b{color:var(--t);font-weight:600}
.acts{display:flex;flex-wrap:wrap;gap:6px;justify-content:flex-end;align-content:start}
@media(max-width:640px){.dev{grid-template-columns:1fr}.acts{justify-content:flex-start}}
#login{max-width:360px;margin:12vh auto}#login input{width:100%;margin:12px 0}
#msg{min-height:20px;margin-top:8px}.err{color:var(--bad)}
</style></head><body><main>
<section id="login" class="card" hidden><h1>아나 관리</h1><p class="muted">서버 .env의 AHNA_ADMIN_PASSWORD 로 로그인합니다.</p>
<form id="loginForm"><input id="pw" type="password" autocomplete="current-password" placeholder="관리자 비밀번호" required><button class="primary" style="width:100%">로그인</button></form><div id="loginMsg" class="muted"></div></section>
<section id="app" hidden>
<header><h1>아나 관리</h1><span class="sp"></span><button id="refresh">새로고침</button><button id="logout">로그아웃</button></header>
<div class="card"><h2>하루 사용량 한도</h2>
<p class="muted">기기 하나가 하루에 서버를 거쳐 주고받는 양입니다(그 기기가 받는 쪽인 전송 + 근처 기기로 맡긴 파일). 한도를 넘으면 그 기기 앱에 알림이 갑니다. 날짜는 서버 시간 0시에 바뀝니다.</p>
<div class="row"><label>한도 <input id="limit" type="number" min="0" step="0.5" style="width:110px"> GB <span class="muted">(0 = 제한 없음)</span></label>
<label><input id="enforce" type="checkbox"> 한도를 넘으면 그날은 서버 전송 막기</label><button id="saveSettings" class="primary">저장</button></div></div>
<div class="card"><div class="row" style="margin-bottom:6px"><h2 style="margin:0">서버에 연결한 기기</h2><span class="sp" style="flex:1"></span><span id="count" class="muted"></span></div>
<p class="muted" style="margin-top:0">초기화하면 그 기기는 서버에서 끊기고, 앱에서 초대 코드를 다시 입력해야 합니다. 차단하면 초대 코드로도 다시 연결할 수 없습니다. 기기끼리의 등록(짝 맺기)은 각 기기에 저장되어 여기서는 보이지 않습니다.</p>
<div id="list"></div></div>
<div class="card"><h2>전체 초기화</h2><p class="muted">연결된 모든 기기를 서버에서 끊습니다. 모두 초대 코드를 다시 입력해야 합니다. 초대 코드 자체를 바꾸려면 .env의 AHNA_INVITE 를 바꾸고 컨테이너를 다시 시작하세요.</p>
<button id="resetAll" class="danger">모든 기기 초기화</button></div>
<div id="msg" class="muted"></div>
</section></main>
<script nonce="__NONCE__">
const $=s=>document.querySelector(s);
const api=async(path,body)=>{const r=await fetch('/_ahna/admin'+path,{method:body===undefined?'GET':'POST',headers:{'X-Ahna-Admin':'1','Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),credentials:'same-origin'});
  let j={};try{j=await r.json()}catch{}if(r.status===401&&path!=='/login'){show(false);throw new Error('로그인이 필요합니다.')}if(!r.ok)throw new Error(j.error||('오류 ('+r.status+')'));return j};
const size=b=>b>=1073741824?(b/1073741824).toFixed(b>=10737418240?0:1)+' GB':b>=1048576?(b/1048576).toFixed(0)+' MB':b>=1024?(b/1024).toFixed(0)+' KB':b+' B';
const ago=t=>{const s=(Date.now()-new Date(t))/1000;return s<90?'방금':s<3600?Math.round(s/60)+'분 전':s<86400?Math.round(s/3600)+'시간 전':Math.round(s/86400)+'일 전'};
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const say=(t,bad)=>{$('#msg').textContent=t;$('#msg').className=bad?'err':'muted'};
let state=null;
function show(on){$('#login').hidden=on;$('#app').hidden=!on}
async function load(){try{state=await api('/api/state');show(true);render()}catch(e){if($('#app').hidden)return;say(e.message,true)}}
function render(){
  $('#limit').value=state.limitGB;$('#enforce').checked=state.enforce;
  const limit=state.limitGB*1073741824;
  $('#count').textContent=state.devices.length+'대 · 온라인 '+state.devices.filter(d=>d.online).length+'대';
  $('#list').innerHTML=state.devices.length?state.devices.map(d=>{
    const st=d.blocked?'<span class="blk">● 차단됨</span>':d.online?'<span class="on">● 온라인</span>':'<span class="off">○ 오프라인 · '+ago(d.last)+'</span>';
    const over=limit>0&&d.today>=limit;
    return `<div class="dev"><div><div><span class="name">${esc(d.name||'이름 없음 (예전 버전)')}</span>${d.platform?'<span class="tag">'+esc(d.platform)+'</span>':''}</div>
    <div class="muted" style="margin:4px 0">${st} · IP ${esc(d.ip||'-')} · 처음 ${new Date(d.first).toLocaleDateString('ko-KR')}${d.resets?' · 초기화 '+d.resets+'회':''}</div>
    <div class="use"><span>오늘 <b class="${over?'over':''}">${size(d.today)}</b>${over?' <span class="over">한도 넘음</span>':''}</span><span>7일 <b>${size(d.week)}</b></span><span>30일 <b>${size(d.month)}</b></span></div></div>
    <div class="acts" data-id="${d.id}"><button data-a="notice" ${d.online&&!d.blocked?'':'disabled'}>알림 보내기</button><button data-a="reset">초기화</button>${d.blocked?'<button data-a="unblock">차단 해제</button>':'<button data-a="block" class="danger">차단</button>'}${d.online?'':'<button data-a="hide">목록에서 숨기기</button>'}</div></div>`}).join(''):'<p class="muted">아직 연결한 기기가 없습니다.</p>';
}
$('#list').addEventListener('click',async e=>{
  const b=e.target.closest('button[data-a]');if(!b)return;const id=b.parentElement.dataset.id,a=b.dataset.a;const d=state.devices.find(x=>x.id===id);const n=d.name||'이 기기';
  let body={};
  if(a==='notice'){const t=prompt(n+'에 보낼 알림 내용 (200자까지)');if(!t||!t.trim())return;body={text:t.trim().slice(0,200)}}
  if(a==='reset'&&!confirm(n+'을(를) 초기화할까요?\n서버에서 끊기고, 앱에서 초대 코드를 다시 입력해야 합니다.'))return;
  if(a==='block'&&!confirm(n+'을(를) 차단할까요?\n서버에서 끊기고 초대 코드로도 다시 연결할 수 없습니다.'))return;
  b.disabled=true;
  try{const r=await api('/api/device/'+id+'/'+a,body);say(a==='notice'?(r.delivered?'알림을 보냈습니다.':'기기가 알림을 받을 수 없습니다(오프라인이거나 예전 버전).'):'완료했습니다.',a==='notice'&&!r.delivered);await load()}catch(err){say(err.message,true);b.disabled=false}
});
$('#saveSettings').onclick=async()=>{try{await api('/api/settings',{limitGB:Number($('#limit').value)||0,enforce:$('#enforce').checked});say('저장했습니다.');await load()}catch(e){say(e.message,true)}};
$('#resetAll').onclick=async()=>{if(prompt('모든 기기를 초기화하려면 "초기화"라고 입력하세요.')!=='초기화')return;try{await api('/api/reset-all',{});say('모든 기기를 초기화했습니다.');await load()}catch(e){say(e.message,true)}};
$('#refresh').onclick=load;
$('#logout').onclick=async()=>{try{await api('/logout',{})}catch{}show(false)};
$('#loginForm').onsubmit=async e=>{e.preventDefault();$('#loginMsg').textContent='';try{await api('/login',{password:$('#pw').value});$('#pw').value='';await load()}catch(err){$('#loginMsg').textContent=err.message;$('#loginMsg').className='err'}};
(async()=>{try{state=await api('/api/state');show(true);render()}catch{show(false)}})();
setInterval(()=>{if(!$('#app').hidden&&document.visibilityState==='visible')load()},15000);
</script></body></html>
""".Replace("__NONCE__", nonce);
}
