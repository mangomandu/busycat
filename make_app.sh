#!/usr/bin/env bash
# Builds BusyCat.app — a self-contained menu bar app (no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="BusyCat.app"
SIGN_IDENTITY="${BUSYCAT_SIGN_IDENTITY:--}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/BusyCat" "$APP/Contents/MacOS/BusyCat"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Local builds default to ad-hoc signing. Official packages pass a Developer ID
# identity through BUSYCAT_SIGN_IDENTITY and receive hardened runtime + timestamp.
codesign_args=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

# `./make_app.sh --install` (or -i): update the /Applications copy and relaunch.
if [ "${1:-}" = "--install" ] || [ "${1:-}" = "-i" ]; then
    destination="/Applications/$APP"
    install_stage="$(mktemp -d "/Applications/.busycat-install.XXXXXX")"
    install_backup="$(mktemp -d "/Applications/.busycat-backup.XXXXXX")"

    cleanup_install() {
        if [ -e "$install_backup/$APP" ] && [ ! -e "$destination" ]; then
            mv "$install_backup/$APP" "$destination" || true
        fi
        rm -rf "$install_stage" "$install_backup"
    }
    trap cleanup_install EXIT

    # Finish and validate the new copy before stopping or moving the installed app.
    ditto "$APP" "$install_stage/$APP"
    codesign --verify --deep --strict "$install_stage/$APP"

    killall BusyCat 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -x BusyCat >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -x BusyCat >/dev/null 2>&1; then
        echo "BusyCat did not quit; refusing to replace a running app." >&2
        exit 1
    fi
    if [ -e "$destination" ]; then
        mv "$destination" "$install_backup/$APP"
    fi
    if ! mv "$install_stage/$APP" "$destination"; then
        echo "Could not install the new app; restoring the previous copy." >&2
        exit 1
    fi
    rm -rf "$install_stage" "$install_backup"
    trap - EXIT
    open "$destination"
    echo "Installed to $destination and relaunched."
else
    echo "Run it:        open $APP"
    echo "Install/update /Applications:  ./make_app.sh --install"
fi
