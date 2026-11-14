#!/bin/bash
# usage: images/ferrofire-rtu.sh [qc2]   (run on the Mac)
# Installs the ferrofire Buildroot RTU image (default ~/git/ferrofire/image/out/ferrofire-rtu-arm64.qc2) into the Lima VM
# as /phenix/images/ferrofire-rtu-arm64.qc2 and injects miniccc into root partition 2. Refuses to overwrite the image
# while a started experiment uses it.
set -euo pipefail
SRC=${1:-$HOME/git/ferrofire/image/out/ferrofire-rtu-arm64.qc2}
NAME=ferrofire-rtu-arm64.qc2
DST=/phenix/images/$NAME
VM() { limactl shell phenix -- "$@"; }
PX() { VM sudo docker exec phenix phenix "$@"; }

[[ -f $SRC ]] || { echo "no image at $SRC" >&2; exit 1; }
# a started experiment's topology references the image by name. Fail closed: any error here aborts the install.
# `exp list` is a table: | NAME | TOPOLOGY | SCENARIO | STARTED | ...; STARTED is empty for stopped experiments.
list=$(PX exp list)
grep -q '| *STARTED *|' <<<"$list" || { echo "unexpected 'px exp list' output, aborting" >&2; exit 1; }
for t in $(awk -F'|' '$5 ~ /[0-9]/ { gsub(/ /,"",$3); print $3 }' <<<"$list"); do
  topo=$(PX cfg get "topology/$t" -o yaml)
  if grep -qF "image: $NAME" <<<"$topo"; then
    echo "refusing: a started experiment uses topology $t with $NAME" >&2; exit 1
  fi
done
VM sudo cp "$SRC" "$DST"
VM sudo docker cp minimega:/opt/minimega/bin/miniccc /phenix/miniccc
PX image inject-miniexe /phenix/miniccc "$DST:2"
VM sudo ls -l "$DST"
