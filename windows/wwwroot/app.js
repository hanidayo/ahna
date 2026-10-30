'use strict';
const $ = id => document.getElementById(id);
let state, currentUpload, busy = false, polling = false, lastInbox = new Set(), selectedTarget = '', openOptionsWhenReady = false, lastOutboundResult = null;
const size = n => n < 1024 ? `${n} B` : n < 1048576 ? `${(n/1024).toFixed(1)} KB` : n < 1073741824 ? `${(n/1048576).toFixed(1)} MB` : `${(n/1073741824).toFixed(2)} GiB`;
function message(text) { $('message').textContent = text; $('message').hidden = false; clearTimeout(message.timer); message.timer = setTimeout(() => $('message').hidden = true, 6500); }
async function api(path, data, headers = {}) {
  const r = await fetch(path, { method: data === undefined ? 'GET' : 'POST', credentials: 'same-origin', headers: { 'Content-Type':'application/json', ...headers }, body: data === undefined ? undefined : JSON.stringify(data) });
  if (!r.ok) { let e; try { e = await r.json(); } catch {} throw new Error(e?.error || (r.status === 429 ? '요청이 많습니다. 1분 뒤 다시 시도하세요.' : `요청 실패 (${r.status})`)); }
  return r.status === 204 || r.headers.get('content-length') === '0' ? null : r.text().then(t => t ? JSON.parse(t) : null);
}
function node(tag, text, className) { const el = document.createElement(tag); if (text !== undefined) el.textContent = text; if (className) el.className = className; return el; }
const SVG = 'http://www.w3.org/2000/svg';
function icon(paths, sizePx = 16) {
  const svg = document.createElementNS(SVG, 'svg');
  for (const [k, v] of Object.entries({ width: sizePx, height: sizePx, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.8', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) svg.setAttribute(k, v);
  for (const d of paths) { const p = document.createElementNS(SVG, 'path'); p.setAttribute('d', d); svg.append(p); }
  return svg;
}
const FILE_ICON = ['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z', 'M14 2v6h6'];
const UP_ICON = ['M12 19V5', 'M5 12l7-7 7 7'];
const DOWN_ICON = ['M12 5v14', 'M19 12l-7 7-7-7'];
function fileIcon(paths = FILE_ICON, muted = false) { const s = node('span', undefined, 'fileIcon' + (muted ? ' muted' : '')); s.append(icon(paths)); return s; }
// 2026. 10. 30. 오후 12:51
const stamp = value => new Date(value).toLocaleString('ko-KR', { year:'numeric', month:'numeric', day:'numeric', hour:'numeric', minute:'2-digit' });
function ago(value) {
  const t = new Date(value), diff = (Date.now() - t.getTime()) / 1000;
  if (!isFinite(diff)) return '';
  if (diff < 60) return '방금';
  if (diff < 3600) return `${Math.floor(diff/60)}분 전`;
  if (diff < 86400) return `${Math.floor(diff/3600)}시간 전`;
  return t.toLocaleString();
}
function formatCode(pin) { return pin && pin.length === 6 ? pin.slice(0,3) + ' ' + pin.slice(3) : (pin || ''); }
function setVersion(version) {
  if (!version) return;
  $('versionChip').textContent = 'v' + version; $('versionChip').hidden = false;
  $('footVersion').textContent = '아나 v' + version;
  $('optVersion').textContent = '아나 v' + version;
}
function setStatus(online, text) { document.querySelector('.status').classList.toggle('online', online); $('deviceLabel').textContent = text; }
function nasShort(status) {
  if (!status) return '서버 연결 꺼짐';
  if (status.startsWith('서버 연결됨')) return '서버 연결됨';
  if (status.startsWith('서버에 연결 중')) return '서버 연결 중…';
  if (status.startsWith('서버 재연결')) return '서버 재연결 대기';
  return status.split(' · ')[0];
}
const nasOnline = status => !!status && status.startsWith('서버 연결됨');

function render(s) {
  const first = !state; state = s;
  document.body.classList.add('paired'); document.body.classList.remove('offline');
  $('pair').hidden = true; $('workspace').hidden = false;
  setVersion(s.version);
  const host = s.hostName || '컴퓨터';
  if (s.owner) setStatus(nasOnline(s.remoteStatus), nasShort(s.remoteStatus) + ' · ' + (s.hostName || s.name));
  else setStatus(true, '연결됨 · ' + host);
  $('ownerPanel').hidden = !s.owner; $('windowsSend').hidden = !s.owner; $('browserSend').hidden = s.owner; $('settings').hidden = !s.owner;
  $('receivedPanel').hidden = !s.owner;
  $('sendTitle').textContent = s.owner ? '보내기' : host + '로 보내기';
  $('inboxLabel').textContent = s.owner ? '보낼 준비가 된 파일' : '도착한 파일';
  $('inboxNote').textContent = s.owner ? '상대 기기에서 아나를 열면 이 파일을 받습니다. 24시간 또는 아나를 종료할 때까지 보관합니다.' : '다운로드를 눌러 저장하세요. 폴더는 ZIP으로 받습니다. 파일은 24시간 또는 컴퓨터의 아나를 종료할 때까지 받을 수 있습니다.';
  if (s.owner) {
    $('code').textContent = formatCode(s.pin); $('code').setAttribute('aria-label', '연결 코드 ' + (s.pin || '').split('').join(' '));
    $('urls').replaceChildren();
    for (const url of s.urls) { const a = node('a', url, 'url'); a.href = url; a.target = '_blank'; a.rel = 'noopener'; $('urls').append(a); }
    if (!s.urls.length) $('urls').append(node('p','서버 주소가 설정되지 않았습니다. 옵션에서 서버를 설정하세요.','fine'));
    renderTargets(allTargets(s));
    refreshNearby();
    renderReceived(s);
    renderOutbound(s.outbound);
    if (isOpen()) renderLinked(s);
    if (openOptionsWhenReady) { openOptionsWhenReady = false; openOptions(); }
    if (!joinChecked) { joinChecked = true; api('/api/admin/options').then(o => { if (o.ahna && !o.remoteKeySaved && !isOpen()) { openOptions().then(() => $('optNasKey').focus()); } }).catch(() => {}); }
  }
  renderClipboard(s);
  $('inbox').replaceChildren(); $('itemCount').textContent = s.items.length;
  $('inboxPanel').hidden = s.owner && !s.items.length;
  for (const item of s.items) {
    const row = node('div',undefined,'fileRow'); row.append(fileIcon(s.owner ? UP_ICON : FILE_ICON));
    const target = s.owner ? (s.peers || s.devices).find(d => d.id === item.target)?.name : null;
    const meta = node('div',undefined,'fileMeta'); meta.append(node('strong',item.name),node('small',(target ? target + ' · ' : '') + size(item.bytes))); row.append(meta);
    const link = node('a','다운로드','download'); link.href = '/api/download/' + encodeURIComponent(item.id); link.download = item.name; row.append(link); $('inbox').append(row);
    if (!first && !lastInbox.has(item.id) && !s.owner) message('새 파일이 도착했습니다. 다운로드를 눌러 저장하세요.');
  }
  lastInbox = new Set(s.items.map(i => i.id));
  if (!s.items.length) $('inbox').append(node('div','아직 도착한 파일이 없습니다.','empty'));
  $('clearHistory').hidden = !s.owner;
  $('history').replaceChildren();
  for (const h of s.history.slice(0,20)) {
    const row = node('div',undefined,'fileRow'), meta = node('div',undefined,'fileMeta');
    const incoming = h.direction === 'receive';
    row.append(fileIcon(incoming ? DOWN_ICON : UP_ICON, true));
    // 보냄 · 기기 · 글자 미리보기(또는 크기) / 시각
    const failed = /실패|중단/.test(h.status || '');
    meta.append(node('strong',h.name),node('small',`${incoming ? '받음' : '보냄'} · ${h.device} · ${h.preview ?? size(h.bytes)}${failed ? ' · ' + h.status : ''}`,'oneLine'),node('small',stamp(h.at))); row.append(meta); $('history').append(row);
  }
  if (!s.history.length) $('history').append(node('div','전송하면 여기에 기록됩니다.','empty'));
}
// 기기마다 한 줄: 옵션에서 이 컴퓨터가 추가한 기기(outbound) + 이 컴퓨터에 연결한 기기(peers).
// 같은 기기는 상대가 알려 준 수신 ID(computerID)로, 예전 앱이라 ID가 없으면 이름으로 합칩니다.
// 둘 다 있으면 추가한 연결로 보내고, 그쪽이 오프라인인데 상대가 이 컴퓨터에서 받는 중이면 이 컴퓨터의 대기열로 보냅니다.
function mergedDevices(s) {
  if (!s?.owner) return [];
  const trim = v => String(v || '').trim(), low = v => String(v || '').toLowerCase();
  const peers = Array.isArray(s.peers) ? s.peers : (s.devices || []).map(d => ({ id: d.id, name: d.name, computerID: d.computerID || '', online: true }));
  const same = (p, cid, name) => p.computerID ? !!cid && low(p.computerID) === low(cid) : trim(p.name) === trim(name);
  const claimed = new Set(), list = [];
  for (const o of s.outbound?.devices || []) {
    const inbound = peers.filter(p => same(p, o.computerID, o.name));
    inbound.forEach(p => claimed.add(p.id));
    const live = inbound.find(p => p.online), viaInbound = !o.online && !!live;
    const online = !!o.online || !!live;
    // 기기 이름과 상태만 보여 주고, 오프라인일 때만 이유 한 줄(연결됨 표시와 오류 문구가 함께 나오지 않게).
    list.push({ id: o.id, sendId: viaInbound ? live.id : o.id, name: o.name, online, outbound: !viaInbound,
      outboundId: o.id, inboundIds: inbound.map(p => p.id), detail: online ? '' : (o.error || '') });
  }
  const groups = [];
  const rest = peers.filter(p => !claimed.has(p.id));
  for (const p of rest.filter(p => p.computerID)) {
    let g = groups.find(g => g.cid === low(p.computerID));
    if (!g) groups.push(g = { cid: low(p.computerID), name: p.name, members: [] });
    g.members.push(p);
  }
  for (const p of rest.filter(p => !p.computerID)) {
    let g = groups.find(g => trim(g.name) === trim(p.name));
    if (!g) groups.push(g = { cid: '', name: p.name, members: [] });
    g.members.push(p);
  }
  for (const g of groups) {
    const live = g.members.find(p => p.online), ids = g.members.map(p => p.id).sort();
    list.push({ id: 'in:' + ids[0], sendId: (live || g.members[0]).id, name: (live || g.members[0]).name, online: !!live, outbound: false,
      outboundId: null, inboundIds: ids, detail: '' });
  }
  return list;
}
// 보낼 기기: 추가한 기기는 늘 보이고, 추가하지 않고 이 컴퓨터에만 연결한 기기는 지금 받을 수 있을 때만 보입니다.
function allTargets(s) { return mergedDevices(s).filter(d => d.outboundId || d.online); }
const findTarget = id => allTargets(state).find(t => t.id === id) || nearbyTargets().find(t => t.id === id);
function renderTargets(list) {
  if (!list.some(d => d.id === selectedTarget) && !nearbyTargets().some(d => d.id === selectedTarget)) selectedTarget = (list.find(d => d.online) || list[0])?.id || '';
  const box = $('targets'), focused = document.activeElement?.closest?.('#targets') ? document.activeElement.dataset.id : null;
  box.replaceChildren();
  for (const d of list) {
    const chip = node('button', undefined, 'chip' + (d.online ? '' : ' offline')); chip.type = 'button'; chip.dataset.id = d.id;
    chip.setAttribute('role', 'radio'); chip.setAttribute('aria-checked', String(d.id === selectedTarget)); chip.tabIndex = d.id === selectedTarget ? 0 : -1;
    chip.append(node('span', d.name), Object.assign(node('i', undefined, 'dot' + (d.online ? ' online' : '')), { title: d.online ? '연결됨' : '오프라인' }));
    chip.setAttribute('aria-label', d.name + (d.online ? ' · 연결됨' : ' · 오프라인'));
    chip.onclick = () => { selectedTarget = d.id; renderTargets(allTargets(state)); renderNearby(); box.querySelector(`[data-id="${CSS.escape(d.id)}"]`)?.focus(); updateClipboardButton(); };
    box.append(chip);
    if (focused === d.id) chip.focus();
  }
  if (!list.length) box.append(node('span','연결된 기기를 기다리는 중… 다른 기기에서 아나를 열어 두거나 옵션에서 기기를 추가하세요.','chipsEmpty'));
  updatePick();
}
// [보낼 파일이나 폴더를 선택하세요]: 고른 기기가 있을 때만. 추가한 기기로 보내는 중이거나 근처 기기로 보내는 중이면 잠급니다.
function updatePick() {
  const target = findTarget(selectedTarget);
  $('pick').disabled = busy || !target || (target.nearby ? nearbyActive() : !!state?.outbound?.sending);
}
$('targets').addEventListener('keydown', e => {
  const list = allTargets(state);
  if (!list.length || !['ArrowRight','ArrowLeft','ArrowDown','ArrowUp'].includes(e.key)) return;
  e.preventDefault();
  const i = Math.max(0, list.findIndex(d => d.id === selectedTarget));
  selectedTarget = list[(i + (e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length].id;
  renderTargets(list); renderNearby(); $('targets').querySelector('[aria-checked="true"]')?.focus(); updateClipboardButton();
});
// 옵션에서 추가한 기기로 보내는 중인 파일: 진행률과 결과 알림
function renderOutbound(o) {
  const sending = o?.sending;
  if (!busy) {
    $('progressBox').hidden = !sending; $('outCancelRow').hidden = !sending;
    if (sending) {
      const pct = sending.total > 0 ? Math.round(sending.sent / sending.total * 100) : 0;
      $('progressName').textContent = `${sending.index}/${sending.count} · ${sending.name} → ${sending.deviceName}`;
      $('progress').value = pct; $('progressPercent').textContent = pct + '%';
    }
  }
  const result = o?.result;
  if (lastOutboundResult === null) lastOutboundResult = result?.id ?? 0;
  else if (result && result.id !== lastOutboundResult) { lastOutboundResult = result.id; message(result.text); }
}
function renderLinked(s) {
  const box = $('optDevices'); box.replaceChildren();
  const o = s?.outbound, list = mergedDevices(s);
  for (const d of list) {
    const row = node('div', undefined, 'linkedRow');
    const name = node('span', d.name, 'linkedName' + (d.online ? '' : ' offline'));
    if (d.detail) name.append(node('small', d.detail));
    const stateEl = node('span', undefined, 'pillState' + (d.online ? ' online' : '')); stateEl.append(node('i'), node('span', d.online ? '연결됨' : '오프라인'));
    const remove = node('button', undefined, 'removeBtn'); remove.type = 'button'; remove.setAttribute('aria-label', d.name + ' 연결 삭제'); remove.title = '연결 삭제';
    const x = node('span'); x.append(Object.assign(icon(['M18 6 6 18','M6 6l12 12'], 9), {})); x.firstChild.setAttribute('stroke-width', '4'); remove.append(x);
    remove.onclick = async () => {
      if (!confirm(`${d.name} 연결을 삭제할까요?\n다시 연결하려면 상대 기기의 연결 코드가 필요합니다.`)) return;
      remove.disabled = true;
      // 이 컴퓨터가 추가한 연결과, 그 기기가 이 컴퓨터에 연결한 세션을 함께 지웁니다.
      try {
        if (d.outboundId) await api('/api/admin/devices/' + encodeURIComponent(d.outboundId) + '/remove', {});
        for (const id of d.inboundIds) await api('/api/admin/sessions/' + encodeURIComponent(id) + '/forget', {});
        message(d.name + ' 연결을 삭제했습니다.'); await refresh();
      }
      catch(e) { optionsError(e.message); remove.disabled = false; }
    };
    row.append(name, stateEl, remove); box.append(row);
  }
  if (!list.length) box.append(node('div', o?.loadError || '아직 추가한 기기가 없습니다.', 'linkedEmpty'));
  else if (o?.loadError) box.append(node('p', o.loadError, 'fine'));
}
function renderReceived(s) {
  const received = s.history.filter(h => h.direction === 'receive' && h.name !== '클립보드 텍스트' && h.status === '저장 완료');
  $('received').replaceChildren(); $('receivedCount').textContent = received.length;
  for (const h of received) {
    const row = node('div', undefined, 'fileRow'), meta = node('div', undefined, 'fileMeta');
    row.append(fileIcon());
    meta.append(node('strong', h.name), node('small', `${h.device} · ${ago(h.at)} · ${size(h.bytes)}`)); row.append(meta);
    $('received').append(row);
  }
  if (!received.length) $('received').append(node('div', '아직 도착한 파일이 없습니다.', 'empty'));
  $('savePath').textContent = '받은 파일은 ' + s.savePath + '에 저장됩니다.';
  renderNotices(s.owner ? (s.announcements || []) : []);
}
// 서버 관리자 공지: 읽지 않은 공지는 이 창에서 한 번 저절로 열고, 상단 [공지]로 언제든 다시 볼 수 있습니다.
let notices = [];
function shownNotices() { try { return JSON.parse(sessionStorage.getItem('ahnaNoticeShown') || '[]'); } catch { return []; } }
let noticeKey = '';
function renderNotices(list) {
  const key = JSON.stringify(list); if (key === noticeKey) return; noticeKey = key;
  notices = list;
  const unread = list.filter(n => !n.read);
  $('noticeBell').hidden = list.length === 0;
  $('noticeCount').hidden = unread.length === 0; $('noticeCount').textContent = unread.length;
  $('noticeBell').title = unread.length ? '읽지 않은 공지 ' + unread.length + '개' : '공지';
  if ($('noticeDialog').open) fillNotices();
  const shown = shownNotices(), fresh = unread.filter(n => !shown.includes(n.id));
  if (fresh.length && !$('clipboardDialog').open) {
    try { sessionStorage.setItem('ahnaNoticeShown', JSON.stringify(shown.concat(fresh.map(n => n.id)).slice(-100))); } catch {}
    openNotices();
  }
  if (!list.length && $('noticeDialog').open) $('noticeDialog').close();
}
function fillNotices() {
  const box = $('noticeList'); box.replaceChildren();
  for (const n of notices) {
    const item = node('div', undefined, 'noticeItem' + (n.read ? '' : ' unread'));
    const meta = node('div', undefined, 'noticeMeta');
    meta.append(node('span', new Date(n.created).toLocaleString('ko-KR', { month:'numeric', day:'numeric', hour:'numeric', minute:'2-digit' }) + (n.read ? ' · 읽음 · 3일 뒤 사라짐' : ' · 읽지 않음')));
    const button = node('button', n.read ? '삭제' : '읽음', 'btn' + (n.read ? '' : ' primary')); button.type = 'button';
    button.onclick = async () => { button.disabled = true; try { await api('/api/admin/announcements/' + encodeURIComponent(n.id) + (n.read ? '/delete' : '/read'), {}); await refresh(); } catch (e) { message(e.message); button.disabled = false; } };
    meta.append(button); item.append(node('p', n.text), meta); box.append(item);
  }
}
function openNotices() { fillNotices(); if (!$('noticeDialog').open) $('noticeDialog').showModal(); }
$('noticeBell').onclick = openNotices;
$('closeNotice').onclick = () => $('noticeDialog').close();
let reauthTried = false;
function ownerSecret() { try { return sessionStorage.getItem('ahnaOwner') || ''; } catch { return ''; } }
async function refresh() {
  if (polling) return; polling = true;
  try {
    const r = await fetch('/api/state', { credentials:'same-origin' });
    if (r.status === 401) {
      // 이 컴퓨터의 아나 창: 업데이트로 아나가 다시 시작되면 세션이 사라지므로 저장해 둔 주인 비밀값으로 다시 들어갑니다.
      if (!reauthTried && ownerSecret()) { reauthTried = true; try { await api('/api/owner', {}, {'X-Ahna-Owner': ownerSecret()}); polling = false; return await refresh(); } catch {} }
      if (state) message('연결이 해제되었습니다. 연결 코드를 다시 입력하세요.'); state = null; unpaired(); return;
    }
    reauthTried = false;
    if (!r.ok) throw new Error(); render(await r.json());
  } catch { if (state) { document.body.classList.add('offline'); setStatus(false, '오프라인 · 컴퓨터의 아나와 인터넷 연결을 확인하세요.'); } }
  finally { polling = false; }
}
$('pairForm').addEventListener('submit', async e => { e.preventDefault(); const button = e.target.querySelector('button'); button.disabled = true; try { await api('/api/pair', {name:$('deviceName').value,pin:$('pin').value}); $('pin').value=''; await refresh(); } catch(e) { message(e.message); } finally { button.disabled=false; } });
function unpaired() { closeOptions(false); document.body.classList.remove('paired','offline'); setStatus(false, '연결 대기 중'); $('pair').hidden = false; $('workspace').hidden = true; }
$('logout').onclick = async () => {
  const text = state?.owner ? '이 창의 연결을 끊을까요?\n다시 열려면 트레이의 아나 아이콘에서 [아나 열기]를 누르세요.\n(다른 기기와의 연결은 그대로 유지됩니다)' : '이 기기와 컴퓨터의 연결을 끊을까요?\n다시 연결하려면 연결 코드를 입력해야 합니다.';
  if (!confirm(text)) return;
  try { await api('/api/logout', {}); state=null; unpaired(); } catch(e) { message(e.message); }
};
$('pick').onclick = async () => {
  const target = findTarget(selectedTarget);
  if (!target) { message('받을 기기를 먼저 연결하세요.'); return; }
  if (busy) { message('끌어다 놓은 파일을 올리는 중입니다. 끝난 뒤 다시 시도하세요.'); return; }
  $('pick').disabled=true;
  try {
    if (target.nearby) {
      if (nearby && !nearby.nas) throw new Error('서버 설정이 필요합니다. 옵션에서 서버를 설정하세요.');
      await api('/api/admin/nearby/' + encodeURIComponent(target.deviceId) + '/send-files', {});
      await refreshNearby();
    } else if (target.outbound) {
      const r = await api('/api/admin/devices/' + encodeURIComponent(target.sendId) + '/send-files', {});
      if (r?.count) message(`${target.name}에 ${r.count}개 파일을 보내는 중입니다.`);
    } else await api('/api/admin/pick', {target:target.sendId});
    await refresh();
  } catch(e) { message(e.message); } finally { updatePick(); }
};
$('outCancel').onclick = () => { if (busy && currentUpload) { currentUpload.abort(); return; } api('/api/admin/devices/cancel', {}).catch(e => message(e.message)); };
$('openFolder').onclick = () => api('/api/admin/open-folder', {}).catch(e => message(e.message));
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
        xhr.onerror=()=>reject(new Error('연결이 끊겼습니다. 인터넷 연결과 컴퓨터의 아나를 확인하세요.'));
        xhr.onabort=()=>reject(new Error('전송을 중단했습니다. 완료된 파일은 유지됩니다.'));
        xhr.send(file);
      });
      completed++;
    }
    message(`${completed}개 파일을 ${state?.hostName || '컴퓨터'}에 저장했습니다.`);
  } catch(e) { message(`${e.message} (${completed}/${files.length}개 완료)`); }
  finally { busy=false; currentUpload=null; $('cancel').hidden=true; $('progressBox').hidden=true; $('files').disabled=$('folder').disabled=false; $('files').value=$('folder').value=''; await refresh(); }
}
$('cancel').onclick=()=>currentUpload?.abort();
$('files').onchange=e=>upload([...e.target.files]); $('folder').onchange=e=>upload([...e.target.files]);
$('drop').ondragover=e=>{e.preventDefault();$('drop').classList.add('over');};
$('drop').ondragleave=()=>$('drop').classList.remove('over');
$('drop').ondrop=e=>{ e.preventDefault();$('drop').classList.remove('over'); if ([...e.dataTransfer.items].some(i=>i.webkitGetAsEntry?.()?.isDirectory)) {message('폴더는 아래 ‘폴더 선택’ 버튼을 사용해 주세요.');return;} upload([...e.dataTransfer.files]); };
window.addEventListener('beforeunload', e=>{if(busy){e.preventDefault();e.returnValue='';}});

