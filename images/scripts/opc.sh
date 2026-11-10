#!/bin/bash
# Chroot build step: OPC UA gateway (asyncua server + pymodbus poller) as opcua-gateway.service.
# The gateway code arrives via overlay images/overlays/opc-arm64 (/opt/opcua-gateway/opcua_gateway.py,
# copy of scada/opcua_gateway.py; gen_configs.py --self-test fails if the copy is stale).
# Config is injected at runtime: /etc/sceptre/opc_gateway.json (scada/gen_configs.py).
set -eu
export DEBIAN_FRONTEND=noninteractive

install -d /opt/opcua-gateway /etc/sceptre
python3 -m venv /opt/opcua-gateway/venv
/opt/opcua-gateway/venv/bin/pip install --no-cache-dir asyncua==2.1.0 pymodbus==3.16.2
# uaread / uals / uawrite for verification: uaread -u opc.tcp://10.1.2.50:4840 -n 'ns=2;s=rtu-1.lowerwater.height'
for t in uaread uals uawrite; do ln -sf /opt/opcua-gateway/venv/bin/$t /usr/local/bin/$t; done

cat > /etc/systemd/system/opcua-gateway.service <<'UNIT'
[Unit]
Description=Waterway OPC UA gateway (Modbus/TCP -> OPC UA)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/opt/opcua-gateway/venv/bin/python /opt/opcua-gateway/opcua_gateway.py --config /etc/sceptre/opc_gateway.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
install -d /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/opcua-gateway.service /etc/systemd/system/multi-user.target.wants/opcua-gateway.service
