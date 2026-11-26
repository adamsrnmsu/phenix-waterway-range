#!/usr/bin/env bash
# usage: shirudo/down.sh [--force]   (run on the Mac)
# Stops experiment shirudo-arm64. rtu-s is powered off cleanly first: phenix exp stop kills QEMU, and after a hard kill
# shirudo's next boot cannot bind its register (status tampered; shirudo/spike/pass.txt). Then removes the mirror,
# stops the experiment and rtu-s's swtpm. rtu-s's disk and vTPM state are kept. If rtu-s does not power off, down.sh
# stops and leaves it running; --force kills it anyway (its next boot will report tampered).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd) repo=$(cd "$(dirname "$0")/.." && pwd)
D=/phenix/shirudo/$(cat "$here/PIN") X=shirudo-arm64
px() { limactl shell phenix sudo docker exec phenix phenix "$@"; }
mm() { limactl shell phenix sudo docker exec minimega mm "$@"; }

force=0; [ "${1:-}" = "--force" ] && force=1
if ! px exp list 2>/dev/null | awk -F'|' '$2 ~ /^ *'$X' *$/ && $5 ~ /[0-9]/' | grep -q .; then
  "$here/swtpm.sh" stop rtu-s >/dev/null
  echo "experiment $X is not started; nothing to stop (rtu-s's swtpm stopped if it was running)"
  exit 0
fi
key=$(limactl shell phenix mktemp); trap 'limactl shell phenix sudo rm -f "$key"' EXIT
limactl shell phenix sudo install -m600 "$D/vms/rtu-s/ssh/id_ed25519" "$key"
limactl shell phenix sudo ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ConnectTimeout=5 -p 22110 root@127.0.0.1 systemctl poweroff --check-inhibitors=no 2>/dev/null || true
# rtu-s's state: RUNNING until the guest has powered off (then QUIT). Anything else (query error) counts as running.
state() { mm namespace "$X" .columns name,state vm info 2>/dev/null | awk -F'|' '$2 ~ /^ *rtu-s *$/ {gsub(/ /,"",$3); print $3}'; }
for _ in $(seq 90); do
  s=$(state); [ -n "$s" ] && [ "$s" != RUNNING ] && break
  sleep 2
done
s=$(state)
if [ -z "$s" ] || [ "$s" = RUNNING ]; then
  if [ "$force" = 0 ]; then
    echo "rtu-s did not power off (state ${s:-unknown}); experiment left running. Rerun with --force to kill it (its next boot will report tampered)" >&2
    exit 1
  fi
  echo "warning: rtu-s did not power off cleanly (state ${s:-unknown}); killing it (--force; its next boot will report tampered)" >&2
fi

"$repo/scripts/mirror.sh" "$X" purple 1 --off 2>/dev/null || true
px exp stop "$X" >/dev/null 2>&1 || { echo "phenix exp stop $X failed" >&2; exit 1; }
"$here/swtpm.sh" stop rtu-s
echo "experiment $X stopped; rtu-s state kept at $D"
