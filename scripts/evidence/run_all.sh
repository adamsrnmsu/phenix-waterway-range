#!/bin/bash
# One command: regenerate all evidence (Playwright shots + GIFs + HMI transit GIF).
# Needs: docker, limactl, range running, parseus at :8080, Kibana :5601, phenix :3000.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
./capture.sh || rc=1
./hmi_gif.sh || rc=1
echo; echo "== artifacts =="; ls -lh ../../docs/shots/playwright
exit $rc
