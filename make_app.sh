#!/usr/bin/env bash
# Builds BusyCat.app — a self-contained menu bar app (no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="BusyCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/BusyCat" "$APP/Contents/MacOS/BusyCat"
cp "Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

# `./make_app.sh --install` (or -i): update the /Applications copy and relaunch.
if [ "${1:-}" = "--install" ] || [ "${1:-}" = "-i" ]; then
    killall BusyCat 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "Installed to /Applications/$APP and relaunched."
else
    echo "Run it:        open $APP"
    echo "Install/update /Applications:  ./make_app.sh --install"
fi
