#!/usr/bin/env bash
# OVS port mirror: copy every range VLAN's traffic to a blue VM's capture tap.
# Usage: scripts/mirror.sh <experiment> <blue-vm> <capture-iface-index> [--off]
#        [VLAN=ICS] scripts/mirror.sh <experiment> port:<name> 0 [--off]
# port:<name> outputs to an OVS internal port on the phenix bridge (created if missing, brought up) instead of a
# VM NIC, so a host-side sniffer (tcpdump, a Zeek container with --network host) can read it. VLAN=<name> mirrors
# only that VLAN's taps (e.g. VLAN=ICS: DNP3/Modbus between the router and the RTUs, each frame exactly once).
# Run on the Mac (via limactl) or inside the Lima VM. Idempotent: re-running replaces the mirror.
# Mirrors every VLAN of the experiment except MGMT and the capture NIC's own (MIRROR) VLAN, so
# it works for waterway and mitm alike. Mirror name: mir-<experiment>. Bridge: phenix.
set -euo pipefail
exp=${1:?experiment} vm=${2:?blue vm} idx=${3:?capture iface index (0-based, e.g. 1)} off=${4:-}
dk="sudo docker exec minimega"; [ -x "$(command -v limactl)" ] && dk="limactl shell phenix $dk"
BR=phenix name="mir-$exp"
ovs() { $dk ovs-vsctl "$@"; }
rmold() { for u in $(ovs --bare --columns=_uuid find Mirror "name=$name"); do ovs remove Bridge $BR mirrors "$u"; done; }  # OVS GCs the orphan row
[ "$off" = "--off" ] && { rmold; [ "${vm#port:}" != "$vm" ] && ovs --if-exists del-port $BR "${vm#port:}"; echo "mirror $name off"; exit 0; }
# "tap vlan-id" pairs: rows come as 'name | [taps] | [VLAN (id), ...]'
info=$($dk mm namespace "$exp" .headers false .columns name,tap,vlan vm info 2>/dev/null | grep -v 'INFO\|^$')
if [ "${vm#port:}" != "$vm" ]; then   # internal monitor port: no VM, no own VLAN to exclude
  tap=${vm#port:}; own=none
  ovs --may-exist add-port $BR "$tap" -- set Interface "$tap" type=internal >/dev/null
  $dk ip link set "$tap" up 2>/dev/null || sudo ip link set "$tap" up
  $dk sysctl -wq "net.ipv6.conf.$tap.disable_ipv6=1" || true   # no v6 chatter from the monitor port itself
else
row=$(grep -E "\| $vm +\|" <<<"$info" | head -1 || true)
[ -n "$row" ] || { echo "vm $vm not found in $exp" >&2; exit 1; }
tap=$(cut -d'|' -f3 <<<"$row" | tr -d '[] ' | cut -d, -f$((idx+1)))
[ -n "$tap" ] || { echo "no iface index $idx on $vm" >&2; exit 1; }
own=$(ovs get Port "$tap" tag)
fi
# taps of every NIC in the experiment's VLANs except MGMT and the capture VLAN. (select_vlan does not
# match traffic from access ports, so mirror by port: src+dst of each tap.)
taps=$(awk -F'|' -v own="($own)" -v only="${VLAN:-}" '{t=$3; v=$4; gsub(/[][ ]/,"",t); gsub(/[][]/,"",v); n=split(t,T,","); split(v,V,",")
  for(i=1;i<=n;i++){x=V[i]; gsub(/^ +/,"",x); if(x!~/^MGMT/ && index(x,own)==0 && (only==""||x~"^"only" ")) print T[i]}}' <<<"$info")
[ -n "$taps" ] || { echo "no ports to mirror" >&2; exit 1; }
ids=$(for t in $taps; do printf '@%s ' "${t#mega_}"; done)
cmd=(); for t in $taps; do cmd+=(-- --id=@${t#mega_} get Port "$t"); done
sel=$(sed 's/ /,/g;s/,$//' <<<"$ids")
rmold   # only after all validation passed, so a bad call never drops a working mirror
ovs "${cmd[@]}" -- --id=@o get Port "$tap" -- --id=@m create Mirror "name=$name" "select_src_port=$sel" "select_dst_port=$sel" output_port=@o -- add Bridge $BR mirrors @m >/dev/null
echo "mirror $name on: $(echo $taps) -> $vm $tap (tag $own)"
