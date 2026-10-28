#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
team="${AHNA_TEAM_ID:-}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'Shared settings requires the same Team prefix in both bundles. Set AHNA_TEAM_ID to the Team ID used for installation, then run again. See 본체공유통합-0.4.4.txt.' >&2
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
xcrun python3 - "$team" "$PWD/Shared/Ahna.entitlements" "$build_root/shared.entitlements" <<'PY'
import plistlib, sys
from pathlib import Path
entitlements = plistlib.loads(Path(sys.argv[2]).read_bytes())
entitlements['keychain-access-groups'] = [x.replace('$(AppIdentifierPrefix)', sys.argv[1]+'.') for x in entitlements['keychain-access-groups']]
Path(sys.argv[3]).write_bytes(plistlib.dumps(entitlements))
PY
# Give the Windows signer existing, verified signature structures to replace.
# These ad-hoc signatures do not use an Apple account or authorize installation.
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$build_root/shared.entitlements" "$prepared/PlugIns/AhnaShare.appex"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$build_root/shared.entitlements" "$prepared"
/usr/bin/codesign --verify --strict --verbose=2 "$prepared/PlugIns/AhnaShare.appex"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$prepared"
xcrun python3 Tools/verify_shared_settings.py "$prepared"
xcrun python3 Tools/verify_ipa.py "$prepared" --report "$PWD/dist/signing-input-check.json"
version="$(grep -m1 '"MARKETING_VERSION"' Ahna.xcodeproj/project.pbxproj | sed -E 's/.*= "([0-9.]+)".*/\1/')"
output="$PWD/dist/Ahna-$version-sideloadly.ipa"
xcrun python3 Tools/package_ipa.py "$prepared" "$output"
/usr/bin/unzip -t "$output"
xcrun python3 Tools/verify_ipa.py "$output" --report "$output.preflight.json"
xcrun python3 Tests/test_signing_preflight.py "$output"
shasum -a 256 "$output" > "$output.sha256"
printf '\nIPA created: %s\nUse Apple ID Sideload in Sideloadly, keep AhnaShare.appex and enable automatic refresh.\nOffline preparation passed; verify the extension after Windows re-signing.\n' "$output"
