# scada/ — FUXA project (Phase 5b)

Boot flow: `gen_configs.py` renders `fuxa_project.json.j2` to `/etc/sceptre/fuxa_project.json` (topology injection).
`fuxa-project.service` (installed by `images/scripts/fuxa.sh`, independent of phenix.service) runs `/usr/local/bin/fuxa-load-project`:
waits up to 180 s for :1881 (FUXA spends ~60 s in plugin init), `POST /api/project` only if the file's sha256 differs from
`/var/lib/fuxa/.project.sha256`, then confirms by reading the project back. Bounded (TimeoutStartSec=420) and idempotent.

## Template variables (`fuxa_project.json.j2`)
- `opc_endpoint` — `opc.tcp://<opc-ip>:4840`
- `tags` — list of `{rtu, point}`; produces tag name `<rtu>.<point>`, address `ns=2;s=<rtu>.<point>`
  (must match the opcua_gateway node ids)
- `view_name` — optional, default `Lock`

Self-check: `python3 -I scada/test_fuxa_project.py` (needs jinja2).

## Project import evidence (resolves plan UNVERIFIED)
- `POST /api/project` takes the whole project object (`server/api/projects/index.js`: `runtime.project.setProject(req.body)` then `runtime.restart(true)`); admin-gated only when FUXA security is enabled (off by default) -> no token needed.
- `setProject` clears storage then writes; so the loader posts only when no OPCUA device exists.
- Storage: `<userDir>/_appdata/project.fuxap.db` (sqlite, key/value rows per table; `prjstorage.js`). Service runs `--userDir /var/lib/fuxa`. Pre-seeding the db is the fallback, not implemented.
- Devices are a dict keyed by id; tags live in `device.tags`; OPC UA endpoint is `device.property.address`; tag nodeId is passed verbatim (`runtime/devices/opcua/index.js`).
- Release: npm `@frangoteam/fuxa` 1.3.5, `@frangoteam/fuxa-min` 1.3.1 (no node-snap7 => no compiler). Image uses -min. Node 22 LTS.

## View (animated lock, ww-585.36)
`lock_view.py` builds the `Lock` view (items + SVG) from the tag map; `fuxa_project.json.j2` embeds it (`view` variable, passed by
`gen_configs.py`). Items still follow FUXA's editor data model (keyed by SVG `<g id>`, `variableId` = tag id, `variableSrc` = device id);
only FUXA's own item types are used. Elements whose tag is missing are skipped (an older register map without `boat.*` still renders).
- Water: three `svg-ext-gauge_progress` bars (range 0-20): lower pool `rtu-1.lowerwater.height`, chamber `rtu-1.lock.height`, upper pool `rtu-2.upperwater.height`.
- Gates (`rtu-1.lowergate.open`, `rtu-2.uppergate.open`): `svg-ext-shapes` leaf with two `move` actions (value >= 0.5 -> sunk into the floor, else raised) plus show/hide OPEN/CLOSED labels.
- Valves (`rtu-1.lowervalve.open`, `rtu-2.uppervalve.open`): culvert + bow-tie coloured through shape `ranges` (green/red; water blue when open), flow arrows `blink`, OPEN/CLOSED labels.
- Boat: three boats (lower pool / chamber / upper pool), shown by `boat.location` (<=100, 100..200, >=200). Each is a nested `<svg>`: the outer
  steps in x with `rtu-1.boat.location` (every 5 m, x = 60 + 2.6*loc), the inner steps in y with that body's level (every 1.0 unit) so the boat rides the water.
- Telemetry table on the right, legend on the dark ground strip.
FUXA 1.3.1 lessons (verified in the lab, see `docs/shots/hmi-animated/lab-*.png`):
- `move` is discrete: while the value is inside `range` it animates to the absolute `toX,toY`. Continuous values need stepped ranges.
- `move` on a `<g>` rewrites the children's coordinates from the bbox, so a group moved in x and a nested group moved in y cancel each
  other (boat ended at x=0). Nested `<svg x y overflow=visible>` elements move via plain x/y attributes and compose.
- Shape `ranges` set `fill`/`stroke` on the item's own element only: do not put fill on the children, they would win.
- The initial hidden state must be `style='display:none'` (a `display` attribute is not cleared by `show`).
- Kiosk viewport has a ~46 px bar on top; the view is 1280x720 and scaled to the screen.
Self-check: `python3 -I scada/test_fuxa_project.py` (needs jinja2). Screenshots without a VM: run FUXA 1.3.1 (`@frangoteam/fuxa-min`), point
the OPC UA device at a mock asyncua server whose node values you set, drive headless Chrome over CDP (`--remote-debugging-port`) and
`Page.captureScreenshot` after ~7 s. `--screenshot`/virtual-time gives inconsistent results with the move animations.
Redeploy to a running range: `cc send` the file, copy to `/etc/sceptre/fuxa_project.json` on scada-server, `systemctl restart fuxa-project`
(loads after ~30 s), then reload the kiosk (`DISPLAY=:0 xdotool key F5` on hmi) and wait ~60 s for the OPC tags to connect.
`boat.location` needs the rtu-1 `boat` device (ww-585.37); without it the boat parks at the left edge and the table shows `##.##`.

## Data-path configs (Phase 5a/5c/5f)
`gen_configs.py` renders opc_gateway.json, fuxa_project.json, telegraf.conf, hmi_url, rtus.txt (`<host> <ip>` per line),
influx-setup.sh into `topologies/waterway-arm64/injects/`. Register map: `reg_addrs.json` from the sceptre app dry run
(`--from-dry-run <phenix-app-sceptre>`). Self-tests (need asyncua==2.1.0 pymodbus==3.16.2 pyyaml jinja2):
`python3 -I scada/gen_configs.py --self-test`, `python3 -I scada/opcua_gateway.py --self-test`.
After editing opcua_gateway.py: `cp scada/opcua_gateway.py images/overlays/opc-arm64/opt/opcua-gateway/`.
