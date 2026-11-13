#!/bin/sh
# Chroot build step (phenix runs this under sh -ec: POSIX only). Provider and RTU network tuning that was done by hand on the
# ww-1df.9 range run (ww-1df.28): (1) a 224.0.0.0/4 route, because a VM with no default route fails every RADIO multicast
# send with ENETUNREACH, so RTUs saw zeros; (2) bigger UDP socket buffers, because an 8112-tag cycle is a burst of ~225 datagrams
# and with the 208 KiB default buffer sends hit EAGAIN and datagrams were dropped.
# The sysctls are a sysctl.d file (applied by systemd-sysctl at boot). The route needs the interface address that phenix
# configures at boot from /etc/phenix/startup/3_interfaces-start.sh (it flushes and re-adds addresses), so it is a startup
# script named 5_* that phenix-start.sh runs after it, in glob order.
set -ex
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iproute2
cat > /etc/sysctl.d/90-ics-udp.conf <<'EOT'
net.core.wmem_default = 4194304
net.core.wmem_max = 8388608
net.core.rmem_default = 4194304
net.core.rmem_max = 8388608
EOT
install -d /etc/phenix/startup
cat > /etc/phenix/startup/5_ics-net-start.sh <<'EOT'
#!/bin/bash
# Route multicast out the interface on MCAST_NET (the MGMT VLAN, where the provider and every RTU meet); otherwise the first non-loopback IPv4 interface.
MCAST_NET=172.16.
dev=$(ip -o -4 addr show scope global | awk -v n="$MCAST_NET" 'index($4, n) == 1 {print $2; exit}')
[ -n "$dev" ] || dev=$(ip -o -4 addr show scope global | awk 'NR == 1 {print $2}')
[ -n "$dev" ] || { echo "ics-net: no IPv4 interface, multicast route not added" >&2; exit 0; }
ip route replace 224.0.0.0/4 dev "$dev"
echo "ics-net: 224.0.0.0/4 dev $dev"
EOT
chmod 0755 /etc/phenix/startup/5_ics-net-start.sh
