#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CloletteWG.app"
MIN_OS="10.9"

[[ "$(uname -s)" == "Darwin" ]] || { echo "The app and DMG must be built on macOS" >&2; exit 1; }
CLANG="${CLANG:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
[[ -d "$SDKROOT" ]] || { echo "macOS SDK not found: $SDKROOT" >&2; exit 1; }
if [[ "${SKIP_CORE_BUILD:-0}" != "1" ]]; then
    /bin/bash "$ROOT/Scripts/build-core.sh"
fi
[[ -f "$ROOT/Binaries/clolettewgd" && -f "$ROOT/Binaries/clolettewgd-modern" ]] || {
    echo "Missing daemon binaries; run Scripts/build-core.sh" >&2
    exit 1
}

rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(
    "$ROOT/Sources/App/main.m"
    "$ROOT/Sources/App/CWGAppDelegate.m"
    "$ROOT/Sources/App/CWGConstants.m"
    "$ROOT/Sources/App/CWGDaemonClient.m"
    "$ROOT/Sources/App/CWGServiceInstaller.m"
    "$ROOT/Sources/App/CWGTunnelStore.m"
    "$ROOT/Sources/App/CWGVPNURLParser.m"
)

MACOSX_DEPLOYMENT_TARGET="$MIN_OS" "$CLANG" \
    -arch x86_64 -isysroot "$SDKROOT" -mmacosx-version-min="$MIN_OS" \
    -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    "${SOURCES[@]}" -framework Cocoa -framework Foundation -lz \
    -o "$APP/Contents/MacOS/CloletteWG"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/com.narek.clolettewg.daemon.plist" "$APP/Contents/Resources/"
cp "$ROOT/Resources/install-service.sh" "$APP/Contents/Resources/"
cp "$ROOT/Binaries/clolettewgd" "$ROOT/Binaries/clolettewgd-modern" "$APP/Contents/Resources/"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Assets/"menubar-icon-*.png "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/App-LICENSE.txt"
cp "$ROOT/Engine/LICENSE" "$APP/Contents/Resources/Engine-LICENSE.txt"
cp "$ROOT/Engine/COPYING" "$APP/Contents/Resources/Engine-COPYING.txt"
chmod 755 "$APP/Contents/MacOS/CloletteWG" "$APP/Contents/Resources/clolettewgd" \
    "$APP/Contents/Resources/clolettewgd-modern" "$APP/Contents/Resources/install-service.sh"

/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/com.narek.clolettewg.daemon.plist" >/dev/null
/bin/bash "$ROOT/Scripts/verify-binaries.sh" "$APP"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP/Contents/Resources/clolettewgd"
    codesign --force --sign - "$APP/Contents/Resources/clolettewgd-modern"
    codesign --force --sign - "$APP"
    codesign --verify --verbose=2 "$APP"
fi

if [[ "${SKIP_DMG:-0}" != "1" ]]; then
    /bin/bash "$ROOT/Scripts/package-dmg.sh"
fi
printf 'App: %s\n' "$APP"
