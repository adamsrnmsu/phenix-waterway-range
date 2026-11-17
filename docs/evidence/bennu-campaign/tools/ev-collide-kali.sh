cd /tmp/miniccc/files; M=$(ls -t *mb.py | head -1); Z=$(ls -t *zreq.py | head -1); P=/tmp/ev-collide-$$.pcap
tcpdump -i any -U -w $P "tcp port 502 and host 10.1.1.102" 2>/tmp/tcpdump-$$.err & TP=$!; sleep 2; date -u +%FT%TZ
for i in $(seq 90); do python3 $Z 172.16.1.2 5555 READ=uppergate.open | grep -q "ACK=1" && break; sleep 2; done  # wait until the gate is open (1), so the scaling is visible
for t in upperwater.height uppergate.open; do python3 $Z 172.16.1.2 5555 "READ=$t"; done
echo "--- FC04 input register 30000 (range 0..1000)"; python3 $M raw 10.1.1.102 0475300001
echo "--- FC03 holding register 30000 (range 0..1)"; python3 $M raw 10.1.1.102 0375300001
sleep 1; kill $TP; sleep 1; echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
