#!/bin/sh
# Chroot build step: MITRE Caldera server laid out for phenix's `caldera` app
# (sceptre-phenix-apps .../caldera/app.py injects /opt/caldera/conf/default.yml, /opt/caldera/data/{sources,adversaries},
# /etc/firefox/policies/policies.json, /root/.config/autostart/Caldera.desktop). Same recipe as upstream
# sceptre-phenix api/config/default/caldera.yml (5.2.0 + activeshadow ot plugins), but a systemd service, not docker.
# Deviation: Sandcat compiles agents for amd64 unless the client sends an `architecture` header; phenix's linux_agent.mako
# does not, so the default is switched to arm64 (this range's Linux guests are all arm64).
set -eu
export DEBIAN_FRONTEND=noninteractive
CALDERA_TAG=5.2.0
NODE=v22.14.0

# Firefox (Mozilla apt repo; Ubuntu's firefox is a snap) for the XFCE autostart the app injects
apt-get update
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg > /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
apt-get update
apt-get install -y --allow-downgrades firefox
install -d /etc/firefox/policies /root/.config/autostart /etc/phenix/startup
touch /etc/cloud/cloud-init.disabled
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

# Caldera + plugins
git clone --branch "$CALDERA_TAG" --recursive --depth 1 --shallow-submodules https://github.com/apache/caldera.git /opt/caldera
cd /opt/caldera
git clone --depth 1 -b facts https://github.com/activeshadow/caldera-modbus.git plugins/modbus
git clone --depth 1 -b main https://github.com/activeshadow/caldera-dnp3.git plugins/dnp3
git clone --depth 1 -b main https://github.com/activeshadow/caldera-ot.git plugins/ot
git clone --depth 1 -b main https://github.com/activeshadow/caldera-phenix.git plugins/phenix
# pre-clone so Caldera does not reach out for it at startup
git clone --depth 1 https://github.com/redcanaryco/atomic-red-team.git plugins/atomic/data/atomic-red-team
python3 -m venv /opt/caldera/venv
/opt/caldera/venv/bin/pip install --no-cache-dir -r requirements.txt
for p in modbus dnp3 ot phenix; do
  [ -f plugins/$p/requirements.txt ] && /opt/caldera/venv/bin/pip install --no-cache-dir -r plugins/$p/requirements.txt
done

# magma UI (needs a newer node than noble's apt nodejs); node is removed afterwards
curl -fsSL "https://nodejs.org/dist/$NODE/node-$NODE-linux-arm64.tar.xz" | tar -xJ -C /opt
PATH=/opt/node-$NODE-linux-arm64/bin:$PATH
(cd plugins/magma && npm install && npm run build)
test -f plugins/magma/dist/index.html
rm -rf plugins/magma/node_modules /opt/node-$NODE-linux-arm64 /root/.npm

# Sandcat: arm64 agents, Go module cache warm (runtime compile on /file/download), prebuilt arm64 fallback payload
sed -i "s/headers.get('architecture', 'amd64')/headers.get('architecture', 'arm64')/" plugins/sandcat/app/sand_svc.py
grep -q "'architecture', 'arm64'" plugins/sandcat/app/sand_svc.py
(cd plugins/sandcat/gocat && go mod tidy && go mod download \
  && GOOS=linux GOARCH=arm64 go build -ldflags '-s -w' -o ../payloads/sandcat.go-linux sandcat.go)

cat > /etc/systemd/system/caldera.service <<'UNIT'
[Unit]
Description=MITRE Caldera
After=network.target

[Service]
WorkingDirectory=/opt/caldera
Environment=HOME=/root
ExecStart=/opt/caldera/venv/bin/python3 server.py --insecure --log INFO
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
install -d /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/caldera.service /etc/systemd/system/multi-user.target.wants/caldera.service
apt-get clean
