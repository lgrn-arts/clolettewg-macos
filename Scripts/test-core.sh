#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="${MODERN_GO:-${GO:-$ROOT/.build/go1.22.12/go/bin/go}}"
if [[ "$GO_BIN" != /* && ! "$GO_BIN" =~ ^[A-Za-z]: ]]; then
    GO_BIN="$ROOT/$GO_BIN"
fi
[[ -x "$GO_BIN" ]] || GO_BIN="$GO_BIN.exe"
[[ -x "$GO_BIN" ]] || { echo "Run Scripts/build-core.sh first or set MODERN_GO to Go 1.22.x" >&2; exit 1; }
export GO111MODULE=on CGO_ENABLED=0
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
    export GOPATH="$(cd "$ROOT/Engine" && pwd -W)"
else
    export GOPATH="$ROOT/Engine"
fi
cd "$ROOT/Engine/src/awg"
"$GO_BIN" test -mod=mod ./device/ ./awgd/ ./tai64n/ ./replay/ ./ratelimiter/
