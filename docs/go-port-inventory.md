# Go port inventory: Python phenix apps, SCORCH components, range tooling (ww-otj.4)

Inventory only, nothing ported. Porting needs Ryan's pick (ww-otj.4 stays open). Date 2026-11-08.
Sources: `~/git/sceptre-phenix-apps` at `6e287f7` (`src/python`, Python 3.12, GPL-3), `~/git/sceptre-phenix`
(`src/go/app/user.go`, `src/go/api/scorch/user.go`), and this repo. Line counts exclude tests and `.venv`.

## 1. How phenix runs them (this decides the port cost)

- **Apps.** `app/user.go:shellOut` runs `phenix-app-<name> <stage>` as a **fresh subprocess per stage**
  (`configure`, `pre-start`, `post-start`, `running`, `cleanup`). The whole experiment is marshalled to JSON on stdin, the
  app prints the modified experiment JSON on stdout (empty stdout = no change), stderr is streamed to the phenix log, and
  exit code `ExitSchedule` means "run this scheduler, then re-run me". Env: `PHENIX_DIR`, `PHENIX_FILES_DIR`,
  `PHENIX_LOG_LEVEL`, `PHENIX_LOG_FILE`, `PHENIX_DRYRUN`, `PHENIX_STORE_ENDPOINT`. Python base class: `phenix_apps/apps/__init__.py` (`AppBase.main`).
- **SCORCH components.** `api/scorch/user.go` runs `phenix-scorch-component-<type> <run_stage> <name> <run_id> <loop> <loop_count>`
  with the experiment JSON on stdin, **once per component per run stage per loop**. The SCORCH controller
  itself (`scorch/app.py`, 564 lines) is also a Python app.
- **The contract is language neutral** (argv, stdin/stdout JSON, exit code, env). So a Go replacement is a drop-in binary
  named `phenix-app-<x>` / `phenix-scorch-component-<x>` earlier on `PATH`, no phenix change needed.
- **Precedent already upstream:** `src/go/cmd/phenix-app-mirror` (1003 lines) plus `src/go/util` (experiment decode,
  scenario/app/node extraction, template render, logging; 1759 Go lines total). A Go port starts from that scaffold.
  Phenix also has in-tree Go "default apps" (`app/ntp.go`, `tap.go`, `vrouter.go`, ...) that run in-process, no subprocess.

## 2. Measurements (arm64, Docker `ubuntu:24.04 --platform linux/arm64`, Python 3.12.3, container `rb-inv-*`)

Method: `python3 -m venv`, `pip install --only-binary=:all:` of every dependency in `pyproject.toml` plus `asyncua`,
`pip install --no-deps -e .`, then min of 5 `python -c "import <entrypoint>"` runs (warm cache). Run on a busy Mac/Docker VM
(another container was running during the first pass), so treat as +/-20%.

| Fact | Result |
|---|---|
| Interpreter baseline (`python -c pass`) | ~10 ms |
| Import of an app entrypoint | caldera/helics/mgmt_tap/protonuke/wireguard 118-121 ms; otsim 123; wind_turbine 125; scale 137; ignition 158; sceptre 165; scorch app 155 |
| Import of a SCORCH component | 152-167 ms typical; ssh 187; erspan 184 |
| **sceptre `pre-start --dry-run` end to end**, waterway-arm64 scenario+topology | **198 ms**, rc 0, 19 KB JSON out |
| Where the import time goes | `phenix_apps.common.utils` imports `elasticsearch` eagerly: 53 ms of the ~123 ms scorch import, paid by **every** app and component, even `caldera` which never touches Elastic |
| Install footprint | venv 131-151 MB (site-packages); 10 native extension packages |
| Native deps | `cffi`, `bcrypt`, `cryptography`, `PyNaCl` (via paramiko/asyncua), `lxml`, `pydantic_core`, `MarkupSafe`, `charset_normalizer`, `PyYAML`, `python-box` |
| **arm64 wheels** | **All present.** `pip install --only-binary=:all:` succeeded on aarch64 for every dep. There is **no arm64 build blocker** in the apps' own dependency tree. |

