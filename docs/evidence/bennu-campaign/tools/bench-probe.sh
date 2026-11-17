# run on an RTU: 200 provider QUERYs through stock bennu-probe, wall time and failures
s=$(date +%s%N); f=0
for i in $(seq 200); do timeout 3 bennu-probe --endpoint tcp://172.16.1.2:5555 --command query >/dev/null 2>&1 || f=$((f+1)); done
e=$(date +%s%N); echo "PROBE queries=200 failed=$f mean_ms=$(( (e-s)/200000000 ))"
timeout 3 bennu-probe --endpoint tcp://172.16.1.2:5555 --command read --tag lock.height 2>&1 | head -3
