#!/usr/bin/env bash
# usage: shirudo/collect.sh [--aggregate-only] <run-id>   (run on the Mac, after shirudo/attack.sh <run-id>)
# --aggregate-only: redo only the per-phase tables from the saved suricata-events.ndjson and Elasticsearch.
# Stops the run's recorders and adds the remaining views to docs/shirudo/raw/<run-id>/:
#   poll.csv / attack.csv   Kali's master poll and attack results        pcap.txt  pcap size and sha256 (+ the pcap if < 20 MB)
#   suricata-alerts.tsv     purple's Suricata alerts and app-layer anomaly events per phase, by signature
#   parseus.tsv             parseus DPI documents involving rtu-s per phase and event.dataset (shirudo/parseus.sh)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd) repo=$(cd "$(dirname "$0")/.." && pwd)
agg=0; [ "${1:-}" = "--aggregate-only" ] && { agg=1; shift; }
run=${1:?run-id} R=$repo/docs/shirudo/raw/${1:?run-id} T=10.1.1.101
[ -f "$R/phases.csv" ] || { echo "no $R/phases.csv; run shirudo/attack.sh $run first" >&2; exit 1; }
L() { limactl shell phenix sudo "$@"; }
key="" tmp=$(mktemp -d); trap 'rm -rf "$tmp"; [ -z "$key" ] || L rm -f "$key"' EXIT
sh_() { printf '%s\n' "$@" > "$tmp/s.sh"; echo "$tmp/s.sh"; }

if [ "$agg" = 0 ]; then
"$here/cc.sh" kali "$(sh_ "pkill -f 'ot_poll.py $T' ; sleep 1; echo '## poll'; cat /root/$run-poll.csv; echo '## attack'; cat /root/$run-attack.csv 2>/dev/null")" > "$tmp/kali.txt"
awk '/^## poll/{f="poll"; next} /^## attack/{f="attack"; next} f{print > ("'"$R"'/" f ".csv")}' "$tmp/kali.txt"
"$here/cc.sh" purple "$(sh_ '[ -s /var/run/suricata.pid ] && kill $(cat /var/run/suricata.pid) 2>/dev/null; sleep 3; wc -l < /root/suri/eve.json')" > "$tmp/eve-lines.txt"
# eve.json is too big for a cc response: fetch it with cc recv (minimega writes it under its responses dir)
mm() { L docker exec minimega mm "$@" 2>/dev/null | grep -v 'got command' || true; }
pu=$(mm namespace shirudo-arm64 .columns name,uuid vm info | awk -F'|' '$2 ~ /^ *purple *$/ {gsub(/ /,"",$3); print $3}')
mm namespace shirudo-arm64 clear cc filter >/dev/null; mm namespace shirudo-arm64 cc filter uuid="$pu" >/dev/null
L sh -c "rm -rf /phenix/images/shirudo-arm64/miniccc_responses/*/$pu/root/suri"
mm namespace shirudo-arm64 cc recv /root/suri/eve.json >/dev/null
for _ in $(seq 60); do
  f=$(L sh -c "ls /phenix/images/shirudo-arm64/miniccc_responses/*/$pu/root/suri/eve.json 2>/dev/null | tail -1")
  [ -n "$f" ] && [ "$(L sh -c "wc -l < $f")" -ge "$(tr -dc 0-9 < "$tmp/eve-lines.txt")" ] && break; sleep 2
done
L cat "$f" | jq -c 'select(.event_type=="alert" or .event_type=="anomaly") | {t: (.flow.start // .timestamp), type: .event_type, sig: (.alert.signature // .anomaly.event // .anomaly.type), src: .src_ip, dst: .dest_ip}' > "$tmp/eve.ndjson"
L sh -c "P=/var/lib/shirudo-range/pcap; [ -s \$P/tcpdump.pid ] && kill \$(cat \$P/tcpdump.pid); rm -f \$P/tcpdump.pid" 2>/dev/null || true
sleep 1
pcap=/var/lib/shirudo-range/pcap/$run.pcap
{ L stat -c '%s bytes' "$pcap"; L sha256sum "$pcap"; } > "$R/pcap.txt"
[ "$(L stat -c %s "$pcap")" -lt 20000000 ] && L cat "$pcap" > "$R/$run.pcap"

key=$(L mktemp); L install -m600 "/phenix/shirudo/$(cat "$here/PIN")/vms/rtu-s/ssh/id_ed25519" "$key"
limactl shell phenix sudo ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -p 22110 root@127.0.0.1 'systemctl start shirudo-map-export.timer' </dev/null 2>/dev/null || true

cp "$tmp/eve.ndjson" "$R/suricata-events.ndjson"
fi

# per phase: Suricata events by signature, each in the last phase that started before it (guest clocks run about 1 s
# off the Mac's, so starts move 2 s earlier; anomaly events have no flow start and can be logged after their phase
# ends), and parseus documents by dataset in [start - 2 s, end + 3 s]
echo -e "phase\ttype\tsignature\tcount" > "$R/suricata-alerts.tsv"
echo -e "phase\tdataset\tdocs" > "$R/parseus.tsv"
starts=$(tail -n +2 "$R/phases.csv" | cut -d, -f2 | tr '\n' ' ')
while IFS=, read -r -u 3 p t0 t1; do
  next=$(awk -v t="$t0" '{for (i = 1; i <= NF; i++) if ($i + 0 > t + 0) {print $i; exit}} END {}' <<<"$starts")
  jq -r --argjson a "$t0" --argjson b "${next:-1e12}" "$(cat "$here/tools/eve_epoch.jq")"'
    (.t | eve_epoch) as $s
    | select($s >= ($a|floor) - 2 and $s < ($b|floor) - 2) | "\(.type)\t\(.sig)"' "$R/suricata-events.ndjson" 2>/dev/null |
    sort | uniq -c | awk -v p="$p" '{c=$1; $1=""; sub(/^ /,""); print p "\t" $0 "\t" c}' >> "$R/suricata-alerts.tsv" || true
  for ds in modbus modbus_detailed dnp3 dnp3_points; do
    q="{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"event.dataset\":\"$ds\"}},{\"range\":{\"@timestamp\":{\"gte\":$(( ${t0%.*} - 2 )),\"lte\":$(( ${t1%.*} + 3 )),\"format\":\"epoch_second\"}}}],\"should\":[{\"term\":{\"destination.ip\":\"$T\"}},{\"term\":{\"source.ip\":\"$T\"}}],\"minimum_should_match\":1}}}"
    printf '%s\t%s\t%s\n' "$p" "$ds" "$(L curl -s -H 'Content-Type: application/json' "http://127.0.0.1:9207/arkime_sessions3-*/_count" -d "$q" | jq -r '.count // 0')" >> "$R/parseus.tsv"
  done
done 3< <(tail -n +2 "$R/phases.csv")
echo "collected $run: $(wc -l < "$R/attack.csv" 2>/dev/null || echo 0) attack rows, $(wc -l < "$R/suricata-events.ndjson") Suricata events, $(cat "$R/pcap.txt" | head -1)"
