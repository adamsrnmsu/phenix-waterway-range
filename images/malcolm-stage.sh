#!/bin/bash
# Run INSIDE Lima as the normal user (auth_setup refuses root): limactl shell phenix -- bash <this> before `images/build.sh kali-purple-arm64`.
# Stages Malcolm v26.10.0 (idaholab/Malcolm) configured by its own scripts/configure + scripts/auth_setup
# (user-approved, ww-ebo.2), pulls the arm64 images and writes the overlay tree
# /phenix/images/overlays-src/kali-purple/{opt/malcolm,opt/malcolm-images.tar.gz}.
set -euo pipefail
V=26.10.0; CAP_IFACE=${CAP_IFACE:-eth1}; PW=${MALCOLM_PW:-MalcolmBlue1!}
SD=$(cd "$(dirname "$0")" && pwd)   # images/ (holds malcolm-zeek/)
S=/tmp/mstage; O=/phenix/images/overlays-src/kali-purple
sudo mkdir -p /phenix/images/overlays-src; sudo chown "$USER" /phenix/images/overlays-src; sudo rm -rf "$O" "$S"
if [ ! -d /tmp/Malcolm-$V ]; then
  curl -fsSL https://github.com/idaholab/Malcolm/archive/refs/tags/v$V.tar.gz | tar -C /tmp -xz
fi
cp -r /tmp/Malcolm-$V $S; cd $S
# arm64 images exist only under the -arm64 tag
sed -i -E "s#(image: ghcr.io/idaholab/malcolm/[a-z-]+:$V)\$#\1-arm64#" docker-compose.yml
python3 -m venv /tmp/mvenv; /tmp/mvenv/bin/pip -q install -r scripts/installer/requirements.txt ruamel.yaml python-dotenv bcrypt
PY=/tmp/mvenv/bin/python
$PY scripts/configure --non-interactive --defaults --configure --skip-splash -f docker-compose.yml -e $S/config
cd config
sed -i 's/^ZEEK_LIVE_CAPTURE=.*/ZEEK_LIVE_CAPTURE=true/' zeek-live.env
sed -i 's/^SURICATA_LIVE_CAPTURE=.*/SURICATA_LIVE_CAPTURE=true/' suricata-live.env
sed -i 's/^ARKIME_LIVE_CAPTURE=.*/ARKIME_LIVE_CAPTURE=true/' arkime-live.env
sed -i "s/^PCAP_IFACE=.*/PCAP_IFACE=$CAP_IFACE/;s/^PCAP_ENABLE_NETSNIFF=.*/PCAP_ENABLE_NETSNIFF=true/" pcap-capture.env
sed -i 's/-Xmx[0-9]*g -Xms[0-9]*g/-Xmx3g -Xms3g/' opensearch.env           # default 10g
sed -i 's/-Xmx[0-9]*m -Xms[0-9]*m/-Xmx2g -Xms2g/' logstash.env   # 1g OOMs the zeek pipeline
sed -i 's/^NETBOX_MODE=.*/NETBOX_MODE=disabled/' netbox-common.env
sed -i 's/^PUID=.*/PUID=1000/;s/^PGID=.*/PGID=1000/' process.env
cd $S
# 16 GiB fit: offline Suricata (1.5 GB), strelka-backend+clamd (2 GB), NetBox+PostgreSQL (1.5 GB) and Keycloak are not needed for live capture; park them in a profile that is never enabled
$PY - <<'PYEOF'
import re
t = open('docker-compose.yml').read()
for svc in ('suricata', 'strelka-backend', 'netbox', 'postgres', 'keycloak'):
    t, n = re.subn(r'(\n  ' + svc + r':\n(?:    .*\n)*?    profiles: )\[[^\]]*\]', r'\1["extras"]', t, count=1)
    assert n == 1
