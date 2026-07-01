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
VOLUME_NAME="$APP_NAME $VERSION Installer"
APPLICATIONS_LINK="Applications"
TEMP_DMG="$STAGE_ROOT/$APP_NAME-$VERSION-rw.dmg"
BACKGROUND_NAME="background.png"
MOUNT_DIR=""
DEV_NAME=""

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
swift tools/render_dmg_background.swift "$STAGE_ROOT/$BACKGROUND_NAME"
IMAGE_SIZE_MB="$(du -sm "$STAGE_DIR" | awk '{print $1 + 32}')"

rm -f "$DMG_NAME" "$TEMP_DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -size "${IMAGE_SIZE_MB}m" \
    -fs HFS+ \
    -ov \
    "$TEMP_DMG"

MOUNT_INFO="$(hdiutil attach "$TEMP_DMG" \
    -mountrandom /Volumes \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse)"
DEV_NAME="$(printf '%s\n' "$MOUNT_INFO" | awk '/\/Volumes\// {print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_INFO" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"

if [ -z "$DEV_NAME" ] || [ -z "$MOUNT_DIR" ]; then
    echo "Could not mount writable DMG" >&2
    exit 1
fi

detach_writable_dmg() {
    if [ -n "$DEV_NAME" ] && hdiutil info | grep -q "$DEV_NAME"; then
        for _ in 1 2 3 4 5; do
            if hdiutil detach "$DEV_NAME" -quiet; then
                return 0
            fi
            sleep 1
        done
        hdiutil detach "$DEV_NAME" -force -quiet
    fi
}

cleanup() {
    detach_writable_dmg || true
}
trap cleanup EXIT

ditto "$STAGE_DIR/$APP_BUNDLE" "$MOUNT_DIR/$APP_BUNDLE"
mkdir -p "$MOUNT_DIR/.background"
ditto "$STAGE_ROOT/$BACKGROUND_NAME" "$MOUNT_DIR/.background/$BACKGROUND_NAME"

osascript <<APPLESCRIPT
tell application "Finder"
    set applicationsFolder to folder "Applications" of startup disk
    set dmgFolder to POSIX file "$MOUNT_DIR" as alias
    set backgroundImage to POSIX file "$MOUNT_DIR/.background/$BACKGROUND_NAME" as alias
    make new alias file at dmgFolder to applicationsFolder with properties {name:"$APPLICATIONS_LINK"}

    activate
    open dmgFolder
    delay 1
    set targetWindow to Finder window 1
    tell targetWindow
        set current view to icon view
        set toolbar visible to false
        set statusbar visible to false
        set bounds to {180, 90, 700, 830}
    end tell

    set viewOptions to the icon view options of targetWindow
    tell viewOptions
        set arrangement to not arranged
        set icon size to 96
        set text size to 14
        set background picture to backgroundImage
    end tell

    set position of item "$APP_BUNDLE" of targetWindow to {260, 112}
    set position of item "$APPLICATIONS_LINK" of targetWindow to {260, 502}

    set extension hidden of item "$APP_BUNDLE" of targetWindow to true

    close targetWindow
    open dmgFolder
    delay 1
    set targetWindow to Finder window 1
    tell targetWindow
        set current view to icon view
        set statusbar visible to false
        set bounds to {180, 90, 700, 830}
    end tell
    set viewOptions to the icon view options of targetWindow
    tell viewOptions
        set arrangement to not arranged
        set icon size to 96
        set text size to 14
        set background picture to backgroundImage
    end tell
    delay 3
end tell
APPLESCRIPT

sync
detach_writable_dmg
trap - EXIT

hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_NAME" >/dev/null

rm -f "$TEMP_DMG"

echo "Built $DMG_NAME"
shasum -a 256 "$DMG_NAME"
