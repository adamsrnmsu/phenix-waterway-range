# sceptre app: Linux SCADA stack ("linux_fuxa")

Bead ww-41d. Target: sandialabs/sceptre-phenix-apps, branch `feat-sceptre-linux-fuxa`
(worktree `/var/tmp/apps-fuxa`, from upstream/main 88643cc). Design only; no app code yet.

## 1. Trigger

`linux_fuxa` cannot live in `hardware.os_type`: phenix validates that enum
(`sceptre-phenix src/go/types/version/schemas/v1.yaml`: centos|linux|minirouter|rhel|vyatta|vyos|windows|other)
and phenix startup/ntp/serial/soh/vrouter branch on `os_type == linux`. So:

- Node keeps `hardware.os_type: linux`.
- Sceptre scenario host metadata carries `stack: linux_fuxa` on each SCADA-side host
  (opc, scada-server, hmi, historian, engineer-workstation). Per host, not global: a mixed
  topology (Windows historian + Linux opc) stays legal.
- `hosts.py` gets `stack(host) -> str` next to `os_type()` (reads `host.metadata.stack`, "" when absent) and
  `is_linux_fuxa(host)` = `os_type(host) == "linux" and stack(host) == "linux_fuxa"`.
- Absent `stack` => every code path below is skipped; Windows output and the golden test stay byte-identical.

## 2. Outputs per role (pre-start writes, configure injects)

App writes configs only. FUXA, the asyncua gateway and telegraf/influx stay in the images
(`images/scripts/*.sh`). Inject paths are the ones the range uses today.

| Role (metadata.type) | File (under `sceptre/<host>/`) | Inject dst | Replaces (Windows) |
|---|---|---|---|
| opc | `opc_gateway.json` | `/etc/sceptre/opc_gateway.json` | opc.xml + topserver.ps1 |
| scada-server | `fuxa_project.json` | `/etc/sceptre/fuxa_project.json` | myscada project / autoproject |
| scada-server | `hmi_url` | `/etc/sceptre/hmi_url` | - |
| hmi | `hmi_url` | `/etc/sceptre/hmi_url` (URL of its SCADA server, same rule as `hmis()`) | hmi.ps1 |
| historian | `telegraf.conf` | `/etc/telegraf/telegraf.conf` | historian_config.txt |
| historian | `influx-setup.sh` | `/etc/phenix/startup/influx-setup.sh` (0744) | historian.ps1 |
| engineer-workstation | `rtus.txt` | `/etc/sceptre/rtus.txt` | putty.ps1 / auto_winscp.ps1 |

Not generated for linux_fuxa hosts: any `.ps1`, `sceptre-startup*` Windows scheduler injects (the
`_windows_host` helper is bypassed). `override=<name>` is kept on every inject so HIL/user overrides still work
(`find_override` keys `<host>_<name>`).

File formats are exactly those of `scada/gen_configs.py` outputs (the range's
`topologies/waterway-arm64/injects/`): gateway config format of `scada/opcua_gateway.py`
(`opc_endpoint`, `poll_interval`, `scale`, `rtus[].points[]` with node id `<rtu>.<device>.<field>`, read/write registers),
`fuxa_project.json.j2` + `lock_view.py`, `telegraf.conf.j2`, `influx-setup.sh`.

## 3. Data mapping: app objects -> outputs (no `reg_addrs.json` round trip)

In-memory source: `PreStartState.fd_server_configs: dict[hostname, FieldDeviceConfig]`, walked with
`configs.all_registers()` / `OpcConfig.channel_list[].devices[].tags[]`.

| gen_configs input | App source |
|---|---|
| reg `ip` | `config.ipaddr` |
| host name (ip2host lookup in topology) | `config.name` (no lookup needed) |
| `register_type` | `register.regtype` (`input-register`, `holding-register`; other modbus types => `AppError`, same `NotImplementedError` as gen_configs) |
| `address` | `register.addr` |
| `name` / `field` | `register.devname` / `register.field` |
| modbus only | `"modbus" in protocol.protocol` (as `elk_files` does) |
| one gateway node per (host, device, field): read=input reg, write=holding reg; holding-only read back from holding | same merge as `gen_configs.build()` |
| gateway/OPC set of RTUs | the `OpcConfig` for that OPC: `opcs()` already narrows `fd_server_configs` by `connected_rtus` (see risk R3) |
| `opc_endpoint` (FUXA, telegraf) | `opc_ip` already in `opc_on_subnet()` / `OpcConfig` = `non_mgmt(opc)[0].address`, port 4840 |
| scale `[0, 1000]` | `config.range` per device (waterway infra `range: [0,1000]`); gateway has one global scale => take it from the first RTU, `AppError` if RTUs disagree |
| influx org/bucket/token | metadata on historian: `influx_org`/`influx_bucket`/`influx_token` with defaults `sceptre`/`waterway`/`waterway-historian-token` (defaults = current range values); pydantic-validated |
| `rtus.txt` | `connected_rtus` else all fd-servers: `<hostname> <address(rtu)>`, sorted |
| `hmi_url` | `http://<scada ip>:1881/` using `non_mgmt(scada)[0].address` |

