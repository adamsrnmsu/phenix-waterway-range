#!/usr/bin/env bash
# usage: shirudo/up.sh   (run on the Mac)
# Starts experiment shirudo-arm64 (topologies/shirudo-arm64): refuses while any other experiment is started, starts
# rtu-s's swtpm, renders the topology (recreating the stopped experiment when the render changed: an edit or a new
# PIN), starts it, waits for rtu-s's shirudo status over its host-only
# SSH (phenix VM 127.0.0.1:22110), then mirrors the SHOT VLAN to purple's capture NIC (index 1).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd) repo=$(cd "$(dirname "$0")/.." && pwd)
D=/phenix/shirudo/$(cat "$here/PIN") X=shirudo-arm64
px() { limactl shell phenix sudo docker exec phenix phenix "$@"; }

list=$(px exp list 2>/dev/null)
grep -q '| *STARTED *|' <<<"$list" || { echo "unexpected 'phenix exp list' output, aborting" >&2; exit 1; }
others=$(awk -F'|' '$5 ~ /[0-9]/ { gsub(/ /,"",$2); if ($2 != "'$X'") print $2 }' <<<"$list")
[ -z "$others" ] || { echo "refusing: other experiments are started: $(echo $others); stop them first (memory)" >&2; exit 1; }
"$here/fetch-build.sh" --check-only
limactl shell phenix test -e "/phenix/images/ferrofire-shirudo-arm64.qc2" || { echo "no ferrofire-shirudo-arm64.qc2; run images/ferrofire-shirudo.sh" >&2; exit 1; }

started=$(awk -F'|' '$5 ~ /[0-9]/ { gsub(/ /,"",$2); if ($2 == "'$X'") print "yes" }' <<<"$list")
out=$HOME/phenix/topologies/$X; mkdir -p "$out"
new=$(sed "s|@D@|$D|g" "$repo/topologies/$X/$X.yaml"; echo "---"; cat "$repo/topologies/$X/$X-scenario.yaml")
old=$(cat "$out/topology.yaml" 2>/dev/null; echo "---"; cat "$out/scenario.yaml" 2>/dev/null)
exists=$(grep -qE "^\| *$X +\|" <<<"$list" && echo yes || true)
if [ "$started" = yes ]; then
  [ "$new" = "$old" ] || { echo "refusing: $X is running with an older topology; run shirudo/down.sh, then up.sh" >&2; exit 1; }
  echo "$X is already started"
elif [ -z "$exists" ] || [ "$new" != "$old" ]; then
  [ -n "$exists" ] && { echo "topology changed: recreating $X (rtu-s's disk and vTPM are kept)"; px exp delete "$X" >/dev/null; }
  sed "s|@D@|$D|g" "$repo/topologies/$X/$X.yaml" > "$out/topology.yaml"
  cp "$repo/topologies/$X/$X-scenario.yaml" "$out/scenario.yaml"
  px cfg delete "scenario/$X" >/dev/null 2>&1 || true
  px cfg delete "topology/$X" >/dev/null 2>&1 || true
  px cfg create "/phenix/topologies/$X/topology.yaml" "/phenix/topologies/$X/scenario.yaml" >/dev/null
  px exp create "$X" -t "$X" -s "$X" >/dev/null
fi

"$here/swtpm.sh" start rtu-s
"$here/swtpm.sh" status rtu-s
if [ "$started" != yes ]; then px exp start "$X" >/dev/null; echo "experiment $X started"; fi

key=$(limactl shell phenix mktemp); trap 'limactl shell phenix sudo rm -f "$key"' EXIT
limactl shell phenix sudo install -m600 "$D/vms/rtu-s/ssh/id_ed25519" "$key"
for _ in $(seq 100); do
  st=$(limactl shell phenix sudo ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=3 -p 22110 root@127.0.0.1 'shirudo-runtime status --json' 2>/dev/null | jq -r .status 2>/dev/null) && [ -n "$st" ] && break
  sleep 3
done
echo "rtu-s shirudo status: ${st:-unreachable}"
VLAN=SHOT "$repo/scripts/mirror.sh" "$X" purple 1
[ "${st:-}" = ok ] || { echo "rtu-s is not ok (status ${st:-unreachable})" >&2; exit 1; }
