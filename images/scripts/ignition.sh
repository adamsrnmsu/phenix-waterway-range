#!/bin/sh
# Chroot build step: Ignition 8.1 gateway, tree comes in via the overlay (images/ignition-stage.sh) at /usr/local/bin/ignition.
# Runs as root under a systemd unit; trial mode (no licence). SOAP's `gwcmd --restore` / `gwcmd -r` live in that dir.
set -eu
IG=/usr/local/bin/ignition
mkdir -p /usr/local/sbin /etc/systemd/system/multi-user.target.wants
mkdir -p /usr/local/bin; tar -C /usr/local/bin -xf /opt/ignition-tree.tar; rm -f /opt/ignition-tree.tar
test -x $IG/ignition-gateway
# the wrapper conf asks for lib/runtime/jre-nix (the x86_64 name); the aarch64 tree ships jre-aarch64
[ -e $IG/lib/runtime/jre-nix ] || ln -s jre-aarch64 $IG/lib/runtime/jre-nix
# First start of 8.1 is uncommissioned (web wizard) and `gwcmd --restore` is ignored in that state.
# Commissioning means accepting Inductive Automation's EULA, which is the operator's decision: the recipe must set
# `IGNITION_ACCEPT_EULA=1 images/ignition-stage.sh <arch>` (marker file in the overlay), else the image stays uncommissioned.
if [ -e /opt/ignition-eula-accepted ]; then
rm -f /opt/ignition-eula-accepted
# Commission by restore, as the official inductiveautomation/ignition image does (docker-entrypoint.sh: on a clean
# data dir with a restore file, `gwcmd.sh -s <gwbk> -m -y` then the Upgrader, before the first start). The backup
# carries a commissioned config, so the first-start wizard never appears. SOAP injects /phenix/ignition.gwbk.
cat > /usr/local/sbin/ignition-prestage <<'EOS'
#!/bin/sh
IG=/usr/local/bin/ignition
B=${IGNITION_RESTORE:-/phenix/ignition.gwbk}
[ -f "$IG/data/db/config.idb" ] && exit 0   # already configured: nothing to stage
[ -f "$B" ] || exit 0                       # no backup injected: leave the clean gateway alone
cd "$IG" || exit 1
./gwcmd.sh -s "$B" -m -y
exec "$IG/lib/runtime/jre-nix/bin/java" -classpath lib/core/common/common.jar \
  com.inductiveautomation.ignition.common.upgrader.Upgrader "$IG" "$IG/data" "$IG/logs" file=ignition.conf
EOS
chmod +x /usr/local/sbin/ignition-prestage
# The gateway itself reads these (same as the official container): accepts the EULA and commissions the connections
# and an admin user, then applies the staged backup. Proven 2026-11-08 with inductiveautomation/ignition:8.1.55 + the
# SOAP gwbk: RUNNING in ~24 s with project soap_hil. Admin login: admin / password (range default).
mkdir -p /etc/systemd/system/ignition.service.d
cat > /etc/systemd/system/ignition.service.d/commission.conf <<'UNIT'
[Service]
Environment=ACCEPT_IGNITION_EULA=Y
Environment=GATEWAY_ADMIN_USERNAME=admin
Environment=GATEWAY_ADMIN_PASSWORD=password
Environment=IGNITION_EDITION=standard
# the official entrypoint always exports these (from gateway.xml); they satisfy the 'connections' commissioning step
Environment=GATEWAY_HTTP_PORT=8088
Environment=GATEWAY_HTTPS_PORT=8043
Environment=GATEWAY_GAN_PORT=8060
UNIT
fi
# SOAP calls `gwcmd` (the tree ships gwcmd.sh): wait until the gateway is commissioned and RUNNING, then run the real one
cat > $IG/gwcmd <<'EOS'
#!/bin/bash
i=0
until s=$(curl -s -m 5 http://localhost:8088/StatusPing) && [[ $s == *RUNNING* && $s != *COMMISSIONING* ]]; do
  i=$((i+1)); [ $i -gt 360 ] && break; sleep 5
done
exec /usr/local/bin/ignition/gwcmd.sh "$@"
EOS
chmod +x $IG/gwcmd
# docker image leftovers: wrapper log symlinked to /dev/stdout, jre-tmp, keystore links need data/local
rm -f $IG/logs/wrapper.log; mkdir -p $IG/logs $IG/data/local $IG/temp
# memory for an 8 GiB VM
sed -i 's/^wrapper.java.initmemory=.*/wrapper.java.initmemory=512/;s/^wrapper.java.maxmemory=.*/wrapper.java.maxmemory=2048/' $IG/data/ignition.conf
cat > /etc/systemd/system/ignition.service <<'UNIT'
[Unit]
Description=Ignition Gateway (trial mode)
After=network.target

[Service]
Type=forking
WorkingDirectory=/usr/local/bin/ignition
ExecStartPre=-/bin/sh -c '[ -x /usr/local/sbin/ignition-prestage ] && /usr/local/sbin/ignition-prestage || true'
ExecStart=/usr/local/bin/ignition/ignition.sh start
ExecStop=/usr/local/bin/ignition/ignition.sh stop
PIDFile=/usr/local/bin/ignition/Ignition-Gateway.pid
TimeoutStartSec=600
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/ignition.service /etc/systemd/system/multi-user.target.wants/ignition.service
