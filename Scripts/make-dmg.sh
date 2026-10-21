#!/usr/bin/env bash
# Build Vocalis.app and wrap it in a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

chmod +x Scripts/package-app.sh Scripts/check-no-secrets.sh
./Scripts/package-app.sh release
./Scripts/check-no-secrets.sh

DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
DMG="$DIST/Vocalis.dmg"
APP_SRC="$ROOT/.build/Vocalis.app"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/Vocalis.app"
ln -s /Applications "$STAGE/Applications"

# Distributable DMG: always ad-hoc so other Macs don't need this machine's
# local "Vocalis Local Codesign" cert. Dev installs via package-app.sh may use
# that identity for stabler TCC on the build machine.
ENTITLEMENTS="$ROOT/Resources/Vocalis.entitlements"
codesign --force --deep --sign - --identifier "com.daniele96l.vocalis" \
  --entitlements "$ENTITLEMENTS" "$STAGE/Vocalis.app" >/dev/null


hdiutil create \
  -volname "Vocalis" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

# Also keep a zip for AirDrop-friendly sharing
ditto -c -k --keepParent "$STAGE/Vocalis.app" "$DIST/Vocalis.app.zip"

echo "DMG: $DMG"
echo "ZIP: $DIST/Vocalis.app.zip"
ls -lh "$DMG" "$DIST/Vocalis.app.zip"
