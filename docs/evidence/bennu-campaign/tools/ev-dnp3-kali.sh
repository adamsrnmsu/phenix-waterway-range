cd /tmp/miniccc/files; M=$(ls -t *ev-dnp3-master.py | head -1); P=/tmp/ev-dnp3-$$.pcap
tcpdump -i any -U -w $P 'tcp and host 10.1.1.102 and (port 20997 or port 20998)' 2>/dev/null & TP=$!; sleep 2
date -u +%FT%TZ
echo "##### direct-operate point (port 20997, no sbo)"; python3 $M 10.1.1.102 20997 0
echo "##### SBO point (port 20998)"; python3 $M 10.1.1.102 20998 1
sleep 1; kill $TP; sleep 1
echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
