# Live proof: sceptre app generates the Linux SCADA configs (ww-41d, ww-de1)

App: `feat-sceptre-linux-fuxa` @ 67ffd0b (sceptre-phenix-apps fork worktree, not pushed), installed into the
phenix container with `burger build/install` (board `fuxa`). Scenario from `gen_scenario.py --linux-fuxa`
(SCADA hosts carry `stack: linux_fuxa`, node keeps `os_type: linux`); topology from `gen_topology.py --linux-fuxa`
(drops the static config injections, so only the app can have supplied them; the six `injects/*` config files were
removed from the staged copy as well). Experiment `waterway` recreated and started; 9 cc clients up.

- App output vs a fresh `scada/gen_configs.py` run: `shots/linux-fuxa/app-vs-gen_configs.txt`
  (opc_gateway.json, hmi_url, rtus.txt byte-identical; fuxa_project.json parsed-equal; telegraf.conf and
  influx-setup.sh equal without comment lines).
- In the guests the injected files match the app's files (md5): opc `/etc/sceptre/opc_gateway.json`,
  historian `telegraf.conf` + `influx-setup.sh`, scada-server `fuxa_project.json`, hmi `hmi_url`.
- OPC UA: all 18 points of the config readable over `opc.tcp://10.1.2.50:4840`, live values: `shots/linux-fuxa/opc-nodes.txt`.
- Historian: telegraf + influxdb active, `waterway` bucket receiving every field: `shots/linux-fuxa/historian-influx.txt`.
- HMI: FUXA 200 on 10.1.2.71:1881, kiosk Firefox shows the animated lock view with live telemetry
  (`shots/linux-fuxa/hmi-{1,2,3}.png`, boat and gates differ between shots); engineer terminals `engineer.png`.

Reproduce: `gen_scenario.py --linux-fuxa`, `gen_topology.py --linux-fuxa`, copy to `~/phenix/topologies/waterway-arm64`,
`px config create` both, `px exp create waterway -t waterway-arm64 -s waterway-arm64`, `px exp start waterway`.

## Burger regression (no `stack`, Windows path)

`burger run fuxa` (arm64 waterway, items bennu/field-device, simulink-provider, modbus-polled) against the same app
branch (apps `67ffd0b06b`): 14 ok, 0 FAIL, total 2:47: `shots/linux-fuxa/burger-fuxa-report.md`. The board is a local,
uncommitted `switchboards/fuxa.yaml` in everything-burger-with-extra-sauce (`apps.branch: feat-sceptre-linux-fuxa`),
run with `BURGER_APPS_REPO=/var/tmp/apps-rebase BURGER_FORK_OWNER=adamsrnmsu` and a git `url.insteadOf` so the unpushed
branch is fetched locally.

## Live boat check (ww-jco), app e429b79 installed
Waterway linux_fuxa booted, HMI loads with live values, two full transits sampled every ~8 s (`shots/linux-fuxa/boat-fix-*.png`).
Fill direction (upward trip) and pools: boat sits on the water, no boat drawn over a closed gate.
NOT FIXED: while the chamber drains on the return trip the boat is drawn above the water: `boat-fix-5-drain-boat-above-water-FAIL.png`
(boat.location 103.7, lock 5.6, boat at about y=10; this is the original ww-cq0 symptom), cycle 2 shows ~2 levels of lag (`boat-fix-6`).
The y step windows are not the cause: it is a lag in FUXA's rendering of the chamber boat y during a drain. `burger run fuxa`: 14 ok, 0 FAIL (`burger-fuxa-report-boatfix.md`).

## Live boat check after the DUR=600 fix (ww-8ve), app 21848bd installed
App branch `feat-sceptre-linux-fuxa` @ 21848bd built/installed with `burger sync/build/install fuxa`
(`BURGER_APPS_REPO=/var/tmp/apps-rebase`, `BURGER_FORK_OWNER=adamsrnmsu`, a `url.insteadOf` for the unpushed branch, `DOCKER_HOST` pointing at
the lima docker socket); installed `lock_view.py` in the phenix container has `DUR = 600`. Waterway linux_fuxa recreated and booted (9 cc clients),
screenshots by `mm namespace waterway vm screenshot hmi file ...` every ~4 s (~104 frames, about 2.5 transit cycles, 21:45-21:53), 19 kept as
`shots/linux-fuxa/anim-fix-*.png`. Offset = boat hull bottom minus water surface read off each frame (12 px per level); the boat floats about
0.8 level below the surface when still (stepped y, by design), so "above water" below is relative to the surface.

| frame | phase | lock.height | boat.location | boat vs water |
|---|---|---|---|---|
| 000 | end of drain | 13.29 | 179 | ~0.3 below (drain, boat in chamber) |
| 007/013/034/038/040/062 | lower pool and lower gate stops | 4.99 | 35/91/76/4/49/98 | on the pool surface, no boat over a closed gate |
| 016 | fill, boat in chamber | 10.47 | 156 | 1.8 below (fill trails the water, stepped y) |
| 019 | upper gate stop | 15 | 212 | ~1 below |
| 024, 082 | upper pool | 15 | 281, 278 | on the surface |
| 028 | drain starts | 14.97 | 196 | on the surface |
| 030 | drain | 10.39 | 150 | 0.2 above |
| 032 | drain, boat near lower gate | 6.39 | 110 | 0.7 above |
| 076 | fill cycle 2 | 14.27 | 194 | 1.7 below |
| 088 | drain cycle 2 | 10.67 | 153 | on the surface |
| 090 | drain cycle 2, near lower gate | 6.59 | 112 | 0.5 above |
| 092/094 | lower pool after drain | 4.99 | 73/33 | on the surface |

Result: PASS. In both drains the boat stays within about 1 level of the water (worst 0.7 above) where before it sat 4.4 levels above
(boat 10 vs lock 5.6). Fill frames show the boat trailing the rising water by up to ~1 level beyond its normal float depth; it is
below the surface, not above it, and recovers at each gate stop.
