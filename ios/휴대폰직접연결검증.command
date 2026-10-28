#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/Ahna-Mobile-tests.XXXXXX")"
trap 'rm -f "$build_root/mobile-tests"; rmdir "$build_root"' EXIT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" Shared/Brand.swift Ahna/MobileHost.swift Ahna/MobileNASBridge.swift Ahna/GuestPage.swift Tests/MobileHostChecks.swift -o "$build_root/mobile-tests"
"$build_root/mobile-tests"
