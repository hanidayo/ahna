#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# 서명 전 IPA를 만듭니다. 설치할 때 Feather · Sideloadly · AltStore 등이 자기 인증서로 다시 서명합니다.
# AHNA_TEAM_ID: 설치에 쓸 Apple 팀 ID(10자리). 모르면 비워 두세요(다시 서명할 때 바뀝니다).
team="${AHNA_TEAM_ID:-AAAAAAAAAA}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'AHNA_TEAM_ID는 영문 대문자·숫자 10자리여야 합니다.' >&2
    exit 1
fi
if ! xcodebuild -version; then
    echo 'Full Xcode is required. Open Xcode once, then select it in Xcode > Settings > Locations > Command Line Tools.' >&2
    exit 1
fi
if [[ "${AHNA_SKIP_CHECKS:-}" != "1" ]]; then
    bash 자동저장검증.command
    bash 다중연결검증.command
    bash 휴대폰직접연결검증.command
fi
build_root="$PWD/build/ipa-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$build_root/Payload" "$PWD/dist"
xcodebuild -project Ahna.xcodeproj -scheme Ahna -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$build_root/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=17.0 DEVELOPMENT_TEAM="$team" AppIdentifierPrefix="$team." CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build 2>&1 | tee "$PWD/ipa-build.log"
app="$build_root/DerivedData/Build/Products/Release-iphoneos/Ahna.app"
test -f "$app/Ahna"
test -f "$app/PlugIns/AhnaShare.appex/AhnaShare"
/usr/libexec/PlistBuddy -c 'Print :UIFileSharingEnabled' "$app/Info.plist" | grep -qx true
xcrun lipo -archs "$app/Ahna" | grep -qw arm64
/usr/bin/ditto "$app" "$build_root/Payload/Ahna.app"
prepared="$build_root/Payload/Ahna.app"
# 앱 신원(application-identifier · team-identifier)도 함께 넣습니다. 이것이 없으면 Feather 등으로 다시 서명했을 때
# 시스템이 앱을 알아보지 못해, 파일 앱 선택 창의 [열기]가 반응하지 않습니다(공유 확장은 영향 없음).
xcrun python3 - "$team" "$PWD/Shared/Ahna.entitlements" "$build_root/shared.entitlements" "$build_root/share.entitlements" <<'PY'
import plistlib, sys
from pathlib import Path
team = sys.argv[1]
base = plistlib.loads(Path(sys.argv[2]).read_bytes())
base['keychain-access-groups'] = [x.replace('$(AppIdentifierPrefix)', team+'.') for x in base['keychain-access-groups']]
for out, bundle in ((sys.argv[3], 'io.ahna.open'), (sys.argv[4], 'io.ahna.open.share')):
    e = dict(base)
    e['application-identifier'] = f'{team}.{bundle}'
    e['com.apple.developer.team-identifier'] = team
    Path(out).write_bytes(plistlib.dumps(e))
PY
# Give the Windows signer existing, verified signature structures to replace.
# These ad-hoc signatures do not use an Apple account or authorize installation.
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$build_root/share.entitlements" "$prepared/PlugIns/AhnaShare.appex"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$build_root/shared.entitlements" "$prepared"
/usr/bin/codesign --verify --strict --verbose=2 "$prepared/PlugIns/AhnaShare.appex"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$prepared"
xcrun python3 Tools/verify_shared_settings.py "$prepared"
xcrun python3 Tools/verify_ipa.py "$prepared" --report "$PWD/dist/signing-input-check.json"
version="$(grep -m1 '"MARKETING_VERSION"' Ahna.xcodeproj/project.pbxproj | sed -E 's/.*= "([0-9.]+)".*/\1/')"
output="$PWD/dist/Ahna-$version.ipa"
xcrun python3 Tools/package_ipa.py "$prepared" "$output"
/usr/bin/unzip -t "$output"
xcrun python3 Tools/verify_ipa.py "$output" --report "$output.preflight.json"
xcrun python3 Tests/test_signing_preflight.py "$output"
shasum -a 256 "$output" > "$output.sha256"
printf '\nIPA 완료: %s\n설치 도구(Feather · Sideloadly 등)로 서명해 설치하세요. 공유 확장(AhnaShare.appex)은 빼지 마세요.\n' "$output"
