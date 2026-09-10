#!/bin/bash
# Builds the app, zips it as a release artifact and prints the cask sha256.
# Usage: ./release.sh 1.0.0
set -euo pipefail

VERSION="${1:?usage: ./release.sh <version>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"

# Keep the bundle version in step with the release tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$ROOT/Resources/Info.plist"

"$ROOT/build.sh"

rm -rf "$DIST"
mkdir -p "$DIST"
ARTIFACT="$DIST/LocalServers_${VERSION}_universal.zip"
# ditto preserves the bundle structure and code signature; plain zip does not.
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Local Servers.app" "$ARTIFACT"

echo "artifact: $ARTIFACT"
echo "sha256:   $(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
