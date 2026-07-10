#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
CASK_VERSION="$(ruby -ne 'puts $1 if $_ =~ /^\s*version "([^"]+)"/' Casks/busycat.rb)"
ASSET="BusyCat-$SHORT_VERSION-macOS.dmg"

if [[ "$SHORT_VERSION" != "$BUILD_VERSION" ]]; then
  echo "Version mismatch: CFBundleShortVersionString=$SHORT_VERSION CFBundleVersion=$BUILD_VERSION" >&2
  exit 1
fi

if [[ "$SHORT_VERSION" != "$CASK_VERSION" ]]; then
  echo "Version mismatch: Info.plist=$SHORT_VERSION Cask=$CASK_VERSION" >&2
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
  if ! grep -q "$ASSET" "$readme"; then
    echo "$readme does not reference $ASSET" >&2
    exit 1
  fi
done

echo "Release metadata is consistent for v$SHORT_VERSION."
