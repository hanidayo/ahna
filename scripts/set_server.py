#!/usr/bin/env python3
"""빌드 전에 아나 서버 주소를 넣습니다. 소스에는 예시 주소(https://example.synology.me)만 둡니다.

    AHNA_SERVER=https://내주소.synology.me python3 scripts/set_server.py
CI에서는 저장소 비밀값 AHNA_SERVER를 씁니다. 바꾸는 파일: Brand(C#·Swift·Java) 다섯 곳.
"""
import os, pathlib, re, sys
root = pathlib.Path(__file__).resolve().parents[1]
server = os.environ.get("AHNA_SERVER", "").strip().rstrip("/")
if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:\d+)?", server):
    sys.exit("AHNA_SERVER 비밀값이 없거나 올바르지 않습니다. 예: https://example.synology.me")
files = ["server/Common/Wire.cs", "windows/Ahna.Remote/Wire.cs", "ios/Shared/Brand.swift", "mac/Sources/Brand.swift", "android/app/src/main/java/me/ahna/Brand.java"]
for rel in files:
    p = root / rel
    raw = p.read_bytes(); bom = raw.startswith(b"\xef\xbb\xbf"); s = raw.decode("utf-8-sig")
    if "https://example.synology.me" not in s: sys.exit(f"{rel}: 예시 주소를 찾지 못했습니다.")
    p.write_bytes((b"\xef\xbb\xbf" if bom else b"") + s.replace("https://example.synology.me", server).encode("utf-8"))
print("서버 주소를 넣었습니다.")
