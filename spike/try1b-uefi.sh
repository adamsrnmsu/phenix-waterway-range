#!/bin/bash
# 1b proper: UEFI + KVM boot of noble arm64 cloud image with a NoCloud seed. Run as root in the VM.
# usage: try1b-uefi.sh <-M value> [secs]
M=${1:-virt,its=off}; T=${2:-120}
cd /var/tmp; rm -f t.qcow2 u.log
qemu-img create -q -f qcow2 -F qcow2 -b /phenix/images/noble-server-cloudimg-arm64.img t.qcow2
start=$(date +%s)
timeout $T qemu-system-aarch64 -M $M -accel kvm -cpu host -m 2048 -smp 2 \
  -bios /usr/share/AAVMF/AAVMF_CODE.fd -drive file=t.qcow2,if=virtio \
  -drive file=seed.iso,format=raw,if=virtio -nographic -nic user > u.log 2>&1 &
until grep -aq "login:" u.log || ! kill -0 $! 2>/dev/null; do sleep 1; done
echo "UEFI M=$M elapsed $(( $(date +%s)-start ))s"
strings u.log | grep -E "login:|rcu: INFO|panic" | head -3
pkill qemu-system; wait 2>/dev/null
