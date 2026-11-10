#!/bin/bash
# usage: images/build.sh <name>   (run on the Mac; recipe = images/recipes/<name>.env)
# ARCH=amd64 in the recipe (default arm64) builds an x86_64 BIOS/grub-pc msdos qcow2 (debootstrap under qemu-user binfmt).
# Builds an arm64 UEFI qcow2 into /phenix/images/<name>.qc2 inside the Lima VM "phenix".
set -euo pipefail
NAME_ARG=${1:?usage: build.sh <name>}
HERE=$(cd "$(dirname "$0")" && pwd)
set -a; . "$HERE/recipes/$NAME_ARG.env"; set +a
ARCH=${ARCH:-arm64}
VM() { if command -v limactl >/dev/null; then limactl shell phenix -- "$@"; else "$@"; fi; }
PX() { VM sudo docker exec phenix phenix "$@"; }
OUT=/phenix/images
STAGE=$OUT/stage/$NAME

# stage scripts/overlays where the phenix container can see them (/phenix is the only shared mount)
VM sudo rm -rf "$STAGE"; VM sudo mkdir -p "$STAGE/scripts" "$STAGE/overlays"
sargs=(); oargs=()
for s in $SCRIPTS; do
  [[ $s = /* ]] || s=$HERE/scripts/$s
  VM sudo cp "$s" "$STAGE/scripts/"; sargs+=("$STAGE/scripts/$(basename "$s")")
done
for o in $OVERLAYS; do
  [[ $o = /* ]] || o=$HERE/overlays/$o
  VM sudo cp -r "$o" "$STAGE/overlays/"; oargs+=("$STAGE/overlays/$(basename "$o")")
done
join() { local IFS=,; echo "$*"; }
args=(-m "$MIRROR" -r "$RELEASE" -v "$VARIANT" -s "$SIZE" --compress)
[[ -n "$PACKAGES" ]] && args+=(-P "$(join $PACKAGES)")
((${#sargs[@]})) && args+=(-T "$(join "${sargs[@]}")")
((${#oargs[@]})) && args+=(-O "$(join "${oargs[@]}")")

if [[ $ARCH = amd64 ]]; then
  # foreign-arch debootstrap needs qemu-user binfmt (F flag) in the VM kernel; qemu-user-binfmt = distro package, no container restart
  VM test -e /proc/sys/fs/binfmt_misc/qemu-x86_64 || VM sudo apt-get install -y qemu-user-binfmt
fi
PX image delete "$NAME" >/dev/null 2>&1 || true
VM sudo rm -f "$OUT/$NAME.qc2" "$OUT/$NAME" "$OUT/$NAME.tar"
PX image create "${args[@]}" "$NAME"
PX image build --dry-run -o "$OUT" "$NAME"            # writes $OUT/$NAME.vmdb
if [[ $ARCH = amd64 ]]; then
  # vmdb2's debootstrap step takes `arch:` (sets state.arch -> grub-pc/i386-pc); phenix's msdos+grub bios layout stays as is
  VM sudo sed -i 's/^\( *- debootstrap: .*\)$/\1\n    arch: amd64/' "$OUT/$NAME.vmdb"
  ROOTPART=1; MCC=/phenix/amd64/miniccc
  # amd64 miniccc: cross-built from ~/git/minimega (GOARCH=amd64, CGO off) in a golang container
  # (copy first: version.bash writes internal/version, and the clone stays untouched)
  # inject-miniexe requires the file to be named miniccc
  VM sudo mkdir -p /phenix/amd64; VM test -x $MCC || VM sudo docker run --rm -v "$HOME/git/minimega:/src:ro" -v /phenix/amd64:/out \
    -e GOOS=linux -e GOARCH=amd64 -e CGO_ENABLED=0 -e GOFLAGS=-mod=vendor golang:1.24 \
    bash -c 'cp -r /src /s && cd /s && scripts/version.bash && go build -o /out/miniccc ./cmd/miniccc'
else
  # phenix's Debian/Kali package lists name amd64 kernels; swap for arm64
  VM sudo sed -i 's/linux-image-amd64/linux-image-arm64/;s/linux-headers-amd64/linux-headers-arm64/' "$OUT/$NAME.vmdb"
  VM sudo python3 -I "$HERE/uefi_patch.py" "$OUT/$NAME.vmdb"
  ROOTPART=2
fi
VM sudo flock /tmp/phenix-image-build.lock \
  docker exec phenix phenix image build -o "$OUT" -x "$OUT/$NAME.vmdb"

# miniccc (+ minirouter) built for arm64 live in the minimega image; root is partition 2 (amd64/BIOS: partition 1)
if [[ $ARCH = amd64 ]]; then MCC=/phenix/amd64/miniccc
else MCC=/phenix/miniccc; VM sudo docker cp minimega:/opt/minimega/bin/miniccc $MCC; fi
PX image inject-miniexe $MCC "$OUT/$NAME.qc2:$ROOTPART"
if [[ ${INJECT_MINIROUTER:-0} = 1 ]]; then
  VM sudo docker cp minimega:/opt/minimega/bin/minirouter /phenix/minirouter
  PX image inject-miniexe /phenix/minirouter "$OUT/$NAME.qc2:$ROOTPART"
fi
VM sudo ls -l "$OUT/$NAME.qc2"
