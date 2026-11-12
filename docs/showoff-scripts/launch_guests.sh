#!/bin/bash
# start ground-truth sampler (rtu-1) and Modbus poller (opc) for $1 seconds, in the background on the guests
D=${1:-600}; S=$(dirname "$0"); CX=/private/tmp/claude-501/-Users-ryanadams-git/d86dff81-4847-4d36-8229-fdb7434aac42/scratchpad/cx.sh
b=$(base64 < $S/gt_sampler.py | tr -d '\n'); W=3 $CX rtu-1 "echo $b | base64 -d > /tmp/gt.py; nohup python3 /tmp/gt.py $D /tmp/gt.csv >/tmp/gt.err 2>&1 &"
b=$(base64 < $S/modbus_poller.py | tr -d '\n'); W=3 $CX opc "echo $b | base64 -d > /tmp/mbp.py; nohup /opt/opcua-gateway/venv/bin/python /tmp/mbp.py $D /tmp/mb.csv >/tmp/mb.err 2>&1 &"
