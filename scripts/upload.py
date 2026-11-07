#!/usr/bin/env python3
"""빌드한 파일 하나를 아나 서버에 올립니다(정식 배포 때만, CI).

    AHNA_PUBLISH_KEY=... python3 scripts/upload.py <파일> <서버에 둘 이름> [출력 이름]
서버 주소는 scripts/set_server.py가 넣은 Brand.Server를 읽습니다.
결과(이름·주소·SHA-256·크기)를 JSON 한 줄로 GITHUB_OUTPUT의 <출력 이름>(기본 asset)에 적습니다.
"""
import hashlib, json, os, pathlib, re, sys, urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
server = re.search(r'public const string Server = "([^"]+)"', (root / "server/Common/Wire.cs").read_text(encoding="utf-8-sig")).group(1).rstrip("/")
if sys.argv[1:2] == ["--server"]:
    print(server); sys.exit()
path, name = pathlib.Path(sys.argv[1]), sys.argv[2]
output = sys.argv[3] if len(sys.argv) > 3 else "asset"
key = os.environ.get("AHNA_PUBLISH_KEY", "")
if not key: sys.exit("비밀값 AHNA_PUBLISH_KEY가 없습니다.")
digest = hashlib.sha256()
with path.open("rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""): digest.update(chunk)
size = path.stat().st_size
for attempt in range(3):
    try:
        with path.open("rb") as body:
            req = urllib.request.Request(f"{server}/_ahna/admin/update/{name}", data=body, method="PUT",
                                         headers={"Authorization": "Bearer " + key, "Content-Type": "application/octet-stream", "Content-Length": str(size), "User-Agent": "Ahna-Publisher/1.0"})
            with urllib.request.urlopen(req, timeout=1800) as r: r.read()
        break
    except Exception as e:
        detail = f"HTTP {e.code}" if hasattr(e, "code") else type(e).__name__ + ": " + str(e)
        print(f"::warning::{name} 올리기 {attempt + 1}번째 실패 · {detail}", flush=True)
        if attempt == 2: print(f"::error::{name} 올리기 실패 · {detail}", flush=True); sys.exit(1)
# 작업 출력에는 서버 주소를 넣지 않습니다(비밀값이 들어간 출력은 GitHub가 다음 작업으로 넘기지 않음).
asset = {"name": name, "sha256": digest.hexdigest(), "size": size}
line = json.dumps(asset)
if os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as o: o.write(f"{output}={line}\n")
print(line)
