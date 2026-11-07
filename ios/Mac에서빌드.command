#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash 자동저장검증.command
bash 다중연결검증.command
bash 휴대폰직접연결검증.command
xcodebuild -project Ahna.xcodeproj -scheme Ahna -configuration Debug -destination 'generic/platform=iOS Simulator' IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build 2>&1 | tee mac-build.log
echo 'Simulator build completed. Open Ahna.xcodeproj to sign and run, or use Sideloadly용IPA만들기.command.'