Reading: per-call startup is 0.12-0.2 s, so a 5-stage app costs ~1 s and a SCORCH run of N components x loops costs
N x loops x ~0.16 s. That is a nuisance, not a failure. The real arm64-range costs are elsewhere:

1. **Image build.** `docker/phenix-arm64.Dockerfile` installs the apps with
   `pip install --break-system-packages git+https://github.com/sandialabs/sceptre-phenix-apps...` (needs network + git at
   build time, mutates the distro Python, `requires-python >=3.12` pins the base image). Go apps are COPYed as static
   binaries from the `gobuilder` stage in the same file (`COPY --from=gobuilder /go/bin/phenix-app-*`).
2. **Size.** ~131 MB of site-packages and an interpreter in the phenix container for ~33k lines of mostly glue.
3. **Guest-side Python is the bigger weight, but it is not phenix.** `images/overlays/bennu-arm64/.../python3.10/dist-packages`
   is **397 MB** (pybennu + numpy/scipy/matplotlib stack). That is the PYPOWER/Simulink provider problem that ferrofire
   (ww-1df) and the Rust field device (ww-otj.1/.2) remove; it is not a Go-port item.

## 3. Inventory: phenix apps (`phenix_apps/apps/*`)

"Used here" = referenced by a topology under `topologies/`.

| App | Lines | What it does | Third-party imports | Used here | Pain on this range |
|---|---|---|---|---|---|
| **sceptre** | 3236 (+ mako templates, `infrastructures.yaml`, mydesigner assets) | Reads per-host scenario metadata; computes deterministic Modbus/DNP3/BACnet register maps; renders fd-server/fep/historian/HMI/SCADA configs, startup scripts and injects (`prestart.py`, `configure.py`, `field_devices.py`, `simulators.py`, `scada.py`, `validation.py` 657, `configs/`). | box, pydantic, pyyaml, `myscada` (Win) | **yes** (waterway, phase4, mitm) | Highest. The range reads its `elk/reg_addrs.json` as the **single source of truth for register addresses** (`scada/gen_configs.py --from-dry-run` shells out to the app). Much of the code (Win7 mySCADA, Wonderware, WinSCP templates) is dead weight on the Linux/FUXA arm64 range. |
| **caldera** | 209 | Creates Caldera server nodes in the topology; injects Sandcat agents into existing hosts. | none (stdlib + Box base) | yes (`caldera-test`) | Low pain, but trivially portable and used. |
| ot-sim | 1853 | Generates OT-sim configs for fd-server/fep/fd-client; HELICS broker script. | box, **lxml** | no (range uses bennu field devices) | lxml is native but has an aarch64 wheel. Not on this range's path. |
| ignition | 1292 | Configures Inductive Automation Ignition 8.3 (DNP3 connections, Perspective). | pydantic | no (range uses FUXA) | None for the range. |
| scale | 1594 (+ plugins) | Plugin-based mass VM/container generator. | box, loguru, lxml, pydantic, rich, minimega | no | None for the range. |
| wind_turbine | 602 | **Deprecated** (README), replaced by the `scale` plugin. | box, lxml | no | Do not port. |
| helics | 179 | Generates HELICS broker start scripts from node annotations. | none | no | Tiny. |
| mgmt_tap | 159 | Taps the experiment management network. | minimega | no | Tiny; the in-tree Go `tap.go` default app overlaps. |
| protonuke | 66 | Injects `/etc/default/protonuke`. | none | no | Tiny. |
| wireguard | 85 | Wireguard injects. | none | no | Tiny. |
| scheduler single_node | 28 | `phenix-scheduler-single-node`. | none | no | Tiny. |
| (mirror) | Go already | `phenix-app-mirror`, 1003 lines Go. | | | Done upstream; the template for ports. |

