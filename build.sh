#!/bin/bash
# Compiles the menu bar app into build/Local Servers.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Local Servers.app"
MIN_MACOS="13.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

SOURCES=("$ROOT"/Sources/LocalServers/*.swift)
OBJ="$ROOT/build/obj"
mkdir -p "$OBJ"

ARCHS=()
for arch in arm64 x86_64; do
    if swiftc -O -swift-version 5 -target "${arch}-apple-macos${MIN_MACOS}" \
        -o "$OBJ/LocalServers-$arch" "${SOURCES[@]}" 2>"$OBJ/$arch.log"; then
        ARCHS+=("$OBJ/LocalServers-$arch")
    else
        echo "note: skipping $arch slice"
        sed 's/^/    /' "$OBJ/$arch.log" | head -20
    fi
done

if [ ${#ARCHS[@]} -eq 0 ]; then
    echo "build failed"; exit 1
fi

lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/LocalServers"

# --options runtime turns on the hardened runtime, which blocks code injection
# into this process (DYLD_INSERT_LIBRARIES, unsigned dylibs) — worth having even
# with an ad-hoc signature, since the app is long-lived and can be a login item.
# A signing failure must fail the build: release.sh publishes exactly this bundle.
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/LocalServers"