Implementation shape (small, mirrors existing code): new `sceptre/scada_linux.py` with pure functions
`gateway_config(opc_config) -> dict`, `points(opc_config) -> list[Point]`, `fuxa_project(...)`,
`telegraf_conf(...)`; `lock_view.py` moved in as `sceptre/lock_view.py` unchanged. Templates become mako in
`sceptre/templates/` (`fuxa_project.mako`, `telegraf.mako`, `influx_setup.mako`); `opc_gateway.json` is `json.dumps`.
The FUXA project JSON stays validated with `json.loads` after render (fail in pre-start, not at FUXA import).
`scada.py` handlers branch at the top of each method: `if is_linux_fuxa(h): self._linux_<role>(h); continue`.
`configure.py` handlers branch the same way, declaring the injects in the table above.

## 4. Metadata / validation (metadata.py, validation.py)

- `metadata.py`: `Stack(StrEnum)` with `LINUX_FUXA = "linux_fuxa"`; constants for the default influx values and FUXA port 1881, OPC UA port 4840.
- `validation.py`: add `stack: Stack | None = None` to `OpcMeta`, `ScadaMeta`, `HmiMeta`, `EngineerMeta`, `HistorianMeta` only, not the `Meta` base (`Meta` keeps `extra="allow"`, so existing scenarios with unknown keys are unaffected). `HistorianMeta` additionally gets optional `influx_org/bucket/token: str`.
- Checks (via `host.flag`, fatal): `stack` set but `os_type != linux` ("stack linux_fuxa needs hardware.os_type linux"); `stack` set on scada-server together with `project`/`automation` ("project is a Windows MyScada file; unset it for linux_fuxa"); mixed `stack` among hosts that must interoperate => warning only (non-fatal).
- Scenario-level (existing `Scenario` check block at ~L496): if a linux_fuxa opc has no modbus registers in its RTUs, flag (non-fatal) that gateway config will be empty; non-modbus protocols in a linux_fuxa RTU => fatal with the protocol name.
- Unknown `stack` value: pydantic enum error listing valid values (closest-match hint like the other validators).

## 5. Stays Windows-only / unchanged

TopServer (`opc.xml`, `topserver.mako/ps1`), MyScada (`scada.mako`, `scada_autoproject.mako`, `autoproject` dir copy,
`scada_connectionsdef/table`), Windows `hmi.ps1`, `putty.ps1`/`auto_winscp.ps1`, `historian.mako/ps1`,
`add_sceptre_startup_injects_windows`. HIL `opc.xml` override. Field devices, providers, HELICS, ELK untouched.
`reg_addrs.json` ELK output stays (still consumed by the ELK box analytics).

## 6. Test plan

Style: existing pytest in `sceptre/tests/` (`sceptre_app`, `node()` fixtures, `injects(app)` helper, golden file).

1. `test_hosts.py`: `stack()`, `is_linux_fuxa()` on merged host / bare node / model shapes; windows + stack => False.
2. `test_validation.py`: stack accepted on 5 types; rejected on Windows host; rejected with `project`; unknown value hint; influx fields typed.
3. `test_scada_linux.py` (unit, pure fns): gateway merge of input+holding, holding-only, `boat` read-only, sorted order, non-modbus/unsupported regtype error, scale mismatch error.
4. `test_prestart.py` additions: linux_fuxa opc/scada/hmi/historian/engineer produce the files in table 2 and NO Windows files; Windows host in the same experiment still gets its files.
5. `test_configure.py` additions: `injects(app)` has exactly the dsts in table 2 for linux_fuxa and none of the Windows dsts, overrides named.
6. Existing `test_sceptre_golden.py` must pass untouched (Windows byte-identical when `stack` absent). Add a second golden input `test_sceptre_input_linux_fuxa.yaml` + hashes for the new path (same regen mechanism `PHENIX_UPDATE_GOLDEN=1`).
7. **Golden vs gen_configs.py (cross-check, runs in range repo, not shipped upstream)**: scenario = upstream waterway scenario with provider/rtus as in `gen_scenario.py` (`rtu-1` + `boat` device last) PLUS opc/scada-server/hmi/historian/engineer-workstation entries carrying `stack: linux_fuxa`; topology = `topologies/waterway-arm64/waterway-topology.yaml`. Run `phenix-app-sceptre pre-start --dry-run`; `diff` each of opc_gateway.json, fuxa_project.json, telegraf.conf, influx-setup.sh, hmi_url, rtus.txt against `topologies/waterway-arm64/injects/` (those are gen_configs.py output). Must be byte-identical for JSON after normalising (`json.loads` equal) and byte-identical for the text files. A copy of the injects lives in the upstream test as a fixture so upstream CI has the same check without the range repo.
8. Lint/type: repo's ruff, mypy, vulture per `src/python/AGENTS.md` (`uv run`), plus CHANGELOG is releasaurus-managed (conventional commits only).

