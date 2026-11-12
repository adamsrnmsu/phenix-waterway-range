#!/bin/sh
# Chroot step (sh -ec, POSIX): Kali Purple (blue team) + Malcolm runtime wiring (ww-ebo.2).
# Malcolm tree + docker image tarball arrive via the overlay (/opt); docker cannot run in a chroot, so a
# first-boot unit loads the images, then malcolm.service (compose up) starts it on every boot.
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends firefox-esr cyberchef tcpdump ethtool jq python3 ca-certificates curl docker.io docker-cli docker-compose
for m in identify protect detect respond recover; do
  apt-get install -y --no-install-recommends kali-tools-$m || echo "WARN kali-tools-$m failed"
done
echo "root:toor" | chpasswd
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-root.conf
ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
mkdir -p /etc/firefox-esr/policies
echo '{"policies":{"OverrideFirstRunPage":"","DontCheckDefaultBrowser":true,"DisableTelemetry":true,"NoDefaultBookmarks":true,"Homepage":{"URL":"https://localhost/","StartPage":"homepage"},"Certificates":{"Install":["/opt/malcolm/nginx/certs/cert.pem"]}}}' > /etc/firefox-esr/policies/policies.json

cat > /etc/sysctl.d/99-malcolm.conf <<'X'
vm.max_map_count=262144
fs.inotify.max_user_watches=131072
fs.inotify.max_user_instances=512
net.core.somaxconn=65535
X
# capture NIC (eth1): up, promiscuous, no IP, hidden from NetworkManager, offloads off
mkdir -p /etc/NetworkManager/conf.d
printf '[keyfile]\nunmanaged-devices=interface-name:eth1\n' > /etc/NetworkManager/conf.d/99-capture.conf
cat > /etc/systemd/system/capture-nic.service <<'X'
[Unit]
Description=Promiscuous capture NIC (eth1) for Malcolm
After=network-pre.target phenix.service sys-subsystem-net-devices-eth1.device
Wants=sys-subsystem-net-devices-eth1.device
Before=malcolm.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip addr flush dev eth1; ip link set eth1 up promisc on; for f in gro lro tso gso rx tx sg; do ethtool -K eth1 $f off 2>/dev/null || true; done'
[Install]
WantedBy=multi-user.target
X
cat > /usr/local/sbin/malcolm-firstboot <<'X'
#!/bin/sh
# load the bundled Malcolm images once, then hand over to malcolm.service
set -e
if [ -f /opt/malcolm-images.tar.gz ]; then
  gunzip -c /opt/malcolm-images.tar.gz | docker load
  rm -f /opt/malcolm-images.tar.gz
fi
chown -R 1000:1000 /opt/malcolm
touch /opt/malcolm/.images-loaded
X
chmod +x /usr/local/sbin/malcolm-firstboot
cat > /etc/systemd/system/malcolm-firstboot.service <<'X'
[Unit]
Description=Load Malcolm docker images (first boot)
After=docker.service
Requires=docker.service
Before=malcolm.service
ConditionPathExists=!/opt/malcolm/.images-loaded
[Service]
Type=oneshot
TimeoutStartSec=3600
ExecStart=/usr/local/sbin/malcolm-firstboot
[Install]
WantedBy=multi-user.target
X
cat > /etc/systemd/system/malcolm.service <<'X'
[Unit]
Description=Malcolm (docker compose, live capture on eth1)
After=phenix.service docker.service capture-nic.service malcolm-firstboot.service
Requires=docker.service
Wants=capture-nic.service malcolm-firstboot.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/malcolm
ExecStartPre=-/bin/sh -c 'ip addr flush dev eth1'
TimeoutStartSec=1800
ExecStart=/usr/bin/docker compose --profile malcolm up -d
ExecStop=/usr/bin/docker compose --profile malcolm stop
[Install]
WantedBy=multi-user.target
X
mkdir -p /etc/systemd/system/multi-user.target.wants
for u in docker capture-nic malcolm-firstboot malcolm; do
  ln -sf /etc/systemd/system/$u.service /etc/systemd/system/multi-user.target.wants/$u.service 2>/dev/null || true
done
ln -sf /usr/lib/systemd/system/docker.service /etc/systemd/system/multi-user.target.wants/docker.service
ls -la /opt /opt/malcolm | head -30
docker --version; (docker compose version || docker-compose version) 2>&1 | head -2; ls /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins 2>&1 | head
