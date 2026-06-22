#!/usr/bin/env bash
# Builds RuncatGPU.app — a self-contained menu bar app (no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="RuncatGPU.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/RuncatGPU" "$APP/Contents/MacOS/RuncatGPU"
cp "Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it:        open $APP"
echo "Install:       cp -R $APP /Applications/   (then open it once)"
