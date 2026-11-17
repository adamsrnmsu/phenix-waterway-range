#!/bin/bash
# SEND="extra files" ccrun.sh <hostname> <localscript> [wait-seconds] : run a script in a bennucamp guest via minimega cc, print its output
NS=${NS:-bennucamp}
mm() { limactl shell phenix sudo docker exec minimega mm "$@" 2>&1 | grep -v "INFO main.go"; }
H=$1; S=$2; W=${3:-8}; B=$(date +%s)$RANDOM-$(basename "$S")  # unique name: cc send reuses a cached file of the same name
limactl shell phenix sudo cp "$S" /phenix/images/"$B"
mm namespace $NS clear cc filter >/dev/null
mm namespace $NS cc delete response all >/dev/null
mm namespace $NS cc filter hostname="$H" >/dev/null
for f in $SEND; do n=$(date +%s)$RANDOM-$(basename "$f"); limactl shell phenix sudo cp "$f" /phenix/images/$n; mm namespace $NS cc send /phenix/images/$n >/dev/null; done  # unique names: scripts pick the newest with ls -t *name
mm namespace $NS cc send /phenix/images/"$B" >/dev/null
mm namespace $NS cc exec bash /tmp/miniccc/files/"$B" >/dev/null
sleep "$W"
mm namespace $NS cc responses all
mm namespace $NS clear cc filter >/dev/null
