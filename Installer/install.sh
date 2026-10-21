#!/usr/bin/env bash
# WispFlow local install — build from source and place app + CLI.
set -euo pipefail

REPO_DEFAULT="https://github.com/daniele96l/wispflow.git"
PREFIX="${WISPFLOW_PREFIX:-$HOME/.local}"
APP_DIR="${WISPFLOW_APP_DIR:-$HOME/Applications}"
BIN_DIR="$PREFIX/bin"

echo "==> WispFlow install"
echo "    prefix: $PREFIX"
echo "    apps:   $APP_DIR"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift toolchain required (Xcode or Command Line Tools)" >&2
  exit 1
fi

# If we're already inside a wispflow checkout, build here; else clone to a temp/cache dir.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT/Package.swift" ]]; then
  SRC="$ROOT"
  echo "==> Building from $SRC"
else
  SRC="${WISPFLOW_SRC:-$HOME/.cache/wispflow/src}"
  mkdir -p "$(dirname "$SRC")"
  if [[ -d "$SRC/.git" ]]; then
    echo "==> Updating $SRC"
    git -C "$SRC" pull --ff-only || true
  else
    echo "==> Cloning $REPO_DEFAULT → $SRC"
    git clone "$REPO_DEFAULT" "$SRC"
  fi
fi

cd "$SRC"
chmod +x Scripts/package-app.sh Installer/install.sh
./Scripts/package-app.sh release

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/WispFlow.app"
cp -R .build/WispFlow.app "$APP_DIR/WispFlow.app"
cp .build/wispflow "$BIN_DIR/wispflow"
chmod +x "$BIN_DIR/wispflow"

# Convenience: also keep a pointer so `wispflow start` finds the app
ln -sfn "$APP_DIR/WispFlow.app" "$BIN_DIR/WispFlow.app" 2>/dev/null || true

echo ""
echo "==> Installed"
echo "    App: $APP_DIR/WispFlow.app"
echo "    CLI: $BIN_DIR/wispflow"
echo ""
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "Add to your shell profile:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
  echo ""
fi
echo "Next:"
echo "  wispflow setup"
echo "  wispflow start"
echo ""
echo "Then grant Microphone + Accessibility when prompted."
echo "Hold Right Option to dictate (or Ctrl+Shift+Space if configured)."
