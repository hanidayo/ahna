'use strict';
const $ = id => document.getElementById(id);
let state, currentUpload, busy = false, polling = false, lastInbox = new Set();
const size = n => n < 1024 ? `${n} B` : n < 1048576 ? `${(n/1024).toFixed(1)} KB` : n < 1073741824 ? `${(n/1048576).toFixed(1)} MB` : `${(n/1073741824).toFixed(2)} GiB`;
function message(text) { $('message').textContent = text; $('message').hidden = false; clearTimeout(message.timer); message.timer = setTimeout(() => $('message').hidden = true, 6500); }
async function api(path, data, headers = {}) {
  const r = await fetch(path, { method: data === undefined ? 'GET' : 'POST', credentials: 'same-origin', headers: { 'Content-Type':'application/json', ...headers }, body: data === undefined ? undefined : JSON.stringify(data) });
  if (!r.ok) { let e; try { e = await r.json(); } catch {} throw new Error(e?.error || (r.status === 429 ? '요청이 많습니다. 1분 뒤 다시 시도하세요.' : `요청 실패 (${r.status})`)); }
  return r.status === 204 || r.headers.get('content-length') === '0' ? null : r.text().then(t => t ? JSON.parse(t) : null);
}
function node(tag, text, className) { const el = document.createElement(tag); if (text !== undefined) el.textContent = text; if (className) el.className = className; return el; }
function render(s) {
  const first = !state; state = s;
  $('pair').hidden = true; $('workspace').hidden = false;
  $('deviceLabel').textContent = s.owner ? (s.platform || 'Windows') + ' · ' + s.name : s.name + ' · 연결됨';
  $('ownerPanel').hidden = !s.owner; $('windowsSend').hidden = !s.owner; $('browserSend').hidden = s.owner; $('settings').hidden = !s.owner;
  $('sendTitle').textContent = s.owner ? '연결한 기기로 보내기' : (s.hostName || '컴퓨터') + '로 보내기';
  $('inboxLabel').textContent = s.owner ? '발신 준비된 파일' : '도착한 파일';
  if (s.owner) {
    $('code').textContent = s.pin; $('urls').replaceChildren();
    for (const url of s.urls) { const a = node('a', url, 'url'); a.href = url; a.target = '_blank'; a.rel = 'noopener'; $('urls').append(a); }
    if (!s.urls.length) $('urls').append(node('p','사용 가능한 네트워크가 없습니다. Wi-Fi 연결을 확인하세요.','fine'));
    const selected = $('target').value; $('target').replaceChildren();
    for (const d of s.devices) { const op = node('option', d.name); op.value = d.id; $('target').append(op); }
    if (s.devices.some(d => d.id === selected)) $('target').value = selected;
    if (!s.devices.length) $('target').append(node('option','연결된 기기를 기다리는 중…'));
    $('pick').disabled = !s.devices.length; $('savePath').hidden = false; $('savePath').textContent = '수신 저장 경로 · ' + s.savePath;
  }
  renderClipboard(s);
  $('inbox').replaceChildren(); $('itemCount').textContent = s.items.length;
  for (const item of s.items) {
    const row = node('div',undefined,'fileRow'); row.append(node('span','↓','fileIcon'));
    const meta = node('div',undefined,'fileMeta'); meta.append(node('strong',item.name),node('small',size(item.bytes))); row.append(meta);
    const link = node('a','다운로드','download'); link.href = '/api/download/' + encodeURIComponent(item.id); link.download = item.name; row.append(link); $('inbox').append(row);
    if (!first && !lastInbox.has(item.id) && !s.owner) message('새 파일이 도착했습니다. 다운로드를 눌러 저장하세요.');
  }
  lastInbox = new Set(s.items.map(i => i.id));
  if (!s.items.length) $('inbox').append(node('div','아직 도착한 파일이 없습니다.','empty'));
  $('clearHistory').hidden = !s.owner;
  $('history').replaceChildren();
  for (const h of s.history.slice(0,20)) {
    const row = node('div',undefined,'fileRow'), meta = node('div',undefined,'fileMeta');
    meta.append(node('strong',(h.direction === 'receive' ? '↑ ' : '↓ ') + h.name),node('small',`${h.device} · ${size(h.bytes)} · ${h.status} · ${new Date(h.at).toLocaleString()}`)); row.append(meta); $('history').append(row);
  }
  if (!s.history.length) $('history').append(node('div','전송하면 여기에 기록됩니다.','empty'));
}
async function refresh() {
  if (polling) return; polling = true;
  try {
    const r = await fetch('/api/state', { credentials:'same-origin' });
    if (r.status === 401) { if (state) message('연결이 해제되었습니다. 연결 코드를 다시 입력하세요.'); state = null; $('pair').hidden = false; $('workspace').hidden = true; return; }
    if (!r.ok) throw new Error(); render(await r.json());
  } catch { if (state) $('deviceLabel').textContent = '연결 확인 중… Windows 앱과 Wi-Fi를 확인하세요.'; }
  finally { polling = false; }
}
$('pairForm').addEventListener('submit', async e => { e.preventDefault(); const button = e.target.querySelector('button'); button.disabled = true; try { await api('/api/pair', {name:$('deviceName').value,pin:$('pin').value}); $('pin').value=''; await refresh(); } catch(e) { message(e.message); } finally { button.disabled=false; } });
$('logout').onclick = async () => { try { await api('/api/logout', {}); state=null; $('pair').hidden=false; $('workspace').hidden=true; } catch(e) { message(e.message); } };
$('pick').onclick = async () => { $('pick').disabled=true; try { await api('/api/admin/pick', {target:$('target').value}); await refresh(); } catch(e) { message(e.message); } finally { $('pick').disabled=!state?.devices?.length; } };
$('settings').onclick = () => api('/api/admin/settings', {}).catch(e => message(e.message));
$('revoke').onclick = async () => { if (confirm('연결된 기기를 모두 해제하고 코드를 변경할까요?')) { try { await api('/api/admin/revoke', {}); await refresh(); } catch(e) { message(e.message); } } };
function batchId() { const b = crypto.getRandomValues(new Uint8Array(16)); b[6] = (b[6]&15)|64; b[8] = (b[8]&63)|128; const h = [...b].map(v=>v.toString(16).padStart(2,'0')).join(''); return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`; }
async function upload(files) {
  if (busy || !files.length) return;
  if (!state) { message('먼저 연결 코드를 입력해 주세요.'); return; }
  if (files.some(f => f.size > state.maxFile)) { message('파일 한 개는 최대 4 GiB까지 지원합니다.'); return; }
  busy=true; $('cancel').hidden=false; $('progressBox').hidden=false; $('files').disabled=$('folder').disabled=true;
  const batch=batchId(); let completed=0;
  try {
    for (const file of files) {
      $('progressName').textContent=`${completed+1}/${files.length} · ${file.webkitRelativePath || file.name}`;
      $('progress').value=0; $('progressPercent').textContent='0%';
      await new Promise((resolve,reject)=>{
        const xhr=new XMLHttpRequest(); currentUpload=xhr;
        xhr.open('POST','/api/upload?batch='+batch+'&path='+encodeURIComponent(file.webkitRelativePath || file.name));
        xhr.setRequestHeader('Content-Type','application/octet-stream');
        xhr.upload.onprogress=e=>{ if(e.lengthComputable) { const pct=Math.round(e.loaded/e.total*100); $('progress').value=pct; $('progressPercent').textContent=pct+'%'; } };
        xhr.onload=()=>{ if(xhr.status>=200&&xhr.status<300) resolve(); else { let error; try { error=JSON.parse(xhr.responseText).error; } catch{} reject(new Error(error || `전송 실패 (${xhr.status})`)); } };
        xhr.onerror=()=>reject(new Error('연결이 끊겼습니다. Wi-Fi와 Windows 앱을 확인하세요.'));
        xhr.onabort=()=>reject(new Error('전송을 중단했습니다. 완료된 파일은 유지됩니다.'));
        xhr.send(file);
      });
      completed++;
    }
    message(`${completed}개 파일을 Windows에 저장했습니다.`);
  } catch(e) { message(`${e.message} (${completed}/${files.length}개 완료)`); }
  finally { busy=false; currentUpload=null; $('cancel').hidden=true; $('files').disabled=$('folder').disabled=false; $('files').value=$('folder').value=''; await refresh(); }
}
$('cancel').onclick=()=>currentUpload?.abort();
$('files').onchange=e=>upload([...e.target.files]); $('folder').onchange=e=>upload([...e.target.files]);
$('drop').ondragover=e=>{e.preventDefault();$('drop').classList.add('over');};
$('drop').ondragleave=()=>$('drop').classList.remove('over');
$('drop').ondrop=e=>{ e.preventDefault();$('drop').classList.remove('over'); if ([...e.dataTransfer.items].some(i=>i.webkitGetAsEntry?.()?.isDirectory)) {message('폴더는 아래 ‘폴더 선택’ 버튼을 사용해 주세요.');return;} upload([...e.dataTransfer.files]); };
window.addEventListener('beforeunload', e=>{if(busy){e.preventDefault();e.returnValue='';}});
(async()=>{
  const owner=new URLSearchParams(location.hash.slice(1)).get('owner');
  if(owner){ history.replaceState(null,'',location.pathname); try{await api('/api/owner',{}, {'X-Ahna-Owner':owner});}catch(e){message('Windows 트레이에서 Ahna를 다시 열어 주세요.');} }
  const ua=navigator.userAgent; $('deviceName').value=/iPhone/.test(ua)?'나의 iPhone':/iPad/.test(ua)?'나의 iPad':/Macintosh/.test(ua)?'나의 Mac':'내 브라우저';
  await refresh(); setInterval(refresh,3000); document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
})();

let receivedClipboardText = '';
function renderClipboard(s) {
  $('clipboardPanel').hidden = !Array.isArray(s.clipboard);
  if (!Array.isArray(s.clipboard)) return;
  $('nativeClipboard').hidden = !s.owner;
  $('sendClipboard').textContent = s.owner ? '위에서 선택한 기기로 글자 보내기' : (s.hostName || '컴퓨터') + '로 글자 보내기';
  $('sendClipboard').disabled = s.owner && !s.devices.length;
  $('clipboardInbox').replaceChildren();
  for (const item of s.clipboard) {
    const row = node('div', undefined, 'fileRow'), meta = node('div', undefined, 'fileMeta');
    meta.append(node('strong', item.sender), node('small', size(item.bytes) + ' · ' + new Date(item.created).toLocaleString()));
    const view = node('button', '보기', 'quiet');
    view.onclick = async () => {
      $('receivedClipboard').value = '불러오는 중…'; $('copyClipboard').disabled = true; receivedClipboardText = '';
      if (!$('clipboardDialog').open) $('clipboardDialog').showModal();
      try {
        const r = await fetch('/api/download/' + encodeURIComponent(item.id) + '?kind=clipboard', { credentials:'same-origin' });
        if (!r.ok) throw new Error('글자를 불러오지 못했습니다. 보관 기간과 연결을 확인하세요.');
        const data = await r.arrayBuffer();
        if (data.byteLength > 65536) throw new Error('받은 글자가 너무 큽니다.');
        receivedClipboardText = new TextDecoder('utf-8', {fatal:true}).decode(data);
        $('receivedClipboard').value = receivedClipboardText; $('copyClipboard').disabled = false;
      } catch(e) { $('receivedClipboard').value = e.message; }
    };
    row.append(meta, view); $('clipboardInbox').append(row);
  }
  if (!s.clipboard.length) $('clipboardInbox').append(node('div', '아직 받은 글자가 없습니다.', 'empty'));
}
$('nativeClipboard').onclick = () => api('/api/admin/clipboard/open', {}).catch(e => message(e.message));
$('pasteClipboard').onclick = async () => {
  try {
    if (!navigator.clipboard?.readText) throw new Error();
    $('clipboardDraft').value = await navigator.clipboard.readText();
  } catch { $('clipboardDraft').focus(); message('입력칸을 길게 누르거나 Ctrl+V로 붙여넣어 주세요.'); }
};
$('sendClipboard').onclick = async () => {
  const text = $('clipboardDraft').value;
  if (!text.length) { message('보낼 글자를 먼저 붙여넣어 주세요.'); return; }
  if (new TextEncoder().encode(text).byteLength > 65536) { message('최대 64 KB까지 보낼 수 있습니다. 긴 글은 파일로 보내세요.'); return; }
  $('sendClipboard').disabled = true;
  try {
    if (state.owner) await api('/api/admin/clipboard', {target:$('target').value, text});
    else {
      const r = await fetch('/api/upload?kind=clipboard&batch=' + batchId(), { method:'POST', credentials:'same-origin', headers:{'Content-Type':'text/plain; charset=utf-8'}, body:text });
      if (!r.ok) throw new Error('글자 전송 실패 (' + r.status + '). 컴퓨터 앱을 업데이트하고 연결을 확인하세요.');
    }
    message('글자를 보냈습니다. 받은 쪽에서 확인하고 복사하세요.');
  } catch(e) { message(e.message); }
  finally { $('sendClipboard').disabled = false; await refresh(); }
};
$('copyClipboard').onclick = async () => {
  try {
    if (!navigator.clipboard?.writeText) throw new Error();
    await navigator.clipboard.writeText(receivedClipboardText);
    message('복사했습니다. 원하는 앱에 붙여넣으세요.');
  } catch {
    $('receivedClipboard').focus(); $('receivedClipboard').select();
    if (document.execCommand('copy')) message('복사했습니다. 원하는 앱에 붙여넣으세요.');
    else message('글자를 선택했습니다. 길게 눌러 복사하거나 Ctrl+C를 누르세요.');
  }
};
$('closeClipboard').onclick = () => { $('clipboardDialog').close(); receivedClipboardText = ''; $('receivedClipboard').value = ''; };

$("clearHistory").onclick=async()=>{try{await api("/api/admin/history/clear",{});location.reload();}catch(e){message(e.message);}};