/* 끌어다 놓아 보내기 (컴퓨터 주인 화면): 페이지 어디에 놓아도 위에서 고른 기기로 보냅니다.
   브라우저가 파일을 이 컴퓨터의 아나에 올리면(/api/admin/drop), 앱이 고른 기기로 보냅니다(/api/admin/drop/send). */
const FOLDER_HINT = '폴더는 ‘보낼 파일이나 폴더를 선택하세요’를 눌러 고르세요.';
let dragDepth = 0;
const draggingFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');
const ownerDrop = () => !!state?.owner && !$('workspace').hidden && !isOpen() && !$('clipboardDialog').open;
function showDropOverlay(e) {
  const target = findTarget(selectedTarget), blocked = !target || busy;
  $('dropOverlay').classList.toggle('blocked', blocked);
  $('dropOverlayText').textContent = !target ? '받을 기기가 없습니다' : busy ? '다른 파일을 올리는 중입니다' : `놓으면 ${target.name}에 보냅니다`;
  $('dropOverlayHint').textContent = !target ? '다른 기기에서 아나를 열어 두거나 옵션에서 기기를 추가하세요.' : '파일당 최대 4 GiB · ' + FOLDER_HINT;
  $('dropOverlay').hidden = false;
  $('pick').classList.toggle('over', !blocked && !!e.target?.closest?.('#pick'));
  return !blocked;
}
function hideDropOverlay() { dragDepth = 0; clearTimeout(hideDropOverlay.timer); $('dropOverlay').hidden = true; $('pick').classList.remove('over'); }
document.addEventListener('dragenter', e => { if (!draggingFiles(e) || !ownerDrop()) return; e.preventDefault(); dragDepth++; showDropOverlay(e); });
document.addEventListener('dragover', e => {
  if (!draggingFiles(e) || !state?.owner) return;
  // 주인 화면에서는 파일을 놓아도 브라우저가 그 파일을 열지 않게 항상 막습니다.
  e.preventDefault();
  if (!ownerDrop()) { e.dataTransfer.dropEffect = 'none'; return; }
  e.dataTransfer.dropEffect = showDropOverlay(e) ? 'copy' : 'none';
  // 창 밖으로 나갔는데 dragleave가 빠진 경우에도 안내가 남지 않게 합니다(dragover는 끄는 동안 계속 옵니다).
  clearTimeout(hideDropOverlay.timer); hideDropOverlay.timer = setTimeout(hideDropOverlay, 1000);
});
document.addEventListener('dragleave', e => { if (!draggingFiles(e) || !state?.owner) return; dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) hideDropOverlay(); });
document.addEventListener('dragend', hideDropOverlay);
document.addEventListener('drop', e => {
  if (!draggingFiles(e) || !state?.owner) return;
  e.preventDefault(); hideDropOverlay();
  if (ownerDrop()) dropFiles(e.dataTransfer);
});
// dataTransfer는 drop 이벤트 안에서만 읽을 수 있어, 파일 목록을 먼저(동기로) 꺼냅니다.
function droppedFiles(dt) {
  const files = []; let folders = 0;
  const items = [...(dt.items || [])].filter(i => i.kind === 'file');
  if (items.length && typeof items[0].webkitGetAsEntry === 'function') {
    for (const item of items) {
      const entry = item.webkitGetAsEntry();
      if (entry?.isDirectory) { folders++; continue; }
      const file = item.getAsFile(); if (file) files.push(file);
    }
  } else files.push(...dt.files);
  return { files, folders };
}
function dropUpload(url, file) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest(); currentUpload = xhr;
    xhr.open('POST', url);
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.upload.onprogress = e => { if (e.lengthComputable) { const pct = Math.round(e.loaded / e.total * 100); $('progress').value = pct; $('progressPercent').textContent = pct + '%'; } };
    xhr.onload = () => { if (xhr.status >= 200 && xhr.status < 300) resolve(); else { let error; try { error = JSON.parse(xhr.responseText).error; } catch {} reject(new Error(error || (xhr.status === 413 ? '파일 한 개는 최대 4 GiB까지 보낼 수 있습니다.' : `파일을 올리지 못했습니다 (${xhr.status})`))); } };
    xhr.onerror = () => reject(new Error('이 컴퓨터의 아나에 연결하지 못했습니다. 트레이에서 아나를 다시 열어 주세요.'));
    xhr.onabort = () => reject(Object.assign(new Error('전송을 중단했습니다.'), { aborted: true }));
    xhr.send(file);
  });
}
async function dropFiles(dt) {
  const { files, folders } = droppedFiles(dt);
  if (!files.length) { message(folders ? FOLDER_HINT : '놓은 항목에서 파일을 찾지 못했습니다.'); return; }
  const target = findTarget(selectedTarget);
  if (!target) { message('받을 기기를 먼저 연결하세요.'); return; }
  if (busy) { message('다른 파일을 올리는 중입니다. 끝난 뒤 다시 놓아 주세요.'); return; }
  if (target.outbound && state.outbound?.sending) { message('다른 파일을 보내는 중입니다. 끝난 뒤 다시 시도하세요.'); return; }
  if (target.nearby && nearby && !nearby.nas) { message('서버 설정이 필요합니다. 옵션에서 서버를 설정하세요.'); return; }
  if (target.nearby && nearbyActive()) { message('근처 기기로 보내는 중입니다. 끝난 뒤 다시 시도하세요.'); return; }
  if (files.some(f => f.size > state.maxFile)) { message('파일 한 개는 최대 4 GiB까지 보낼 수 있습니다.'); return; }
  busy = true; $('pick').disabled = true;
  $('progressBox').hidden = false; $('outCancelRow').hidden = false; $('outCancel').disabled = false;
  const batch = batchId(), id = encodeURIComponent(target.sendId);
  let done = 0, sent = false;
  try {
    for (const file of files) {
      $('progressName').textContent = `${done + 1}/${files.length} · ${file.name} → ${target.name}`;
      $('progress').value = 0; $('progressPercent').textContent = '0%';
      await dropUpload(`/api/admin/drop?target=${id}&batch=${batch}&name=${encodeURIComponent(file.name)}`, file);
      done++;
    }
    currentUpload = null; $('outCancel').disabled = true;
    $('progressName').textContent = `${target.name}에 보낼 준비 중…`; $('progress').value = 100; $('progressPercent').textContent = '';
    const r = await api(`/api/admin/drop/send?target=${id}&batch=${batch}`, {});
    sent = true;
    const count = r?.count ?? done;
    if (target.nearby) { if (folders) message(FOLDER_HINT); await refreshNearby(); }
    else message((r?.external ? `${target.name}에 ${count}개 파일을 보내는 중입니다.` : `${target.name}에 보낼 ${count}개 파일을 준비했습니다. 상대 기기에서 아나를 열면 받습니다.`) + (folders ? ' ' + FOLDER_HINT : ''));
  } catch (e) { message(e.aborted ? `전송을 중단했습니다. 아무것도 보내지 않았습니다. (${done}/${files.length}개 올림)` : e.message); }
  finally {
    busy = false; currentUpload = null; $('outCancel').disabled = false;
    $('progressBox').hidden = true; $('outCancelRow').hidden = true;
    updatePick();
    await refresh();
  }
}
(async()=>{
  const params=new URLSearchParams(location.hash.slice(1));
  const owner=params.get('owner');
  openOptionsWhenReady = params.has('options');
  if(owner || params.has('options')) history.replaceState(null,'',location.pathname);
  if(owner){ try{ sessionStorage.setItem('ahnaOwner', owner); }catch{} try{await api('/api/owner',{}, {'X-Ahna-Owner':owner});}catch(e){message('Windows 트레이에서 아나를 다시 열어 주세요.');} }
  // 이 컴퓨터에서 연 화면이면 안내 한 줄: 주인 화면이 이렇게 바뀌었을 때 되돌리는 방법
  if (['127.0.0.1','localhost','[::1]'].includes(location.hostname)) $('pairLocalHint').hidden = false;
  const ua=navigator.userAgent; $('deviceName').value=/iPhone/.test(ua)?'나의 iPhone':/iPad/.test(ua)?'나의 iPad':/Macintosh/.test(ua)?'나의 Mac':'내 브라우저';
  api('/api/version').then(v => { if (!state) setVersion(v?.version); }).catch(() => {});
  await refresh(); setInterval(refresh,3000); document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
})();

