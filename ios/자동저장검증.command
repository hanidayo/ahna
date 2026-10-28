#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_root="$(mktemp -d -t ahna-store-check)"
trap 'rm -f "$build_root/received-file-tests"; rmdir "$build_root" 2>/dev/null || true' EXIT
xcrun swiftc Shared/ReceivedFileStore.swift Tests/main.swift -o "$build_root/received-file-tests"
"$build_root/received-file-tests"