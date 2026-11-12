#!/bin/bash
# Run capture.py in the official Playwright container; nothing installed on the host.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$PWD/docs/shots/playwright; mkdir -p "$OUT"
rc=0
docker run --rm --add-host host.docker.internal:host-gateway \
  -e PARSEUS_URL -e KIBANA_URL -e PHENIX_URL -e ONLY \
  -v "$OUT":/out -v "$PWD/scripts/evidence/capture.py":/capture.py:ro \
  mcr.microsoft.com/playwright/python:v1.49.0-noble \
  sh -c 'pip install -q --root-user-action=ignore playwright==1.49.0 >/dev/null 2>&1; python /capture.py' || rc=$?
# webm -> gif (ffmpeg container)
for v in "$OUT"/*.webm; do
  [ -e "$v" ] || continue
  docker run --rm -v "$OUT":/out lscr.io/linuxserver/ffmpeg:latest -y -loglevel error -i "/out/$(basename "$v")" \
    -vf "fps=8,scale=1000:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "/out/$(basename "${v%.webm}").gif"
  rm -f "$v"
done
rm -rf "$OUT/.video"
exit $rc
