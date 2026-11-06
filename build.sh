#!/bin/bash
# Builds build/Feather.app.   ./build.sh        build only
#                             ./build.sh run    build and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Feather"
APP=build/Feather.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Feather"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "run" ]]; then open "$APP"; fi
