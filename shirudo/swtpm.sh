#!/usr/bin/env bash
# usage: shirudo/swtpm.sh start|stop|status <vm>   (run on the Mac)
# One swtpm per shirudo target, on the phenix VM host, as transient systemd unit shirudo-swtpm-<vm>.
# State: /phenix/shirudo/<pin>/tpm/<vm>/ (staged by stage.sh). Control socket: .../tpm/<vm>/swtpm.sock, which QEMU in
# the minimega container reaches at the same path. start is idempotent and replaces a stale socket; status exits 0 only
# when the unit is active and the socket accepts a connection.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:?start|stop|status} vm=${2:?vm}
pin=$(cat "$here/PIN")
dir=/phenix/shirudo/$pin/tpm/$vm sock=/phenix/shirudo/$pin/tpm/$vm/swtpm.sock unit=shirudo-swtpm-$vm
px() { limactl shell phenix sudo "$@"; }

status() {
  px systemctl is-active -q "$unit" &&
    px python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])" "$sock" 2>/dev/null
}

# Ubuntu's swtpm AppArmor profile only allows libvirt paths and libvirt-labelled peers.
apparmor() {
  local f=/etc/apparmor.d/local/usr.bin.swtpm
  px grep -q 'shirudo-range' "$f" 2>/dev/null && return
  px sh -c "printf '%s\n' '# shirudo-range: swtpm for phenix/minimega shirudo targets' '/phenix/shirudo/** rwk,' 'unix (send, receive, accept, bind, listen, create, getattr, setopt, shutdown) type=stream,' >> $f"
  px apparmor_parser -r /etc/apparmor.d/usr.bin.swtpm
}

case $cmd in
status)
  status || { echo "swtpm for $vm is not running or $sock does not accept" >&2; exit 1; }
  echo "swtpm for $vm running, $sock accepts" ;;
start)
  if status; then echo "swtpm for $vm already running"; exit 0; fi
  px test -f "$dir/tpm2-00.permall" || { echo "no staged vTPM at $dir; run stage.sh $vm" >&2; exit 1; }
  apparmor
  # an active unit whose socket does not accept (hung) is stopped first, or systemd-run would refuse the unit name
  px systemctl is-active -q "$unit" && px systemctl stop "$unit"
  px systemctl reset-failed "$unit" 2>/dev/null || true
  px rm -f "$sock"
  px systemd-run -q --unit="$unit" swtpm socket --tpmstate "dir=$dir,mode=0700" \
    --ctrl "type=unixio,path=$sock" --tpm2 --log "file=$dir/swtpm.log,level=20"
  for _ in $(seq 50); do status && break; sleep 0.1; done
  status || { echo "swtpm for $vm did not come up; see $dir/swtpm.log and journalctl -u $unit" >&2; exit 1; }
  echo "swtpm for $vm started" ;;
stop)
  px systemctl stop "$unit" 2>/dev/null || true
  px systemctl reset-failed "$unit" 2>/dev/null || true
  px rm -f "$sock"
  echo "swtpm for $vm stopped" ;;
*) echo "usage: $0 start|stop|status <vm>" >&2; exit 2 ;;
esac
