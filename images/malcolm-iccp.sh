#!/bin/bash
# ww-otj.51: make a staged Malcolm tree (the dir malcolm-stage.sh builds, or the overlay's opt/malcolm) ingest ICCP/TASE.2.
#   images/malcolm-iccp.sh <malcolm-dir>     idempotent; run inside Lima (docker + the ferrofire checkout are there)
# What it does (nothing is baked into the Malcolm images, so no 25 GB re-pull / re-save):
#  - Zeek: compiles ferrofire's tools/zeek/iccp Spicy analyzer with the Malcolm zeek image's own spicyz into
#    zeek/custom/iccp/ (loaded by Malcolm's local.zeek `@load custom`; the dir is bind-mounted into zeek and zeek-live)
#  - Logstash: images/malcolm-iccp/1075_zeek_iccp.conf parses mms.log + iccp.log; zeek_log_transport/_ecs_categories
#    maps get mms+iccp rows; all bind-mounted over the in-image files through docker-compose.yml
#  - OpenSearch: zeek_ot.json component template gets zeek.mms.* and zeek.iccp.* mappings, bind-mounted into dashboards-helper
# The compiled .hlto is a build product and is not committed; ferrofire is pinned (FF_REF) so a rebuild is reproducible.
set -euo pipefail
M=$(cd "${1:?usage: malcolm-iccp.sh <malcolm-dir>}" && pwd)
SD=$(cd "$(dirname "$0")" && pwd)
FF=${FERROFIRE_DIR:-/Users/ryanadams/git/ferrofire}
FF_REF=${FF_REF:-065653b}
cd "$M"
ZIMG=$(grep -m1 'image: ghcr.io/idaholab/malcolm/zeek:' docker-compose.yml | awk '{print $2}')
[ -n "$ZIMG" ] || { echo 'no zeek image in docker-compose.yml' >&2; exit 1; }

# --- Zeek
B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
git -c safe.directory='*' -C "$FF" archive "$FF_REF" tools/zeek/iccp | tar -C "$B" -x
docker run --rm -u "$(id -u):$(id -g)" --entrypoint spicyz -v "$B":/w -w /w/tools/zeek/iccp "$ZIMG" \
  -o /w/iccp.hlto analyzer/iccp.spicy analyzer/iccp.evt
mkdir -p zeek/custom/iccp
cp "$B/iccp.hlto" "$B/tools/zeek/iccp/scripts/main.zeek" zeek/custom/iccp/
# `@load ./x.hlto` resolves against the cwd, so the analyzer goes where zkg puts packages' .hlto (a plugin dir, mounted
# below); custom/iccp only carries the scripts
echo '@load ./main' > zeek/custom/iccp/__load__.zeek
touch zeek/custom/__load__.zeek
grep -qxF '@load ./iccp' zeek/custom/__load__.zeek || echo '@load ./iccp' >> zeek/custom/__load__.zeek

# --- Logstash
# logstash-start.sh seds the .conf files in place (cannot on a single-file bind mount) and copies every
# malcolm-pipelines.available/<pipeline>/* into the pipeline, so mount a directory there
rm -f logstash/pipelines/zeek/1075_zeek_iccp.conf
mkdir -p logstash/pipelines-extra/zeek
cp "$SD/malcolm-iccp/1075_zeek_iccp.conf" logstash/pipelines-extra/zeek/
python3 - <<'PYEOF'
import json, re
def add_rows(path, rows):
    t = open(path).read()
    for r in rows:
        if re.search(r'^"?%s"?:' % r.split(':')[0].strip('"'), t, re.M):
            continue
        t = t.rstrip('\n') + '\n' + r + '\n'
    open(path, 'w').write(t)
add_rows('logstash/maps/zeek_log_transport.yaml', ['mms: tcp', 'iccp: tcp'])
add_rows('logstash/maps/zeek_log_ecs_categories.yaml', ['"mms": ["ot", "network"]', '"iccp": ["ot", "network"]'])

kw, lg, fl = {"type": "keyword"}, {"type": "long"}, {"type": "float"}
P = 'dashboards/templates/composable/component/zeek_ot.json'
d = json.load(open(P))
z = d['template']['mappings']['properties']['zeek']['properties']
z['mms'] = {"properties": {**{k: kw for k in ('pdu', 'mms_service', 'scope', 'domain', 'target', 'items', 'values',
                                                  'result', 'error', 'detail')},
                           "invoke_id": lg, "rtt": fl}}
z['iccp'] = {"properties": {**{k: kw for k in ('op', 'scope', 'domain', 'name', 'class', 'vtype', 'value', 'quality',
                                                  'result', 'transfer_set', 'ds_conditions', 'timetag',
                                                  'bilateral_table_id', 'tase2_version', 'supported_features',
                                                  'supported_blocks')},
                            "invoke_id": lg}}
json.dump(d, open(P, 'w'), indent=2)

# bind mounts (single files over the in-image ones); compose service -> [(host, container)]
M = {'logstash': [('./logstash/pipelines-extra/zeek', '/usr/share/logstash/malcolm-pipelines.available/zeek'),
                  ('./logstash/maps/zeek_log_transport.yaml', '/etc/zeek_log_transport.yaml'),
                  ('./logstash/maps/zeek_log_ecs_categories.yaml', '/etc/zeek_log_ecs_categories.yaml')],
     'zeek': [('./zeek/custom/iccp/iccp.hlto', '/usr/local/zeek/lib/zeek/plugins/packages/ferrofire-iccp/iccp.hlto')],
     'zeek-live': [('./zeek/custom/iccp/iccp.hlto', '/usr/local/zeek/lib/zeek/plugins/packages/ferrofire-iccp/iccp.hlto')],
     'dashboards-helper': [('./' + P, '/opt/templates/composable/component/zeek_ot.json')]}
t = open('docker-compose.yml').read()
t = re.sub(r'    - [^\n]*malcolm-pipelines/zeek/1075[^\n]*\n', '', t)   # first version of this script
for svc, ms in M.items():
    for h, c in ms:
        blk = re.search(r'\n  %s:\n(?:    .*\n|\n)*' % svc, t)
        if blk and c in blk.group(0):
            continue
        t, n = re.subn(r'(\n  %s:\n(?:    .*\n)*?    volumes:\n)' % svc,
                       lambda m: m.group(1) + '    - %s:%s:ro\n' % (h, c), t, count=1)
        assert n == 1, (svc, c)
# zeek/custom is mounted read-only into zeek and zeek-live already (arp-spoof)
assert t.count('/usr/local/zeek/share/zeek/site/custom') >= 2, 'zeek custom mount missing'
open('docker-compose.yml', 'w').write(t)
PYEOF
echo "malcolm-iccp: staged in $M ($ZIMG, ferrofire $FF_REF)"