open('docker-compose.yml', 'w').write(t)
PYEOF
$PY - <<'PYEOF'
import re
t = open('docker-compose.yml').read()
# live capture containers use network_mode: host and cannot resolve the compose service name "opensearch":
# publish 9200 on loopback and map the name to 127.0.0.1 for arkime-live
t, n1 = re.subn(r'(\n  opensearch:\n(?:    .*\n)*?    image: [^\n]+\n)', r'\1    ports:\n    - 127.0.0.1:9200:9200/tcp\n', t, count=1)
t, n2 = re.subn(r'(\n  arkime-live:\n(?:    .*\n)*?    image: [^\n]+\n)', r'\1    extra_hosts:\n    - opensearch:127.0.0.1\n', t, count=1)
# ww-ebo.10: patched live_capture.sh (tcpSaveTimeout, see below) replaces the image's copy
t, n3 = re.subn(r'(\n  arkime-live:\n(?:    .*\n)*?    volumes:\n)', r'\1    - ./arkime/live_capture.sh:/usr/local/bin/live_capture.sh:ro\n', t, count=1)
assert n1 == 1 and n2 == 1 and n3 == 1
i = t.index('\n  nginx-proxy:\n')
t = t[:i] + t[i:].replace('    - keycloak\n    - netbox\n', '', 1)
open('docker-compose.yml', 'w').write(t)
PYEOF
# ww-ebo.10: Arkime saves a long-lived TCP session (Modbus polling never closes) only every tcpSaveTimeout (720 s default),
# so attack-time sessions appeared ~12 min late. Malcolm has no env knob for it and config.ini lives in the image, but the
# arkime-live script passes capture its -o overrides: add one (90 s) in a copy of the script that compose bind-mounts.
AIMG=$(grep -m1 'image: ghcr.io/idaholab/malcolm/arkime:' docker-compose.yml | awk '{print $2}')
docker run --rm --entrypoint cat "$AIMG" /usr/local/bin/live_capture.sh > arkime/live_capture.sh
sed -i 's#^  -o pcapDir=/data/pcap/arkime-live \\#&\n  -o tcpSaveTimeout=${ARKIME_TCP_SAVE_TIMEOUT:-90} \\#' arkime/live_capture.sh
grep -q 'tcpSaveTimeout=\${ARKIME_TCP_SAVE_TIMEOUT:-90}' arkime/live_capture.sh && bash -n arkime/live_capture.sh && chmod 755 arkime/live_capture.sh || { echo 'tcpSaveTimeout patch of live_capture.sh failed' >&2; exit 1; }
# ww-ebo.10: custom Suricata rules (suricata/rules/*.rules is mounted into suricata-live; see docs/custom-rules.md)
cp "$SD/malcolm-suricata/ics-mitm.rules" suricata/rules/
OSSL=$(openssl passwd -6 "$PW")
HTA=$($PY -c "import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode().replace('\$2b\$','\$2y\$',1))" "$PW")
$PY scripts/auth_setup -f docker-compose.yml -e $S/config --auth-noninteractive --auth-method basic \
  --auth-admin-username admin --auth-admin-password-openssl "$OSSL" --auth-admin-password-htpasswd "$HTA" \
  --auth-arkime-password "$PW" --auth-generate-webcerts --auth-generate-fwcerts --auth-generate-netbox-passwords \
  --auth-generate-valkey-password --auth-generate-postgres-password --auth-generate-opensearch-internal-creds \
  --auth-generate-keycloak-db-password
# what scripts/start would do before `compose up` (we start via systemd, compose alone does not): files, keystore, bind dirs
touch .opensearch.secondary.curlrc nginx/nginx_ldap.conf; chmod 600 .opensearch.*.curlrc nginx/nginx_ldap.conf
KS=/usr/share/opensearch/config
docker run --rm --entrypoint /usr/local/bin/docker-uid-gid-setup.sh -e PUID=1000 -e DEFAULT_UID=1000 -e PGID=1000 \
  -e DEFAULT_GID=1000 -e PUSER_CHOWN=$KS -v $S/opensearch:$KS:rw -w $KS -u root \
  $(grep -m1 'image: ghcr.io/idaholab/malcolm/opensearch:' docker-compose.yml | awk '{print $2}') /usr/share/opensearch/bin/opensearch-keystore create
sudo rmdir $S/opensearch/certs 2>/dev/null || true
mkdir -p zeek/intel zeek/custom; touch zeek/intel/__load__.zeek zeek/custom/__load__.zeek
# ww-ebo.8: ARP-spoof notice (ArpSpoof::Conflict); local.zeek does `@load custom` -> custom/__load__.zeek
cp "$SD/malcolm-zeek/arp-spoof.zeek" zeek/custom/arp-spoof.zeek; echo '@load ./arp-spoof' >> zeek/custom/__load__.zeek
# ww-otj.51: ICCP/TASE.2 (mms.log, iccp.log): Zeek analyzer + Logstash parse + OpenSearch mapping (also runnable alone on a staged tree)
bash "$SD/malcolm-iccp.sh" "$S"
docker compose --profile malcolm config | awk -v s="$S/" 'index($2,s)==1 && $1=="source:" {print $2}' | while read -r d; do [ -e "$d" ] || mkdir -p "$d"; done
sudo rm -rf .git docs _includes _layouts malcolm-iso hedgehog-raspi kubernetes
mkdir -p $O/opt
cp -a $S $O/opt/malcolm
grep image: docker-compose.yml | awk '{print $2}' | sort -u > /tmp/imgs.txt
for i in $(cat /tmp/imgs.txt); do docker pull -q $i >/dev/null; done
docker save $(cat /tmp/imgs.txt) | gzip -1 > $O/opt/malcolm-images.tar.gz
ls -lh $O/opt
