#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests/CloletteWGCoreTests"
mkdir -p "$(dirname "$OUT")"
CLANG="${CLANG:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
MACOSX_DEPLOYMENT_TARGET=10.9 "$CLANG" -arch x86_64 -isysroot "$SDKROOT" \
    -mmacosx-version-min=10.9 -fobjc-arc -O0 -g -Wall -Wextra -Werror \
    "$ROOT/Tests/CloletteWGCoreTests.m" \
    "$ROOT/Sources/App/CWGConstants.m" "$ROOT/Sources/App/CWGVPNURLParser.m" \
    -framework Foundation -lz -o "$OUT"
"$OUT" "$ROOT/Tests/Fixtures"
