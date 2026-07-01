#!/usr/bin/env bash
# Builds a drag-to-Applications DMG for BusyCat.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BusyCat"
APP_BUNDLE="$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG_NAME="$APP_NAME-$VERSION-macOS.dmg"
STAGE_ROOT=".build/dmg"
STAGE_DIR="$STAGE_ROOT/$APP_NAME-$VERSION"
VOLUME_NAME="$APP_NAME $VERSION"

if [ -z "$VERSION" ]; then
    echo "Could not read app version from Info.plist" >&2
    exit 1
fi

./make_app.sh

case "$STAGE_DIR" in
    "$STAGE_ROOT"/*) ;;
    *)
        echo "Refusing to remove unexpected staging path: $STAGE_DIR" >&2
        exit 1
        ;;
esac

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_BUNDLE"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_NAME"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -format UDZO \
    -ov \
    "$DMG_NAME"

echo "Built $DMG_NAME"
shasum -a 256 "$DMG_NAME"
