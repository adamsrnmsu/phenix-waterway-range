#!/usr/bin/env bash
# usage: shirudo/pass-check.sh [--mm <ssh-port>] [vm]   (run on the Mac; vm defaults to ref)
# The spike's pass condition, following shirudo's Documentation/start/quickstart.rst: status ok, a signed upatch
# (testing/fixtures/basic.bpf.c) loads and unloads, and TPM evidence after the load verifies against the predicted
# register. Exits non-zero on the first failed check.
# Default: the target is shirudo's own test VM in shirudo-dev. --mm: the staged target booted by minimega on the
# phenix VM (spike/launch.sh), reached over its forwarded SSH port; upatches and evidence move over that SSH. Building, signing, predicting and verifying always run in
# shirudo-dev, where the bundle's signing key lives.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mmport=""; [ "${1:-}" = "--mm" ] && { mmport=${2:?ssh port}; shift 2; }
name=${1:-ref}
src=${SHIRUDO_SRC:-$HOME/git/shirudo}
D=/phenix/shirudo/$(cat "$here/PIN")
op() { limactl shell --workdir "$src" shirudo-dev bash -lc "export PATH=\$PWD:\$PWD/tools/shirudo-build:\$PATH; $*"; }
px() { limactl shell phenix sudo "$@"; }
keys='/tmp/shirudo-test-vm-private-$(id -u)/operator-keys/keys'
w=pass-check-$name   # under the checkout; the guest sees it at /workspace/shirudo/$w
if [ -z "$mmport" ]; then
  tg() { op "VM_NAME=$name VM_SSH_COMMAND='$*' make -s -C testing vm-ssh"; }
  put() { :; }
  ev=build/test-vm/vms/$name/result/ev.json
  trap 'op "rm -rf $w"' EXIT
else
  px install -m600 "$D/vms/$name/ssh/id_ed25519" "/tmp/shirudo-$name.key"
  tg() { px ssh -i "/tmp/shirudo-$name.key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -p "$mmport" root@127.0.0.1 "$*"; }
  put() { op "tar -cf - $w" | tg "mkdir -p /workspace/shirudo && rm -rf /workspace/shirudo/$w && tar -C /workspace/shirudo -xf -"; }
  ev=$w/ev.json
  trap 'op "rm -rf $w"; px rm -f "/tmp/shirudo-$name.key"' EXIT
fi

echo "## status"
tg 'shirudo-runtime status --json' | sed -n '/^{/,$p' > /tmp/pc-status.json
jq -e '.status == "ok"' /tmp/pc-status.json >/dev/null || { cat /tmp/pc-status.json; echo "FAIL: status not ok"; exit 1; }
tg 'shirudo-runtime status'

echo "## build and sign"
op "rm -rf $w && mkdir -p $w && cp testing/fixtures/basic.bpf.c $w/ && shirudo build $w/basic.bpf.c --keys-dir $keys --vmlinux vendor/linux/vmlinux.h -o $w/basic.upatch"
payload=$(op "shirudo upatch info --json $w/basic.upatch | jq -r .payload_sha256")
op "shirudo build --unload basic --payload-sha256 $payload --keys-dir $keys -o $w/basic.unload.upatch"
put

# a run that failed after its load leaves basic loaded and archived: unload it first (same source and path, same payload)
tg "cd /workspace/shirudo && if shirudo-runtime upatch list | grep -q '^ *basic  *yes'; then shirudo-runtime upatch unload $w/basic.unload.upatch; fi" || true
echo "## load"
tg "cd /workspace/shirudo && shirudo-runtime upatch load $w/basic.upatch && shirudo-runtime upatch list"

echo "## attest"
nonce=$(openssl rand -hex 32)
if [ -z "$mmport" ]; then
  tg "shirudo-runtime attest --nonce=$nonce --output=/mnt/shirudo-out/ev.json"
else
  tg "shirudo-runtime attest --nonce=$nonce --output=/root/ev.json && cat /root/ev.json" | op "cat > $ev"
fi
own=build/test-vm/host-bundle-bpf-next-verity/fixtures/own.der
# upatches the target restored at boot (archived ones, e.g. kernel-obs) are part of the register too
# (a leftover basic counts as installed at boot, followed by the pre-clean's unload event)
installed=$(jq -r '[.upatches_loaded[]? | "--expect=\(.name)=\(.payload_sha256)"] | join(" ")' /tmp/pc-status.json)
events="--event=load:basic=$payload"
jq -e '[.upatches_loaded[]? | .name] | index("basic")' /tmp/pc-status.json >/dev/null && events="--event=unload:basic=$payload $events"
chain=$(op "shirudo attest predict --cert=$keys/cert.der --cert=$own $installed $events" | awk '/^register_after_events:/{print $2}')
op "shirudo attest verify --evidence=$ev --nonce=$nonce --ak-name=\$(jq -r .ak.name $ev) --expect-chain=$chain" | tee /tmp/pc-verify.txt
grep -qx 'verdict: ok' /tmp/pc-verify.txt || { echo "FAIL: attest verify"; exit 1; }

echo "## unload"
tg "cd /workspace/shirudo && shirudo-runtime upatch unload $w/basic.unload.upatch && shirudo-runtime upatch list"
echo "PASS pass-check $name${mmport:+ (minimega, port $mmport)}"
