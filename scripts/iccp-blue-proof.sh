#!/usr/bin/env bash
# ww-otj.51 proof: replay ICCP pcaps onto the blue VM's capture NIC (live Zeek in Malcolm) and query OpenSearch inside blue.
# Usage (Mac): scripts/iccp-blue-proof.sh [-e experiment] [-v blue-vm] [-o outdir] PCAP...   (pcaps are on the Mac; copied to Lima)
# Needs: experiment running (kali-purple-arm64 with images/malcolm-iccp.sh applied), miniccc up in blue, Malcolm healthy.
set -euo pipefail
exp=blue-iccp vm=blue out=
while getopts e:v:o: o; do case $o in e) exp=$OPTARG;; v) vm=$OPTARG;; o) out=$OPTARG;; *) exit 2;; esac; done; shift $((OPTIND-1))
root=$(cd "$(dirname "$0")/.." && pwd); out=${out:-$root/docs/evidence/iccp-malcolm}; mkdir -p "$out"
L() { limactl shell phenix "$@"; }
mm() { L sudo docker exec minimega mm "$@" 2>&1 | grep -v "INFO main.go" || true; }
# guest queries (also saved as the evidence)
cat > "$out/blue-queries.sh" <<'QEOF'
Q() { echo "=== $1 ==="; curl -sk -m 60 --config /opt/malcolm/.opensearch.primary.curlrc -H 'Content-Type: application/json' "https://127.0.0.1:9200/arkime_sessions3-*/$2" ${3:+-d "$3"}; echo; }
Q count-iccp  _count '{"query":{"term":{"event.dataset":"iccp"}}}'
Q count-mms   _count '{"query":{"term":{"event.dataset":"mms"}}}'
Q iccp-by-class _search?size=0 '{"query":{"term":{"event.dataset":"iccp"}},"aggs":{"class":{"terms":{"field":"zeek.iccp.class","size":20}},"op":{"terms":{"field":"zeek.iccp.op"}}}}'
Q mms-by-service _search?size=0 '{"query":{"term":{"event.dataset":"mms"}},"aggs":{"svc":{"terms":{"field":"zeek.mms.mms_service","size":20}},"pdu":{"terms":{"field":"zeek.mms.pdu"}}}}'
Q sample-iccp _search?size=1 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"iccp"}},{"term":{"zeek.iccp.class":"data"}}]}},"sort":[{"@timestamp":"desc"}]}'
Q sample-mms _search?size=1 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"mms"}},{"term":{"zeek.mms.pdu":"confirmed_resp"}}]}},"sort":[{"@timestamp":"desc"}]}'
Q weird _search?size=3 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"weird"}},{"term":{"zeek.weird.source":"ICCP"}}]}}}'
echo "=== index-pattern fields ==="
curl -sk -m 60 -u 'admin:MalcolmBlue1!' 'https://127.0.0.1/dashboards/api/saved_objects/index-pattern/arkime_sessions3-*' | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x["name"] for x in json.loads(d["attributes"]["fields"]) if x["name"].startswith(("zeek.iccp.","zeek.mms."))];print(len(f),"fields",f)'
echo "=== zeek packages ==="; docker exec malcolm-zeek-live-1 true 2>/dev/null; docker ps --format '{{.Names}}' | grep zeek | head -2
QEOF
b=iccp-proof-$(date -u +%H%M%S).sh
L sudo cp "$out/blue-queries.sh" /phenix/images/$b
# replay: copy pcaps to Lima, inject on blue's capture tap (iface index 1)
tap=$(mm namespace "$exp" .headers false .columns name,tap vm info | grep -E "\| *$vm *\|" | cut -d'|' -f3 | tr -d '[] ' | cut -d, -f2)
[ -n "$tap" ] || { echo "no capture tap for $vm" >&2; exit 1; }
L mkdir -p /tmp/iccp-replay; for p in "$@"; do limactl cp "$p" phenix:/tmp/iccp-replay/; done
limactl cp "$root/scripts/pcap_inject.py" phenix:/tmp/iccp-replay/
echo "inject on $tap at $(date -u +%T)Z"
L sudo python3 -I /tmp/iccp-replay/pcap_inject.py "$tap" --delay "${DELAY:-0.002}" $(for p in "$@"; do echo /tmp/iccp-replay/$(basename "$p"); done) | tee "$out/inject.txt"
sleep ${SETTLE:-90}   # Zeek -> filebeat -> Logstash -> OpenSearch
mm namespace "$exp" clear cc filter >/dev/null; mm namespace "$exp" cc delete response all >/dev/null; mm namespace "$exp" cc delete command all >/dev/null
mm namespace "$exp" cc filter hostname="$vm" >/dev/null
mm namespace "$exp" cc send /phenix/images/$b >/dev/null
mm namespace "$exp" cc exec bash /tmp/miniccc/files/$b >/dev/null
for i in $(seq 40); do sleep 3; r=$(mm namespace "$exp" cc responses all raw); grep -q '=== zeek packages' <<<"$r" && break; done
mm namespace "$exp" clear cc filter >/dev/null
printf '%s\n' "$r" > "$out/results.txt"; cat "$out/results.txt" | cut -c1-1500
