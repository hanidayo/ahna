#!/usr/bin/env python3
"""서버(중계) 동작 확인: 초대 코드 연결 · 관리자 페이지 · 알림 · 사용량 한도 · 초기화 · 차단.

    AHNA_KEY=… AHNA_INVITE=TEST-INVITE AHNA_ADMIN_PASSWORD=admin-pass-1 AHNA_ORIGIN=http://localhost:8080 AHNA_TEST_HTTP=1 \
      AHNA_DATA=/tmp/ahna-data dotnet run --project server/Server &
    python3 scripts/server_smoke.py

(pip install websockets requests)
"""
import asyncio, json, os, sys, time, uuid, urllib.parse
import requests, websockets

BASE = os.environ.get("BASE", "http://localhost:8080")
WS = BASE.replace("http", "ws", 1)
INVITE = os.environ.get("AHNA_INVITE", "TEST-INVITE")
PASSWORD = os.environ.get("AHNA_ADMIN_PASSWORD", "admin-pass-1")
ok = 0

def check(cond, what):
    global ok
    if not cond: print("::error::실패: " + what, flush=True); sys.exit(1)
    ok += 1; print("통과:", what)

def join(cid, name="테스트 PC"):
    return requests.post(BASE + "/_ahna/join", json={"invite": INVITE, "computer": cid, "name": name, "platform": "Windows"})

admin = requests.Session()
def api(path, body=None):
    h = {"X-Ahna-Admin": "1"}
    return admin.post(BASE + "/_ahna/admin" + path, json=body, headers=h) if body is not None else admin.get(BASE + "/_ahna/admin" + path, headers=h)

async def control(token, cid, notices=True):
    headers = {"Authorization": "Bearer " + token, "X-Ahna-Computer": cid, "X-Ahna-Name": urllib.parse.quote("테스트 PC")}
    if notices: headers["X-Ahna-Features"] = "notice,notices"
    ws = await websockets.connect(WS + "/_bridge/control", additional_headers=headers)
    try: await ws.send(json.dumps({"type": "ping"}))
    except websockets.ConnectionClosed: return ws   # 초기화·차단된 기기: 안내만 받고 닫힘
    # 서버는 45초 동안 ping이 없으면 끊습니다(앱은 15초마다 보냄).
    async def keep():
        try:
            while True: await asyncio.sleep(10); await ws.send(json.dumps({"type": "ping"}))
        except Exception: pass
    asyncio.get_running_loop().create_task(keep())
    return ws

async def notice(ws, timeout=10):
    return json.loads(await asyncio.wait_for(ws.recv(), timeout))

