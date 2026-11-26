#!/usr/bin/env bash
# usage: shirudo/fetch-build.sh [--check-only]   (run on the Mac)
# Builds shirudo at the commit in shirudo/PIN inside the Lima VM shirudo-dev (shirudo's infra/lima/shirudo.yaml,
# which shares the checkout at the same path) and boots shirudo's own test VM "ref" there as the reference target.
# --check-only: only verify that the checkout HEAD is the pin.
# SHIRUDO_SRC: the shirudo checkout (default ~/git/shirudo). LIMA_VM: the build VM (default shirudo-dev).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${SHIRUDO_SRC:-$HOME/git/shirudo}
vm=${LIMA_VM:-shirudo-dev}
pin=$(cat "$here/PIN")

head=$(git -C "$src" rev-parse HEAD)
if [ "$head" != "$pin" ]; then
  echo "shirudo checkout $src is at $head, not the pin $pin (shirudo/PIN); check out the pin first" >&2
  exit 1
fi
if ! git -C "$src" diff --quiet HEAD --; then
  echo "shirudo checkout $src has uncommitted changes to tracked files; changes go in shirudo/patches/, not the checkout" >&2
  exit 1
fi
[ "${1:-}" = "--check-only" ] && exit 0

in_vm() { limactl shell --workdir "$src" "$vm" bash -lc "$*"; }
in_vm 'ulimit -l | grep -qx unlimited' || { echo "$vm: locked-memory limit is not unlimited" >&2; exit 1; }
in_vm testing/vm/kernel-artifact.sh fetch
in_vm make
in_vm make shirudo-build
in_vm make -C testing vm VM_NAME=ref
