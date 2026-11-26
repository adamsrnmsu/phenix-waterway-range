#!/usr/bin/env bash
# Test: shirudo/tools/eve_epoch.jq turns Suricata timestamps with any UTC offset into the same epoch second.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*"; exit 1; }
for t in 2026-11-26T05:23:29.379018+0000 2026-11-26T07:23:29.1+0200 2026-11-25T22:23:29-0700 2026-11-26T05:23:29Z; do
  got=$(jq -n --arg t "$t" "$(cat "$here/tools/eve_epoch.jq") \$t | eve_epoch")
  [ "$got" = 1795670609 ] || fail "$t -> $got, want 1795670609"
done
echo "PASS eve-epoch"
