#!/bin/bash
# usage: images/ferrofire-shirudo.sh   (run on the Mac)
# Builds the shirudo-protected field device: shirudo's own test target "rtu-s" (shirudo-dev, see shirudo/README.md)
# with the ferrofire RTU added (static aarch64 musl release, the same field device the range's ferrofire RTUs run,
# started from /etc/sceptre/config.xml by ferrofire-rtu-start). Then stages it (shirudo/stage.sh --rebuild-tpm rtu-s)
# and links /phenix/images/ferrofire-shirudo-arm64.qc2 to the staged disk. The disk, initrd and vTPM are one set: a
# rebuild makes a new target (new keys, new vTPM). Refuses while a started experiment uses the image.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
NAME=ferrofire-shirudo-arm64.qc2 VM=rtu-s
FF_TAG=${FF_TAG:-v2026.11.15} FF_ASSET=ferrofire-2026.11.15-aarch64-linux-musl.tar.gz
src=${SHIRUDO_SRC:-$HOME/git/shirudo}
pin=$(cat "$repo/shirudo/PIN")
L() { limactl shell phenix -- "$@"; }
PX() { L sudo docker exec phenix phenix "$@"; }
dev() { limactl shell --workdir "$src" shirudo-dev bash -lc "$*"; }
guest() { dev "VM_NAME=$VM VM_SSH_COMMAND='$*' make -s -C testing vm-ssh"; }

# a started experiment's topology references the image by name. Fail closed: any error here aborts the build.
list=$(PX exp list)
grep -q '| *STARTED *|' <<<"$list" || { echo "unexpected 'px exp list' output, aborting" >&2; exit 1; }
for t in $(awk -F'|' '$5 ~ /[0-9]/ { gsub(/ /,"",$3); print $3 }' <<<"$list"); do
  topo=$(PX cfg get "topology/$t" -o yaml)
  if grep -qF "image: $NAME" <<<"$topo"; then
    echo "refusing: a started experiment uses topology $t with $NAME" >&2; exit 1
  fi
done
"$repo/shirudo/fetch-build.sh" --check-only

# ferrofire release, checked against its SHA256SUMS
cache=$HOME/.cache/shirudo-range/ferrofire-$FF_TAG
mkdir -p "$cache"
[ -f "$cache/$FF_ASSET" ] || gh release download "$FF_TAG" -R adamsrnmsu/ferrofire -p "$FF_ASSET" -p SHA256SUMS -D "$cache" --clobber
(cd "$cache" && grep " $FF_ASSET\$" SHA256SUMS | shasum -a 256 -c -) >/dev/null
tar -C "$cache" -xzf "$cache/$FF_ASSET"
bin=$(find "$cache" -type f -name ferrofire -perm -u+x | head -1)
[ -n "$bin" ] || { echo "no ferrofire binary in $FF_ASSET" >&2; exit 1; }
# ferrofire-rtu-start from the same release tag as the binary (not whatever ~/git/ferrofire has checked out)
start=$cache/ferrofire-rtu-start
git -C "$HOME/git/ferrofire" fetch -q --tags origin 2>/dev/null || true
git -C "$HOME/git/ferrofire" show "$FF_TAG:image/board/ferrofire-rtu/rootfs-overlay/usr/sbin/ferrofire-rtu-start" > "$start"

# a fresh target in shirudo-dev (keys, disk, vTPM made for this name)
"$repo/shirudo/swtpm.sh" stop "$VM" >/dev/null
dev "make -s -C testing vm-clean VM_NAME=$VM >/dev/null 2>&1 || true; make -s -C testing vm VM_NAME=$VM 2>&1" | grep -E 'VM ready|error'

guest 'useradd --system --create-home --home-dir /home/sceptre sceptre 2>/dev/null || true; install -d -m 0755 /etc/sceptre'
guest 'cat > /usr/bin/ferrofire && chmod 0755 /usr/bin/ferrofire' < "$bin"
guest 'cat > /usr/sbin/ferrofire-rtu-start && chmod 0755 /usr/sbin/ferrofire-rtu-start' < "$start"
guest 'cat > /etc/systemd/system/ferrofire-rtu.service' <<'UNIT'
[Unit]
Description=ferrofire RTU (field device) from /etc/sceptre/config.xml
ConditionPathExists=/etc/sceptre/config.xml
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=process
ExecStart=/usr/sbin/ferrofire-rtu-start /etc/sceptre/config.xml

[Install]
WantedBy=multi-user.target
UNIT
guest 'systemctl daemon-reload && systemctl enable ferrofire-rtu.service && /usr/bin/ferrofire --version'

# Range addressing, baked in: the image has no phenix startup, and phenix injects nothing into a target whose disk
# must stay with its vTPM (snapshot false). NICs are matched by the MACs topologies/shirudo-arm64 gives them:
#   mgmt  52:54:00:12:34:56  QEMU user-net, DHCP (host-only SSH via hostfwd)
#   ot    02:5e:10:01:01:65  SHOT    10.1.1.101/24  Modbus 502, DNP3 20000
#   prov  02:5e:10:10:01:65  SHPROV  172.16.1.101/16  provider updates (udp 239.0.0.1:40000, tcp 172.16.1.2:5555)
guest 'cat > /etc/sceptre/config.xml' < "$repo/topologies/shirudo-arm64/injects/rtu-s-config.xml"
guest 'install -d /etc/cloud/cloud.cfg.d && echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-shirudo-range.cfg && rm -f /etc/netplan/50-cloud-init.yaml && cat > /etc/netplan/60-shirudo-range.yaml && chmod 0600 /etc/netplan/60-shirudo-range.yaml && netplan generate' <<'NETPLAN'
network:
  version: 2
  ethernets:
    mgmt:
      match: {macaddress: "52:54:00:12:34:56"}
      set-name: mgmt
      dhcp4: true
    ot:
      match: {macaddress: "02:5e:10:01:01:65"}
      set-name: ot
      addresses: [10.1.1.101/24]
      optional: true
    prov:
      match: {macaddress: "02:5e:10:10:01:65"}
      set-name: prov
      addresses: [172.16.1.101/16]
      optional: true
NETPLAN

"$repo/shirudo/stage.sh" --rebuild-tpm "$VM"
L sudo ln -sfn "/phenix/shirudo/$pin/vms/$VM/rootfs.qcow2" "/phenix/images/$NAME"
L sudo ls -l "/phenix/images/$NAME"
