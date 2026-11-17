# rtu-2: three extra 104 servers: 25405 (double, IOA test), 25407 (double) and 25408 (single) for the rtu-1 client
cd /tmp/miniccc/files; X=$(ls -t *iec60870-5-104-server.xml | head -1)
IP=$(ip -4 -o addr show | grep -o '10\.1\.1\.[0-9]*' | head -1)
pkill -f 'bennu-field-device --f /tmp/ev-104' ; sleep 1
for v in 25405:double 25407:double 25408:single; do P=${v%%:*}; K=${v##*:}
  sed -e "s#tcp://127.0.0.1:2404#tcp://$IP:$P#" -e "s#udp://239.0.0.1:40000#udp://239.0.0.98:$((P+20000))#" -e "s#tcp://127.0.0.1:5555#tcp://127.0.0.1:$((P-20000))#" -e "s#rtu-1-104-outstation.log#/tmp/ev-104-$P-events.log#" -e "s#<subtype>double</subtype>#<subtype>$K</subtype>#" $X > /tmp/ev-104-$P.xml
  (cd /tmp && exec setsid stdbuf -oL bennu-field-device --f /tmp/ev-104-$P.xml) > /tmp/ev-104-$P.log 2>&1 < /dev/null &
done
sleep 4; cat /etc/bennu-bundle; ss -ltnp | grep -E ':254|:502'; ps -eo pid,args | grep ev-104 | grep -v grep
