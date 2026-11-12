#!/bin/sh
# Chroot step (sh -ec, POSIX): full offensive Kali for the blue/red range (ww-ebo.4).
# kali-tools-top10 + ettercap + firefox-esr (Caldera UI) on the mingui xfce desktop.
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends firefox-esr ettercap-text-only tcpdump python3 python3-scapy arping jq dnsutils
# top10 pulls metasploit, hydra, john, nmap, sqlmap, wireshark, burpsuite, etc.
apt-get install -y kali-tools-top10 || apt-get install -y --no-install-recommends nmap metasploit-framework hydra john sqlmap wireshark responder crackmapexec
echo "root:toor" | chpasswd
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-root.conf
ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
mkdir -p /etc/firefox-esr/policies
echo '{"policies":{"OverrideFirstRunPage":"","DontCheckDefaultBrowser":true,"DisableTelemetry":true,"NoDefaultBookmarks":true}}' > /etc/firefox-esr/policies/policies.json
nmap --version | head -1; ettercap --version | head -2; hydra -h 2>&1 | head -1
