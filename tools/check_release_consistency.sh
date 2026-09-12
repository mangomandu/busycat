#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ARTIFACT=""
case "${1:-}" in
  "")
    if [ "$#" -ne 0 ]; then
      echo "Usage: $0 [--artifact PATH]" >&2
      exit 2
    fi
    ;;
  --artifact)
    if [ "$#" -ne 2 ] || [ -z "$2" ]; then
      echo "Usage: $0 [--artifact PATH]" >&2
      exit 2
    fi
    # Resolve relative paths against the caller, before changing directory.
    case "$2" in
      /*) ARTIFACT="$2" ;;
      *) ARTIFACT="$PWD/$2" ;;
    esac
    ;;
  *)
    echo "Usage: $0 [--artifact PATH]" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
CASK_VERSION="$(awk -F'"' '/^[[:space:]]*version / { print $2 }' Casks/busycat.rb)"
CASK_SHA="$(awk -F'"' '/^[[:space:]]*sha256 / { print $2 }' Casks/busycat.rb)"
ASSET="BusyCat-$SHORT_VERSION-macOS.dmg"

if [[ ! "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || [[ "$SHORT_VERSION" =~ (^|\.)0[0-9] ]]; then
  echo "Invalid release version: $SHORT_VERSION" >&2
  exit 1
fi

if [[ "$SHORT_VERSION" != "$BUILD_VERSION" ]]; then
  echo "Version mismatch: CFBundleShortVersionString=$SHORT_VERSION CFBundleVersion=$BUILD_VERSION" >&2
  exit 1
fi

if [[ "$SHORT_VERSION" != "$CASK_VERSION" ]]; then
  echo "Version mismatch: Info.plist=$SHORT_VERSION Cask=$CASK_VERSION" >&2
  exit 1
fi

if [[ ! "$CASK_SHA" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Cask sha256 must be exactly 64 lowercase hexadecimal characters" >&2
  exit 1
fi

if ! grep -q 'depends_on arch: :arm64' Casks/busycat.rb; then
  echo "Cask must declare the Apple Silicon architecture requirement" >&2
  exit 1
fi

if ! grep -q 'depends_on macos: :ventura' Casks/busycat.rb; then
  echo "Cask must declare the macOS 13 Ventura requirement" >&2
  exit 1
fi

for readme in README.md README.ko.md; do
  if ! grep -Fq -- "$ASSET" "$readme"; then
    echo "$readme does not reference $ASSET" >&2
    exit 1
  fi
done

echo "Release metadata is consistent for v$SHORT_VERSION."

if [ -n "$ARTIFACT" ]; then
  if [ "${ARTIFACT##*/}" != "$ASSET" ]; then
    echo "Expected release artifact named $ASSET (not a local package or another version)." >&2
    exit 1
  fi
  if [ ! -f "$ARTIFACT" ]; then
    echo "Release artifact not found: $ARTIFACT" >&2
    exit 1
  fi
  ACTUAL_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$CASK_SHA" ]; then
    echo "Release artifact SHA-256 mismatch. Do not publish this Cask yet." >&2
    echo "Cask:   $CASK_SHA" >&2
    echo "Actual: $ACTUAL_SHA" >&2
    echo "After confirming this is the intended final DMG, update Casks/busycat.rb and rerun this check without rebuilding the DMG." >&2
    exit 1
  fi
  echo "Release artifact SHA-256 matches Casks/busycat.rb."
else
  echo "Artifact SHA-256 not checked; use --artifact PATH before publishing."
fi
