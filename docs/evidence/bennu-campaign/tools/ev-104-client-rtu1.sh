# rtu-1: stock 104 client against the rtu-2 servers (25407 double-point, 25408 single-point), 9 s each
cd /tmp/miniccc/files; C=$(ls -t *iec60870-5-104-client.xml | head -1); P=/tmp/ev-104cl-$$.pcap
tcpdump -i any -U -w $P 'tcp and host 10.1.1.102 and (port 25407 or port 25408)' 2>/dev/null & TP=$!; sleep 1
for v in 25407:double 25408:single; do Q=${v%%:*}
  sed -e "s#tcp://127.0.0.1:2404#tcp://10.1.1.102:$Q#" -e "s#tcp://127.0.0.1:1330#tcp://127.0.0.1:2$Q#" $C > /tmp/ev-104cl-$Q.xml
  (cd /tmp && exec setsid stdbuf -oL bennu-field-device --f /tmp/ev-104cl-$Q.xml) > /tmp/ev-104cl-$Q.log 2>&1 < /dev/null &
  CP=$!; sleep 9; pkill -f 'bennu-field-device --f /tmp/ev-104cl'; sleep 1
  echo "##### client -> server port $Q (${v##*:}-point server)"; date -u +%FT%TZ
  echo "IOA 100 value lines: $(grep -c 'IOA: 100 value:' /tmp/ev-104cl-$Q.log)"; echo "ASDU types:"; grep '^RECVD ASDU' /tmp/ev-104cl-$Q.log | sort | uniq -c
  echo "--- first 40 lines of client log"; head -40 /tmp/ev-104cl-$Q.log
done
sleep 1; kill $TP; sleep 1
echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
