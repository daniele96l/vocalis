#!/usr/bin/env bash
# Mint friend license codes for Vocalis. Writes a local ledger (gitignored)
# and prints a comma-separated list for Cloudflare Worker secret LICENSE_CODES.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="${VOCALIS_LICENSES_FILE:-$ROOT/licenses.json}"
COUNT="${1:-10}"
NOTE="${2:-}"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "usage: $0 [count=10] [optional note]" >&2
  exit 1
fi

created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

python3 - "$LEDGER" "$COUNT" "$created_at" "$NOTE" <<'PY'
import json, os, secrets, sys

ledger_path, count_s, created_at, note = sys.argv[1:5]
count = int(count_s)

def mint():
    parts = [secrets.token_hex(2).upper() for _ in range(3)]
    return f"VOC-{parts[0]}-{parts[1]}-{parts[2]}"

existing = []
if os.path.isfile(ledger_path):
    with open(ledger_path, "r", encoding="utf-8") as f:
        data = json.load(f)
        if isinstance(data, list):
            existing = data
        elif isinstance(data, dict) and isinstance(data.get("licenses"), list):
            existing = data["licenses"]

known = {e.get("code") for e in existing if isinstance(e, dict)}
fresh = []
while len(fresh) < count:
    code = mint()
    if code in known:
        continue
    fresh.append({"code": code, "created_at": created_at, "note": note or ""})
    known.add(code)

merged = existing + fresh
with open(ledger_path, "w", encoding="utf-8") as f:
    json.dump({"licenses": merged}, f, indent=2)
    f.write("\n")

os.chmod(ledger_path, 0o600)

print(f"Minted {len(fresh)} code(s) → {ledger_path}")
print("")
print("New codes:")
for e in fresh:
    print(f"  {e['code']}")
print("")
print("All codes (paste into: wrangler secret put LICENSE_CODES):")
print(",".join(e["code"] for e in merged if e.get("code")))
PY
