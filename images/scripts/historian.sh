#!/bin/bash
# Chroot build step: InfluxDB 2 + Telegraf (arm64 debs from repos.influxdata.com).
# Runtime injections: /etc/telegraf/telegraf.conf and /etc/phenix/startup/influx-setup.sh
# (both rendered/copied by scada/gen_configs.py). influx-setup.sh creates org/bucket/token and restarts telegraf.
set -eu
export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /etc/apt/keyrings /etc/phenix/startup
curl -fsSL https://repos.influxdata.com/influxdata-archive.key -o /tmp/influxdata-archive.key
# archive key fingerprint checked 2026-11-07
gpg --show-keys --with-fingerprint --with-colons /tmp/influxdata-archive.key 2>&1 \
  | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$'
gpg --dearmor < /tmp/influxdata-archive.key > /etc/apt/keyrings/influxdata-archive.gpg
rm -f /tmp/influxdata-archive.key
echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' \
  > /etc/apt/sources.list.d/influxdata.list

apt-get update
apt-get install -y influxdb2 influxdb2-cli telegraf
systemctl enable influxdb telegraf || {
  for u in influxdb telegraf; do
    ln -sf /lib/systemd/system/$u.service /etc/systemd/system/multi-user.target.wants/$u.service
  done
}
