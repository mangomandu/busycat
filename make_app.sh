#!/usr/bin/env bash
# Builds BusyCat.app — a self-contained menu bar app (no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="BusyCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/BusyCat" "$APP/Contents/MacOS/BusyCat"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS is happy launching it locally.
if ! codesign --force --sign - "$APP" >/dev/null 2>&1; then
    echo "Warning: ad-hoc codesign failed; built app may trigger extra macOS launch warnings." >&2
fi
echo "Built $APP"

# `./make_app.sh --install` (or -i): update the /Applications copy and relaunch.
if [ "${1:-}" = "--install" ] || [ "${1:-}" = "-i" ]; then
    killall BusyCat 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -x BusyCat >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -x BusyCat >/dev/null 2>&1; then
        echo "BusyCat did not quit; refusing to replace a running app." >&2
        exit 1
    fi
    rm -rf "/Applications/$APP"
    ditto "$APP" "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed to /Applications/$APP and relaunched."
else
    echo "Run it:        open $APP"
    echo "Install/update /Applications:  ./make_app.sh --install"
fi
