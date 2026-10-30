#!/usr/bin/env python3
"""모든 플랫폼의 버전을 한 번에 맞춥니다.

    python3 scripts/set_version.py 1.0.0

VERSION 파일, Windows/Mac/iOS/Android/NAS 프로젝트와 웹 화면 표기를 같은 버전으로 바꿉니다.
CI(release.yml)가 태그(vX.Y.Z)로 자동 실행하므로 평소에는 VERSION만 바꾸고 태그를 올리면 됩니다.
"""
import argparse, pathlib, re, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")  # Windows 콘솔(cp1252 등)에서도 한글 출력
except Exception:
    pass

root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("version")
p.add_argument("--build", type=int, help="빌드 번호를 직접 지정할 때만 사용")
a = p.parse_args()
v = a.version.lstrip("vV")
if not re.fullmatch(r"\d+\.\d+\.\d+", v):
    sys.exit("버전은 X.Y.Z 형식이어야 합니다: " + v)
major, minor, patch = map(int, v.split("."))
# 빌드 번호는 버전에서 계산합니다(1.0.0 → 30000). 새 서버로 옮기며 버전을 1.0.0으로 되돌렸으므로
# 예전 빌드(1.0.x → 100xx)보다 커지게 20000을 더합니다(안드로이드는 빌드 번호가 작으면 덮어 설치가 안 됨).
code = a.build or (20000 + major * 10000 + minor * 100 + patch)


def sub(rel, pattern, repl, count=0, required=True):
    f = root / rel
    s = f.read_text(encoding="utf-8")
    n, k = re.subn(pattern, repl, s, count=count, flags=re.M)
    if k == 0 and required:
        sys.exit(f"{rel}: 바꿀 위치를 찾지 못했습니다 ({pattern})")
    f.write_text(n, encoding="utf-8")


(root / "VERSION").write_text(v + "\n", encoding="utf-8")

# Windows
sub("windows/Properties/AssemblyInfo.cs", r'AssemblyFileVersion\("[^"]*"\)', f'AssemblyFileVersion("{v}.0")')
sub("windows/Properties/AssemblyInfo.cs", r'AssemblyInformationalVersion\("[^"]*"\)', f'AssemblyInformationalVersion("{v}")')
sub("windows/Properties/AssemblyInfo.cs", r'AssemblyVersion\("[^"]*"\)', f'AssemblyVersion("{v}.0")')
for web, need in (("windows/wwwroot/index.html", True), ("src/wwwroot/index.html", False)):
    sub(web, r"((?:Ahna|아나) )\d+\.\d+\.\d+", rf"\g<1>{v}", required=need)

# Mac (앱 + 공유 확장 + 수신 구성요소)
for plist in ("mac/Bundle/Info.plist", "mac/ShareExtension/Info.plist"):
    sub(plist, r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*", rf"\g<1>{v}")
    sub(plist, r"(<key>CFBundleVersion</key>\s*<string>)[^<]*", rf"\g<1>{code}")
sub("mac/Receiver/Ahna.MacReceiver.csproj", r"<Version>[^<]*</Version>", f"<Version>{v}</Version>")

# iOS
sub("ios/Ahna.xcodeproj/project.pbxproj", r'"MARKETING_VERSION" = "[^"]*";', f'"MARKETING_VERSION" = "{v}";')
sub("ios/Ahna.xcodeproj/project.pbxproj", r'"CURRENT_PROJECT_VERSION" = "[^"]*";', f'"CURRENT_PROJECT_VERSION" = "{code}";')

# Android
sub("android/app/build.gradle", r"versionCode \d+; versionName '[^']*'", f"versionCode {code}; versionName '{v}'")
sub("android/build_apk.py", r"'--version-code','\d+','--version-name','[^']*'", f"'--version-code','{code}','--version-name','{v}'")
sub("android/build_apk.py", r"Ahna-[\d.]+-Android\.apk", f"Ahna-{v}-Android.apk")

# NAS
sub("server/Server/Ahna.Relay.csproj", r"<Version>[^<]*</Version>", f"<Version>{v}</Version>")
sub("server/Dockerfile", r"ARG VERSION=[\d.]+", f"ARG VERSION={v}")

print(f"버전 {v} (빌드 {code}) 적용 완료")
