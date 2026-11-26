#!/usr/bin/env bash
# Test: swtpm.sh start is idempotent, status fails when swtpm is not running, and a stale socket left behind by a
# killed swtpm fails status and is replaced by start. Needs a staged TPM (stage.sh) for the VM. Runs on the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
vm=${1:-ref}
pin=$(cat "$here/PIN")
unit=shirudo-swtpm-$vm
sock=/phenix/shirudo/$pin/tpm/$vm/swtpm.sock
px() { limactl shell phenix sudo "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
trap '"$here/swtpm.sh" stop "$vm" >/dev/null 2>&1 || true' EXIT

"$here/swtpm.sh" stop "$vm" >/dev/null 2>&1 || true
"$here/swtpm.sh" status "$vm" >/dev/null 2>&1 && fail "status passed with swtpm stopped"

"$here/swtpm.sh" start "$vm" >/dev/null || fail "start failed"
"$here/swtpm.sh" status "$vm" >/dev/null || fail "status failed after start"
pid1=$(px systemctl show -p MainPID --value "$unit")
"$here/swtpm.sh" start "$vm" >/dev/null || fail "second start failed"
pid2=$(px systemctl show -p MainPID --value "$unit")
[ "$pid1" = "$pid2" ] || fail "second start replaced the process ($pid1 -> $pid2)"
[ "$(px pgrep -c -x swtpm)" = 1 ] || fail "more than one swtpm"

px systemctl kill -s KILL "$unit"
for _ in 1 2 3 4 5; do px systemctl is-active -q "$unit" || break; sleep 1; done
px test -S "$sock" || fail "test setup: socket did not survive the kill"
"$here/swtpm.sh" status "$vm" >/dev/null 2>&1 && fail "status passed with a stale socket"
"$here/swtpm.sh" start "$vm" >/dev/null || fail "start over a stale socket failed"
"$here/swtpm.sh" status "$vm" >/dev/null || fail "status failed after restart over a stale socket"
echo "PASS swtpm-lifecycle"
