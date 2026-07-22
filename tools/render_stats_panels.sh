#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c debug
BIN="$ROOT/.build/debug/BusyCat"

"$BIN" --statsdump "$ROOT/docs/panel.png" -language korean
"$BIN" --statsdump "$ROOT/docs/panel-en.png" -language english

for image in "$ROOT/docs/panel.png" "$ROOT/docs/panel-en.png"; do
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight/ {print $2}')"
    if [ "$width" != "500" ] || [ "$height" != "1132" ]; then
        echo "Unexpected panel size for $image: ${width}x${height}" >&2
        exit 1
    fi
done

echo "Updated docs/panel.png and docs/panel-en.png."
