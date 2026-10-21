#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
BIN_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/.build/WispFlow.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

mkdir -p "$MACOS" "$RES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$BIN_DIR/WispFlow" "$MACOS/WispFlow"
chmod +x "$MACOS/WispFlow"

# Ad-hoc sign so TCC prompts (mic / accessibility) can bind to the bundle id
codesign --force --deep --sign - "$APP_DIR" >/dev/null

# Install CLI as `wispflow` (product is wispflow-cli to avoid case-collision with WispFlow)
cp "$BIN_DIR/wispflow-cli" "$ROOT/.build/wispflow"
chmod +x "$ROOT/.build/wispflow"

echo "Packaged: $APP_DIR"
echo "CLI:      $ROOT/.build/wispflow"
