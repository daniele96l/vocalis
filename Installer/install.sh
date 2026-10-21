#!/usr/bin/env bash
# Vocalis local install — build from source and place app + CLI.
set -euo pipefail

REPO_DEFAULT="https://github.com/daniele96l/vocalis.git"
PREFIX="${VOCALIS_PREFIX:-$HOME/.local}"
APP_DIR="${VOCALIS_APP_DIR:-$HOME/Applications}"
BIN_DIR="$PREFIX/bin"

echo "==> Vocalis install"
echo "    prefix: $PREFIX"
echo "    apps:   $APP_DIR"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift toolchain required (full Xcode for source builds)." >&2
  echo "  Or install the pre-built app (no compile):" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/daniele96l/vocalis/main/Scripts/install-release.sh | bash" >&2
  exit 1
fi

# Some Command Line Tools installs (esp. newer macOS SDKs) cannot compile
# SwiftUI @State — they fail with SwiftUIMacros.StateMacro not found.
# Prefer the pre-built Release on those Macs; full Xcode always works.
DEVELOPER_DIR_RESOLVED="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVELOPER_DIR_RESOLVED" != *"/Xcode.app/"* ]] \
   && [[ "$DEVELOPER_DIR_RESOLVED" != *"/Xcode-beta.app/"* ]]; then
  echo "note: using Command Line Tools (not full Xcode)."
  echo "      If the build fails on SwiftUIMacros / @State, install the Release instead:"
  echo "      curl -fsSL https://raw.githubusercontent.com/daniele96l/vocalis/main/Scripts/install-release.sh | bash"
  echo ""
fi

# If we're already inside a vocalis checkout, build here; else clone to a temp/cache dir.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT/Package.swift" ]]; then
  SRC="$ROOT"
  echo "==> Building from $SRC"
else
  SRC="${VOCALIS_SRC:-$HOME/.cache/vocalis/src}"
  mkdir -p "$(dirname "$SRC")"
  if [[ -d "$SRC/.git" ]]; then
    echo "==> Updating $SRC to origin/main"
    git -C "$SRC" remote set-url origin "$REPO_DEFAULT" 2>/dev/null || true
    git -C "$SRC" fetch --prune origin
    git -C "$SRC" checkout -B main origin/main
  else
    echo "==> Cloning $REPO_DEFAULT → $SRC"
    git clone --branch main --single-branch "$REPO_DEFAULT" "$SRC"
  fi
fi

cd "$SRC"
echo "==> Source: $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown) ($(git -C "$SRC" log -1 --pretty=%s 2>/dev/null || true))"
chmod +x Scripts/package-app.sh Installer/install.sh Scripts/install-release.sh 2>/dev/null || true
./Scripts/package-app.sh release

# Quit any running Vocalis so TCC binds to the freshly installed copy.
pkill -x Vocalis 2>/dev/null || true
sleep 0.3

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/Vocalis.app" "$APP_DIR/WispFlow.app"
cp -R .build/Vocalis.app "$APP_DIR/Vocalis.app"
cp .build/vocalis "$BIN_DIR/vocalis"
chmod +x "$BIN_DIR/vocalis"
rm -f "$BIN_DIR/wispflow" "$BIN_DIR/WispFlow.app" 2>/dev/null || true

# Convenience: also keep a pointer so `vocalis start` finds the app
ln -sfn "$APP_DIR/Vocalis.app" "$BIN_DIR/Vocalis.app" 2>/dev/null || true

# Warn if another Vocalis.app exists (TCC grants are per-copy / code identity).
if [[ "$APP_DIR/Vocalis.app" != "/Applications/Vocalis.app" && -d /Applications/Vocalis.app ]]; then
  echo ""
  echo "Note: /Applications/Vocalis.app also exists."
  echo "      Prefer one copy. This install uses: $APP_DIR/Vocalis.app"
  echo "      Grant Mic / Accessibility / Input Monitoring for that path."
fi

echo ""
echo "==> Installed"
echo "    App: $APP_DIR/Vocalis.app"
echo "    CLI: $BIN_DIR/vocalis"
echo ""
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "Add to your shell profile:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
  echo ""
fi
echo "Next:"
echo "  vocalis setup"
echo "  vocalis start"
echo ""
echo "Then grant Microphone + Accessibility + Input Monitoring when prompted."
echo "If Vocalis is missing from Input Monitoring: click + and choose $APP_DIR/Vocalis.app."
echo "Hold Right Option to dictate (or Ctrl+Shift+Space if configured)."
