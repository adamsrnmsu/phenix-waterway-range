#!/bin/bash
# ww-1df.28: breaker write that originates at an RTU, end to end. An independent DNP3 master (tools/dnp3-master, stepfunc
# `dnp3` crate) on VM dnp3-master sends a CROB (latch off) to rtu-3's outstation, binary index 16 = branch-1_243-244.active;
# then the provider's value is read over REP and the voltages at rtu-3/rtu-4 are read back over DNP3.
# Prereq: `px exp start soap-arm64` is up with 6 cc clients. Build the master:  `docker run --rm -v $PWD/tools/dnp3-master:/w -w /w -e CARGO_TARGET_DIR=/w/target ff-rust:22.04 cargo build --release` (ff-rust:22.04 = ferrofire docker/).
# usage: dnp3-breaker-check.sh   (run on the Mac; EXP=soap-arm64 to rename)
set -euo pipefail
N=${EXP:-soap-arm64}; HERE=$(cd "$(dirname "$0")" && pwd); BIN=$HERE/../../tools/dnp3-master/target/release/dnp3-master
mm() { limactl shell phenix sudo docker exec minimega mm "$@" 2>&1 | grep -v INFO; }
x() { mm namespace $N clear cc responses; mm namespace $N cc filter hostname=$1; mm namespace $N cc exec bash -c "$2"; sleep ${3:-6}; mm namespace $N cc responses all | grep -v '^$'; }
f=dnp3-master-$(date +%s)   # unique name: cc send does not overwrite a delivered file
limactl shell phenix sudo cp "$BIN" /phenix/images/$f
mm namespace $N clear cc filter; mm namespace $N cc filter hostname=dnp3-master; mm namespace $N cc send /phenix/images/$f; sleep 3
rd() { echo "dnp3-master 10.117.4.103:20000 1 10 read | grep -E '^(analog-input 0 |binary-input (9|16) )' | sed 's/^/rtu-3 /'; dnp3-master 10.117.4.104:20000 1 10 read | grep -E '^analog-input 0 ' | sed 's/^/rtu-4 /'"; }
x dnp3-master "cp /tmp/miniccc/files/$f /usr/local/bin/dnp3-master; chmod +x /usr/local/bin/dnp3-master; echo BEFORE; $(rd); echo CROB; dnp3-master 10.117.4.103:20000 1 10 crob 16 off 2>&1; sleep 6; echo AFTER; $(rd)" 40
x power-provider "bennu-probe --endpoint tcp://172.16.1.2:5555 --command read --tag branch-1_243-244.active 2>&1 | tail -2" 8
limactl shell phenix sudo rm -f /phenix/images/$f
