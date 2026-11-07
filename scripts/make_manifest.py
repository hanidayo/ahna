#!/usr/bin/env python3
"""배포 마지막 단계: 각 빌드가 릴리스에 올린 파일 정보로 latest.json을 만듭니다.

    WINDOWS='{...}' WINDOWS_SETUP='{...}' IOS='{...}' MAC='{...}' ANDROID='{...}' \\
    RELEASE_BASE=https://github.com/소유자/저장소/releases/download/v1.0 python3 scripts/make_manifest.py 1.0 dist/latest.json

각 값은 scripts/release_asset.py가 출력한 JSON입니다. 만든 latest.json도 같은 릴리스에 올리면,
앱이 https://github.com/{저장소}/releases/latest/download/latest.json 으로 새 버전을 확인합니다.
"""
import datetime, json, os, pathlib, sys

version = sys.argv[1].lstrip("vV")
output = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "latest.json")
base = os.environ.get("RELEASE_BASE", "").rstrip("/")
if not base: sys.exit("RELEASE_BASE(릴리스 파일 주소)를 지정하세요.")
def asset(env):
    value = os.environ.get(env, "").strip()
    if not value: return None
    a = json.loads(value)
    return {"url": f"{base}/{a['name']}", "sha256": a["sha256"], "size": a["size"]}
missing = [k for k in ("WINDOWS", "IOS", "MAC", "ANDROID") if not os.environ.get(k, "").strip()]
if missing: sys.exit("빌드 결과를 받지 못했습니다: " + ", ".join(missing))
platforms = {k: v for k, v in {"windows": asset("WINDOWS"), "ios": asset("IOS"), "mac": asset("MAC"), "android": asset("ANDROID")}.items() if v}
setup = asset("WINDOWS_SETUP")
manifest = {
    "name": "아나", "version": version,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notesUrl": os.environ.get("NOTES_URL") or None, "fullInstallRequired": False,
    "platforms": platforms, "downloads": {"windows": setup["url"]} if setup else {},
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
print("버전", version, "· 플랫폼", ", ".join(platforms), "→", output)
