#!/usr/bin/env bash
# Test: shirudo/up.sh refuses to start shirudo-arm64 while another experiment is started (exit 1, names it), and
# starts nothing. Uses a throwaway one-VM experiment (256 MB placeholder) as the "other" experiment. Runs on the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
px() { limactl shell phenix sudo docker exec phenix phenix "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
t=shirudo-uptest
cleanup() { px exp stop "$t" >/dev/null 2>&1 || true; px exp delete "$t" >/dev/null 2>&1 || true; px cfg delete "topology/$t" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

limactl shell phenix sudo tee /phenix/$t.yaml >/dev/null <<EOF
apiVersion: phenix.sandia.gov/v1
kind: Topology
metadata:
  name: $t
spec:
  nodes:
  - general:
      hostname: $t
    hardware:
      cpu: host
      os_type: linux
      memory: 256
      vcpus: 1
      drives:
      - image: t1.qc2
        interface: virtio
    advanced:
      machine: virt
    overrides:
      bus=usb-bus.0: bus=xhci.0
    network:
      interfaces: []
    type: VirtualMachine
EOF
px cfg create /phenix/$t.yaml >/dev/null
px exp create "$t" -t "$t" >/dev/null
px exp start "$t" >/dev/null || fail "test setup: could not start $t"

set +e; out=$("$here/up.sh" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || fail "want exit 1 with $t started, got $rc: $out"
grep -q "$t" <<<"$out" || fail "message does not name $t: $out"
px exp list 2>/dev/null | grep -E '^\| *shirudo-arm64 ' | awk -F'|' '$5 ~ /[0-9]/' | grep -q . && fail "shirudo-arm64 was started"
"$here/swtpm.sh" status rtu-s >/dev/null 2>&1 && fail "swtpm for rtu-s was started"
echo "PASS up-refusal"
