#!/usr/bin/env bash
# Push licenses.json → Cloudflare Worker secret LICENSE_CODES.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="${VOCALIS_LICENSES_FILE:-$ROOT/licenses.json}"
WORKER_DIR="$ROOT/workers/vocalis-proxy"

if [[ ! -f "$LEDGER" ]]; then
  echo "error: missing $LEDGER — run Scripts/mint-licenses.sh first" >&2
  exit 1
fi

CODES="$(python3 - "$LEDGER" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
items = data.get("licenses", data if isinstance(data, list) else [])
codes = [e["code"] for e in items if isinstance(e, dict) and e.get("code")]
if not codes:
    raise SystemExit("no codes in ledger")
print(",".join(codes), end="")
print(f"\n# count={len(codes)}", file=sys.stderr)
PY
)"

COUNT="$(python3 -c "import json; d=json.load(open('$LEDGER')); print(len(d.get('licenses',[])))")"
echo "==> Uploading $COUNT code(s) to Worker secret LICENSE_CODES…"
printf '%s' "$CODES" | (cd "$WORKER_DIR" && npx wrangler secret put LICENSE_CODES)
echo "==> Done. New codes are live immediately (no app update needed for the list)."
