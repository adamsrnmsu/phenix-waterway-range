#!/usr/bin/env bash
# usage: shirudo/parseus.sh up|down|counts [ip]   (run on the Mac; ip defaults to rtu-s 10.1.1.101)
# parseus Zeek DPI over the shirudo-arm64 OT VLAN, live, in the phenix VM (the parseus in kali-purple-parseus-arm64 has
# no Zeek DPI). Same pipeline as docs/dnp3-parseus-evidence.md:
#   shz-zeek  parseus-zeek:<tag> (parseus deploy/integrations/zeek, PR #4 branch) on purple's capture tap, host net
#   shz-ing   python -m parseus.ingestors.zeek from that branch's src/, in python:3.12-slim
#   shz-es    Elasticsearch 8.19.5, security off, 127.0.0.1:9207
# The capture tap is purple's NIC 1, which scripts/mirror.sh (run by shirudo/up.sh) feeds with the SHOT VLAN: Zeek on
# the host side of the tap sees every mirrored frame. counts: documents per event.dataset that involve <ip>.
set -euo pipefail
cmd=${1:?up|down|counts} ip=${2:-10.1.1.101}
X=shirudo-arm64 PARSEUS=${PARSEUS:-$HOME/git/parseus-wt-dpfix} TAG=${ZEEK_TAG:-dpi-1f39fb8}
L() { limactl shell phenix sudo "$@"; }
dk() { L docker "$@"; }
logs=/var/lib/shirudo-range/zeek-logs

case $cmd in
up)
  row=$(L docker exec minimega mm namespace "$X" .columns name,tap vm info 2>/dev/null | awk -F'|' '$2 ~ /^ *purple *$/ {print $3}')
  tap=$(tr -d '[] ' <<<"$row" | cut -d, -f2)
  [ -n "$tap" ] || { echo "no capture tap for purple in $X; is it started (shirudo/up.sh)?" >&2; exit 1; }
  dk rm -f shz-zeek shz-ing shz-es >/dev/null 2>&1 || true
  L rm -rf "$logs"; L mkdir -p "$logs"
  dk run -d --name shz-es -p 127.0.0.1:9207:9200 -e discovery.type=single-node -e xpack.security.enabled=false \
    -e ES_JAVA_OPTS="-Xms1g -Xmx1g" docker.elastic.co/elasticsearch/elasticsearch:8.19.5 >/dev/null
  for _ in $(seq 60); do L curl -fs http://127.0.0.1:9207/_cluster/health >/dev/null 2>&1 && break; sleep 2; done
  dk run -d --name shz-zeek --network host -e ZEEK_IFACE="$tap" -v "$logs:/zeek/logs" -w /zeek/logs \
    "parseus-zeek:$TAG" >/dev/null
  dk run -d --name shz-ing --network host -v "$PARSEUS/src:/src:ro" -v "$logs:/zeek/logs:ro" -e PYTHONPATH=/src \
    -e DATASTORE_HOST_URL=http://127.0.0.1:9207 -e DATASTORE_TYPE=elasticsearch -e INGESTOR_ZEEK_LOG_DIR=/zeek/logs \
    -e INGESTOR_ZEEK_STATE_FILE=/tmp/zeek_state.json python:3.12-slim \
    sh -c 'pip install -q --root-user-action=ignore "elasticsearch>=8,<9" opensearch-py python-dateutil && exec python -m parseus.ingestors.zeek' >/dev/null
  echo "parseus DPI on $tap (purple capture) -> http://127.0.0.1:9207 (phenix VM); parseus $(git -C "$PARSEUS" rev-parse --short HEAD)" ;;
down)
  dk rm -f shz-zeek shz-ing shz-es >/dev/null 2>&1 || true
  echo "parseus DPI stopped (Zeek logs kept in $logs on the phenix VM)" ;;
counts)
  for ds in modbus modbus_detailed dnp3 dnp3_points; do
    q="{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"event.dataset\":\"$ds\"}}],\"should\":[{\"term\":{\"destination.ip\":\"$ip\"}},{\"term\":{\"source.ip\":\"$ip\"}}],\"minimum_should_match\":1}}}"
    n=$(L curl -s -H 'Content-Type: application/json' "http://127.0.0.1:9207/arkime_sessions3-*/_count" -d "$q" | jq -r '.count // 0')
    echo "$ds $n"
  done ;;
*) echo "usage: $0 up|down|counts [ip]" >&2; exit 2 ;;
esac
