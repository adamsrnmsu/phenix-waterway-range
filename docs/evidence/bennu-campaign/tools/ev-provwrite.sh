# kali: provider WRITE parsing (stock bennu-simulink-provider, ZMQ REP 172.16.1.2:5555), raw ZMTP client; pcap
cd /tmp/miniccc/files; Z=$(ls -t *zreq.py | head -1); P=/tmp/ev-provwrite-$$.pcap
tcpdump -i any -U -w $P "tcp port 5555 and host 172.16.1.200" 2>/tmp/tcpdump-$$.err & TP=$!; sleep 2
date -u +%FT%TZ; q() { python3 $Z 172.16.1.2 5555 "$1"; sleep 1; }
echo "--- duplicate tag: last value should win"; q "READ=lowervalve.open"; q "WRITE=lowervalve.open:1,lowervalve.open:0"; q "READ=lowervalve.open"
q "WRITE=lowervalve.open:0,lowervalve.open:1"; q "READ=lowervalve.open"
echo "--- malformed point in a batch is dropped, batch still ACKed"; q "WRITE=lowervalve.open:0,no-colon-here"; q "READ=lowervalve.open"
echo "--- nothing parseable at all, still ACKed"; q "WRITE=junk"
sleep 1; kill $TP; sleep 1; echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
