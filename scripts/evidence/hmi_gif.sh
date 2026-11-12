#!/bin/bash
# HMI is not reachable from the Mac: grab minimega VM screenshots of `hmi` and assemble a GIF.
# usage: hmi_gif.sh [frames=13] [interval_s=5]   (default ~60 s)
set -euo pipefail
N=${1:-13}; DT=${2:-5}
OUT=$(cd "$(dirname "$0")/../.." && pwd)/docs/shots/playwright
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mm() { limactl shell phenix sudo docker exec minimega mm "$@"; }
for i in $(seq -w 1 "$N"); do
  mm namespace waterway vm screenshot hmi file /tmp/hmi-shot.png >/dev/null
  limactl shell phenix sudo docker cp minimega:/tmp/hmi-shot.png /tmp/hmi-shot.png
  limactl cp phenix:/tmp/hmi-shot.png "$W/f$i.png"
  [ "$i" -lt "$N" ] && sleep "$DT"
done
docker run --rm -v "$W":/w -v "$OUT":/out lscr.io/linuxserver/ffmpeg:latest -y -loglevel error -framerate 1 -i /w/f%02d.png \
  -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" -loop 0 /out/hmi-transit.gif