/* 클립보드 */
let receivedClipboardText = '';
const clipboardTexts = new Map(), clipboardLoading = new Set();
async function loadClipboardText(id) {
  const r = await fetch('/api/download/' + encodeURIComponent(id) + '?kind=clipboard', { credentials:'same-origin' });
  if (!r.ok) throw new Error('글자를 불러오지 못했습니다. 보관 기간과 연결을 확인하세요.');
  const data = await r.arrayBuffer();
  if (data.byteLength > 65536) throw new Error('받은 글자가 너무 큽니다.');
  return new TextDecoder('utf-8', {fatal:true}).decode(data);
}
function prefetchClipboard(id, target) {
  if (clipboardTexts.has(id) || clipboardLoading.has(id)) return;
  clipboardLoading.add(id);
  loadClipboardText(id).then(text => { clipboardTexts.set(id, text); target.textContent = text.replace(/\s+/g, ' ').trim() || '(빈 글자)'; }).catch(() => {}).finally(() => clipboardLoading.delete(id));
}
function updateClipboardButton() {
  if (!state || !Array.isArray(state.clipboard)) return;
  const target = state.owner ? findTarget(selectedTarget) : null;
  $('sendClipboard').textContent = state.owner ? (target?.nearby ? '근처 기기에는 글자를 보낼 수 없습니다' : target ? target.name + '에 글자 보내기' : '글자 보내기') : (state.hostName || '컴퓨터') + '로 글자 보내기';
  $('sendClipboard').disabled = state.owner && (!allTargets(state).length || !!target?.nearby);
}
async function showClipboard(item) {
  $('receivedClipboard').value = '불러오는 중…'; $('copyClipboard').disabled = true; receivedClipboardText = '';
  if (!$('clipboardDialog').open) $('clipboardDialog').showModal();
  try {
    const text = clipboardTexts.get(item.id) ?? await loadClipboardText(item.id);
    clipboardTexts.set(item.id, text);
    receivedClipboardText = text; $('receivedClipboard').value = text; $('copyClipboard').disabled = false;
  } catch(e) { $('receivedClipboard').value = e.message; }
}
async function copyText(text) {
  if (!navigator.clipboard?.writeText) throw new Error();
  await navigator.clipboard.writeText(text);
}
function renderClipboard(s) {
  $('clipboardPanel').hidden = !Array.isArray(s.clipboard);
  if (!Array.isArray(s.clipboard)) return;
  $('nativeClipboard').hidden = !s.owner;
  updateClipboardButton();
  $('clipboardInbox').replaceChildren();
  const ids = new Set(s.clipboard.map(c => c.id));
  for (const id of [...clipboardTexts.keys()]) if (!ids.has(id)) clipboardTexts.delete(id);
  for (const item of s.clipboard) {
    const row = node('div', undefined, 'fileRow'), meta = node('div', undefined, 'fileMeta');
    const preview = node('span', clipboardTexts.has(item.id) ? (clipboardTexts.get(item.id).replace(/\s+/g, ' ').trim() || '(빈 글자)') : '불러오는 중…', 'clipText');
    meta.append(node('small', `${item.sender} · ${ago(item.created)} · ${size(item.bytes)}`), preview, node('small', stamp(item.created), 'clipTime'));
    const view = node('button', '보기', 'quiet neutral'); view.type = 'button'; view.onclick = () => showClipboard(item);
    const copy = node('button', '복사', 'copyBtn'); copy.type = 'button';
    copy.onclick = async () => {
      try {
        const text = clipboardTexts.get(item.id) ?? await loadClipboardText(item.id);
        clipboardTexts.set(item.id, text);
        await copyText(text);
        message('복사했습니다. 원하는 앱에 붙여넣으세요.');
      } catch(e) { if (e.message) message(e.message); else showClipboard(item); }
    };
    const actions = node('div', undefined, 'rowActions'); actions.append(view, copy);
    row.append(meta, actions); $('clipboardInbox').append(row);
    prefetchClipboard(item.id, preview);
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
    const target = state.owner ? findTarget(selectedTarget) : null;
    if (state.owner && !target) throw new Error('받을 기기를 먼저 연결하세요.');
    if (target?.nearby) throw new Error('근처 기기에는 글자를 보낼 수 없습니다. 파일로 보내 주세요.');
    if (target?.outbound) await api('/api/admin/devices/' + encodeURIComponent(target.sendId) + '/send-text', {text});
    else if (state.owner) await api('/api/admin/clipboard', {target:target.sendId, text});
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
    await copyText(receivedClipboardText);
    message('복사했습니다. 원하는 앱에 붙여넣으세요.');
  } catch {
    $('receivedClipboard').focus(); $('receivedClipboard').select();
    if (document.execCommand('copy')) message('복사했습니다. 원하는 앱에 붙여넣으세요.');
    else message('글자를 선택했습니다. 길게 눌러 복사하거나 Ctrl+C를 누르세요.');
  }
};
$('closeClipboard').onclick = () => { $('clipboardDialog').close(); receivedClipboardText = ''; $('receivedClipboard').value = ''; };

