#!/usr/bin/env bash
# usage: shirudo/spike/launch.sh up|down [vm] [ssh-port]   (run on the Mac; vm ref, port 22101 by default)
# up: start the target's swtpm, render rtu-s.mm and have minimega read it in namespace shirudo-spike.
# down: kill the VM, clear the namespace, stop swtpm. The staged disk and vTPM state are kept.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:?up|down} vm=${2:-ref} port=${3:-22101}
pin=$(cat "$here/PIN") name=shirudo-spike
D=/phenix/shirudo/$pin
px() { limactl shell phenix sudo "$@"; }
mm() { px docker exec minimega mm "$@"; }

# a target whose swtpm runs while the spike namespace has no VM belongs to someone else (shirudo-arm64's rtu-s):
# starting it here would boot a second QEMU on its disk; stopping would take the swtpm from under the live VM
spike_vms=$(mm namespace "$name" .columns name vm info 2>/dev/null | grep -c -v -E '^(host|$)' || true)
case $cmd in
up)
  if "$here/swtpm.sh" status "$vm" >/dev/null 2>&1 && [ "$spike_vms" = 0 ]; then
    echo "refusing: $vm's swtpm is running outside $name (a started experiment owns it); stop that first" >&2; exit 1
  fi
  "$here/swtpm.sh" start "$vm"
  sed -e "s|@D@|$D|g" -e "s|@VM@|$vm|g" -e "s|@NAME@|$name|g" -e "s|@SSH@|$port|g" "$here/spike/rtu-s.mm" |
    grep -v '^#' | px tee "$D/spike-$vm.mm" >/dev/null
  mm read "$D/spike-$vm.mm"
  mm namespace "$name" vm info ;;
down)
  [ "$spike_vms" = 0 ] && { echo "no VM in $name; nothing to stop (left $vm's swtpm alone)"; exit 0; }
  # power the guest off cleanly first: after a QEMU kill swtpm saves TPM state (Shutdown(STATE)), so the next boot is a TPM restart and shirudo cannot bind its register (status
  # tampered) until a clean shutdown and another boot. --check-inhibitors=no: unattended-upgrades holds one.
  px install -m600 "$D/vms/$vm/ssh/id_ed25519" "/tmp/shirudo-$vm.key"
  px ssh -i "/tmp/shirudo-$vm.key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=5 -p "$port" root@127.0.0.1 systemctl poweroff --check-inhibitors=no 2>/dev/null || true
  for _ in $(seq 60); do mm namespace "$name" .columns state vm info 2>/dev/null | grep -q RUNNING || break; sleep 2; done
  mm namespace "$name" .columns state vm info 2>/dev/null | grep -q RUNNING &&
    echo "warning: $vm did not power off cleanly; killing it (its next boot will report tampered)" >&2
  px rm -f "/tmp/shirudo-$vm.key"
  mm namespace "$name" vm kill all 2>/dev/null || true
  mm namespace "$name" vm flush 2>/dev/null || true
  mm clear namespace "$name" 2>/dev/null || true
  "$here/swtpm.sh" stop "$vm" ;;
*) echo "usage: $0 up|down [vm] [ssh-port]" >&2; exit 2 ;;
esac
