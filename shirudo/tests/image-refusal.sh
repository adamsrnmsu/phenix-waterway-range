#!/usr/bin/env bash
# Test: images/ferrofire-shirudo.sh refuses to rebuild ferrofire-shirudo-arm64.qc2 while a started experiment uses it.
# Starts a throwaway experiment: the node naming the image does not boot (do_not_boot); a 256 MB placeholder does.
# Runs on the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
px() { limactl shell phenix sudo docker exec phenix phenix "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
t=shirudo-reftest
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
      do_not_boot: true
    hardware:
      os_type: linux
      memory: 512
      vcpus: 1
      drives:
      - image: ferrofire-shirudo-arm64.qc2
    network:
      interfaces: []
    type: VirtualMachine
  # phenix will not start an experiment with no VM to launch: a tiny placeholder that boots nothing
  - general:
      hostname: $t-k
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

set +e; out=$("$here/images/ferrofire-shirudo.sh" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || fail "want exit 1 with $t started, got $rc: $out"
grep -q "refusing: a started experiment uses topology $t" <<<"$out" || fail "wrong message: $out"
echo "PASS image-refusal"