$("clearHistory").onclick=async()=>{try{await api("/api/admin/history/clear",{});location.reload();}catch(e){message(e.message);}};

/* 옵션 패널 (컴퓨터 주인만) */
let options = null, optionsBusy = false, optionsReturnFocus = null, joinChecked = false;
const switches = { optStartup: 'startup', optExplorer: 'explorerMenu', optNotify: 'notifications', optSaved: 'recipientSavedNotifications' };
const isOpen = () => document.body.classList.contains('drawerOpen');
function setSwitch(id, on) { $(id).setAttribute('aria-checked', String(!!on)); }
const switchOn = id => $(id).getAttribute('aria-checked') === 'true';
for (const id of Object.keys(switches)) $(id).onclick = () => setSwitch(id, !switchOn(id));
function optionsError(text) { $('optError').textContent = text || ''; $('optError').hidden = !text; }
function fillOptions(o) {
  options = o;
  setVersion(o.version);
  const online = nasOnline(o.remoteStatus);
  $('optNasState').classList.toggle('online', online);
  $('optNasState').lastElementChild.textContent = online ? '연결됨' : nasShort(o.remoteStatus).replace(/^서버 /, '');
  $('optNasStatus').textContent = o.remoteStatus || '';
  $('optNasUrl').value = o.remoteUrl || '';
  $('optNasKey').value = '';
  $('optNasKey').placeholder = o.remoteKeySaved ? '저장됨 · 바꿀 때만 새 키 입력' : '처음 한 번 입력 · 서버 설치 때 만든 64자리 키';
  if (o.ahna) {
    // 아나: 서버는 고정, 처음 한 번 초대 코드로 가입합니다.
    $('optNasTitle').textContent = '서버';
    $('optNasUrl').hidden = $('optNasUrlLabel').hidden = true;
    $('optNasKeyLabel').textContent = o.remoteKeySaved ? '연결됨' : '초대 코드';
    $('optNasKey').type = 'text';
    $('optNasKey').placeholder = o.remoteKeySaved ? '다시 연결할 때만 새 초대 코드 입력' : '받은 초대 코드 입력';
    $('optJoin').hidden = false;
  }
  $('optSavePath').textContent = o.savePath; $('optSavePath').title = o.savePath;
  $('optPickFolder').disabled = !o.folderPicker;
  setSwitch('optStartup', o.startup); setSwitch('optExplorer', o.explorerMenu);
  setSwitch('optNotify', o.notifications); setSwitch('optSaved', o.recipientSavedNotifications);
  $('optStartup').disabled = $('optExplorer').disabled = !o.integrationsAvailable;
  $('optUpdateCheck').disabled = !o.updates;
}
async function openOptions() {
  if (!state?.owner) return;
  optionsReturnFocus = document.activeElement;
  optionsError('');
  $('drawer').inert = false; $('drawer').setAttribute('aria-hidden', 'false');
  document.body.classList.add('drawerOpen'); $('settings').classList.add('active'); $('settings').setAttribute('aria-expanded', 'true');
  setTimeout(() => $('drawerClose').focus(), 30);
  renderLinked(state);
  refreshNearby();
  try { fillOptions(await api('/api/admin/options')); }
  catch(e) { optionsError(e.message); }
}
function closeOptions(restoreFocus = true) {
  if (!isOpen()) return;
  document.body.classList.remove('drawerOpen'); $('settings').classList.remove('active'); $('settings').setAttribute('aria-expanded', 'false');
  $('drawer').inert = true; $('drawer').setAttribute('aria-hidden', 'true');
  $('optNasKey').value = '';
  if (restoreFocus) (optionsReturnFocus && document.contains(optionsReturnFocus) ? optionsReturnFocus : $('settings')).focus?.();
}
$('settings').onclick = () => isOpen() ? closeOptions() : openOptions();
$('drawerClose').onclick = () => closeOptions();
$('optCancel').onclick = () => closeOptions();
$('drawerDim').onclick = () => closeOptions();
document.addEventListener('keydown', e => {
  if (!isOpen()) return;
  if (e.key === 'Escape' && !$('clipboardDialog').open) { e.preventDefault(); closeOptions(); return; }
  if (e.key === 'Tab') {
    const items = [...$('drawer').querySelectorAll('button:not(:disabled),input:not(:disabled),[tabindex]:not([tabindex="-1"])')].filter(el => !el.closest('[hidden]'));
    if (!items.length) return;
    const firstEl = items[0], lastEl = items[items.length - 1];
    if (e.shiftKey && document.activeElement === firstEl) { e.preventDefault(); lastEl.focus(); }
    else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); firstEl.focus(); }
  }
});
window.addEventListener('hashchange', () => { if (new URLSearchParams(location.hash.slice(1)).has('options')) { history.replaceState(null,'',location.pathname); openOptions(); } });
$('optPairCode').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); $('optPair').click(); } });
$('optPair').onclick = async () => {
  const pin = $('optPairCode').value.trim(), address = ''; // 위 서버 주소를 그대로 씁니다
  if (!/^[0-9]{6}$/.test(pin)) { optionsError('상대 기기의 6자리 연결 코드를 입력하세요.'); $('optPairCode').focus(); return; }
  $('optPair').disabled = true; optionsError('');
  try {
    const r = await api('/api/admin/devices/pair', { address, pin });
    $('optPairCode').value = '';
    message(`${r?.name || '기기'}을(를) 추가했습니다. 보내기에서 고를 수 있습니다.`);
    await refresh();
  } catch(e) { optionsError(e.message); }
  finally { $('optPair').disabled = false; }
};
$('optPickFolder').onclick = async () => {
  $('optPickFolder').disabled = true;
  try {
    const r = await api('/api/admin/pick-folder', {});
    if (r?.path) { $('optSavePath').textContent = r.path; $('optSavePath').title = r.path; }
  } catch(e) { optionsError(e.message); }
  finally { $('optPickFolder').disabled = !options?.folderPicker; }
};
function showUpdate(u) {
  $('optUpdateText').textContent = u.message + (u.available ? '' : ' · 6시간마다 자동 확인');
  $('optUpdateInstall').hidden = !u.available;
  $('optUpdateInstall').textContent = u.fullInstallRequired ? '릴리스 페이지' : '설치';
}
$('optUpdateCheck').onclick = async () => {
  $('optUpdateCheck').disabled = true; $('optUpdateText').textContent = '확인 중…';
  try { showUpdate(await api('/api/admin/update-check', {})); }
  catch(e) { $('optUpdateText').textContent = e.message; }
  finally { $('optUpdateCheck').disabled = !options?.updates; }
};
$('optUpdateInstall').onclick = async () => {
  if (!$('optUpdateInstall').textContent.includes('릴리스') && !confirm('새 버전을 설치하고 아나를 다시 시작할까요?\n설치하는 동안 이 화면의 연결이 잠시 끊깁니다.')) return;
  $('optUpdateInstall').disabled = true;
  try { const u = await api('/api/admin/update-install', {}); $('optUpdateText').textContent = u.message; }
  catch(e) { $('optUpdateText').textContent = e.message; }
  finally { $('optUpdateInstall').disabled = false; }
};
// 아나: 초대 코드 칸의 [연결] 버튼과 엔터는 옵션 저장(=가입)과 같습니다.
$('optJoin').onclick = () => { if ($('optNasKey').value.trim()) $('optSave').click(); else $('optNasKey').focus(); };
$('optNasKey').addEventListener('keydown', e => { if (e.key === 'Enter' && options?.ahna && $('optNasKey').value.trim()) { e.preventDefault(); $('optSave').click(); } });
$('optSave').onclick = async () => {
  if (!options || optionsBusy) return;
  optionsBusy = true; $('optSave').disabled = true; optionsError('');
  try {
    const body = {
      savePath: $('optSavePath').textContent,
      notifications: switchOn('optNotify'),
      recipientSavedNotifications: switchOn('optSaved'),
      remoteUrl: $('optNasUrl').value.trim(),
      nasKey: $('optNasKey').value.trim()
    };
    if (options.integrationsAvailable) { body.startup = switchOn('optStartup'); body.explorerMenu = switchOn('optExplorer'); }
    fillOptions(await api('/api/admin/options', body));
    closeOptions();
    message('옵션을 저장했습니다.');
    await refresh();
  } catch(e) { optionsError(e.message); }
  finally { optionsBusy = false; $('optSave').disabled = false; }
};

