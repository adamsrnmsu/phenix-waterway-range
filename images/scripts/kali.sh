#!/bin/sh
# Chroot step: Kali arm64 attacker for the PR #31 mitm topology (sceptre-phenix-apps ettercap component
# runs: ip link set <if> up; ettercap -Tq -i <if> -M <method> <targets>; pkill ettercap).
# Adapted from sceptre-phenix-images scripts/kali-harmonie.sh, without the desktop/kali-linux-default
# metapackages (headless; the x86 script's pip/ntpsec/kali-grant-root bits are not needed here).
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ettercap-text-only tcpdump python3 python3-scapy nmap arping jq
echo "root:toor" | chpasswd
# root ssh for debugging
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-root.conf
ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
ettercap --version | head -2
