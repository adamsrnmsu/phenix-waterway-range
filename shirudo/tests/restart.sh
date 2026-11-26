#!/usr/bin/env bash
# Test: shirudo/down.sh then shirudo/up.sh brings rtu-s back with the same vTPM: up.sh reports status ok (register
# bound in the initrd), the pass check's attestation verifies against the attestation key pinned when rtu-s was
# provisioned, and the staged vTPM was not replaced (version_id untouched). Needs shirudo-arm64 started. Runs on the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
D=/phenix/shirudo/$(cat "$here/PIN")
L() { limactl shell phenix sudo "$@"; }
fail() { echo "FAIL: $*"; exit 1; }

before=$(L stat -c %Y "$D/tpm/rtu-s/version_id")
"$here/down.sh" > /tmp/shirudo-restart-down.log 2>&1 || fail "down.sh failed: $(tail -3 /tmp/shirudo-restart-down.log)"
grep -q 'did not power off cleanly' /tmp/shirudo-restart-down.log && fail "rtu-s was killed, not powered off"
L sh -c "strings '$D/vms/rtu-s/console.log' | tail -1" | grep -q 'reboot: Power down' || fail "console does not end in Power down"
L truncate -s0 "$D/vms/rtu-s/console.log"   # the console log appends across boots; check only the next one
out=$("$here/up.sh" 2>&1) || fail "up.sh failed: $(tail -3 <<<"$out")"
grep -q 'rtu-s shirudo status: ok' <<<"$out" || fail "rtu-s not ok after restart: $(grep status <<<"$out")"
L sh -c "strings '$D/vms/rtu-s/console.log' | grep -c 'Failed to start .*shirudo-initrd' || true" | grep -qx 0 || fail "shirudo-initrd failed in some boot logged"
"$here/pass-check.sh" --mm 22110 rtu-s > /tmp/shirudo-restart-pass.txt 2>&1 || fail "pass check after restart: $(tail -3 /tmp/shirudo-restart-pass.txt)"
grep -q 'OK    attestation key: the pinned key' /tmp/shirudo-restart-pass.txt || fail "attestation key is not the pinned one"
[ "$(L stat -c %Y "$D/tpm/rtu-s/version_id")" = "$before" ] || fail "staged vTPM was replaced"
echo "PASS restart"
