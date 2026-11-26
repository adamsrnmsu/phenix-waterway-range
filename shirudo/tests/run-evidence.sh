#!/usr/bin/env bash
# Test: an attack run's evidence (docs/shirudo/raw/<run>) is complete. Every phase has a window; each OT attack phase
# has attacker (10.1.1.66) packets in the run's pcap; every root tamper attempt but list_pins was refused; rtu-s's
# shirudo status was ok after every phase; parseus counted documents in every phase; the field device was active after
# every phase. Runs on the Mac.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
run=${1:?run-id} R=$repo/docs/shirudo/raw/${1:?run-id}
fail() { echo "FAIL: $*"; exit 1; }
[ -f "$R/phases.csv" ] || fail "no phases.csv"
pcap=/var/lib/shirudo-range/pcap/$run.pcap
while IFS=, read -r -u 3 p a b; do
  case $p in recon|write|malformed|dnp3|fuzz)
    n=$(limactl shell phenix sudo tcpdump -nr "$pcap" -tt 'host 10.1.1.66' 2>/dev/null </dev/null | awk -v a="$a" -v b="$b" '$1>=a && $1<=b' | wc -l)
    [ "$n" -gt 0 ] || fail "$p: no attacker packets in the pcap" ;;
  esac
  st=$(ls "$R"/*-"$p"-status.json | head -1)
  sed -n '/^{/,$p' "$st" | jq -e '.status == "ok"' >/dev/null || fail "$p: rtu-s status not ok"
  grep -qx active "$(ls "$R"/*-"$p"-fd.txt | head -1)" || fail "$p: field device not active"
  awk -F'\t' -v p="$p" '$1==p && $3>0' "$R/parseus.tsv" | grep -q . || fail "$p: no parseus documents"
  # each kernel-obs table must cover the phase: its interval starts no later than the phase did
  for k in "$R"/*-"$p"-kobs-*.json; do
    since=$(sed -n '/^{/,$p' "$k" | jq -r '.interval.since_unix_nano')
    [ "${since:0:10}" -le "${a%.*}" ] || fail "$p: $(basename "$k") starts at ${since:0:10}, after the phase (${a%.*})"
  done
done 3< <(tail -n +2 "$R/phases.csv")
if grep -q '^tamper,' "$R/phases.csv"; then
  # each attempt must fail with shirudo's (or the kernel's) refusal, not with a missing precondition
  t=$(ls "$R"/*-tamper.txt | head -1)
  grep -q '^SKIP' "$t" && fail "tamper: an attempt was skipped: $(grep '^SKIP' "$t")"
  while read -r name want; do
    awk -v n="## $name" '$0==n{f=1; next} /^## /{f=0} f' "$t" | grep -q -- "$want" || fail "tamper $name: no \"$want\""
    awk -v n="## $name" '$0==n{f=1; next} /^## /{f=0} f' "$t" | grep -qx 'rc=0' && fail "tamper $name succeeded"
  done <<'EXP'
read_pin Permission denied
unpin_kernel_obs Operation not permitted
umount_bpffs must be superuser
unsigned_bpf_load errno 13
forged_upatch does not match signed content
archive_write Permission denied
runtime_binary_write Read-only file system
EXP
fi
# every Suricata event must land in some phase window (collect.sh widens windows by 2 s)
if [ -s "$R/suricata-events.ndjson" ]; then
  total=$(wc -l < "$R/suricata-events.ndjson" | tr -d ' ')
  inwin=$(awk -F'\t' 'NR>1{s+=$NF} END{print s+0}' "$R/suricata-alerts.tsv")
  [ "$inwin" -eq "$total" ] || fail "suricata: $((total - inwin)) of $total events fall outside every phase window"
fi
echo "PASS run-evidence $run"
