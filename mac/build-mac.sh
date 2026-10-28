#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache build/tmp dist/Ahna.app/Contents/MacOS dist/Ahna.app/Contents/Resources
export TMPDIR="$PWD/build/tmp" CLANG_MODULE_CACHE_PATH="$PWD/build/cache" SWIFT_MODULECACHE_PATH="$PWD/build/cache"
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -O -target "$arch-apple-macosx13.0" Sources/*.swift -o "build/Ahna-$arch"
done
lipo -create build/Ahna-arm64 build/Ahna-x86_64 -output dist/Ahna.app/Contents/MacOS/Ahna
cp Bundle/Info.plist dist/Ahna.app/Contents/Info.plist
cp Bundle/Ahna.icns dist/Ahna.app/Contents/Resources/Ahna.icns
# 폴더 이름은 영문(Ahna.app)이어야 공유 확장이 실행됩니다. Finder에는 "아나"로 보입니다.
for lang in ko en Base; do mkdir -p "dist/Ahna.app/Contents/Resources/$lang.lproj"; printf '"CFBundleDisplayName" = "아나";\n"CFBundleName" = "아나";\n' > "dist/Ahna.app/Contents/Resources/$lang.lproj/InfoPlist.strings"; done
extension=dist/Ahna.app/Contents/PlugIns/AhnaSend.appex
mkdir -p "$extension/Contents/MacOS" "$extension/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -application-extension -O -target "$arch-apple-macosx13.0" -Xlinker -e -Xlinker _NSExtensionMain Sources/Brand.swift Sources/NearbyRadio.swift Sources/AhnaClient.swift Sources/ConfigurationCache.swift Sources/ReceiveHistory.swift Sources/ReceiveFolder.swift Sources/ReceivedFileStore.swift Sources/PhotoLibrarySaver.swift Sources/ConnectionStatusBadge.swift ShareExtension/*.swift -o "build/Share-$arch"
done
lipo -create build/Share-arm64 build/Share-x86_64 -output "$extension/Contents/MacOS/AhnaShare"
cp Bundle/Ahna.icns "$extension/Contents/Resources/Ahna.icns"
cp ShareExtension/Info.plist "$extension/Contents/Info.plist"
codesign --force --sign - --timestamp=none --entitlements ShareExtension/entitlements.plist "$extension"
cp -R Backend dist/Ahna.app/Contents/Resources/
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    chmod 755 "$binary"
    codesign --force --sign - --timestamp=none "$binary"
  fi
done < <(find dist/Ahna.app/Contents/Resources/Backend -type f -print0)
codesign --force --sign - --timestamp=none dist/Ahna.app
codesign --verify --deep --strict dist/Ahna.app
