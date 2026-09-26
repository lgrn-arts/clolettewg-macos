#!/bin/sh
# make-pkg.sh — wrap the built Nanami.app in a flat installer package.
#
#   ./make-pkg.sh                            -> Nanami-1.4.pkg, right here
#   ./make-pkg.sh --sign "Developer ID ..."  -> same, but signed
#
# Needs pkgbuild from the Xcode command line tools.
#
# The payload is only Nanami.app in /Applications. Everything privileged gets
# created the first time the app runs, by HelperInstaller.m:
#
#   /Library/LaunchDaemons/ru.awg.mavericks.awgd.plist
#   /Library/Application Support/AwgMavericks/{token,launchd.log,awgd.log}
#   /var/run/awg-client.sock              (the daemon makes this, not us)
#
# So there's no LaunchDaemons payload, no pre/post-install scripts and no
# installer plugins. That's on purpose. A flat package with no scripts is the
# most robust thing Installer.app handles, and uninstalling is then just
# dragging the app to the Trash plus the app's own Uninstall button, which
# does unload the daemon.
#
# --ownership preserve keeps whatever the build produced. Building as a normal
# user means the app installs owned by that user, which is fine for personal
# use. For wider distribution, build and package as root, or re-chown the
# payload, so /Applications ends up root:admin like Apple's own installers.

set -e

cd "$(dirname "$0")"

APP_NAME="Nanami"
BUNDLE="$APP_NAME.app"
IDENT="ru.awg.mavericks.nanami"

SIGN_IDENTITY=""
case "${1:-}" in
    --sign) SIGN_IDENTITY="${2:?--sign needs a certificate identity}"
            shift 2 ;;
    --sign=*) SIGN_IDENTITY="${1#--sign=}" ; shift ;;
esac

# ---------------------------------------------------------------- checks ---
if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE not found — run 'make' first." >&2
    exit 1
fi

if [ ! -x "$BUNDLE/Contents/MacOS/$APP_NAME" ]; then
    echo "error: $BUNDLE has no executable — the build is incomplete." >&2
    exit 1
fi

if [ ! -f "$BUNDLE/Contents/Resources/awgd" ]; then
    echo "error: awgd is not bundled — the app would install but never connect." >&2
    exit 1
fi

if ! command -v pkgbuild >/dev/null 2>&1; then
    echo "error: pkgbuild not found. Install the Xcode command line tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
fi

# ---------------------------------------------------------------- version --
# sed rather than PlistBuddy, which needs full Xcode and not just the
# command line tools.
VERSION=$(sed -n '/<key>CFBundleShortVersionString<\/key>/{
    n
    s/.*<string>\(.*\)<\/string>.*/\1/p
}' Info.plist)

if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from Info.plist." >&2
    exit 1
fi

OUT="$APP_NAME-$VERSION.pkg"

# --------------------------------------------------------------- payload ---
# Stage into a clean dir so --root can't sweep up anything else.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/nanami-pkg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

mkdir -p "$STAGE/payload"
cp -R "$BUNDLE" "$STAGE/payload/"

# No .DS_Store in the payload.
find "$STAGE/payload" -name '.DS_Store' -delete
find "$STAGE/payload" -name '__MACOSX'  -type d -exec rm -rf {} + 2>/dev/null || true

echo "== packaging =="
echo "   payload    $APP_NAME.app"
echo "   version    $VERSION"
echo "   identifier $IDENT"
echo "   install to /Applications"

rm -f "$OUT"

pkgbuild \
    --identifier   "$IDENT" \
    --version      "$VERSION" \
    --install-location /Applications \
    --ownership    preserve \
    --root         "$STAGE/payload" \
    "$OUT"

# ------------------------------------------------------------------ sign ---
# Optional. 10.9's Gatekeeper doesn't block unsigned packages, so this only
# matters if you're distributing to newer systems too.
if [ -n "$SIGN_IDENTITY" ]; then
    if ! command -v productsign >/dev/null 2>&1; then
        echo "warning: productsign not found, leaving the package unsigned." >&2
    else
        echo "== signing =="
        mv "$OUT" "$OUT.unsigned"
        productsign --sign "$SIGN_IDENTITY" "$OUT.unsigned" "$OUT"
        rm -f "$OUT.unsigned"
    fi
fi

# ----------------------------------------------------------------- done ----
echo "== done =="
echo "   $(pwd)/$OUT"
echo "   $(du -h "$OUT" | cut -f1)"
echo
echo "   Verify the payload before shipping:"
echo "     pkgutil --payload-files $OUT | head -20"
echo "     installer -pkg $OUT -target / -verbose   # dry-run: see below"
echo
if [ -z "$SIGN_IDENTITY" ]; then
    echo "   Unsigned. To sign: ./make-pkg.sh --sign \"Developer ID Installer: ...\""
fi
