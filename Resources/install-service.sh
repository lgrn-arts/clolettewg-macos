#!/bin/sh
set -eu

ACTION="${1:-}"
RESOURCES="${2:-}"
APP_VERSION="${3:-}"
SERVICE_LABEL="${4:-}"
EXPECTED_RESOURCES="/Applications/CloletteWG.app/Contents/Resources"
DAEMON_SOURCE="$RESOURCES/clolettewgd"
PLIST_SOURCE="$RESOURCES/com.clolettewg.daemon.plist"
DAEMON_DEST="/Library/PrivilegedHelperTools/com.clolettewg.daemon"
PLIST_DEST="/Library/LaunchDaemons/com.clolettewg.daemon.plist"
STATE_DIR="/Library/Application Support/CloletteWG"
LAUNCHD_LOG="$STATE_DIR/launchd.log"
SOCKET="/var/run/clolette-wg.sock"

fail() {
    printf 'CloletteWG setup: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "installer must run as root"
[ "$RESOURCES" = "$EXPECTED_RESOURCES" ] || fail "install CloletteWG at /Applications/CloletteWG.app first"
[ "$SERVICE_LABEL" = "com.clolettewg.daemon" ] || fail "unexpected service label"
case "$APP_VERSION" in
    ''|*[!A-Za-z0-9._-]*) fail "invalid app version" ;;
esac

case "$ACTION" in
    uninstall)
        if [ -f "$PLIST_DEST" ]; then
            /bin/launchctl unload "$PLIST_DEST" 2>/dev/null || true
        fi
        /bin/rm -f "$DAEMON_DEST" "$PLIST_DEST" "$SOCKET"
        /bin/rm -rf "$STATE_DIR"
        printf 'CloletteWG: ok\n'
        exit 0
        ;;
    install)
        ;;
    *)
        fail "usage: install-service.sh install|uninstall resources version label"
        ;;
esac

MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
if /usr/bin/awk -F. '{ exit !(($1 > 10) || ($1 == 10 && $2 >= 15)) }' <<EOF
$MACOS_VERSION
EOF
then
    DAEMON_SOURCE="$RESOURCES/clolettewgd-modern"
fi

[ -f "$DAEMON_SOURCE" ] && [ -x "$DAEMON_SOURCE" ] || fail "bundled daemon is missing or not executable: $DAEMON_SOURCE"
[ -f "$PLIST_SOURCE" ] || fail "bundled launchd plist is missing"
/usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null || fail "invalid bundled launchd plist"

/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
/usr/bin/install -d -o root -g admin -m 750 "$STATE_DIR"
/usr/bin/install -o root -g wheel -m 755 "$DAEMON_SOURCE" "$DAEMON_DEST.tmp"
/bin/mv -f "$DAEMON_DEST.tmp" "$DAEMON_DEST"
/usr/bin/install -o root -g wheel -m 644 "$PLIST_SOURCE" "$PLIST_DEST.tmp"
/bin/mv -f "$PLIST_DEST.tmp" "$PLIST_DEST"
/usr/bin/xattr -d com.apple.quarantine "$DAEMON_DEST" 2>/dev/null || true

if ! VERSION_OUTPUT="$("$DAEMON_DEST" -version 2>&1)"; then
    fail "installed daemon cannot start on macOS $MACOS_VERSION: $VERSION_OUTPUT"
fi

LEGACY_PLIST="/Library/LaunchDaemons/com.narek.clolettewg.daemon.plist"
LEGACY_DAEMON="/Library/PrivilegedHelperTools/com.narek.clolettewg.daemon"
if [ -f "$LEGACY_PLIST" ]; then
    /bin/launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
fi
/bin/rm -f "$LEGACY_PLIST" "$LEGACY_DAEMON"
if [ -f "$PLIST_DEST" ]; then
    /bin/launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi
/bin/rm -f "$SOCKET" "$LAUNCHD_LOG"
/bin/launchctl load -w "$PLIST_DEST" || fail "launchctl load failed; see $LAUNCHD_LOG"

attempt=0
while [ "$attempt" -lt 30 ]; do
    [ -S "$SOCKET" ] && break
    attempt=$((attempt + 1))
    /bin/sleep 0.5
done
if [ ! -S "$SOCKET" ]; then
    /bin/launchctl list "$SERVICE_LABEL" >&2 2>/dev/null || true
    if [ -f "$LAUNCHD_LOG" ]; then
        printf '%s\n' '--- launchd.log ---' >&2
        /usr/bin/tail -n 60 "$LAUNCHD_LOG" >&2
    fi
    fail "daemon did not open $SOCKET on macOS $MACOS_VERSION"
fi

[ -f "$STATE_DIR/token" ] || fail "daemon did not create $STATE_DIR/token"
/usr/sbin/chown root:admin "$STATE_DIR" "$STATE_DIR/token" "$SOCKET" || fail "could not grant the admin group access to the service"
/bin/chmod 750 "$STATE_DIR"
/bin/chmod 640 "$STATE_DIR/token"
/bin/chmod 660 "$SOCKET"
[ "$(/usr/bin/stat -f '%g:%Lp' "$STATE_DIR")" = "80:750" ] || fail "incorrect state directory ownership or permissions"
[ "$(/usr/bin/stat -f '%g:%Lp' "$STATE_DIR/token")" = "80:640" ] || fail "incorrect token ownership or permissions"

printf '%s\n' "$APP_VERSION" > "$STATE_DIR/VERSION"
/usr/sbin/chown root:wheel "$STATE_DIR/VERSION"
/bin/chmod 644 "$STATE_DIR/VERSION"
printf 'CloletteWG: ok\n'
