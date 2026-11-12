#!/bin/bash
# Builds build/Feather.app.   ./build.sh             build only
#                             ./build.sh run         build and launch
#                             ./build.sh translator  also build the translation helper (MLX; needs
#                                                    Xcode and its Metal toolchain), then the app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Feather"
APP=build/Feather.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Feather"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The translation helper runs the model in its own process. Built separately: MLX's Metal
# shaders only build with xcodebuild. Without it the app works, and translation says so.
HELPER=Translator/.build-xcode/Build/Products/Release
if [[ "${1:-}" == "translator" ]]; then
    (cd Translator && xcodebuild -scheme FeatherTranslator -destination 'platform=macOS,arch=arm64' -configuration Release \
        -derivedDataPath .build-xcode -skipPackagePluginValidation -skipMacroValidation build -quiet)
fi
if [[ -x "$HELPER/FeatherTranslator" ]]; then
    mkdir -p "$APP/Contents/Helpers"
    cp "$HELPER/FeatherTranslator" "$APP/Contents/Helpers/"
    for bundle in "$HELPER"/*.bundle; do [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Helpers/"; done
    # Nested code is signed inside out: the resource bundles count as nested code too.
    for nested in "$APP/Contents/Helpers"/*.bundle "$APP/Contents/Helpers/FeatherTranslator"; do
        codesign --force --sign - "$nested" >/dev/null 2>&1
    done
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "run" ]]; then open "$APP"; fi
