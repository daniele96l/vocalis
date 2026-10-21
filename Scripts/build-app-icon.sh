#!/usr/bin/env bash
# Build Resources/AppIcon.icns from Resources/AppIcon-source.png
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
SRC="$RES/AppIcon-source.png"
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

sips -z 1024 1024 "$SRC" --out "$RES/AppIcon-1024.png" >/dev/null
rm -rf "$RES/AppIcon.iconset"
mkdir "$RES/AppIcon.iconset"
sips -z 16 16     "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32     "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/diana.k@example.org" >/dev/null
sips -z 32 32     "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64     "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/ivan.p@example.net" >/dev/null
sips -z 128 128   "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256   "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/wendy.h@example.net" >/dev/null
sips -z 256 256   "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512   "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/wendy.h@example.net" >/dev/null
sips -z 512 512   "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$RES/AppIcon-1024.png" --out "$RES/AppIcon.iconset/walt.e@example.net" >/dev/null
iconutil -c icns "$RES/AppIcon.iconset" -o "$RES/AppIcon.icns"
echo "Wrote $RES/AppIcon.icns"
