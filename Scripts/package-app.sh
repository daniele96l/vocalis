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

# Prefer a stable local codesign identity when available so TCC entries stick across
# rebuilds. Fall back to ad-hoc. Never enable hardened runtime here without a full
# entitlement set — it breaks Microphone for unsigned/local builds.
ENTITLEMENTS="$ROOT/Resources/Vocalis.entitlements"
SIGN_ID="${VOCALIS_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Vocalis Local Codesign/{print $2; exit}')"
fi
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" --identifier "com.daniele96l.vocalis" \
    --entitlements "$ENTITLEMENTS" "$APP_DIR" >/dev/null
else
  echo "Signing ad-hoc (set VOCALIS_SIGN_IDENTITY or create 'Vocalis Local Codesign' for stable TCC)"
  codesign --force --deep --sign - --identifier "com.daniele96l.vocalis" \
    --entitlements "$ENTITLEMENTS" "$APP_DIR" >/dev/null
fi

# Install CLI as `vocalis` (product is vocalis-cli to avoid case-collision with Vocalis)
cp "$BIN_DIR/vocalis-cli" "$ROOT/.build/vocalis"
chmod +x "$ROOT/.build/vocalis"

echo "Packaged: $APP_DIR"
echo "CLI:      $ROOT/.build/vocalis"
