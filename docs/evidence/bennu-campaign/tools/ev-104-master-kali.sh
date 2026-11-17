cd /tmp/miniccc/files; M=$(ls -t *ev-104-master.py | head -1); P=/tmp/ev-104ioa-$$.pcap
tcpdump -i any -U -w $P 'tcp and host 10.1.1.102 and port 25405' 2>/dev/null & TP=$!; sleep 2
date -u +%FT%TZ
python3 $M 10.1.1.102 25405
sleep 1; kill $TP; sleep 1
echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
