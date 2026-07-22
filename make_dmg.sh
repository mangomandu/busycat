#!/bin/bash
# Builds a drag-to-Applications DMG for BusyCat.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 022
cd "$(dirname "$0")"

APP_NAME="BusyCat"
APP_BUNDLE="$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG_NAME="$APP_NAME-$VERSION-macOS.dmg"
STAGE_ROOT=".build/dmg"
STAGE_DIR="$STAGE_ROOT/$APP_NAME-$VERSION"
VOLUME_NAME="$APP_NAME $VERSION"
APPLICATIONS_LINK="Applications"
TEMP_DMG="$STAGE_ROOT/$APP_NAME-$VERSION-rw.dmg"
PENDING_DMG="$STAGE_ROOT/$APP_NAME-$VERSION-pending.dmg"
BACKGROUND_NAME="background.png"
MOUNT_DIR=""
DEV_NAME=""
LOCAL_PACKAGE=false

case "${1:-}" in
    "") ;;
    --local) LOCAL_PACKAGE=true ;;
    *)
        echo "Usage: $0 [--local]" >&2
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--local]" >&2
    exit 2
fi

if [ -z "$VERSION" ]; then
    echo "Could not read app version from Info.plist" >&2
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || [[ "$VERSION" =~ (^|\.)0[0-9] ]]; then
    echo "Invalid release version: $VERSION" >&2
    exit 1
fi

if ! $LOCAL_PACKAGE; then
    if [ -z "${BUSYCAT_SIGN_IDENTITY:-}" ] || [ "$BUSYCAT_SIGN_IDENTITY" = "-" ]; then
        echo "Official DMGs require BUSYCAT_SIGN_IDENTITY with a Developer ID Application identity." >&2
        echo "Use --local only for an ad-hoc local package." >&2
        exit 1
    fi
    if [ -z "${BUSYCAT_NOTARY_PROFILE:-}" ]; then
        echo "Official DMGs require BUSYCAT_NOTARY_PROFILE for xcrun notarytool." >&2
        exit 1
    fi
fi

./tools/check_release_consistency.sh
./make_app.sh
codesign --verify --deep --strict "$APP_BUNDLE"

if ! $LOCAL_PACKAGE; then
    signing_details="$(LC_ALL=C codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
    if ! grep -Fq "Authority=Developer ID Application:" <<<"$signing_details"; then
        echo "Official DMGs require a Developer ID Application signature." >&2
        exit 1
    fi
fi

if ! lipo "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -verify_arch arm64; then
    echo "BusyCat releases must contain an arm64 binary." >&2
    exit 1
fi

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

rm -f "$TEMP_DMG" "$PENDING_DMG"

detach_writable_dmg() {
    if [ -n "$DEV_NAME" ]; then
        local hdi_info
        hdi_info="$(hdiutil info 2>/dev/null || true)"
        if [[ "$hdi_info" != *"$DEV_NAME"* ]] || { [ -n "$MOUNT_DIR" ] && [[ "$hdi_info" != *"$MOUNT_DIR"* ]]; }; then
            return 1
        fi
        for _ in 1 2 3 4 5; do
            if hdiutil detach "$DEV_NAME" -quiet; then
                DEV_NAME=""
                MOUNT_DIR=""
                return 0
            fi
            sleep 1
        done
        if hdiutil detach "$DEV_NAME" -force -quiet; then
            DEV_NAME=""
            MOUNT_DIR=""
            return 0
        fi
        return 1
    fi
}

cleanup() {
    detach_writable_dmg || true
    rm -f "$TEMP_DMG" "$PENDING_DMG"
}
trap cleanup EXIT

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
    set targetWindow to container window of dmgFolder
    tell targetWindow
        set current view to icon view
        set toolbar visible to false
        set statusbar visible to false
        set pathbar visible to false
        set bounds to {180, 120, 840, 560}
    end tell

    set viewOptions to the icon view options of targetWindow
    tell viewOptions
        set arrangement to not arranged
        set icon size to 112
        set text size to 13
        set background picture to backgroundImage
    end tell

    set position of item "$APP_BUNDLE" of targetWindow to {170, 235}
    set position of item "$APPLICATIONS_LINK" of targetWindow to {490, 235}

    set extension hidden of item "$APP_BUNDLE" of targetWindow to true

    close targetWindow
    delay 1
    open dmgFolder
    delay 1
    set targetWindow to container window of dmgFolder
    tell targetWindow
        set current view to icon view
        set toolbar visible to false
        set statusbar visible to false
        set pathbar visible to false
        set bounds to {180, 120, 840, 560}
    end tell
    set viewOptions to the icon view options of targetWindow
    tell viewOptions
        set arrangement to not arranged
        set icon size to 112
        set text size to 13
        set background picture to backgroundImage
    end tell
    set position of item "$APP_BUNDLE" of targetWindow to {170, 235}
    set position of item "$APPLICATIONS_LINK" of targetWindow to {490, 235}
    update dmgFolder without registering applications
    delay 3
end tell
APPLESCRIPT

sync
detach_writable_dmg

hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$PENDING_DMG" >/dev/null

rm -f "$TEMP_DMG"

if ! $LOCAL_PACKAGE; then
    codesign --force --timestamp --sign "$BUSYCAT_SIGN_IDENTITY" "$PENDING_DMG"
    codesign --verify --strict "$PENDING_DMG"
    xcrun notarytool submit "$PENDING_DMG" \
        --keychain-profile "$BUSYCAT_NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$PENDING_DMG"
    xcrun stapler validate "$PENDING_DMG"
    codesign --verify --strict "$PENDING_DMG"
fi

hdiutil verify "$PENDING_DMG" >/dev/null
mv -f "$PENDING_DMG" "$DMG_NAME"
trap - EXIT

echo "Built $DMG_NAME"
shasum -a 256 "$DMG_NAME"
