#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_root="$(mktemp -d -t ahna-connections-check)"
trap 'rm -f "$build_root/connection-tests"; rmdir "$build_root" 2>/dev/null || true' EXIT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx12.0" Shared/Brand.swift Shared/AhnaClient.swift Shared/InstalledKeychainGroups.swift Shared/ReceivedFileStore.swift Shared/PhotoLibrarySaver.swift Tests/Connections.swift -o "$build_root/connection-tests"
"$build_root/connection-tests"