async def main():
    for _ in range(60):
        try:
            if requests.get(BASE + "/_ahna/version").ok: break
        except requests.ConnectionError: pass
        time.sleep(1)
    cid = uuid.uuid4().hex
    r = join(cid); check(r.ok, "초대 코드로 연결"); token = r.json()["token"]
    ws = await control(token, cid)

    page = requests.get(BASE + "/_ahna/admin")
    check(page.ok and "아나 관리" in page.text and "nonce-" in page.headers.get("Content-Security-Policy", ""), "관리자 화면 열림")
    check(api("/api/state").status_code == 401, "로그인 전에는 막힘")
    check(api("/login", {"password": "wrong-password"}).status_code == 403, "틀린 비밀번호 거부")
    check(api("/login", {"password": PASSWORD}).ok, "관리자 로그인")
    state = api("/api/state").json()
    dev = next((d for d in state["devices"] if d["id"] == cid), None)
    check(dev and dev["online"] and dev["name"] == "테스트 PC" and dev["platform"] == "Windows", "기기 목록에 이름·온라인 표시")

    r = api(f"/api/device/{cid}/notice", {"text": "안녕하세요"}); check(r.ok and r.json()["delivered"], "알림 보내기")
    n = await notice(ws); check(n["type"] == "notice" and n["action"] == "message" and "안녕하세요" in n["text"], "앱이 알림 받음")

    # 큰 파일 나눠 올리기: 가짜 받는 기기(호스트)가 /api/upload를 한 요청으로 받는지 확인
    hid = uuid.uuid4().hex; htoken = join(hid, "받는 PC").json()["token"]
    hws = await websockets.connect(WS + "/_bridge/control", additional_headers={"Authorization": "Bearer " + htoken, "X-Ahna-Computer": hid})
    await hws.send(json.dumps({"type": "ping"}))
    got = {}
    async def host():
        msg = json.loads(await hws.recv())
        data = await websockets.connect(WS + "/_bridge/data/" + msg["id"], additional_headers={"Authorization": "Bearer " + htoken})
        head = json.loads(await data.recv()); got["head"] = head
        await data.send(json.dumps({"Status": 100}))
        n = 0; h = __import__("hashlib").sha256()
        while n < head["Length"]:
            b = await data.recv(); n += len(b); h.update(b)
        got["bytes"] = n; got["sha"] = h.hexdigest()
        await data.send(json.dumps({"Status": 200, "Length": 2, "Headers": {"Content-Type": ["text/plain"]}}))
        await data.send(b"ok"); await data.recv(); await data.close()
    task = asyncio.create_task(host())
    piece = 3 * 1024 * 1024; blob = os.urandom(piece * 2 + 12345)
    loop = asyncio.get_running_loop()
    first = await loop.run_in_executor(None, lambda: requests.post(BASE + "/api/upload?batch=x&path=big.bin", data=blob[:piece], headers={"X-Ahna-Computer": hid, "X-Ahna-Total": str(len(blob)), "Content-Type": "application/octet-stream"}))
    check(first.status_code == 202 and first.json()["received"] == piece, "첫 조각 → 나눠 올리기 시작")
    up = first.json()["upload"]
    bad = await loop.run_in_executor(None, lambda: requests.put(f"{BASE}/_ahna/chunk/{up}", data=b"x", headers={"X-Ahna-Offset": "0"}))
    check(bad.status_code == 409, "잘못된 위치의 조각은 거부")
    r2 = await loop.run_in_executor(None, lambda: requests.put(f"{BASE}/_ahna/chunk/{up}", data=blob[piece:piece * 2], headers={"X-Ahna-Offset": str(piece)}))
    check(r2.status_code == 202, "둘째 조각")
    r3 = await loop.run_in_executor(None, lambda: requests.put(f"{BASE}/_ahna/chunk/{up}", data=blob[piece * 2:], headers={"X-Ahna-Offset": str(piece * 2)}))
    await asyncio.wait_for(task, 20)
    check(r3.status_code == 200 and r3.text == "ok", "마지막 조각 → 받는 기기 응답")
    check(got["bytes"] == len(blob) and got["sha"] == __import__("hashlib").sha256(blob).hexdigest() and got["head"]["Length"] == len(blob), "받는 기기가 전체를 한 번에 받음")
    await hws.close()

    # 근처 기기로 맡기기(drop)도 조각으로
    dauth = {"Authorization": "Bearer " + token}
    r = requests.post(BASE + "/_ahna/drop", json={"sender": "테스트", "code": "34", "files": [{"name": "d.bin", "bytes": 10}]}, headers=dauth); dtok = r.json()["token"]
    check(requests.put(f"{BASE}/_ahna/drop/{dtok}/0", data=b"12345", headers={**dauth, "X-Ahna-Offset": "0"}).json()["state"] == "uploading", "맡기기 첫 조각")
    check(requests.put(f"{BASE}/_ahna/drop/{dtok}/0", data=b"67890", headers={**dauth, "X-Ahna-Offset": "5"}).json()["state"] == "ready", "맡기기 마지막 조각")
    check(requests.get(f"{BASE}/s/{'0'*32}/{dtok}/file/0").content == b"1234567890", "맡긴 파일 그대로 받기")

    # 전체 공지: 만들면 온라인 기기에 "notices" 알림 → 기기가 받아 가서 읽음 표시
    r = api("/api/notices", {"text": "점검 안내\n오늘 밤 12시"}); check(r.ok, "공지 보내기"); nid = r.json()["id"]
    n = await notice(ws); check(n["action"] == "notices", "공지 알림")
    auth = {"Authorization": "Bearer " + token}
    lst = requests.get(BASE + "/_ahna/notices", headers=auth).json()["notices"]
    check(lst and lst[0]["id"] == nid and lst[0]["text"] == "점검 안내\n오늘 밤 12시" and isinstance(lst[0]["created"], int), "기기가 공지 받기")
    check(requests.get(BASE + "/_ahna/notices").status_code == 401, "공지는 연결한 기기만")
    check(requests.post(f"{BASE}/_ahna/notices/{nid}/read", headers=auth).ok, "읽음 알리기")
    state = api("/api/state").json()
    check(state["notices"][0]["reads"] == 1 and "total" in state and len(state["days"]) == 7, "관리자 화면에 읽음 수·전체 사용량")
    check(api(f"/api/notices/{nid}/delete", {}).ok, "공지 지우기")
    n = await notice(ws); check(n["action"] == "notices", "지운 뒤 다시 받기 알림")
    check(requests.get(BASE + "/_ahna/notices", headers=auth).json()["notices"] == [], "지운 공지는 사라짐")

    # 하루 한도 0.1 GB, 넘으면 막기 → 근처 기기로 맡기기(drop)로 110 MB 올려 한도를 넘김
    check(api("/api/settings", {"limitGB": 0.1, "enforce": True}).ok, "한도 저장")
    auth = {"Authorization": "Bearer " + token}
    size = 110 * 1024 * 1024
    r = requests.post(BASE + "/_ahna/drop", json={"sender": "테스트", "code": "12", "files": [{"name": "big.bin", "bytes": size}]}, headers=auth)
    check(r.ok, "맡기기 만들기"); drop = r.json()["token"]
    r = requests.put(f"{BASE}/_ahna/drop/{drop}/0", data=b"\0" * size, headers={**auth, "Content-Type": "application/octet-stream"})
    check(r.ok, "110 MB 올리기")
    n = await notice(ws); check(n["action"] == "limit", "한도 넘음 알림")
    r = requests.post(BASE + "/_ahna/drop", json={"sender": "테스트", "code": "12", "files": [{"name": "a", "bytes": 1}]}, headers=auth)
    check(r.status_code == 429 and "한도" in r.json()["error"], "한도 넘으면 막힘")
    state = api("/api/state").json(); dev = next(d for d in state["devices"] if d["id"] == cid)
    check(dev["today"] >= size, "사용량 집계")
    check(api("/api/settings", {"limitGB": 0, "enforce": False}).ok, "한도 해제")

    # 초기화 → 알림 + 끊김, 예전 토큰은 다시 연결하라는 안내만 받음
    check(api(f"/api/device/{cid}/reset", {}).ok, "기기 초기화")
    n = await notice(ws); check(n["action"] == "rejoin", "초기화 알림")
    try: await asyncio.wait_for(ws.recv(), 5); closed = False
    except (websockets.ConnectionClosed, asyncio.TimeoutError) as e: closed = isinstance(e, websockets.ConnectionClosed)
    check(closed, "초기화하면 연결 끊김")
    old = await control(token, cid); n = await notice(old); check(n["action"] == "rejoin", "예전 토큰 → 다시 연결 안내")
    try: await control(token, cid, notices=False); check(False, "예전 앱은 거부")
    except websockets.InvalidStatus as e: check(e.response.status_code == 401, "예전 토큰 거부(401)")
    r = join(cid); check(r.ok and r.json()["token"] != token, "초대 코드로 다시 연결 → 새 토큰"); token = r.json()["token"]
    ws = await control(token, cid)

    # 차단 → 알림 + 끊김, 초대 코드도 거부, 해제하면 다시 연결
    check(api(f"/api/device/{cid}/block", {}).ok, "차단")
    n = await notice(ws); check(n["action"] == "blocked", "차단 알림")
    check(join(cid).status_code == 403, "차단된 기기는 초대 코드도 거부")
    check(api(f"/api/device/{cid}/unblock", {}).ok, "차단 해제")
    r = join(cid); check(r.ok, "해제 뒤 다시 연결"); token = r.json()["token"]
    ws = await control(token, cid)

    # 전체 초기화
    check(api("/api/reset-all", {}).ok, "전체 초기화")
    n = await notice(ws); check(n["action"] == "rejoin", "전체 초기화 알림")
    check(requests.post(BASE + "/_ahna/drop", json={"files": [{"name": "a", "bytes": 1}]}, headers={"Authorization": "Bearer " + token}).status_code == 401, "전체 초기화 뒤 예전 토큰 무효")
    check(api(f"/api/device/{cid}/hide", {}).ok and all(d["id"] != cid for d in api("/api/state").json()["devices"]), "목록에서 숨기기")
    check(api("/logout", {}).ok and api("/api/state").status_code == 401, "로그아웃")
    print(f"모두 통과 ({ok}개)")

asyncio.run(main())
