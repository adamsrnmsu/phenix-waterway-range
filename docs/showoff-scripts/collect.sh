#!/bin/bash
# usage: collect.sh <workdir>  -- pull artefacts from Lima/guests, replay pcap with the fixed image into a fresh ES, ingest
set -eu
WD=${1:-work2}; SP=/private/tmp/claude-501/-Users-ryanadams-git/d86dff81-4847-4d36-8229-fdb7434aac42/scratchpad; mkdir -p $WD/live-logs $WD/pcap-logs
limactl shell phenix -- bash -c 'rm -rf /tmp/sw/live-logs2 /tmp/sw/pcap-logs2; mkdir /tmp/sw/live-logs2 /tmp/sw/pcap-logs2; sudo docker cp pz-zeek:/zeek/logs/. /tmp/sw/live-logs2/; sudo chmod -R a+r /tmp/sw/live-logs2'
mmx() { limactl shell phenix sudo docker exec minimega mm "$@" 2>&1 | grep -v main.go || true; }
mmx namespace waterway clear cc filter >/dev/null; mmx namespace waterway cc delete response all >/dev/null
mmx namespace waterway cc filter hostname=rtu-1 >/dev/null; mmx namespace waterway cc recv /tmp/gt.csv >/dev/null
mmx namespace waterway clear cc filter >/dev/null; mmx namespace waterway cc filter hostname=opc >/dev/null; mmx namespace waterway cc recv /tmp/mb.csv >/dev/null; sleep 8
mmx namespace waterway clear cc filter >/dev/null
limactl shell phenix sudo bash -c 'cp $(ls -t /phenix/images/waterway/miniccc_responses/*/*/tmp/gt.csv | head -1) /tmp/sw/gt2.csv; cp $(ls -t /phenix/images/waterway/miniccc_responses/*/*/tmp/mb.csv | head -1) /tmp/sw/mb2.csv; chmod 644 /tmp/sw/*2.csv'
limactl cp -r phenix:/tmp/sw/live-logs2/. $WD/live-logs/; limactl cp phenix:/tmp/sw/live2.pcap $WD/live.pcap; limactl cp phenix:/tmp/sw/st2.jsonl $WD/st.jsonl
limactl cp phenix:/tmp/sw/tcpdump2.log $WD/tcpdump.log; limactl cp phenix:/tmp/sw/gt2.csv $WD/gt.csv; limactl cp phenix:/tmp/sw/mb2.csv $WD/mb.csv
# replay with fixed image into fresh ES
limactl shell phenix -- bash -c 'sudo docker rm -f pz-ing-pcap pz-es-pcap >/dev/null 2>&1; sudo docker volume rm pz-state-pcap >/dev/null 2>&1; rm -rf /tmp/sw/pcap-logs2; mkdir -p /tmp/sw/pcap-logs2
ZEEK_IMAGE=parseus-zeek:dpfix /tmp/sw/replay.sh /tmp/sw/live2.pcap /tmp/sw/pcap-logs2
sudo docker run -d --name pz-es-pcap --restart unless-stopped -p 9206:9200 -e discovery.type=single-node -e xpack.security.enabled=false -e ES_JAVA_OPTS="-Xms1g -Xmx1g" docker.elastic.co/elasticsearch/elasticsearch:8.19.5 >/dev/null
for i in $(seq 60); do curl -s localhost:9206 >/dev/null && break; sleep 2; done
sudo docker run -d --name pz-ing-pcap --restart unless-stopped --network host -e DATASTORE_HOST_URL=http://localhost:9206 -e DATASTORE_TYPE=elasticsearch -e INGESTOR_ZEEK_LOG_DIR=/zeek/logs -e INGESTOR_ZEEK_STATE_FILE=/state/zeek_state.json -e LOG_LEVEL=INFO -v /tmp/sw/pcap-logs2:/zeek/logs:ro -v pz-state-pcap:/state pz-ingestor >/dev/null
sleep 30; curl -s localhost:9206/_cat/indices; sudo chmod -R a+r /tmp/sw/pcap-logs2'
limactl cp -r phenix:/tmp/sw/pcap-logs2/. $WD/pcap-logs/
tshark -r $WD/live.pcap -T fields -e frame.time_epoch 2>/dev/null | sed -n '1p;$p' | paste -sd' ' | python3 -c "
import sys,json,os
a,b=map(float,sys.stdin.read().split()); n=os.path.getsize('$WD/live.pcap')
pk=len(open('$WD/tcpdump.log').read()) and [l for l in open('$WD/tcpdump.log') if 'captured' in l][0].split()[0]; print(json.dumps({'first':a,'last':b,'file_bytes':n,'duration_s':b-a,'packets':int(pk)}))" > $WD/pcap_info.json
