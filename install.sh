#!/bin/bash
# Builds the app and installs it into /Applications, then launches it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

pkill -f "Local Servers.app/Contents/MacOS/LocalServers" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Local Servers.app"
cp -R "$ROOT/build/Local Servers.app" /Applications/
open "/Applications/Local Servers.app"
echo "installed: /Applications/Local Servers.app — look for the server icon in the menu bar"
