#!/usr/bin/env python3
"""정식 배포 마지막 단계: 각 빌드가 서버에 올린 파일 정보로 latest.json을 만들어 올립니다.

    WINDOWS='{...}' WINDOWS_SETUP='{...}' IOS='{...}' MAC='{...}' ANDROID='{...}' python3 scripts/make_manifest.py 1.0.5
(각 값은 scripts/upload.py가 출력한 JSON). 앱은 {서버}/_ahna/update/latest.json 을 6시간마다 확인합니다.
"""
import datetime, json, os, pathlib, subprocess, sys, tempfile

version = sys.argv[1].lstrip("v")
root = pathlib.Path(__file__).resolve().parents[1]
server = subprocess.run([sys.executable, str(root / "scripts/upload.py"), "--server"], capture_output=True, text=True, check=True).stdout.strip()
def asset(env):
    value = os.environ.get(env, "").strip()
    if not value: return None
    a = json.loads(value)
    return {"url": f"{server}/_ahna/update/{a['name']}", "sha256": a["sha256"], "size": a["size"]}
missing = [k for k in ("WINDOWS", "IOS", "MAC", "ANDROID") if not os.environ.get(k, "").strip()]
if missing: sys.exit("빌드 결과를 받지 못했습니다: " + ", ".join(missing))
platforms = {k: v for k, v in {"windows": asset("WINDOWS"), "ios": asset("IOS"), "mac": asset("MAC"), "android": asset("ANDROID")}.items() if v}
setup = asset("WINDOWS_SETUP")
manifest = {
    "name": "아나", "version": version,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notesUrl": f"{server}/_ahna/download", "fullInstallRequired": False,
    "platforms": platforms, "downloads": {"windows": setup["url"]} if setup else {},
}
folder = pathlib.Path(tempfile.mkdtemp())
(folder / "latest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
print("버전", version, "· 플랫폼", ", ".join(platforms))
# 앱 파일을 모두 올린 뒤 마지막에 올립니다(서버는 여기에 없는 예전 파일을 지웁니다).
subprocess.run([sys.executable, str(root / "scripts/upload.py"), str(folder / "latest.json"), "latest.json", "manifest"], check=True)