Shared library `common/` (2049 lines; `utils.py` 1626): minimega client wrapper (`minimega.py` is 16,654 lines, a unix-socket
client), mako rendering, Elastic and ssh helpers. Every Python app/component pays for it. The Go side reaches minimega via
`libminimega` (indirect dep in the apps `go.mod`) and phenix's own client code.

## 4. Inventory: SCORCH (`apps/scorch`, 8638 lines total incl. the controller)

Controller `scorch/app.py` 564 lines + `validate.py`. Components (one executable each, per section 1):

| Component | Lines | What it does | Third-party | Used here |
|---|---|---|---|---|
| tcpdump | 295 | Starts/stops tcpdump on VMs via minimega cc, collects pcaps | pydantic | **yes** (mitm-capture) |
| ettercap | 78 | Starts/stops ettercap MITM on a VM | none | **yes** (mitm) |
| cc | 293 | Runs commands on VMs via minimega cc, optional validators | none | no (but the base of most others) |
| caldera | 249 | Drives the Caldera REST API (operations) | none | planned (ww-ebo) |
| pcap | 542 | Captures/processes pcaps (tshark) | box, pydantic | related (ww-ebo.3) |
| mm | 522 | Raw minimega commands | pydantic | no |
| iperf | 792 | iperf server/client orchestration and results | box, pydantic | no |
| disruption | 502 | Fault injection (link/node) | pydantic | no |
| collector | 963 | Gathers files and shapes CSV/Elastic output | dateutil, elasticsearch, pyyaml | no |
| opcexport | 639 | OPC UA to Elastic export | **asyncua**, elasticsearch | no (FUXA path) |
| ssh | 401 | SSH command execution | **paramiko** | no |
| erspan | 396 | ERSPAN capture | paramiko, pydantic | no |
| rtds | 330 | RTDS simulator control | elasticsearch, requests | no |
| providerdata | 303 | Reads simulation provider data | pydantic | maybe (pairs with ferrofire) |
| kafka | 363 | Kafka produce/consume | **kafka-python** | no |
| vmstats | 224 | VM stats | pydantic | no |
| trafficgen | 223 | Traffic generation | none | no |
| qos | 177 | tc/QoS | box, pydantic | no |
| snort | 187 | Snort IDS control | pydantic | no |
| hoststats | 155 | Host stats | pydantic | no |
| art | 156 | Atomic Red Team runner | box | no |
| pipe | 115 | Named pipe passthrough | pydantic | no |

## 5. Inventory: Python tooling in this repo (excluding `.build/`, vendored overlays)

| File | Lines | Role | How invoked | Verdict |
|---|---|---|---|---|
| `scada/opcua_gateway.py` (+ identical copy under `images/overlays/opc-arm64/opt/opcua-gateway/`) | 246 | **Runs inside the `opc` guest**: pymodbus poll to asyncua OPC UA server; systemd service | long-running service in a venv (`asyncua==2.1.0`, `pymodbus==3.16.2`) | Candidate for **Rust** (runs in a range VM, per the language rule), not Go. Two copies can drift: dedupe. |
| `scada/gen_configs.py` | 212 | Renders opc/FUXA/telegraf configs from the sceptre register map | manual, host side; shells out to `phenix-app-sceptre` | Falls away or shrinks once the register map is a Go library/binary. |
| `scripts/pcap_walkthrough.py` | 388 | Evidence analysis for the MITM capture | manual | Keep (analysis script, no startup cost issue). |
| `topologies/*/gen_*.py` | 21 / 67 / 54 | Generators for the scenario/topology YAML | manual | Keep. |
| `images/uefi_patch.py` | 89 | Rewrites a vmdb to GPT/ESP for arm64 image builds | image build | Keep. |
| `scada/test_fuxa_project.py` | 12 | Self-check | manual | Keep. |
| `images/overlays/bennu-arm64/.../python3.10/dist-packages` | 397 MB vendored | pybennu runtime in the provider guest | in guest | Not Go: removed by ferrofire (ww-1df) and the Rust field device. |

