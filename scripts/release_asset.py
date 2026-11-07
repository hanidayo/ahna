#!/usr/bin/env python3
"""정식 배포: 빌드한 앱 파일을 공개 배포 저장소(GitHub Releases)의 vX.Y 초안에 올립니다.

    GH_TOKEN=… RELEASES_REPO=hanidayo/ahna-releases python3 scripts/release_asset.py dist/Ahna-Setup.exe 1.0 [출력이름]

파일 이름 그대로 올립니다(버전이 없는 이름 → releases/latest/download/파일 이 늘 최신을 가리킴).
출력: {"name", "sha256", "size"} (GITHUB_OUTPUT의 출력이름=… 으로도 남김). latest.json은 make_manifest.py가 만듭니다.
"""
import hashlib, json, os, pathlib, subprocess, sys

path, version = pathlib.Path(sys.argv[1]), sys.argv[2].lstrip("vV")
output = sys.argv[3] if len(sys.argv) > 3 else "asset"
repo = os.environ.get("RELEASES_REPO", "hanidayo/ahna-releases")
if not os.environ.get("GH_TOKEN"): sys.exit("비밀값 RELEASES_TOKEN이 없습니다.")
digest = hashlib.sha256()
with path.open("rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""): digest.update(chunk)
for attempt in range(3):
    r = subprocess.run(["gh", "release", "upload", "v" + version, str(path), "--clobber", "-R", repo], capture_output=True, text=True)
    if r.returncode == 0: break
    print(f"::warning::{path.name} 올리기 {attempt + 1}번째 실패 · {r.stderr.strip()[:300]}", flush=True)
else:
    print(f"::error::{path.name} 올리기 실패", flush=True); sys.exit(1)
line = json.dumps({"name": path.name, "sha256": digest.hexdigest(), "size": path.stat().st_size})
if os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as o: o.write(f"{output}={line}\n")
print(line)