## 7. Implementation plan (small TDD steps; each = failing test, minimal code, green, conventional commit)

1. Baseline: `uv run pytest phenix_apps/apps/sceptre` green in `/var/tmp/apps-fuxa`; record golden hashes unchanged. (No commit.)
2. `hosts.stack()` + `is_linux_fuxa()` + `Stack` enum in metadata.py. `feat(sceptre): stack metadata helper`.
3. Validation: `stack` field on the 5 metas + the Windows/project/unknown-value checks + historian influx fields. `feat(sceptre): validate linux_fuxa stack metadata`.
4. `scada_linux.py` gateway: points merge + `gateway_config()` + scale rule, unit tests with hand-built `FieldDeviceConfig`s. `feat(sceptre): linux opc gateway config`.
5. Vendor `lock_view.py` + `fuxa_project.mako`; `fuxa_project()` pure fn; tests port `test_fuxa_project.py`. `feat(sceptre): fuxa project generator`.
6. `telegraf.mako` + `influx_setup.mako` + `hmi_url`/`rtus.txt` helpers; unit tests. `feat(sceptre): telegraf, influx and engineer configs`.
7. Wire `Scada` pre-start handlers (opcs, scada_servers, hmis, engineer_workstations, historians) behind `is_linux_fuxa`; prestart tests; existing golden unchanged. `feat(sceptre): pre-start for linux_fuxa hosts`.
8. Wire `ConfigureStage` injects (bypassing `_windows_host`); configure tests. `feat(sceptre): inject linux_fuxa configs`.
9. Second golden input + hashes for the linux path. `test(sceptre): linux_fuxa golden`.
10. Cross-check against gen_configs.py output for waterway-arm64 (add stack hosts to range `gen_scenario.py`, run app dry-run, diff). Fix mismatches. Also then retire `reg_addrs.json` path in the range (range-repo change, separate bead).
11. Docs: sceptre `README.md` (stack section, metadata table, inject table), final lint/mypy/vulture, squash-free review. `docs(sceptre): linux_fuxa stack`.
12. (Range repo, optional) one end-to-end boot of waterway-arm64 via burger/phenix with the app generating the configs; only one heavy experiment at a time.

## 8. Risks / open points

- R1 (design-affecting, already resolved above): `hardware.os_type: linux_fuxa` is not valid in phenix; `stack` metadata is the carrier. If Ryan insists on os_type, phenix schema + every `os_type == linux` branch must change in sceptre-phenix first.
- R2 Range scenario (`gen_scenario.py`) currently drops all SCADA-side hosts ("configs come from topology injections"), so the app has nothing to hook on until those hosts are added with `stack: linux_fuxa`; the golden (test 7) needs that scenario. Upstream waterway scenario's scada-server has `project:`/`automation:` (Windows); validation fatals on that combination, so the range scenario must omit them.
- R3 `connected_rtus` on opc narrows the registers; the range gateway today has all RTUs. Waterway opc lists rtu-1,rtu-2 so the golden holds; the existing "no rtus defined => all field devices" warning path also feeds the gateway.
- R4 Verify during step 10 that `config.ipaddr` (the "tcp" interface chosen in field_devices.py) is the ICS address 10.1.1.10x and not the MGMT one; gen_configs took the reg `ip` from that same field, so it should match.
- R5 Gateway has one global `scale`; per-device ranges that differ raise instead of silently picking one.
- R6 Modbus only: dnp3/bacnet/IEC104 RTUs behind a linux_fuxa OPC are rejected (gateway speaks Modbus TCP only).
- R7 Upstream reviewers may object to vendoring a ~230-line lock view specific to waterway; it skips elements whose tag is missing, so non-waterway topologies get a bare project (tags, no animation). Acceptable but call out in the PR.
- R8 Sceptre `AGENTS.md` requires Windows output unchanged; step 6 of the test plan is the guard.