## 6. Port-to-Go priority

Judged on: pain on this arm64 range, whether the range actually uses it, size/risk, and fit with the roadmap rule
(Go for the orchestration layer next to phenix/minimega; Rust inside VMs).

| Rank | Port | Why | Size | Risk / note |
|---|---|---|---|---|
| **1** | **sceptre register-map slice** (`configs/`, `prestart.py`, `field_devices.py`, `simulators.py`, ~1.4k lines) as `phenix-app-sceptre` in Go, keeping the `elk/reg_addrs.json` output byte-compatible | The only app the range truly depends on; `reg_addrs.json` is the contract that feeds OPC, FUXA, telegraf and, later, the Rust field device config (ww-otj.1). Removes the Python subprocess from `gen_configs.py`. | Medium | Keep the Windows/mySCADA templates out of the Go app; leave `validation.py` and the remaining templates in Python until needed. Needs a golden-file test against `scada/testdata/reg_addrs.json` (already a real dry-run capture). Decide full-replace vs. Python-fallback for stages the Go app does not implement. |
| **2** | **SCORCH minimal set: `tcpdump`, `ettercap`, `cc`** (666 lines) plus the shared component contract in `util` | Used by the MITM scenario now. They only shell out to minimega cc; no native deps, so little arm64 gain, but they run N x loops times per experiment and are the cheapest SCORCH ports. | Small | Controller (`scorch/app.py`) stays Python initially; components are independent executables so they port one at a time. |
| **3** | **caldera app** (209 lines) and **scorch `caldera` component** (249) | Pure stdlib + REST/topology generation, used by the `caldera-test` topology and the ww-ebo red/blue epic. Best "first Go port" to prove the scaffold (smallest, fully understood contract). | Small | Could be done first as a pilot. |
| 4 | **`common` shrink: lazy-import `elasticsearch`** (a Python edit upstream, not a port) | 53 ms of every ~120-160 ms start is Elastic client import. Cheap, helps every app until ports land. | Trivial | Upstream PR to sandialabs; out of scope to patch the clone here. |
| 5 | `pcap`, `providerdata`, `collector`, `disruption`, `iperf` | Useful but only when those features are exercised (blue-team capture, ferrofire integration). | Medium each | Defer until a scenario needs them. |
| 6 | `ssh`, `erspan`, `kafka`, `opcexport`, `rtds` | Heavier deps (paramiko, kafka-python, asyncua). Go libs exist (`x/crypto/ssh`, kafka-go/sarama, gopcua) but none are used by this range. | Medium each | Defer. |
| - | `ot-sim`, `ignition`, `scale`, `wind_turbine`, `helics`, `mgmt_tap`, `protonuke`, `wireguard` | Not on this range's path; `wind_turbine` is deprecated upstream. | | Do not port now. |
| - | `scada/opcua_gateway.py` | Runs inside the `opc` VM: Rust track, not Go. | | Raise under ww-otj.2/ww-585 if wanted. |

Honest caveat: on arm64 the Python apps **work today** (all wheels exist; sceptre pre-start is ~0.2 s). The case for porting is
image size and build hygiene (no pip-from-git, no 131 MB venv), per-call latency multiplied by SCORCH loops, and one shared
Go type system with phenix/minimega, not a blocking defect. That is why ranks 1-3 are small, targeted, contract-preserving
drop-ins rather than a rewrite, and why upstream-compatibility (same argv/stdin/stdout, same output JSON) is the rule.

## 7. Reproduce the measurements

```
docker run --rm --platform linux/arm64 -v ~/git/sceptre-phenix-apps/src/python:/src:ro -v /tmp/rb-inv:/inv ubuntu:24.04 bash /inv/run.sh
```
(`/tmp/rb-inv/run.sh`: python3-venv, binary-only pip install of the dependency list, `-X importtime`, min-of-5 timers;
`/tmp/rb-inv/e2e.sh` runs `phenix-app-sceptre pre-start --dry-run` on `topologies/waterway-arm64`.)
