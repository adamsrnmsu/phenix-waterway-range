#!/bin/bash
# Chroot build step: Node 22 (NodeSource, arm64) + FUXA under /opt/fuxa + fuxa.service on :1881.
# Uses @frangoteam/fuxa-min (no node-snap7 => no compiler needed; S7 is unused here).
# Dry-checked against FUXA README: `npm install -g @frangoteam/fuxa[-min]`, then `fuxa`;
# CLI flags are only --port/--userDir (server/main.js), project db = <userDir>/_appdata/project.fuxap.db.
set -eu
FUXA_VERSION="${FUXA_VERSION:-1.3.1}"
export DEBIAN_FRONTEND=noninteractive

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install --prefix /opt/fuxa --omit=dev --no-audit --no-fund "@frangoteam/fuxa-min@${FUXA_VERSION}"
install -d /var/lib/fuxa /etc/phenix/startup /etc/sceptre

cat > /etc/systemd/system/fuxa.service <<'UNIT'
[Unit]
Description=FUXA SCADA/HMI
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/var/lib/fuxa
ExecStart=/usr/bin/node /opt/fuxa/node_modules/@frangoteam/fuxa-min/main.js --port 1881 --userDir /var/lib/fuxa
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable fuxa.service || ln -sf /etc/systemd/system/fuxa.service /etc/systemd/system/multi-user.target.wants/fuxa.service

# Project loader (ww-585.31): its own bounded oneshot, NOT a phenix startup script, so a slow or failed
# FUXA init (it spends ~60 s on plugin init) can never leave phenix.service activating/failed.
# Idempotent: POSTs /etc/sceptre/fuxa_project.json only when its sha256 differs from the last one loaded.
cat > /usr/local/bin/fuxa-load-project <<'BIN'
#!/bin/bash
PROJ=/etc/sceptre/fuxa_project.json
URL=http://127.0.0.1:1881/api/project
STAMP=/var/lib/fuxa/.project.sha256
[ -s "$PROJ" ] || { echo "fuxa-load-project: $PROJ not injected, nothing to load"; exit 0; }
want=$(sha256sum "$PROJ" | cut -d' ' -f1)
[ "$(cat "$STAMP" 2>/dev/null)" = "$want" ] && { echo "fuxa-load-project: $want already loaded"; exit 0; }
for _ in $(seq 1 90); do curl -fs -m 3 "$URL" >/dev/null && break; sleep 2; done
curl -fs -m 3 "$URL" >/dev/null || { echo "fuxa-load-project: FUXA not answering after 180 s" >&2; exit 1; }
# the POST restarts the FUXA runtime, so curl may get an empty reply (exit 52): judge by reading the project back
curl -s -m 60 -X POST -H 'Content-Type: application/json' --data-binary @"$PROJ" "$URL" >/dev/null
for _ in $(seq 1 60); do
  if curl -fs -m 3 "$URL" | jq -e '[.devices[]? | select(.type=="OPCUA")] | length >= 1' >/dev/null 2>&1; then
    echo "$want" > "$STAMP"; echo "fuxa-load-project: loaded $want"; exit 0
  fi
  sleep 2
done
echo "fuxa-load-project: project not visible after POST" >&2; exit 1
BIN
chmod +x /usr/local/bin/fuxa-load-project
cat > /etc/systemd/system/fuxa-project.service <<'UNIT'
[Unit]
Description=Load the injected FUXA project
After=fuxa.service
Wants=fuxa.service
ConditionPathExists=/etc/sceptre/fuxa_project.json

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fuxa-load-project
TimeoutStartSec=420
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable fuxa-project.service || ln -sf /etc/systemd/system/fuxa-project.service /etc/systemd/system/multi-user.target.wants/fuxa-project.service
