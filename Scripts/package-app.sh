#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
BIN_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/.build/Vocalis.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

mkdir -p "$MACOS" "$RES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$BIN_DIR/Vocalis" "$MACOS/Vocalis"
chmod +x "$MACOS/Vocalis"

# App icon
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
elif [[ -f "$ROOT/Resources/AppIcon-source.png" ]]; then
  # Regenerate icns if missing
  "$ROOT/Scripts/build-app-icon.sh"
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Ad-hoc sign so TCC prompts (mic / accessibility) can bind to the bundle id
codesign --force --deep --sign - "$APP_DIR" >/dev/null

# Install CLI as `vocalis` (product is vocalis-cli to avoid case-collision with Vocalis)
cp "$BIN_DIR/vocalis-cli" "$ROOT/.build/vocalis"
chmod +x "$ROOT/.build/vocalis"

echo "Packaged: $APP_DIR"
echo "CLI:      $ROOT/.build/vocalis"
