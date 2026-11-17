#!/bin/bash
# ev-dnp3-104-phase.sh before|after : deploy bundle to rtu-1/rtu-2 and run the three scenarios across the range
cd "$(dirname "$0")"; PH=$1; O=evidence/dnp3-104/range-$PH; mkdir -p $O
CFG=$PWD/ev-cfg
if [ $PH = before ]; then B=bennu-cd3bb5b-arm64; else B=bennu-dnp3-104-cc56e96-arm64; fi
[ -f deploy-$B.sh ] || ./mkdeploy.sh $B.tgz >/dev/null
for h in rtu-1 rtu-2; do SEND=$B.tgz ./ccrun.sh $h deploy-$B.sh 30 > $O/deploy-$h.txt; done
for h in rtu-1 rtu-2; do ./ccrun.sh $h probe-state.sh 6 > $O/state-$h.txt; done
# 1. DNP3
SEND=$CFG/dnp3-server.xml ./ccrun.sh rtu-2 ev-dnp3-start.sh 12 > $O/dnp3-rtu2-start.txt
SEND=ev-dnp3-master.py ./ccrun.sh kali ev-dnp3-kali.sh 40 > $O/dnp3-kali.txt; python3 xpcap.py $O/dnp3-kali.txt $O/dnp3.pcap
./ccrun.sh rtu-2 ev-dnp3-stop.sh 8 > $O/dnp3-rtu2-stop.txt
# 2. 104 IOA alias, 3. 104 client binary updates
SEND=$CFG/iec60870-5-104-server.xml ./ccrun.sh rtu-2 ev-104-start.sh 12 > $O/104-rtu2-start.txt
SEND=ev-104-master.py ./ccrun.sh kali ev-104-master-kali.sh 25 > $O/104-ioa-kali.txt; python3 xpcap.py $O/104-ioa-kali.txt $O/104-ioa.pcap
SEND=$CFG/iec60870-5-104-client.xml ./ccrun.sh rtu-1 ev-104-client-rtu1.sh 40 > $O/104-client-rtu1.txt; python3 xpcap.py $O/104-client-rtu1.txt $O/104-client.pcap
./ccrun.sh rtu-2 ev-104-stop.sh 8 > $O/104-rtu2-stop.txt
