#!/usr/bin/env bash
# Run the BusyCat test suite.
#
# Why this wrapper exists: some standalone Command Line Tools releases ship
# Apple's swift-testing framework outside SwiftPM's default framework and rpath
# search paths. A plain `swift test` then fails with "no such module 'Testing'".
# This script supplies the framework and interop-library paths when present.
#
# If you have full Xcode selected (`xcode-select -p` shows .../Xcode.app), a
# plain `swift test` works and you don't need this — but this script still works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CACHE="$ROOT/.build/ModuleCache"
mkdir -p "$CACHE"
cd "$ROOT"

DEVDIR="$(xcode-select -p)"
FW="$DEVDIR/Library/Developer/Frameworks"
INTEROP="$DEVDIR/Library/Developer/usr/lib"

if [[ ! -d "$FW/Testing.framework" ]]; then
  # Full Xcode (or a layout without the standalone framework): try a plain run.
  exec env \
    CLANG_MODULE_CACHE_PATH="$CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift test "$@"
fi

exec env \
  CLANG_MODULE_CACHE_PATH="$CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
  DYLD_FRAMEWORK_PATH="$FW" \
  DYLD_LIBRARY_PATH="$INTEROP" \
  swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
