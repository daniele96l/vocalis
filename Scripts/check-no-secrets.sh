#!/usr/bin/env bash
# Fail if tracked/staged content looks like a real OpenAI key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATTERN='sk-(proj-)?[A-Za-z0-9_-]{20,}'

fail=0
# Staged + HEAD + working tree tracked files
files=$(git ls-files -z | tr '\0' '\n')
if [[ -n "${files}" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    if rg -n --no-messages -e "$PATTERN" -- "$f" >/tmp/vocalis-secret-hits.txt 2>/dev/null; then
      # Allow documentation placeholders only
      if rg -n -e 'sk-\.\.\.|sk-your|CHANGE_ME|example' -- "$f" >/dev/null 2>&1; then
        # still fail if a long real-looking key exists alongside
        if rg -n -e 'sk-proj-[A-Za-z0-9_-]{30,}|sk-[A-Za-z0-9]{40,}' -- "$f" >/tmp/vocalis-secret-hits.txt 2>/dev/null; then
          echo "ERROR: possible secret in tracked file: $f" >&2
          cat /tmp/vocalis-secret-hits.txt >&2 || true
          fail=1
        fi
      else
        echo "ERROR: possible secret in tracked file: $f" >&2
        cat /tmp/vocalis-secret-hits.txt >&2 || true
        fail=1
      fi
    fi
  done <<< "$files"
fi

# Ensure local config / license ledger is never staged
if git diff --cached --name-only | rg -n 'config\.toml|usage\.jsonl|\.env|licenses\.json' >/dev/null 2>&1; then
  echo "ERROR: refusing to commit config.toml / usage.jsonl / .env / licenses.json" >&2
  fail=1
fi

# DMG / app binary must not embed local key if present
if [[ -f "$HOME/.config/vocalis/config.toml" ]]; then
  key=$(python3 - <<'PY'
from pathlib import Path
import re
t = Path.home().joinpath(".config/vocalis/config.toml").read_text(encoding="utf-8", errors="ignore")
m = re.search(r'openai_api_key\s*=\s*"([^"]+)"', t)
print(m.group(1) if m and m.group(1) else "")
PY
)
  if [[ -n "$key" && ${#key} -gt 12 ]]; then
    for bin in \
      "$ROOT/dist/Vocalis.dmg" \
      "$ROOT/dist/Vocalis.app.zip" \
      "$ROOT/.build/Vocalis.app/Contents/MacOS/Vocalis" \
      "$ROOT/.build/release/Vocalis"
    do
      if [[ -f "$bin" ]] && grep -a -F -q -- "$key" "$bin" 2>/dev/null; then
        echo "ERROR: local API key found inside $bin" >&2
        fail=1
      fi
    done
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Secret check FAILED — keys must stay in ~/.config/vocalis only (never GitHub)." >&2
  exit 1
fi
echo "Secret check OK (no keys for GitHub)."
