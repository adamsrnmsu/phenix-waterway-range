#!/bin/bash
# usage: run_capture.sh <seconds> <workdir>   (blocking). Live Zeek stack (pz-*) must be running; mirror on.
set -u
D=${1:-300}; WD=${2:-work2}; S=$(cd $(dirname $0); pwd); SP=/private/tmp/claude-501/-Users-ryanadams-git/d86dff81-4847-4d36-8229-fdb7434aac42/scratchpad
mkdir -p $WD/live-logs $WD/pcap-logs
limactl cp $S/lima_stats.py phenix:/tmp/sw/lima_stats.py
limactl shell phenix -- bash -c "cd /tmp/sw; rm -f live2.pcap st2.jsonl; sudo nohup timeout $((D+20)) tcpdump -i monitor0 -U -w /tmp/sw/live2.pcap >/tmp/sw/tcpdump2.log 2>&1 & nohup python3 /tmp/sw/lima_stats.py $D /tmp/sw/st2.jsonl >/dev/null 2>&1 &"
sleep 3
W=5 $SP/cx.sh opc 'systemctl restart opcua-gateway' >/dev/null
$S/launch_guests.sh $((D-10)) >/dev/null
T0=$(date +%s); until [ $(date +%s) -ge $((T0+D+15)) ]; do sleep 5; done
echo capture done
