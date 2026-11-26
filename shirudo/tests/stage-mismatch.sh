#!/usr/bin/env bash
# Test: stage.sh keeps a staged vTPM tied to its bundle, takes --rebuild-tpm in any position, and verifies its copies. A staged TPM whose version_id differs from the incoming
# bundle's is refused (exit 1, both ids named) unless --rebuild-tpm, which replaces it. Runs on the Mac; stages for
# real into /phenix/shirudo/<pin>/ on the phenix VM.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
vm=${1:-ref}
pin=$(cat "$here/PIN")
idf=/phenix/shirudo/$pin/tpm/$vm/version_id
px() { limactl shell phenix sudo "$@"; }
fail() { echo "FAIL: $*"; exit 1; }

"$here/stage.sh" --rebuild-tpm "$vm" >/dev/null || fail "setup stage failed"
"$here/stage.sh" "$vm" >/dev/null || fail "restage over a matching TPM failed"
want=$(px cat "$idf")
[ -n "$want" ] || fail "no version_id staged at $idf"

px sh -c "echo deadbeef > $idf"
set +e; out=$("$here/stage.sh" "$vm" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || fail "mismatch: want exit 1, got $rc: $out"
grep -q deadbeef <<<"$out" || fail "message does not name the staged id: $out"
grep -q "$want" <<<"$out" || fail "message does not name the bundle id: $out"

out=$("$here/stage.sh" "$vm" --rebuild-tpm 2>&1) || fail "--rebuild-tpm after the vm name failed: $out"
grep -q 'copies verified against shirudo-dev' <<<"$out" || fail "staged copies were not verified: $out"
[ "$(px cat "$idf")" = "$want" ] || fail "--rebuild-tpm did not restore the bundle's version_id"
# the staged disk must stand alone: shirudo-dev's disk is an overlay on a cache image minimega cannot see
disk=/phenix/shirudo/$pin/vms/$vm/rootfs.qcow2
px docker exec minimega qemu-img info "$disk" | grep -q '^backing file' && fail "staged $disk has a backing file"
echo "PASS stage-mismatch"
