#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CloletteWG.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/CloletteWG-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"
PYTHON="${PYTHON:-python3}"
CLANG="${CLANG:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
ICONSET="$ROOT/build/VolumeIcon.iconset"

[[ -d "$APP" ]] || { echo "Build the app first" >&2; exit 1; }
command -v "$PYTHON" >/dev/null || { echo "Python 3 is required for DMG styling" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil is required for the DMG icon" >&2; exit 1; }
[[ -f "$ROOT/Assets/DiskImage.icns" ]] || {
    echo "DMG icon asset is missing" >&2
    exit 1
}
rm -rf "$STAGE" "$ICONSET" "$DMG" "$ROOT/build/dmg-background.tiff" \
    "$ROOT/build/VolumeIcon.icns" "$ROOT/build/make-volume-icon"
mkdir -p "$STAGE" "$ICONSET"
cp -R "$APP" "$STAGE/CloletteWG.app"

"$CLANG" -isysroot "$SDKROOT" -fobjc-arc -O2 \
    "$ROOT/Scripts/make-volume-icon.m" -framework Cocoa \
    -o "$ROOT/build/make-volume-icon"
for spec in \
    "16:icon_16x16" \
    "32:icon_16x16@2x" \
    "32:icon_32x32" \
    "64:icon_32x32@2x" \
    "128:icon_128x128" \
    "256:icon_128x128@2x" \
    "256:icon_256x256" \
    "512:icon_256x256@2x" \
    "512:icon_512x512" \
    "1024:icon_512x512@2x"; do
    size="${spec%%:*}"
    name="${spec#*:}"
    "$ROOT/build/make-volume-icon" \
        "$ROOT/Assets/DiskImage.icns" \
        "$ICONSET/$name.png" "$size"
done
iconutil -c icns "$ICONSET" -o "$ROOT/build/VolumeIcon.icns"

/usr/bin/sips -s format tiff -z 350 600 \
    "$ROOT/Assets/dmg-background.png" \
    --out "$ROOT/build/dmg-background.tiff" >/dev/null
/usr/bin/sed "s|__ROOT__|$ROOT|g" "$ROOT/Scripts/dmg-settings.json" > "$ROOT/build/dmg-settings.json"
PYTHONPATH="$ROOT/Scripts/vendor" "$PYTHON" -m dmgbuild \
    CloletteWG "$DMG" -s "$ROOT/build/dmg-settings.json"
printf 'DMG: %s\n' "$DMG"
