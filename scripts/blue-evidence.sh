#!/usr/bin/env bash
# Save the blue team's OpenSearch evidence as files, with the queries that produced them (ww-ebo.10).
# Usage (on the Mac): scripts/blue-evidence.sh [-e experiment] [-v blue-vm] [-f FROM] [-t TO] [-r run-id]
#   FROM/TO: UTC, e.g. 2026-11-09T02:14:00Z (default: the last 20 minutes). Needs the blue VM up with miniccc.
# Writes docs/evidence/<run-id>/{queries/*.json, results/*.json, summary.txt}. Queries run INSIDE blue against
# Malcolm's OpenSearch (https://127.0.0.1:9200, /opt/malcolm/.opensearch.primary.curlrc) via cc send/exec, the same way
# .build/ccrun.sh does it. Only the cc filter/command/response state of the named experiment is touched.
set -euo pipefail
exp=mitm vm=blue from= to= run=
while getopts e:v:f:t:r: o; do case $o in e) exp=$OPTARG;; v) vm=$OPTARG;; f) from=$OPTARG;; t) to=$OPTARG;; r) run=$OPTARG;; *) exit 2;; esac; done
to=${to:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
from=${from:-$(date -u -v-20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-20 min' +%Y-%m-%dT%H:%M:%SZ)}
run=${run:-$(date -u +%Y%m%dT%H%M%SZ)}
root=$(cd "$(dirname "$0")/.." && pwd); out=$root/docs/evidence/$run
mkdir -p "$out/queries" "$out/results"
mm() { limactl shell phenix sudo docker exec minimega mm "$@" 2>&1 | grep -v "INFO main.go" || true; }

# --- the queries (all on arkime_sessions3-*: Zeek logs, Suricata alerts and Arkime sessions share it) ---
W="{\"range\":{\"@timestamp\":{\"gte\":\"$from\",\"lte\":\"$to\"}}}"
q() { printf '%s\n' "$2" > "$out/queries/$1.json"; }
q 01-arpspoof-notices '{"size":100,"sort":[{"@timestamp":"asc"}],"_source":["@timestamp","event.dataset","zeek.notice.note","zeek.notice.msg","zeek.notice.sub","zeek.notice.src"],
 "query":{"bool":{"filter":['"$W"',{"query_string":{"query":"event.dataset:notice AND zeek.notice.note:\"ArpSpoof::Conflict\""}}]}}}'
q 02-zeek-modbus-by-src-dst '{"size":0,"query":{"bool":{"filter":['"$W"',{"term":{"event.dataset":"modbus"}}]}},
 "aggs":{"src":{"terms":{"field":"source.ip","size":20},"aggs":{"dst":{"terms":{"field":"destination.ip","size":20}}}}}}'
q 03-datasets-in-window '{"size":0,"query":{"bool":{"filter":['"$W"']}},"aggs":{"dataset":{"terms":{"field":"event.dataset","size":50}}}}'
q 04-suricata-alerts '{"size":200,"sort":[{"@timestamp":"asc"}],"_source":["@timestamp","rule.id","rule.name","source.ip","destination.ip","destination.port"],
 "query":{"bool":{"filter":['"$W"',{"query_string":{"query":"event.dataset:alert AND event.module:suricata"}}]}},
 "aggs":{"rule":{"terms":{"field":"rule.name","size":50}}}}'
q 05-arkime-tcp502-sessions '{"size":100,"sort":[{"@timestamp":"asc"}],"_source":["@timestamp","firstPacket","lastPacket","source.ip","destination.ip","destination.port","network.packets","network.bytes"],
 "query":{"bool":{"filter":['"$W"',{"query_string":{"query":"event.provider:arkime AND ipProtocol:6 AND destination.port:502"}}]}},
 "aggs":{"pair":{"terms":{"field":"source.ip","size":20},"aggs":{"dst":{"terms":{"field":"destination.ip","size":20}}}}}}'

# --- guest script: run each query, print "=== name ===" then the JSON body ---
g=$out/blue-run.sh; : > "$g"
for f in "$out"/queries/*.json; do n=$(basename "$f" .json)
  { echo "echo '=== $n ==='"
    echo "curl -sk --config /opt/malcolm/.opensearch.primary.curlrc -H 'Content-Type: application/json' 'https://127.0.0.1:9200/arkime_sessions3-*/_search?ignore_unavailable=true' -d @- <<'QEOF'"
    cat "$f"; echo "QEOF"; echo "echo"; } >> "$g"
done
b=blue-ev-$run.sh   # unique name: cc send does not overwrite a delivered file
limactl shell phenix sudo cp "$g" /phenix/images/$b
mm namespace "$exp" clear cc filter >/dev/null
mm namespace "$exp" cc delete response all >/dev/null
mm namespace "$exp" cc delete command all >/dev/null
mm namespace "$exp" cc filter hostname="$vm" >/dev/null
mm namespace "$exp" cc send /phenix/images/$b >/dev/null
mm namespace "$exp" cc exec bash /tmp/miniccc/files/$b >/dev/null
for i in $(seq 40); do sleep 3; r=$(mm namespace "$exp" cc responses all raw); grep -q '=== 05-' <<<"$r" && grep -q '"took"' <<<"$r" && [ "$(grep -c '^=== ' <<<"$r")" -ge 5 ] && break; done
mm namespace "$exp" clear cc filter >/dev/null
printf '%s\n' "$r" > "$out/results/raw-cc-response.txt"
python3 -I - "$out" "$from" "$to" "$exp" "$vm" <<'PY'
import json, re, sys
out, frm, to, exp, vm = sys.argv[1:]
raw = open(out + '/results/raw-cc-response.txt').read()
parts = re.split(r"^(?:\S+: )?=== (\S+) ===\s*$", raw, flags=re.M)
lines = [f'window {frm} .. {to} (UTC), experiment {exp}, vm {vm}']
for name, body in zip(parts[1::2], parts[2::2]):
    s, e = body.find('{'), body.rfind('}')
    try: d = json.loads(body[s:e + 1])
    except ValueError: lines.append(f'{name}: NOT JSON'); continue
    json.dump(d, open(f'{out}/results/{name}.json', 'w'), indent=1)
    h = d.get('hits', {}); t = h.get('total', {}); t = t.get('value', t) if isinstance(t, dict) else t
    lines.append(f'{name}: total hits {t}')
    def walk(a, p=''):
        for k, v in a.items():
            if isinstance(v, dict) and 'buckets' in v:
                for b in v['buckets']:
                    lines.append(f'    {p}{k}={b["key"]}: {b["doc_count"]}'); walk(b, p + '  ')
    walk(d.get('aggregations', {}))
open(out + '/summary.txt', 'w').write('\n'.join(lines) + '\n'); print('\n'.join(lines))
PY
rm -f "$g"; echo "saved: docs/evidence/$run"