/* 근처 기기 (Bluetooth) · QR — 컴퓨터 주인 화면만.
   목록과 상태는 /api/admin/nearby 에서 읽습니다(읽는 동안만 이 PC가 근처 기기를 찾습니다).
   근처 기기로 보내기: 파일 선택(/api/admin/nearby/{id}/send-files) 또는 끌어다 놓기(id 'nearby:…')
   → 1회용 링크를 만들어 상대에게 Bluetooth로 알리고, 보내기 카드에 수락 대기 · 확인 숫자 · 진행률을 보여 줍니다. */
let nearby = null, nearbyPolling = false, nearbyAt = 0, nearbyModeBusy = false;
const BT_PATH = 'm7 7 10 10-5 5V2l5 5L7 17';
const initial = name => { const t = String(name || '').trim(); return t ? [...t][0].toUpperCase() : '?'; };
const nearbyActive = () => !!nearby?.send && ['connecting', 'waiting', 'transferring'].includes(nearby.send.state);
function nearbyTargets() {
  if (!state?.owner || !nearby?.available || nearby.bluetooth !== 'on') return [];
  return (nearby.devices || []).map(d => ({ id: 'nearby:' + d.id, sendId: 'nearby:' + d.id, deviceId: d.id, name: d.name, platform: d.platform, proximity: d.proximity, online: true, outbound: false, nearby: true }));
}
async function refreshNearby() {
  if (!state?.owner || nearbyPolling) return;
  nearbyPolling = true;
  try { nearby = await api('/api/admin/nearby'); nearbyAt = Date.now(); }
  catch { nearby = null; }
  finally { nearbyPolling = false; }
  renderNearby();
}
function nearbyRemaining() { return nearby?.remaining == null ? 0 : Math.max(0, nearby.remaining - Math.floor((Date.now() - nearbyAt) / 1000)); }
const clock = sec => Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2, '0');
function renderNearby() {
  if (!state?.owner) return;
  const available = !!nearby?.available;
  const on = available && nearby.bluetooth === 'on';
  $('qrOpen').hidden = !available;
  // 보내기 카드: 근처 기기 목록
  const list = nearbyTargets();
  if (selectedTarget.startsWith('nearby:') && !list.some(d => d.id === selectedTarget)) {
    const fallback = allTargets(state); selectedTarget = (fallback.find(d => d.online) || fallback[0])?.id || '';
    renderTargets(allTargets(state)); updateClipboardButton();
  }
  $('myDevicesLabel').hidden = !on;
  $('nearbyBox').hidden = !on || !list.length;
  const box = $('nearbyList'), focused = document.activeElement?.closest?.('#nearbyList') ? document.activeElement.dataset.id : null;
  box.replaceChildren();
  for (const d of list) {
    const chip = node('button', undefined, 'nearChip'); chip.type = 'button'; chip.dataset.id = d.id;
    chip.setAttribute('role', 'radio'); chip.setAttribute('aria-checked', String(d.id === selectedTarget)); chip.tabIndex = d.id === selectedTarget || (!list.some(x => x.id === selectedTarget) && d === list[0]) ? 0 : -1;
    const name = node('span', d.name, 'nearName'); if (d.platform) name.append(node('small', d.platform));
    chip.append(node('span', initial(d.name), 'nearAvatar'), name, node('span', d.proximity, 'nearBadge'));
    chip.setAttribute('aria-label', `${d.name} · 근처 기기 · ${d.proximity}`);
    chip.onclick = () => { selectedTarget = d.id; renderTargets(allTargets(state)); renderNearby(); box.querySelector(`[data-id="${CSS.escape(d.id)}"]`)?.focus(); updateClipboardButton(); };
    box.append(chip);
    if (focused === d.id) chip.focus();
  }
  const note = !available ? '' : nearby.bluetooth === 'none' ? '등록한 기기에만 보낼 수 있습니다.' : nearby.bluetooth === 'off' ? 'Bluetooth가 꺼져 있어 등록한 기기에만 보낼 수 있습니다.' : nearby.bluetooth === 'denied' ? 'Bluetooth를 쓸 수 없어 등록한 기기에만 보낼 수 있습니다.' : '';
  $('nearbyNote').textContent = note; $('nearbyNote').hidden = !note;
  renderNearbySend();
  updatePick();
  if (isOpen()) renderNearbyOptions();
}
function renderNearbySend() {
  const s = nearby?.send, card = $('nearbySend');
  card.hidden = !s; $('pick').hidden = !!s;
  if (!s) return;
  const percent = s.percent || 0, what = [s.summary, s.bytes ? size(s.bytes) : ''].filter(Boolean).join(' · ');
  const view = {
    connecting: [`${s.device}에 알리는 중…`, 'Bluetooth로 보내기 요청을 전하고 있습니다', '', '보내기 취소'],
    waiting: [`${s.device}에서 수락을 기다리는 중`, '상대 화면에 같은 확인 숫자가 보이는지 확인해 달라고 하세요', `${s.remaining}초 안에 받지 않으면 자동으로 취소됩니다`, '보내기 취소'],
    transferring: [`${s.device}에 보내는 중`, what, '', '보내기 취소'],
    done: [`${s.device}에 보냈습니다`, what, '', '닫기'],
    declined: [`${s.device}에서 받지 않았습니다`, s.message || '상대가 거절했거나 응답이 없었습니다', '', '닫기'],
    failed: [`${s.device}에 보내지 못했습니다`, s.message || '다시 시도하세요', '', '닫기']
  }[s.state] || [s.device, '', '', '닫기'];
  card.classList.toggle('ok', s.state === 'done'); card.classList.toggle('ended', s.state === 'declined' || s.state === 'failed');
  const avatar = $('nearSendAvatar'); avatar.className = 'nearAvatar big' + (s.state === 'done' ? ' ok' : s.state === 'declined' || s.state === 'failed' ? ' no' : '');
  avatar.replaceChildren(s.state === 'done' ? icon(['M20 6 9 17l-5-5'], 24) : s.state === 'declined' || s.state === 'failed' ? icon(['M18 6 6 18', 'M6 6l12 12'], 24) : document.createTextNode(initial(s.device)));
  $('nearSendTitle').textContent = view[0]; $('nearSendText').textContent = view[1]; $('nearSendText').hidden = !view[1];
  $('nearSendHint').textContent = view[2]; $('nearSendHint').hidden = !view[2];
  const showCode = s.state === 'waiting' && !!s.code;
  $('nearSendCode').hidden = !showCode;
  if (showCode) { $('nearSendCode').replaceChildren(...String(s.code).split('').map(c => node('span', c))); $('nearSendCode').setAttribute('aria-label', '확인 숫자 ' + s.code); }
  $('nearSendProgress').hidden = s.state !== 'transferring';
  $('nearSendBar').value = percent; $('nearSendPercent').textContent = percent + '%';
  $('nearSendCancel').textContent = view[3];
}
$('nearSendCancel').onclick = async () => {
  $('nearSendCancel').disabled = true;
  try { await api('/api/admin/nearby/cancel', {}); } catch(e) { message(e.message); }
  finally { $('nearSendCancel').disabled = false; await refreshNearby(); }
};
$('qrOpen').onclick = () => api('/api/admin/qr/open', {}).catch(e => message(e.message));
// 근처 기기로 보내는 동안에는 1초마다, 받기 모드 남은 시간은 화면에서 1초마다 줄입니다.
setInterval(() => {
  if (document.hidden || !state?.owner) return;
  if (nearbyActive()) refreshNearby();
  else if (isOpen() && nearby?.mode === 'everyone') renderNearbyOptions();
}, 1000);
$('nearbyList').addEventListener('keydown', e => {
  const list = nearbyTargets();
  if (!list.length || !['ArrowRight','ArrowLeft','ArrowDown','ArrowUp'].includes(e.key)) return;
  e.preventDefault();
  const i = Math.max(0, list.findIndex(d => d.id === selectedTarget));
  selectedTarget = list[(i + (e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length].id;
  renderTargets(allTargets(state)); renderNearby(); $('nearbyList').querySelector('[aria-checked="true"]')?.focus(); updateClipboardButton();
});

/* 옵션 › 근처 기기에서 받기 (끔 / 등록된 기기만 / 10분 동안 모두) — 고르면 바로 적용됩니다. */
function renderNearbyOptions() {
  const n = nearby;
  $('optNearby').hidden = !n?.available;
  if (!n?.available) return;
  const usable = n.bluetooth === 'on' || n.bluetooth === 'checking';
  $('optNearOn').hidden = !usable; $('optNearNone').hidden = usable;
  $('optNearNas').hidden = !!n.nas;
  if (!usable) {
    const text = {
      none: ['이 PC에는 Bluetooth가 없습니다', '근처 기기 보내기·받기는 쓸 수 없고, 등록한 기기와는 지금처럼 주고받습니다. Bluetooth 동글을 꽂으면 자동으로 켜집니다.'],
      off: ['Bluetooth가 꺼져 있습니다', 'Windows 설정 › Bluetooth 및 장치에서 켜면 근처 기기와 주고받을 수 있습니다. 등록한 기기와는 지금처럼 주고받습니다.'],
      denied: ['Bluetooth를 쓸 수 없습니다', 'Windows 설정 › 개인 정보 및 보안 › 라디오에서 앱의 Bluetooth 사용을 허용하세요. 등록한 기기와는 지금처럼 주고받습니다.']
    }[n.bluetooth] || ['Bluetooth를 쓸 수 없습니다', '등록한 기기와는 지금처럼 주고받습니다.'];
    $('optNoBtTitle').textContent = text[0]; $('optNoBtText').textContent = text[1];
    return;
  }
  for (const b of $('optNearMode').querySelectorAll('button')) {
    const checked = b.dataset.mode === n.mode;
    b.setAttribute('aria-checked', String(checked)); b.tabIndex = checked ? 0 : -1;
    b.disabled = nearbyModeBusy || (b.dataset.mode === 'everyone' && (!n.canReceive || n.bluetooth !== 'on'));
    b.textContent = b.dataset.mode === 'everyone' && n.mode === 'everyone' ? `모두 · ${clock(nearbyRemaining())} 남음` : { off: '끔', registered: '등록된 기기만', everyone: '10분 동안 모두' }[b.dataset.mode];
  }
  const status = $('optNearStatus');
  status.classList.toggle('on', n.bluetooth === 'on');
  status.lastElementChild.textContent = n.bluetooth === 'checking' ? 'Bluetooth 확인 중…'
    : !n.canReceive ? 'Bluetooth 켜짐 · 이 PC는 근처 기기로 보내기만 할 수 있습니다 (받기 미지원)'
    : n.mode === 'everyone' ? `Bluetooth 켜짐 · 근처에 '${n.name}'(으)로 보입니다 · ${clock(nearbyRemaining())} 뒤 '등록된 기기만'으로 돌아갑니다`
    : n.mode === 'off' ? 'Bluetooth 켜짐 · 근처 기기에서 받지 않습니다'
    : 'Bluetooth 켜짐 · 근처 기기로 보낼 수 있습니다';
}
$('optNearMode').addEventListener('click', async e => {
  const b = e.target.closest('button[data-mode]');
  if (!b || b.disabled || nearbyModeBusy || b.getAttribute('aria-checked') === 'true') return;
  nearbyModeBusy = true; optionsError(''); renderNearbyOptions();
  try { nearby = await api('/api/admin/nearby/mode', { mode: b.dataset.mode }); nearbyAt = Date.now(); }
  catch(err) { optionsError(err.message); }
  finally { nearbyModeBusy = false; renderNearby(); renderNearbyOptions(); $('optNearMode').querySelector('[aria-checked="true"]')?.focus(); }
});
$('optNearMode').addEventListener('keydown', e => {
  if (!['ArrowRight','ArrowLeft'].includes(e.key)) return;
  e.preventDefault();
  const buttons = [...$('optNearMode').querySelectorAll('button')].filter(b => !b.disabled);
  const i = Math.max(0, buttons.indexOf(document.activeElement));
  buttons[(i + (e.key === 'ArrowRight' ? 1 : buttons.length - 1)) % buttons.length]?.click();
});
