# ICCP / TASE.2 in the range's Malcolm (ww-otj.51)

`images/malcolm-iccp.sh <malcolm-dir>` (called by `images/malcolm-stage.sh`, also runnable alone on the staged overlay
`/phenix/images/overlays-src/kali-purple/opt/malcolm` inside Lima, then `images/build.sh kali-purple-arm64`) adds, with no change to the
25 GB of Malcolm images:

| Layer | What | Where |
|---|---|---|
| Zeek | ferrofire `tools/zeek/iccp` (pinned `FF_REF`, default `065653b`) compiled with the Malcolm zeek image's own `spicyz`; the `.hlto` is bind-mounted into `zeek` and `zeek-live` as a plugin (`lib/zeek/plugins/packages/ferrofire-iccp/`), the scripts load through `zeek/custom` (`@load custom`) | `zeek/custom/iccp/` |
| Logstash | `images/malcolm-iccp/1075_zeek_iccp.conf`: dissect + split/zip fallback for `mms.log` and `iccp.log`; `mms.log`'s own `service` column becomes `mms_service`, `service` is set to `mms`/`iccp` (so `network.protocol` is the application) | mounted as a **directory** at `malcolm-pipelines.available/zeek` (logstash-start.sh seds `.conf` files in place, which fails on a single-file mount) |
| Maps | `mms`/`iccp` rows in `zeek_log_transport.yaml` and `zeek_log_ecs_categories.yaml` (`ot`, `network`) | single-file mounts over `/etc/*.yaml` |
| OpenSearch | `zeek.mms.*` / `zeek.iccp.*` in the `zeek_ot.json` component template (keywords, `invoke_id` long, `rtt` float) | mounted into dashboards-helper `/opt/templates/...` |

Documents land in `arkime_sessions3-*` with `event.dataset` `iccp` or `mms`; the Dashboards index pattern has all 29 fields.
The compiled `.hlto` is a build product and is not committed.

## Proof (2026-11-12, VM `blue`, kali-purple-arm64 rebuilt from the existing tarball)

Experiment `blue-iccp` (topology `blue-test`, 24 GiB / 8 vCPU). `scripts/iccp-blue-proof.sh` replays pcaps as raw frames out of
blue's capture tap (`scripts/pcap_inject.py`, so live Zeek sees them at the current time) and queries OpenSearch inside blue over cc.
Replayed: `tase2_assoc.pcap`, `tase2_report.pcap` (ferrofire synthetic), then the two real captures from `fetch-real.sh`
(`mms.pcap`, `iccp.pcap`; local only, never committed). Evidence: `docs/evidence/iccp-malcolm/` (`results.txt`, the queries,
inject logs).

* after all four: **3952 `iccp` and 4662 `mms` documents**; `iccp` by class: data, next_dstransfer_set, transfer_set, dataset,
  supported_features, bilateral_table_id ...; `mms` by service: informationReport, identify, read, write,
  defineNamedVariableList ...
* sample `iccp` document: `zeek.iccp.{op: report, domain: BELLEVUE, name: BELLEVUE/ANALOG_ICCP_IN[7], tase2_version: {1996;8},
  supported_blocks: BasicServices,...}`, `network.protocol: iccp`; sample `mms`: `confirmed_resp identify rtt 0.0066`.
* the saved Dashboards index pattern lists the 29 `zeek.iccp.*`/`zeek.mms.*` fields.

Caveats
* Counts include Malcolm's offline pass over its own netsniff pcaps (about 2x, as in docs/blue-evidence.md).
* One `weird` row: `iccp_parse_error: &requires failed ($$ != 128 && $$ != 255) iccp.spicy:26` on a 192.0.2.x flow of the real
  `iccp.pcap` (the README says weird.log is empty on the real captures; the live path differs, e.g. a mid-stream start). Follow-up filed.
* **Start storm.** Starting all 22 containers at once on a (re)boot drove the guest to load 100-220 and dropped miniccc (first
  boot after the image load was fine). Staged starting settles at load ~4; `images/scripts/kali-purple.sh` now installs
  `/usr/local/sbin/malcolm-start` (staged `compose up`) for `malcolm.service`. Not yet in the qc2 that was proven above (the
  stages were done by hand with the same order); it takes the next rebuild.
