#!/usr/bin/env bash
# usage: shirudo/spike/power-loss.sh [vm] [isolate]   (run on the Mac; vm defaults to ref; the spike namespace must be empty)
# Characterises shirudo's behaviour after a power loss (bead ww-hubl) on a staged target booted by spike/launch.sh:
#   E1  plain "systemctl poweroff" (no --check-inhibitors=no) on a healthy boot: accepted or refused?
#   E2  hard kill, boot, hard kill, boot: does the second boot after a kill recover by itself?
#   E3  after a tampered boot, "poweroff --check-inhibitors=no", boot: recovers? (the known recovery)
# isolate runs instead:
#   E4  "sync" in the guest, then hard kill: does flushing the page cache first avoid the tampered boot?
#   E5  hard kill QEMU but keep swtpm running (only the guest loses power; QEMU re-initialises the TPM on connect)
# Each boot records shirudo status and the init line (the whole shirudo-initrd log when not ok); output on stdout.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
vm=${1:-ref} mode=${2:-} port=22101 D=/phenix/shirudo/$(cat "$here/PIN") N=shirudo-spike
L() { limactl shell phenix sudo "$@"; }
mm() { L docker exec minimega mm "$@" 2>/dev/null | grep -v 'got command' || true; }
key=$(L mktemp); trap 'L rm -f "$key"' EXIT
L install -m600 "$D/vms/$vm/ssh/id_ed25519" "$key"
S() { L ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -p $port root@127.0.0.1 "$@"; }
state() { mm namespace $N .columns name,state vm info | awk -F'|' 'NR>1 {gsub(/ /,"",$3); print $3}' | head -1; }

boot() {  # <label>
  "$here/spike/launch.sh" up "$vm" $port >/dev/null 2>&1
  for _ in $(seq 100); do S true 2>/dev/null && break; sleep 3; done
  sleep 10   # let shirudo.service settle
  echo "## $1: $(S 'shirudo-runtime status --json' 2>/dev/null | sed -n '/^{/,$p' | jq -r '.status + " (" + ([.conditions[] | select(.status != "OK") | .type + " " + .status] | join(", ")) + ")"')"
  echo "   init: $(S 'journalctl -b -o cat -u shirudo-initrd | grep -E "^init:" | tail -1')"
  S 'shirudo-runtime status --json' 2>/dev/null | sed -n '/^{/,$p' | jq -e '.status == "ok"' >/dev/null ||
    S 'journalctl -b -o short-monotonic -u shirudo-initrd | tail -25' | sed 's/^/     | /'
}
qemu_kill() {  # power off the guest only: swtpm keeps running and keeps its state
  mm namespace $N vm kill all >/dev/null; for _ in $(seq 30); do [ "$(state)" != RUNNING ] && break; sleep 1; done
  mm namespace $N vm flush >/dev/null
  "$here/swtpm.sh" status "$vm" >/dev/null && echo "   -> hard kill of QEMU only (swtpm still running)"
  L docker exec minimega mm read "$D/spike-$vm.mm" >/dev/null   # rendered by the last launch.sh up
}
boot_up() { for _ in $(seq 100); do S true 2>/dev/null && break; sleep 3; done; sleep 10; }
kill_vm() { mm namespace $N vm kill all >/dev/null; for _ in $(seq 30); do [ "$(state)" != RUNNING ] && break; sleep 1; done
            "$here/spike/launch.sh" down "$vm" $port >/dev/null 2>&1; echo "   -> hard kill"; }
off() {  # <flag or empty>
  echo "   -> systemctl poweroff $1: $(S "systemctl poweroff $1" 2>&1 | head -1 || true)"
  for _ in $(seq 60); do [ "$(state)" != RUNNING ] && break; sleep 2; done
  echo "      state after 120 s at most: $(state)"
  if [ "$(state)" = RUNNING ] && [ -z "$1" ]; then off "--check-inhibitors=no"; return; fi   # keep the next boot clean
  if [ "$(state)" = RUNNING ]; then kill_vm; else "$here/spike/launch.sh" down "$vm" $port >/dev/null 2>&1; fi
}

[ "$(mm namespace $N .columns name vm info | grep -c -v -E '^(host|$)')" = 0 ] || { echo "the spike namespace has a VM; launch.sh down first" >&2; exit 1; }
echo "# power-loss characterisation${mode:+ ($mode)}, $vm, shirudo $(cut -c1-12 "$here/PIN"), $(date -u +%FT%TZ)"
if [ "$mode" = isolate ]; then
  echo "## E4: sync, then hard kill"
  boot "boot A (baseline)"
  echo "   -> sync: $(S 'sync && echo done')"; kill_vm
  boot "boot B (after sync + kill)"
  off "--check-inhibitors=no"
  echo "## E5: hard kill of QEMU, swtpm kept running"
  boot "boot C (baseline)"
  qemu_kill; boot_up
  echo "## boot D (after a QEMU-only kill): $(S 'shirudo-runtime status --json' 2>/dev/null | sed -n '/^{/,$p' | jq -r '.status + " (" + ([.conditions[] | select(.status != "OK") | .type + " " + .status] | join(", ")) + ")"')"
  echo "   init: $(S 'journalctl -b -o cat -u shirudo-initrd | grep -E "^init:" | tail -1')"
  off "--check-inhibitors=no"
  boot "boot E (after a forced clean poweroff)"
  off "--check-inhibitors=no"
  exit 0
fi
echo "## E1: plain poweroff on a healthy boot"
boot "boot 1 (baseline)";                 off ""
echo "## E2: kill, boot, kill, boot"
boot "boot 2 (after a clean poweroff)";   kill_vm
boot "boot 3 (after kill #1)";            kill_vm
boot "boot 4 (after kill #2)"
echo "## E3: recovery from the tampered state"
off "--check-inhibitors=no"
boot "boot 5 (after a forced clean poweroff)"
off "--check-inhibitors=no"
