#!/usr/bin/env bash
set -euo pipefail

APP="${1:?missing app bundle path}"
TARGETS=(
    "$APP/Contents/MacOS/CloletteWG:10.9"
    "$APP/Contents/Resources/clolettewgd:10.9"
    "$APP/Contents/Resources/clolettewgd-modern:10.15"
)

for entry in "${TARGETS[@]}"; do
    target="${entry%:*}"
    maximum="${entry##*:}"
    [[ -f "$target" && -x "$target" ]] || { echo "Missing executable: $target" >&2; exit 1; }
    file -b "$target" | grep -q 'Mach-O' || { echo "Not a Mach-O binary: $target" >&2; exit 1; }
    lipo -info "$target" | grep -q 'x86_64' || { echo "x86_64 slice missing: $target" >&2; exit 1; }
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            *) echo "External dependency $dependency in $target" >&2; exit 1 ;;
        esac
    done < <(otool -L "$target" | awk 'NR > 1 {print $1}')

    minimum=""
    if command -v vtool >/dev/null 2>&1; then
        minimum="$(vtool -show-build "$target" 2>/dev/null | awk '/minos/ {print $2; exit}' || true)"
    fi
    if [[ -z "$minimum" ]]; then
        minimum="$(otool -l "$target" | awk '
            /LC_VERSION_MIN_MACOSX/ {legacy=1; next}
            /LC_BUILD_VERSION/ {build=1; next}
            legacy && /version/ {print $2; exit}
            build && /minos/ {print $2; exit}
        ')"
    fi
    if [[ -n "$minimum" ]]; then
        major="$(printf '%s' "$minimum" | cut -d. -f1)"
        minor="$(printf '%s' "$minimum" | cut -d. -f2)"
        maximum_minor="${maximum#*.}"
        [[ "$major" -lt 10 || ( "$major" -eq 10 && "$minor" -le "$maximum_minor" ) ]] || {
            echo "Deployment target $minimum is newer than $maximum: $target" >&2
            exit 1
        }
    fi
done

if otool -L "$APP/Contents/MacOS/CloletteWG" | grep -q 'swift'; then
    echo "Unexpected Swift runtime dependency" >&2
    exit 1
fi
printf 'Verified x86_64 executables: legacy OS X 10.9, Catalina+ 10.15\n'
