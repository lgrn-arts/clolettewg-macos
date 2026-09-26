#!/bin/sh
# build-core.sh — rebuild the awgd Go daemon.
#
# Default: download Go 1.10.8 (linux/amd64) into /tmp and cross-compile the
# darwin/amd64 binary — works on any Linux box with internet access.
#
#   GO_ON_MAC=1 ./build-core.sh     # build ON a Mac with the system Go 1.10
#   SKIP_DL=1 ./build-core.sh       # use an existing /tmp/go toolchain
#
# Output: bin/awgd.darwin-amd64 (+ .sha256)
set -e
cd "$(dirname "$0")"

GO_VERSION=1.10.8
ROOT="$PWD"
SRC="$ROOT/go-core"
OUT="$ROOT/bin/awgd.darwin-amd64"

if [ "$(uname -s)" = "Darwin" ] || [ "$GO_ON_MAC" = "1" ]; then
    if ! command -v go >/dev/null; then
        echo "Go 1.10.x is required (https://dl.google.com/go/go1.10.8.darwin-amd64.tar.gz)" >&2
        exit 1
    fi
    case "$(go version)" in
        *go1.10*) ;;
        *) echo "WARNING: $(go version) is not 1.10.x; the tree may not build." >&2 ;;
    esac
    GO=go
else
    if [ ! -x "/tmp/go/bin/go" ] || [ "$SKIP_DL" != "1" ]; then
        echo "== downloading go$GO_VERSION (linux/amd64) =="
        rm -rf /tmp/go /tmp/go.tgz
        curl -fsSL -o /tmp/go.tgz "https://dl.google.com/go/go$GO_VERSION.linux-amd64.tar.gz"
        tar -C /tmp -xzf /tmp/go.tgz
    fi
    GO=/tmp/go/bin/go
fi

echo "== building awgd (darwin/amd64, CGO off) =="
export GOPATH="$SRC"
export GO111MODULE=off
export PATH="/tmp/go/bin:$PATH"
cd "$SRC/src/awg"

echo "== tests =="
"$GO" test ./device/ ./awgd/ ./tai64n/ ./replay/ ./ratelimiter/

mkdir -p "$ROOT/bin"
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 \
    "$GO" build -ldflags "-s -w" -o "$OUT" ./awgd

echo "== smoke (host arch build) =="
GOOS=$(uname -s | tr '[:upper:]' '[:lower:]') GOARCH=amd64 CGO_ENABLED=0 \
    "$GO" build -o /tmp/awgd-smoke ./awgd || true
if [ -x /tmp/awgd-smoke ]; then /tmp/awgd-smoke -version; fi

shasum -a 256 "$OUT" > "$OUT.sha256" 2>/dev/null || sha256sum "$OUT" > "$OUT.sha256"
echo "== done: $OUT =="
cat "$OUT.sha256"
