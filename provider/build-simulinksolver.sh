#!/usr/bin/env bash
# Build the simulinksolver binary. Default: ferrofire (~/git/ferrofire, override with FERROFIRE_DIR). SOLVER=legacy builds
# the old waterway-sim crate in the Lima VM. Either way the result lands in provider/waterway-sim/dist/simulinksolver,
# so the README step "cp dist/simulinksolver topologies/waterway-arm64/injects/" is unchanged.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ "${SOLVER:-ferrofire}" = legacy ]; then
  exec "$here/waterway-sim/build-linux.sh"
fi
ff="${FERROFIRE_DIR:-$HOME/git/ferrofire}"
[ -x "$ff/build-linux.sh" ] || { echo "ferrofire not found at $ff (set FERROFIRE_DIR, or SOLVER=legacy)" >&2; exit 1; }
"$ff/build-linux.sh"
mkdir -p "$here/waterway-sim/dist"
cp "$ff/dist/simulinksolver" "$here/waterway-sim/dist/simulinksolver"
echo "-> $here/waterway-sim/dist/simulinksolver"
