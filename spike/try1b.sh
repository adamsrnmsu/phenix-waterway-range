#!/bin/bash
# 1b diagnostic: boot noble arm64 under KVM via direct kernel (serial console visible).
# usage (inside VM, as root): try1b.sh <-M value> <smp> [secs] [extra kernel args]
M=$1; S=$2; T=${3:-90}; X=$4
cd /var/tmp; rm -f t.qcow2 d.log
qemu-img create -q -f qcow2 -F qcow2 -b /phenix/images/noble-server-cloudimg-arm64.img t.qcow2
start=$(date +%s)
timeout $T qemu-system-aarch64 -M $M -accel kvm -cpu host -m 2048 -smp $S \
  -kernel /var/tmp/k/vmlinuz -initrd /var/tmp/k/initrd.img \
  -append "root=LABEL=cloudimg-rootfs ro console=ttyAMA0 $X" \
  -drive file=t.qcow2,if=virtio -nographic -nic user > d.log 2>&1 &
until grep -aq "login:" d.log || ! kill -0 $! 2>/dev/null; do sleep 2; done
echo "M=$M smp=$S X=[$X] elapsed $(( $(date +%s)-start ))s"
strings d.log | grep -E "login:|rcu: INFO|Kernel panic|stall" | head -3
pkill qemu-system; wait 2>/dev/null
