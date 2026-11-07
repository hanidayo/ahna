#!/usr/bin/env python3
"""앱이 새 버전을 확인할 GitHub 저장소(소유자/이름)를 넣습니다.

    GITHUB_REPOSITORY=이름/저장소 python3 scripts/set_repo.py

GitHub Actions에서는 GITHUB_REPOSITORY가 자동으로 정해집니다(빌드한 저장소).
앱은 https://github.com/{저장소}/releases/latest/download/latest.json 으로 업데이트를 확인합니다.
넣지 않은 빌드(OWNER/REPO 그대로)는 업데이트를 확인하지 않습니다.
"""
import os, pathlib, re, sys

repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+", repo):
    sys.exit("GITHUB_REPOSITORY를 '소유자/저장소' 꼴로 지정하세요: " + repr(repo))
root = pathlib.Path(__file__).resolve().parents[1]
files = ["server/Common/Wire.cs", "windows/Ahna.Remote/Wire.cs", "ios/Shared/Brand.swift", "mac/Sources/Brand.swift",
         "android/app/src/main/java/me/ahna/Brand.java"]
for rel in files:
    f = root / rel
    raw = f.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    if '"OWNER/REPO"' not in text:
        sys.exit(f"{rel}: OWNER/REPO 자리를 찾지 못했습니다(이미 바꿨나요?)")
    text = text.replace('"OWNER/REPO"', '"' + repo + '"')
    f.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))
print("업데이트 저장소:", repo)
