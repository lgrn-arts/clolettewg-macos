#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY_VERSION="1.10.8"
MODERN_VERSION="1.22.12"
mkdir -p "$ROOT/.build" "$ROOT/Binaries"

case "$(uname -s)" in
    Darwin) HOST_OS="darwin"; ARCHIVE_EXT="tar.gz" ;;
    Linux) HOST_OS="linux"; ARCHIVE_EXT="tar.gz" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows"; ARCHIVE_EXT="zip" ;;
    *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

ensure_go() {
    local version="$1"
    local directory="$ROOT/.build/go$version"
    local executable="$directory/go/bin/go"
    [[ -x "$executable" ]] || executable="$executable.exe"
    if [[ -x "$executable" ]]; then
        printf '%s\n' "$executable"
        return
    fi

    local archive="go$version.$HOST_OS-amd64.$ARCHIVE_EXT"
    local archive_path="$ROOT/.build/$archive"
    curl -fL --retry 2 -o "$archive_path" "https://dl.google.com/go/$archive" >&2
    curl -fL --retry 2 -o "$archive_path.sha256" "https://dl.google.com/go/$archive.sha256" >&2
    local expected actual
    expected="$(awk '{print $1}' "$archive_path.sha256")"
    if command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    else
        actual="$(sha256sum "$archive_path" | awk '{print $1}')"
    fi
    [[ "$actual" == "$expected" ]] || { echo "Go archive checksum mismatch: $archive" >&2; exit 1; }
    rm -rf "$directory"
    mkdir -p "$directory"
    case "$archive" in
        *.zip) unzip -q "$archive_path" -d "$directory" >&2 ;;
        *) tar -C "$directory" -xzf "$archive_path" >&2 ;;
    esac
    executable="$directory/go/bin/go"
    [[ -x "$executable" ]] || executable="$executable.exe"
    printf '%s\n' "$executable"
}

resolve_override() {
    local executable="$1"
    if [[ "$executable" != /* && ! "$executable" =~ ^[A-Za-z]: ]]; then
        executable="$ROOT/$executable"
    fi
    printf '%s\n' "$executable"
}

if [[ -n "${LEGACY_GO:-${GO:-}}" ]]; then
    LEGACY_BIN="$(resolve_override "${LEGACY_GO:-$GO}")"
else
    LEGACY_BIN="$(ensure_go "$LEGACY_VERSION")"
fi
if [[ -n "${MODERN_GO:-}" ]]; then
    MODERN_BIN="$(resolve_override "$MODERN_GO")"
else
    MODERN_BIN="$(ensure_go "$MODERN_VERSION")"
fi

"$LEGACY_BIN" version | grep -q 'go1\.10\.' || { echo "Go 1.10.x is required for the legacy daemon" >&2; exit 1; }
"$MODERN_BIN" version | grep -q 'go1\.22\.' || { echo "Go 1.22.x is required for the Catalina+ daemon" >&2; exit 1; }

export CGO_ENABLED=0 GOOS=darwin GOARCH=amd64
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    export GOPATH="$(cd "$ROOT/Engine" && pwd -W)"
else
    export GOPATH="$ROOT/Engine"
fi
cd "$ROOT/Engine/src/awg"
GO111MODULE=off "$LEGACY_BIN" build -ldflags '-s -w' -o "$ROOT/Binaries/clolettewgd" ./awgd
GO111MODULE=on "$MODERN_BIN" build -mod=mod -trimpath -ldflags '-s -w -buildid=' -o "$ROOT/Binaries/clolettewgd-modern" ./awgd

for binary in clolettewgd clolettewgd-modern; do
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$ROOT/Binaries/$binary" > "$ROOT/Binaries/$binary.sha256"
    else
        sha256sum "$ROOT/Binaries/$binary" > "$ROOT/Binaries/$binary.sha256"
    fi
    printf 'Built %s\n' "$ROOT/Binaries/$binary"
done
