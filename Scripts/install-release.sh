#!/usr/bin/env bash
# Install the latest pre-built Vocalis from GitHub Releases.
# No Xcode / Swift / git clone required — just curl (and unzip).
set -euo pipefail

REPO="${VOCALIS_REPO:-daniele96l/vocalis}"
APP_DIR="${VOCALIS_APP_DIR:-$HOME/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Vocalis install (pre-built release)"
echo "    apps: $APP_DIR"

API="https://api.github.com/repos/${REPO}/releases/latest"
echo "==> Fetching latest release metadata…"
JSON="$(curl -fsSL "$API")"
TAG="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$JSON")"
ZIP_URL="$(python3 -c '
import json,sys
rel=json.load(sys.stdin)
for a in rel.get("assets",[]):
    if a["name"]=="Vocalis.app.zip":
        print(a["browser_download_url"]); break
' <<<"$JSON")"

if [[ -z "$ZIP_URL" ]]; then
  echo "error: Vocalis.app.zip not found on release $TAG" >&2
  exit 1
fi

echo "==> Downloading $TAG → Vocalis.app.zip"
curl -fL --progress-bar -o "$TMP/Vocalis.app.zip" "$ZIP_URL"

echo "==> Unpacking"
ditto -x -k "$TMP/Vocalis.app.zip" "$TMP/out"
if [[ ! -d "$TMP/out/Vocalis.app" ]]; then
  echo "error: zip did not contain Vocalis.app" >&2
  exit 1
fi

pkill -x Vocalis 2>/dev/null || true
sleep 0.3
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Vocalis.app"
cp -R "$TMP/out/Vocalis.app" "$APP_DIR/Vocalis.app"

# Optional CLI shim that opens the app
BIN_DIR="${VOCALIS_PREFIX:-$HOME/.local}/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/vocalis" <<EOF
#!/usr/bin/env bash
case "\${1:-start}" in
  start|open|"") open "$APP_DIR/Vocalis.app" ;;
  status) echo "Installed: $APP_DIR/Vocalis.app ($TAG)"; defaults read "$APP_DIR/Vocalis.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true ;;
  *) echo "usage: vocalis [start|status]"; exit 1 ;;
esac
EOF
chmod +x "$BIN_DIR/vocalis"

VER="$(defaults read "$APP_DIR/Vocalis.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo ""
echo "==> Installed Vocalis $VER ($TAG)"
echo "    App: $APP_DIR/Vocalis.app"
echo "    CLI: $BIN_DIR/vocalis  (vocalis start)"
echo ""
echo "First launch: right-click → Open if Gatekeeper warns."
echo "Then grant Microphone + Accessibility + Input Monitoring."
echo "Account tab: license code or your own API keys."
open "$APP_DIR/Vocalis.app" 2>/dev/null || true
