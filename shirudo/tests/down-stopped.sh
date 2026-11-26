#!/usr/bin/env bash
# Test: shirudo/down.sh on a stopped shirudo-arm64 returns at once (no 180 s wait, no kill warning) and exits 0.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*"; exit 1; }
limactl shell phenix sudo docker exec phenix phenix exp list 2>/dev/null | awk -F'|' '$2 ~ /^ *shirudo-arm64 *$/ && $5 ~ /[0-9]/' | grep -q . &&
  fail "test setup: shirudo-arm64 is started; stop it first"
start=$(date +%s)
out=$("$here/down.sh" 2>&1) || fail "down.sh failed: $out"
[ $(( $(date +%s) - start )) -lt 60 ] || fail "down.sh took $(( $(date +%s) - start )) s on a stopped experiment"
grep -q 'warning' <<<"$out" && fail "down.sh warned on a stopped experiment: $out"
grep -q 'not started' <<<"$out" || fail "down.sh did not say it was not started: $out"
echo "PASS down-stopped"
