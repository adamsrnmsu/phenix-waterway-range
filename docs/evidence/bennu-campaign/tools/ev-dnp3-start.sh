# rtu-2: two extra DNP3 outstations (20997 direct-operate point, 20998 SBO point); Modbus fd untouched
cd /tmp/miniccc/files; X=$(ls -t *dnp3-server.xml | head -1); H=$(hostname)
IP=$(ip -4 -o addr show | grep -o '10\.1\.1\.[0-9]*' | head -1)
pkill -f 'bennu-field-device --f /tmp/ev-dnp3' ; sleep 1
for v in 20997:nosbo 20998:sbo; do P=${v%%:*}; K=${v##*:}
  sed -e "s#tcp://127.0.0.1:20000#tcp://$IP:$P#" -e "s#udp://239.0.0.1:40000#udp://239.0.0.99:$((P+29000))#" -e "s#tcp://127.0.0.1:5555#tcp://127.0.0.1:$((P-15000))#" -e "s#rtu-1-dnp3-outstation.log#/tmp/ev-dnp3-$P-events.log#" $X > /tmp/ev-dnp3-$P.xml
  [ $K = nosbo ] && sed -i 's#<sbo>1</sbo>##' /tmp/ev-dnp3-$P.xml
  (cd /tmp && exec setsid stdbuf -oL bennu-field-device --f /tmp/ev-dnp3-$P.xml) > /tmp/ev-dnp3-$P.log 2>&1 < /dev/null &
done
sleep 4; cat /etc/bennu-bundle; ss -ltnp | grep -E ':2099|:502'; ps -eo pid,args | grep ev-dnp3 | grep -v grep
