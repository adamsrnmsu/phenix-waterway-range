# Plan: SCEPTRE phenix "waterway" range on Ryan's Apple Silicon Mac

Status: PLAN ONLY (2026-11-07). Nothing installed, nothing edited outside this file.
All new work lands in `~/git/phenix-waterway-range`; the sandialabs clones under
`~/git` are read-only inputs (build contexts, overlays reused by path). Upstream
changes are listed separately in Phase 7 as optional PRs.

Legend: `file:line` = verified in a local clone today; URL = verified by fetch today;
**UNVERIFIED** = could not confirm, treat as a spike item.

---

## 0. Host facts (verified today, with two corrections to the brief)

| Fact | Evidence |
| --- | --- |
| Apple M5 Max, 18 cores, 128 GiB RAM, macOS 27.0 (26A428), `kern.hv_support=1` | `sysctl`, `sw_vers` |
| 3.2 TiB free on the data volume; `/phenix` and `~/phenix` do not exist; no `/etc/synthetic.conf` | `df -h`, `ls` |
| **Correction:** Docker Desktop 4.98.0 *is* installed (brew cask, installed 2026-11-07 20:10), `/Applications/Docker.app` exists, `docker` CLI 29.9.2 works and `docker manifest inspect` succeeds. The `/usr/local/bin/docker` symlink is not dangling. | `brew info --cask docker-desktop`, `docker version` |
| It does not change the design: Docker Desktop's VM exposes no `/dev/kvm` to containers and cannot host minimega (needs `privileged`, `network_mode: host`, `/dev`, `/lib/modules` of the *same* kernel: `sceptre-phenix/docker/docker-compose.yml`). No official statement that Docker Desktop enables nested virt was found (**UNVERIFIED**, treat as "no"). | web search, compose file |
| No Lima/Colima/UTM/QEMU/Tart/Podman installed | `which`, `brew list` |
| Nested virtualization via Apple Virtualization.framework requires M3+ and macOS 15+ (`VZGenericPlatformConfiguration.isNestedVirtualizationSupported`); M5/macOS 27 satisfy the documented floor. No M5-specific statement exists. | https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported |
| Lima supports it: `nestedVirtualization: true` "Supported with `vmType: vz` or `vmType: krunkit` on Apple M3 or later (macOS 15 or later)", opt-in, since Lima v1.0 | https://raw.githubusercontent.com/lima-vm/lima/master/templates/default.yaml ; https://github.com/lima-vm/lima/issues/2824 |
| One field report on an **M5 + macOS 26 + Lima vz nested** setup: `/dev/kvm` appears in the guest, but QEMU (under Kata) "hangs on nested virt"; the author switched to Cloud Hypervisor. Cause, QEMU version and machine options are not given. | https://dev.to/terum/running-a-container-inside-a-non-privileged-microvm-on-an-apple-silicon-mac-145f (**UNVERIFIED** whether it applies to plain qemu-system-aarch64 + KVM; Phase 1 tests exactly this) |

The waterway inputs (`~/git/sceptre-phenix-topologies/waterway/`):
9 nodes; `simulink-provider`, `rtu-1`, `rtu-2` on `bennu.qc2`; `opc`, `historian`,
`hmi`, `scada-server`, `engineer-workstation` on Windows images with
`inject_partition: 2`; `router` on `minirouter.qc2` (`waterway-topology.yaml`).
The scenario drives the `sceptre` app: RTUs are `fd-server` with Modbus devices of
types `water`, `gate`, `valve`, `boat-sensor`, provider is `simulator: Simulink`
with x86-64 ELF binaries `simulinksolver` (dynamic) and `simulinkgt` (static Go)
(`waterway-scenario.yaml`, `file injects/*`). `myscada.exe` is a Win32 PE.
`waterway-dnp3.mep` is unused by the scenario (Modbus only).

---

## 1. Architecture

```
 macOS 27 (M5 Max)                                    ~/phenix/topologies (edit here)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ Lima VM "phenix"  vmType: vz, nestedVirtualization: true, Ubuntu 24.04 arm64 │
 │  /phenix/images  = Lima data disk (ext4)   /phenix/topologies = virtiofs mount│
 │  /dev/kvm (nested)   openvswitch.ko        ~/git mounted at same path (ctx)  │
 │ ┌──────────────── docker (rootful) ───────────────────────────────────────┐  │
 │ │ minimega:arm64  (privileged, host net, OVS, qemu-system-aarch64 + KVM)  │  │
 │ │ phenix:arm64    (privileged, host net, vmdb2/debootstrap, UI :3000)     │  │
 │ └──────────────────────────────┬──────────────────────────────────────────┘  │
 │     OVS bridge "phenix" ─ VLANs MGMT(172.16/16) SCADA(10.1.2/24) ICS(10.1.1/24)│
 │   aarch64 KVM guests (-M virt, -cpu host, AAVMF UEFI, virtio disk/net):      │
 │   provider  rtu-1  rtu-2  router(minirouter)  opc  scada  historian  hmi  eng │
 │   (provider may instead be ONE x86-64 TCG guest, see Decision 2)             │
 └──────────────────────────────────────────────────────────────────────────────┘
   Mac ⇄ VM: Lima port forwards (3000 phenix UI, 9001 miniweb) + `ssh -L` into
   guest IPs via a minimega tap on the MGMT vlan (`tap create MGMT bridge phenix ip 172.16.0.254/16`,
   syntax: minimega/cmd/minimega/bridge_cli.go:37).
```

Why a Linux VM, not Docker Desktop: phenix/minimega are Linux-only, need `/dev/kvm`,
privileged host networking and the OVS kernel module (`sceptre-phenix/docker/docker-compose.yml`
services `phenix`/`minimega`: `privileged: true`, `network_mode: host`, `/dev`, `/lib/modules`,
`/phenix:/phenix:shared`, `MM_FILEPATH: /phenix/images`). Only Apple's vz backend offers
nested virt on Apple Silicon; Lima is the thinnest supported wrapper around it.

### 1.1 Why arm64 guests are feasible (verified against source)

| Question | Answer | Evidence |
| --- | --- | --- |
| Does minimega hardcode `qemu-system-x86_64`? | No. `vm config qemu <path>` sets `QemuPath` (default `kvm`); resolved via PATH. `vm config machine` and `vm config cpu` exist; CPU default is `host`. | `minimega/cmd/minimega/kvm.go:54,91-95,114-118,1043-1049`; `vmconfiger_cli.go:1813` |
| Is the `kvm` default usable on arm64? | Ubuntu jammy `qemu-system-arm` (what `qemu-kvm` resolves to on arm64) ships `/usr/bin/qemu-system-aarch64` and `/usr/bin/kvm`. The minimega Dockerfile installs `qemu-kvm`. | https://packages.ubuntu.com/jammy/arm64/qemu-system-arm/filelist ; `minimega/docker/Dockerfile` (`openvswitch-switch qemu-kvm qemu-utils`) |
| x86-isms in minimega's qemu command line | (a) `-vga std` (b) `-usb -device usb-ehci,id=ehci -device usb-tablet,bus=usb-bus.0` (bus `usb-bus.0` exists only on x86 `pc`) (c) disk default `if=ide` (d) net default `e1000` (works on PCIe) (e) devices hang off `pci-bridge,id=pci.1` so no `pci.0` naming issue (f) `isa-serial` only when serial ports are configured (none in waterway) (g) recovery mode greps `qemu-system-x86` (unused: `MM_RECOVER=false`). | `kvm.go:36-39` (defaults), `kvm.go:1396-1500` (args), `kvm.go:1454` (usb-tablet), `kvm.go:1549,1593,1615`; `internal/recovery/recovery.go:116,162` |
| Can phenix pass per-VM qemu settings without code changes? | Yes: node-level `advanced:` map becomes `vm config <key> <value>` lines; node-level `overrides:` map becomes `vm config qemu-override "<match>" "<repl>"` (plain string replace on the joined arg string). | `sceptre-phenix/src/go/tmpl/templates/minimega_script.tmpl:63-68`; `src/go/types/version/v1/node.go:25-26`; `minimega/cmd/minimega/kvm.go:1714-1720` |
| Does phenix hardcode x86 bits? | Default `hardware.cpu` = `Broadwell` (invalid on aarch64, must set `cpu: host`); Linux VMs get `vm config qemu-append -vga qxl`; the vmdb template is BIOS/msdos (`grub: bios`); Debian/Kali package lists name `linux-image-amd64`, Ubuntu's are arch-neutral (`linux-image-generic`). | `node.go:682-683`; `minimega_script.tmpl:57-59`; `tmpl/templates/vmdb.tmpl:7-13,55`; `api/image/constants.go:183-184,208-209,219-222` |
| Ordering trap | phenix emits `vm config cpu` (`tmpl:49`) before any `advanced` line (`tmpl:63`), and minimega validates the CPU immediately by running `<qemu> -cpu ?` with no `-M`; on aarch64 QEMU has no default machine, so the script fails. Fix without code change: a `kvm` wrapper in our minimega image that inserts `-M virt` when no `-M/-machine` is present. | `vmconfiger_cli.go:632` → `kvm.go:1739-1747`; `internal/qemu/qemu.go:43-58` |
| `vm config qemu-append` semantics | Replaces the list (so our `advanced.qemu-append` drops phenix's `-vga qxl`). | `vmconfiger_cli.go:1015` |
| UEFI firmware | `qemu-efi-aarch64` provides `/usr/share/AAVMF/AAVMF_CODE.fd`; not installed by the minimega Dockerfile → add in our derived image. | https://packages.ubuntu.com/jammy/all/qemu-efi-aarch64/filelist |
| Can `phenix image build` make arm64 UEFI qcow2s? | `phenix image build` accepts a `.vmdb` path directly (`image.go:231`) and just runs `vmdb2 <file> --output … --rootfs-tarball …` (`image.go:262-283`); phenix's generated template is msdos+`grub: bios` (`vmdb.tmpl:7-13,55`). vmdb2's grub plugin supports `grub: uefi` with an `efi:` partition tag and installs `grub-efi-arm64` when `state.arch == arm64` (needs a GPT layout with an ESP). debootstrap inside the arm64 phenix container is native (no qemu-user). Ubuntu arm64 packages live on `ports.ubuntu.com/ubuntu-ports`, not the `us.archive` default (`cmd/image.go:167`; `image.go:52-58` only special-cases the default mirror). `inject-miniexe` assumes partition 1 unless given `disk.qc2:2`. | https://gitlab.com/larswirzenius/vmdb2/-/raw/main/vmdb/plugins/grub_plugin.py ; `api/image/image.go:510-513`. The glattercj fork used by phenix: **UNVERIFIED** that it carries the same plugin (fetch 404'd); Phase 2 checks `vmdb2 --help`/plugin list in the container. |
| Do bennu/minirouter recipes pull amd64-only bits? | Yes: `scripts/bennu.sh` writes `deb [arch=amd64 …]`, downloads `helics_3.6.1-1_amd64.deb`, `libzmq_4.3.4-1_amd64.deb`, `bennu.deb`, a `py3-none-any` pybennu wheel (which embeds a SWIG extension) and the x64 LabJack installer. bennu releases are "x86_64 builds only". cpack hardcodes `amd64`. The minirouter recipe is arch-neutral apt packages plus the `minirouter`/`miniccc` Go binaries, which just need an arm64 build. | `sceptre-phenix-images/scripts/bennu.sh`; `sceptre-bennu/README.md:119-133`; `sceptre-bennu/cmake/CpackConfig.cmake:15`; `sceptre-phenix-images/Makefile` (`_minirouter_img`) |
| Can bennu build on arm64? | Nothing arch-specific in bennu proper (no x86 intrinsics outside vendored HELICS third-party, which has portable fallbacks). `sceptre-bennu/Dockerfile` builds libzmq, HELICS, bennu and pybennu from source on `ubuntu:22.04` (multi-arch base) — run as-is on arm64. CI only exercises `ubuntu-22.04` x86 runners. pyhelics 3.6.1 has a `manylinux_2_28_aarch64` wheel; pyzmq/helics are pinned to git sources in pybennu so they build locally anyway. | `sceptre-bennu/Dockerfile`; `.github/workflows/build.yml:13`; `src/pybennu/pyproject.toml:45-46`; https://pypi.org/pypi/helics/3.6.1/json |
| Registry images | `ghcr.io/sandia-minimega/minimega:master` is amd64-only → build locally. `frangoteam/fuxa:latest` has arm64. phenix:main manifest not readable anonymously → build locally regardless (its Dockerfile downloads `glow_1.5.0_Linux_x86_64.tar.gz` and `filebeat-7.17.5-amd64.deb`, both have arm64 counterparts). | `docker manifest inspect` today; `sceptre-phenix/docker/Dockerfile` |

### 1.2 The per-node arm64 block (what every Linux node in our topology carries)

```yaml
hardware:
  cpu: host                       # phenix default "Broadwell" is x86-only (node.go:683)
  drives:
  - image: <role>-arm64.qc2
    interface: virtio             # minimega default if=ide has no controller on -M virt (kvm.go:37)
    inject_partition: 2           # UEFI layout: p1 = ESP, p2 = root
advanced:
  machine: virt                   # exact name only: minimega validates against `-M ?` (kvm.go:1752-1760)
  vga: virtio                     # replaces -vga std; the qxl append is dropped by qemu-append
  qemu-append: -bios /usr/share/AAVMF/AAVMF_CODE.fd
overrides:
  bus=usb-bus.0: bus=xhci.0       # usb-tablet bus name is x86-only (kvm.go:1454); CORRECTED: the controller on virt is xhci.0 (ehci.0 is wrong on virt, ww-585.23)
```
Phase 1 confirms this exact set (it may shrink or grow by one or two lines).
**Corrections found in Phases 1-6 (ww-585.23, ww-585.28):**
- The usb-tablet override is `bus=usb-bus.0: bus=xhci.0`, not `ehci.0`.
- The `kvm` wrapper (`docker/kvm-wrapper.sh`) also rewrites `-M virt` to `virt,its=off` (nested KVM on Apple vz hangs in early boot with the GICv3 ITS) and the bare empty-cdrom arg `media=cdrom` to `media=cdrom,if=none` (virt has no IDE controller; qemu errors `Device needs media`).
- `-nographic`-style launches drop `-vga virtio`, so GUI nodes (hmi, engineer) must carry `-device virtio-gpu-pci -device usb-kbd,bus=xhci.0` in `qemu-append` (alongside `-bios ...AAVMF_CODE.fd`) or `mm vm screenshot` is black and the desktop has no keyboard.
- Docker build contexts must not be the raw `~/git/<repo>` trees: the host's git fsmonitor socket (`.git/fsmonitor--daemon.ipc`) truncates the context upload. Build from the rsync'd private copies that `docker/Makefile` makes (`minimega-ctx`, `phenix-ctx`, `--exclude 'fsmonitor--daemon*'`).
Fallback knobs if KVM misbehaves: `advanced.qemu: qemu-system-aarch64` (no `-enable-kvm`
→ TCG; then `cpu: max`), or `qemu-append: … -machine gic-version=3`.

---

## 2. Role → software mapping and protocol flows

Original flow (`sceptre-phenix-apps/.../sceptre/README.md` diagram and `scada.py`):
provider →(UDP multicast `239.0.0.1:40000` publish + ZMQ `tcp://provider:5555` cmd)→ RTUs
→(Modbus/TCP :502)→ OPC (Kepware TopServer, `opc_channel_template.mako` "Modbus Ethernet" driver)
→ SCADA (mySCADA) → HMI; OPC → historian (Wonderware); engineer → RTU brash (sceptre login shell) over SSH
(`templates/putty.mako`).

| VM (hostname) | Original | Linux replacement (arm64) | Talks to | Protocol |
| --- | --- | --- | --- | --- |
| `waterway-provider` (renamed from `simulink-provider`, see §4.4) | bennu `bennu-simulink-provider` + x86 `simulinksolver` | **A (default):** unchanged binaries in ONE x86-64 TCG guest on the prebuilt amd64 `bennu.qc2`. **B:** pybennu `GenericPython` provider running `waterway_sim.py` on `bennu-arm64.qc2` | rtu-1, rtu-2 | bennu publish (UDP mcast 40000) + cmd (ZMQ tcp 5555) |
| `rtu-1`, `rtu-2` | `bennu-field-deviced` | same, native arm64 build (`bennu-arm64.qc2`) | opc | Modbus/TCP server :502; analog registers scaled to 16-bit over range `[0,1000]` (`infrastructures.yaml:190-204`; `bennu/.../modbus/module/Server.hpp:83`, `ClientConnection.hpp:137`) |
| `router` | minirouter | minirouter (arm64 build of `minimega/cmd/minirouter`) | all | OSPF between SCADA/ICS, static MGMT |
| `opc` | Kepware TopServer (OPC DA/UA server, Modbus master) | **Python gateway**: `pymodbus` client polling both RTUs → `asyncua` OPC UA server `opc.tcp://10.1.2.50:4840`, nodes `ns=2;s=<rtu>.<device>.<field>`, writes forwarded to holding registers | rtu-1/2 (Modbus), scada, historian (OPC UA) | Modbus/TCP → OPC UA |
| `scada-server` | mySCADA server + `myscada.exe` automation | **FUXA** (Node 22, native) with an OPC UA *client* device pointing at `opc`; serves the HMI web app on :1881 | opc; hmi (browser) | OPC UA client; HTTP :1881 |
| `hmi` | Win7 mySCADA HMI | Linux desktop (xfce autologin) running Firefox `--kiosk http://10.1.2.71:1881` | scada-server | HTTP |
| `historian` | Wonderware Historian (OPC) | **Telegraf** `inputs.opcua` → **InfluxDB 2** (:8086), bucket `waterway` | opc | OPC UA client (poll `interval`) |
| `engineer-workstation` | Win7 + PuTTY/WinSCP to RTUs | Linux desktop with xfce4-terminal autostarts `ssh sceptre@<rtu>` (login shell = brash) | rtu-1/2 | ssh 22 |

### 2.1 FUXA fit (verified)
- README protocol list: "Modbus RTU/TCP, Siemens S7 Protocol, OPC-UA, BACnet IP, MQTT,
  Ethernet/IP (Allen Bradley), ODBC, ADSclient, Gpio (Raspberry), WebCam, MELSEC, Redis, SNMP";
  Node.js 22 LTS recommended; port 1881; image `frangoteam/fuxa:latest` (arm64 available);
  "Built-in data historian (DAQ) with support for SQLite, InfluxDB". https://github.com/frangoteam/FUXA
- Driver directory has no DNP3 driver. https://github.com/frangoteam/FUXA/tree/master/server/runtime/devices
- The OPC UA driver is a **client only** (`opcua.OPCUAClient.create`, `client.connect(endpoint)`;
  no `OPCUAServer`). https://raw.githubusercontent.com/frangoteam/FUXA/master/server/runtime/devices/opcua/index.js
- Therefore FUXA covers `scada-server` and the HMI front end; it cannot be the `opc` role
  (needs an OPC *server*) and is not needed for the historian (Telegraf+Influx keeps the
  original "historian reads OPC" flow; FUXA's DAQ would collapse historian into the SCADA VM).

### 2.2 Address map source of truth
The sceptre app computes Modbus register addresses deterministically
(`configs/configs.py`, `configs/registers.py`) and pre-start already emits exactly the map
an OPC gateway needs: `elk/reg_addrs.json` = `{ip, register_type, address, name, field}` for
every Modbus register (`prestart.py` `elk_files`, written unconditionally). Our generator
consumes that file from a dry run (`make dry-run APP=sceptre STAGE=pre-start INPUT=…`; the target
accepts `pre-start`, `src/python/Makefile:65-77`) rather than re-implementing the register math.
Fallback if the dry run does not land the file where expected: import
`phenix_apps.apps.sceptre.configs.configs` directly in `gen_configs.py`.

---

## 3. Phases (ordered; each gates the next)

Repo layout created as phases run:
```
~/git/phenix-waterway-range/
  lima/phenix.yaml                  Phase 0
  docker/{Makefile,minimega-arm64.Dockerfile,kvm-wrapper.sh,phenix-arm64.sed,docker-compose.yml}  Phase 1
  spike/                            Phase 1 notes + the recorded working `vm config` lines
  images/{build.sh,uefi_patch.py,recipes/*.env,scripts/*.sh,overlays/*/}                     Phase 2,3,5
  topologies/helloworld-arm64/      Phase 1-2
  topologies/waterway-arm64/{waterway-topology.yaml,waterway-scenario.yaml,injects/}          Phase 4-6
  provider/waterway-sim/            Phase 4 (Rust simulinksolver drop-in)
  scada/{gen_configs.py,opcua_gateway.py,fuxa_project.json.j2,telegraf.conf.j2,influx-setup.sh}  Phase 5
```

### Phase 0 — Host prep (≈30 min)
Goal: tooling present, directories exist, nothing else.
- `brew install lima` (Lima ≥ 1.0 for `nestedVirtualization`; current is 2.x), optionally `oras`.
- `mkdir -p ~/phenix/topologies` (Mac side; `/phenix/images` lives on a Lima data disk, §Decision 7).
  No `/etc/synthetic.conf`, no reboot: `/phenix` exists only inside the VM.
- `limactl disk create phenix-images --size 300GiB`.
- Deliverable `lima/phenix.yaml` (sketch; `base:` keys exist in Lima ≥1.0 templates):
  ```yaml
  base: template://docker-rootful      # rootful docker: privileged + host networking + /dev mounts
  vmType: vz
  nestedVirtualization: true
  arch: aarch64
  cpus: 12
  memory: 48GiB
  disk: 120GiB
  mountType: virtiofs
  mounts:
  - {location: "~/phenix/topologies", mountPoint: /phenix/topologies, writable: true}
  - {location: "~/git", writable: true}       # same path in guest: build contexts, symlink targets
  additionalDisks:
  - {name: phenix-images, mountPoint: /phenix/images}
  portForwards:
  - {guestPort: 3000}                          # phenix UI (cmd/ui.go:82 default 0.0.0.0:3000)
  - {guestPort: 9001}                          # miniweb
  provision:
  - mode: system
    script: |
      modprobe openvswitch || (apt-get update && apt-get install -y linux-modules-extra-$(uname -r) && modprobe openvswitch)
      mkdir -p /phenix/images /phenix/topologies /etc/phenix /var/log/phenix
  ```
  Guest RAM budget: waterway asks 8192+4096+4×2048 MiB plus RTUs/router defaults ≈ 22-26 GiB.
Verify: `limactl --version` ≥ 1.0; `limactl disk ls` shows `phenix-images`.

### Phase 1 — GO/NO-GO spike (≈0.5-1 day). Nothing else starts until 1b and 1c pass.
Goal: prove nested KVM, then minimega launching ONE aarch64 guest, then one phenix experiment.
1a. `limactl start lima/phenix.yaml`; inside: `ls -l /dev/kvm` and `dmesg | grep -i kvm`
    (expect `kvm [1]: ... initialized`). FAIL → nested virt unsupported here; go to fallback (§3-F).
1b. Plain QEMU with KVM, no minimega:
    `apt install qemu-system-arm qemu-efi-aarch64; wget noble-server-cloudimg-arm64.img;`
    `qemu-system-aarch64 -M virt -accel kvm -cpu host -m 1024 -bios /usr/share/AAVMF/AAVMF_CODE.fd -drive file=noble-server-cloudimg-arm64.img,if=virtio -nographic`
    PASS = login prompt in < 90 s. HANG → retry with `-M virt,gic-version=3` then `gic-version=2`;
    still hangs → this is the dev.to failure mode; TCG fallback decision (§3-F).
1c. Containers (built in the VM, `~/git` is mounted):
    - `docker build -t minimega:arm64 -f ~/git/minimega/docker/Dockerfile ~/git/minimega` (unchanged upstream file).
    - `docker/minimega-arm64.Dockerfile`: `FROM minimega:arm64`; `apt-get install -y qemu-efi-aarch64 qemu-system-x86`
      (x86 for Decision 2-A); `COPY kvm-wrapper.sh /usr/local/bin/kvm` (adds `-M virt,its=off` when
      no `-M`/`-machine` given and rewrites `-M virt` to `virt,its=off`, plus `media=cdrom` -> `media=cdrom,if=none`; then `exec qemu-system-aarch64 -enable-kvm "$@"`).
    - `docker/phenix-arm64.sed` applied to `~/git/sceptre-phenix/docker/Dockerfile` into
      `docker/phenix-arm64.Dockerfile` (generated, never hand-edited): `Linux_x86_64`→`Linux_arm64`,
      `filebeat-7.17.5-amd64.deb`→`-arm64.deb`, `ghcr.io/sandia-minimega/minimega:${MM_MIN_REV}`→`minimega:arm64`
      (that stage only supplies `/opt/minimega/lib`). Build with context `~/git/sceptre-phenix`.
    - `docker/docker-compose.yml` = upstream compose with the two local image names (volumes unchanged:
      `/phenix:/phenix:shared`, `/dev`, `/lib/modules`, `MM_FILEPATH=/phenix/images`).
    - minimega-only test: `docker exec minimega mm vm config disk /phenix/images/noble.img,virtio`
      then the §1.2 lines by hand (`vm config cpu host`, `vm config vga virtio`,
      `vm config qemu-append -bios /usr/share/AAVMF/AAVMF_CODE.fd`,
      `vm config qemu-override bus=usb-bus.0 bus=xhci.0`, `vm config net 100`) → `vm launch kvm t1; vm start t1`.
    PASS = `mm vm info` shows `RUNNING` and miniweb VNC (`:9001`) shows the console.
    Record the final working lines in `spike/vmconfig-aarch64.txt`; they become §1.2.
1d. phenix helloworld, zero image building: `cp noble-server-cloudimg-arm64.img /phenix/images/ubuntu.qc2`
    (cloud image is already qcow2); `topologies/helloworld-arm64/helloworld.yaml` = upstream
    `helloworld/helloworld.yaml` (2 nodes, `ubuntu.qc2`) plus the §1.2 block (`inject_partition` omitted:
    phenix's startup app still injects hostname/interfaces files into every Linux VM — `src/go/app/startup.go:447,460` —
    and the cloud image's root is partition 1, so the default works);
    `phenix experiment create hw -t /phenix/topologies/helloworld-arm64/helloworld.yaml && phenix experiment start hw`.
    PASS = `phenix vm info` lists both VMs running; phenix UI (`localhost:3000`) VNC shows boot.
Deliverables: `lima/phenix.yaml`, `docker/*`, `spike/*`, `topologies/helloworld-arm64/`.
Exit criterion: 1b, 1c and 1d all PASS → arm64-native track confirmed; else §3-F.

### Phase 2 — arm64 image pipeline with `phenix image` (≈1 day). Depends on Phase 1.
Goal: UEFI-bootable arm64 qcow2s from phenix recipes, with miniccc and the phenix startup
service working; a router image.
- `images/build.sh <name>`: `phenix image create … <name>` (args from `recipes/<name>.env`,
  always `-m http://ports.ubuntu.com/ubuntu-ports`), `phenix image build --dry-run -o /phenix/images <name>`
  (writes `<name>.vmdb` before the dry-run check, `image.go:254-256,281`), `images/uefi_patch.py`
  rewrites that file to GPT: ESP (`mkpart` 1M-257M, `tag: efi`, `mkfs: vfat`, mounted at `/boot/efi`
  via `mount-on: root`) + root p2, `grub: uefi` with `tag: root`, `efi: efi`; then
  `phenix image build -o /phenix/images -c -x /phenix/images/<name>.vmdb` (method 3 in
  `sceptre-phenix-images/README.md`) and `phenix image inject-miniexe /phenix/miniccc /phenix/images/<name>.qc2:2`
  (`miniccc` copied out of `minimega:arm64` with `docker cp`). Exact vmdb2 mount-step keys: **UNVERIFIED**, first build fixes them.
- Recipes: `ubuntu-arm64` (noble, minbase, default packages) and `minirouter-arm64`
  (noble; `-P dnsmasq,openvswitch-switch,bird,nano,iptables,nftables,isc-dhcp-client,isc-dhcp-common`,
  `-T ~/git/sceptre-phenix-images/scripts/minirouter.sh`, `-O ~/git/sceptre-phenix-images/overlays/minirouter`,
  then inject arm64 `minirouter` binary from the container, exactly as `Makefile:_minirouter_img` does).
Verify: helloworld-arm64 on `ubuntu-arm64.qc2` with `inject_partition: 2` → `phenix vm info` running and
`docker exec minimega mm cc exec hostname` returns the guest hostname (proves miniccc + virtio-serial);
3-node test topology (two ubuntu + router with `type: Router`, `os_type: minirouter`) → `cc exec ping -c1`
across VLANs succeeds (proves minirouter arm64 + OSPF/static config).

### Phase 3 — bennu on arm64 (≈1 day, mostly compile time). Depends on Phase 2.
Goal: `bennu-arm64.qc2` with `bennu-field-deviced`, brash, pybennu.
- Build artifacts in the VM with the upstream Dockerfile unchanged:
  `docker build -t bennu:arm64 ~/git/sceptre-bennu`. The final stage deletes its source and build
  tree (`Dockerfile:121` `rm -rf /tmp/*`), so there is nothing to `cpack`; instead take the finished
  tree: `id=$(docker create bennu:arm64); docker cp $id:/usr/local - > images/overlays/bennu-arm64/usr-local.tar`
  → unpacked into `images/overlays/bennu-arm64/usr/local/`. That tree already holds the bennu binaries,
  libzmq (drafts) and HELICS libs, and pybennu with its dependencies installed system-wide by
  `uv pip install --system` into `/usr/local/lib/python3.10/dist-packages` (`Dockerfile:57,91`;
  python3.10 = jammy, which is why the image release below is jammy). A `.deb` is optional: rebuild in a
  container with `~/git/sceptre-bennu` bind-mounted and run `cpack -G DEB -D CPACK_DEBIAN_PACKAGE_ARCHITECTURE=arm64`
  (overrides `CpackConfig.cmake:15`). If the arm64 docker build fails on a pybennu dependency (risk 4),
  edit nothing upstream: build pybennu with `--no-deps` in a bind-mounted container and install only what
  the GenericPython path imports (`zmq`, the swig endpoint, settings: `power_daemon.py:1-13,308-331`).
- `images/scripts/bennu-arm64.sh` = `sceptre-phenix-images/scripts/bennu.sh` with: `[arch=arm64] ports.ubuntu.com/ubuntu-ports`
  sources, the runtime apt packages the bennu Dockerfile's final stage installs (boost, libsodium,
  libfreetype6, liblapack3, python3), `ldconfig` for `/usr/local/lib`, the GitHub `.deb`/wheel downloads and
  the LabJack step dropped (the overlay supplies them). Release `jammy` to match the build container
  (`ubuntu:22.04`). Overlays reused by path: `overlays/bennu`, `overlays/brash`.
Verify (inside the VM, mirrors upstream CI `build.yml:30-56`): `bennu-test-ep-server --d 1 &`,
`bennu-field-device --f /tmp/dnp3-server.xml &`, `bennu-probe --c query | grep brkr`; and
`pybennu-power-solver --help`. Then `bennu-arm64.qc2` boots under phenix with `cc exec bennu-brash --help`.

### Phase 4 — Physics provider: Rust `simulinksolver` drop-in (Decision 2, chosen 2026-11-07). Depends on Phase 3.
Goal: tags `lowerwater.height … uppersensor.active` (`injects/publishPoints.txt`) published to RTUs, native arm64.
- Ryan chose a new Rust simulator over emulating the x86 Simulink binaries.
- Interface: `bennu-simulink-provider` talks to the solver through SysV shared memory
  (`shmget` keys NUM_PUBLISH_POINTS/PUBLISH_POINTS/updates) and POSIX named semaphores
  (`PUBLISH_SEM`, `UPDATES_SEM`) — `sceptre-bennu/src/bennu/executables/bennu-simulink-provider/main.cpp:1-170`;
  the solver side of the contract is `solver/modelhooks/modelHooks.{c,h}` (and `modelhooksRealtime/`).
  The Rust binary implements that same contract, so it is a drop-in for `./simulinksolver -tf inf`.
- Why this route: zero changes to the sceptre app (its Simulink branch in `sceptre_start.mako:9-18` already
  launches `bennu-simulink-provider` + `./simulinksolver`), the RTUs and the provider stay stock
  (arm64 `bennu-simulink-provider` comes from Phase 3), and no ZMQ RADIO/DISH wire compatibility to re-implement.
- Deliverables: `provider/waterway-sim/` Rust crate → `simulinksolver` (static, aarch64-unknown-linux-gnu).
  Physics as in the old 4B sketch: inputs `lowergate.open, lowervalve.open, uppergate.open, uppervalve.open`
  (written by RTU logic, `waterway-scenario.yaml` `logic:`); outputs the 15 publish points; lock level moves toward
  the pool whose valve is open, boat advances through open gates, sensors reflect position, boat reverses at the ends.
  Fixed-step real-time loop; `-tf inf` accepted for CLI compatibility.
- Ground truth: `simulinkgt` (x86 Go, no source) is dropped; omit `gt`/`gt_template` metadata, or add a small
  HTTP ground-truth page to the Rust binary later (separate bead).
- Tests: `cargo test` covers a full boat transit in pure physics; an IPC test runs the binary against stock
  `bennu-simulink-provider` inside the Lima VM.
Verify: on the provider VM `bennu-probe --e tcp://127.0.0.1:5555 --c query` lists all 15 points; from rtu-1
`bennu-probe --c read --t lock.height` changes while `lowervalve.open` is 1.
- Fallbacks if the shm contract proves awkward: (A) original Simulink binaries in one x86-64 TCG guest on the
  prebuilt amd64 `bennu.qc2` (`advanced.qemu: qemu-system-x86_64`, `hardware.cpu: max`, see §1.1 ordering trap);
  (B) pybennu `GenericPython` with `waterway_sim.py`.
- Rename the host to `waterway-provider` (accepted); keep `simulator: Simulink` so `sceptre_start.mako` still
  takes the Simulink branch via metadata rather than the hostname substring.

### Phase 5 — Linux SCADA stack, one image per role (≈2-3 days). Depends on Phase 2; 5a needs Phase 3/4 for live data.
Common: every image is noble (`ports` mirror, UEFI via `build.sh`), root autologin GUI via phenix's
`mingui` post-build where needed (`constants.go:75-106`), role config delivered to `/etc/sceptre/…`
plus `/etc/phenix/startup/<role>.sh` (phenix's startup service runs that directory: `constants.go:64-72`).
All configs are rendered by `scada/gen_configs.py` from `reg_addrs.json` + the topology (Decision 4).

| Recipe | Base / variant | Script / overlays | Injected at runtime | Verify (from the Lima VM through the MGMT tap, or `cc exec`) |
| --- | --- | --- | --- | --- |
| `opc-arm64` | noble minbase | `opc.sh`: `python3-venv`; venv with `asyncua`, `pymodbus`; `opcua-gateway.service` | `/etc/sceptre/opc_gateway.json` (RTU IP, unit, register→tag, scale `[0,1000]`/65535) | `uaread -u opc.tcp://10.1.2.50:4840 -n 'ns=2;s=rtu-1.lowerwater.height'` prints a float that matches `bennu-probe` on rtu-1 |
| `scada-arm64` | noble minbase, 10G | `fuxa.sh`: Node 22 (NodeSource arm64), FUXA release tarball under `/opt/fuxa`, `fuxa.service` | project JSON (OPC UA device `opc.tcp://10.1.2.50:4840`, tags, one lock view) loaded at boot by `/etc/phenix/startup/fuxa.sh` through FUXA's project API (**UNVERIFIED** endpoint; fallback: pre-seed `_appdata` in the image) | `curl -s http://10.1.2.71:1881/api/project \| jq '.devices\|length'` ≥ 1; UI device status connected |
| `historian-arm64` | noble minbase | `historian.sh`: `influxdb2`, `telegraf` from repos.influxdata.com (arm64 debs), services enabled | `telegraf.conf` (`[[inputs.opcua]] endpoint="opc.tcp://10.1.2.50:4840"`, nodes list; `[[outputs.influxdb_v2]]`), `influx-setup.sh` (org/bucket/token, first boot) | `influx query 'from(bucket:"waterway")\|>range(start:-5m)\|>count()'` > 0 (plugin: https://github.com/influxdata/telegraf/blob/master/plugins/inputs/opcua/README.md, Telegraf ≥1.16) |
| `hmi-arm64` | noble **mingui** | `hmi.sh`: Firefox from packages.mozilla.org apt repo (Ubuntu's firefox is a snap and cannot be installed in a chroot build), autostart `.desktop` → `firefox --kiosk $(cat /etc/sceptre/hmi_url)` | `/etc/sceptre/hmi_url` = `http://10.1.2.71:1881/` | `mm vm screenshot hmi /tmp/hmi.png` shows the FUXA view |
| `engineer-arm64` | noble **mingui** | `engineer.sh`: `telnet`, `openssh-client`, `xfce4-terminal`; autostart one terminal per RTU | `/etc/sceptre/rtus.txt` (from `connected_rtus`/all fd-servers) | screenshot shows the brash prompt (ssh as sceptre; brash is its login shell) |

### Phase 6 — The waterway-arm64 range end to end (≈1 day). Depends on 2-5.
Deliverables: `topologies/waterway-arm64/waterway-topology.yaml` (upstream node list, Linux images,
§1.2 block per node, Windows `os_type` → `linux`), `waterway-scenario.yaml` (sceptre app for
provider + RTUs only; SCADA-side hosts carry **no** `type` so the app renders nothing Windows-specific
for them — `configure.py:_windows_host` would otherwise inject `.ps1` and `ProgramData/...` paths;
their files come from topology `injections` written by `gen_configs.py`. Drop `labels: [elk]` from
**every** host, including the provider and RTUs: with no ELK box, `configure.py:elk()` still injects a
`service filebeat start` script into each `elk`-labelled Linux VM),
`injects/` (gateway JSON, FUXA project, telegraf.conf, kiosk URL, RTU list, `waterway_sim.py` if 4B).
Commands (as upstream README): `phenix config create …topology.yaml; phenix config create …scenario.yaml;`
`phenix exp create waterway -t waterway-arm64 -s waterway-arm64; phenix exp start waterway`.
Verify: a boat transit is visible end to end — `bennu-probe` on rtu-1 shows `lowergate.open` 0→1,
`uaread` on opc agrees, FUXA view animates lock level, Influx has rows for `lock.height`;
and `phenix exp stop/start` is repeatable (snapshots on `/phenix/images` data disk).

### Phase 7 — Optional upstream PRs (separate beads; none blocks the range)
1. sceptre-phenix-apps: Linux variants of `opc`/`scada-server`/`historian`/`hmi`/`engineer-workstation`
   when `os_type == linux` (the Phase 5 artifacts become Mako templates; follow README "Adding a host type",
   extend `validation.py` models `OpcMeta/ScadaMeta/HmiMeta/EngineerMeta/HistorianMeta` and the golden tests);
   fix the hostname heuristic in `sceptre_start.mako` (branch on `metadata.simulator`, not `'simulink-provider' in name`).
2. sceptre-phenix: `phenix image --arch` (UEFI vmdb layout, `linux-image-arm64` for Debian/Kali, `ports` mirror default),
   arch-neutral Dockerfile downloads (`$(dpkg --print-architecture)`), skip the `Broadwell` default when `advanced.machine` is `virt`.
3. minimega: machine-aware USB tablet bus / `-usb` handling, `if=virtio` default off x86, validate `cpu` lazily
   or after `machine`, recovery process name; aarch64 doc page.
4. sceptre-phenix-images: `bennu-arm64`, `minirouter-arm64` recipes; `ARCH` in the Makefile; CI arm64 runner.
5. sceptre-bennu: arm64 CI job (`ubuntu-22.04-arm`), cpack architecture from `dpkg --print-architecture`, arm64 release debs/wheels.

### 3-F Fallbacks if Phase 1 fails
- 1a/1b fail (no usable nested KVM): **TCG inside the same Lima VM** — aarch64 guests: `advanced.qemu: qemu-system-aarch64`,
  `cpu: max` (≈3-5× slower than KVM, 9 small guests still workable on 12 vCPUs); or x86 guests with the
  prebuilt amd64 images and `qemu: qemu-system-x86_64` (≈10-20× slower; 9 VMs ≈ 20 TCG threads; only
  acceptable for a demo). Everything else in this plan is unchanged — the recipes, the SCADA stack and the
  topology are arch-independent apart from the §1.2 block.
- Or a **remote x86 Linux host** running the stock upstream containers; this plan's Phases 4-6 apply unchanged,
  Phases 2-3 are skipped (use prebuilt `bennu.qc2`, `minirouter.qc2`, `ubuntu.qc2` via `oras pull`).

---

## 4. Image recipe summary (one per VM role, as requested)

| Image | Role(s) | Release / variant / arch | Overlays | Scripts | Notes |
| --- | --- | --- | --- | --- | --- |
| `ubuntu-arm64.qc2` | spike/helloworld | noble / minbase / arm64 | – | – | first UEFI build; miniccc into `:2` |
| `minirouter-arm64.qc2` | router | noble / minbase / arm64 | `sceptre-phenix-images/overlays/minirouter` | `sceptre-phenix-images/scripts/minirouter.sh` | + `minirouter`,`miniccc` arm64 binaries |
| `bennu-arm64.qc2` | rtu-1, rtu-2 (+ provider in 4B) | jammy / minbase / arm64 | `overlays/bennu`, `overlays/brash` (upstream), `images/overlays/bennu-arm64` (local debs/wheels) | `images/scripts/bennu-arm64.sh` | matches `ubuntu:22.04` build container |
| `bennu.qc2` (prebuilt amd64) | provider in 4A | jammy / amd64 (GHCR) | – | – | `oras pull`; runs under x86 TCG |
| `opc-arm64.qc2` | opc | noble / minbase / arm64 | – | `opc.sh` | asyncua + pymodbus gateway |
| `scada-arm64.qc2` | scada-server | noble / minbase / arm64, 10G | – | `fuxa.sh` | FUXA, Node 22 |
| `historian-arm64.qc2` | historian | noble / minbase / arm64 | – | `historian.sh` | InfluxDB 2 + Telegraf |
| `hmi-arm64.qc2` | hmi | noble / mingui / arm64 | – | `hmi.sh` | Firefox kiosk |
| `engineer-arm64.qc2` | engineer-workstation | noble / mingui / arm64 | – | `engineer.sh` | terminals to brash |

Lazy alternative (not recommended, breaks "one recipe per role"): one `desktop-arm64` image for hmi
and engineer with the role picked by the injected startup file.

---

## 5. Risks

| # | Risk | Likelihood | Fallback |
| --- | --- | --- | --- |
| 1 | QEMU+KVM hangs inside Apple nested virt (one M5 field report, cause unknown) | medium | GIC version knobs; TCG (§3-F); remote x86 host |
| 2 | More x86 assumptions in minimega than the four found (§1.1) | medium | `qemu-override` lines recorded in Phase 1c; last resort a one-line minimega patch in a git worktree + local container build (we build it anyway) |
| 3 | vmdb2 UEFI/arm64 quirks in the glattercj fork (`grub-install --no-nvram` in chroot, ESP mount keys) | medium | hand-written `.vmdb`; or convert the Ubuntu cloud image + `virt-customize` to add miniccc/phenix services |
| 4 | bennu/HELICS/pybennu compile or dependency failures on arm64 (opendssdirect/labjack have no aarch64 wheels) | low-medium | `--no-deps` minimal pybennu set; disable the HELICS provider target; field devices only need the C++ tree |
| 5 | x86 TCG provider (4A) too slow for real-time stepping | medium | 4B GenericPython; or more vCPUs to the one TCG guest |
| 6 | FUXA project import automation (API shape) | medium | pre-seed `_appdata` at image build; inject the sqlite db |
| 7 | virtiofs semantics for qcow2 backing files (locking, perf) | avoided | images on the Lima data disk; only topologies on virtiofs |
| 8 | `openvswitch.ko` absent from the Lima kernel | low | `linux-modules-extra-$(uname -r)` in provisioning |
| 9 | Ubuntu snaps (firefox/chromium) unusable in chroot builds | certain, handled | Mozilla apt repo; or Debian bookworm `firefox-esr` with `linux-image-arm64` |
| 10 | Reaching guest IPs from the Mac | low | minimega tap on MGMT + `ssh -L`; phenix UI VNC and `cc exec` always work |
| 11 | Disk/RAM | low | 3.2 TiB free; 128 GiB host; VM 48 GiB |

---

## 6. Decisions for Ryan (recommendation first)

1. **Guest architecture.** arm64-native guests under nested KVM (recommended; gated by Phase 1) vs
   all-x86 TCG in the same VM vs a remote x86 Linux host. Everything but the §1.2 block is shared.
2. **Physics provider** (the Simulink binaries are x86-only and FUXA does not replace them).
   **A** keep the original `bennu-simulink-provider` + `simulinksolver`/`simulinkgt` in one x86-64 TCG guest
   on the prebuilt amd64 `bennu.qc2` (recommended first: config only, exact original physics; cost = one slow VM) vs
   **B** `GenericPython` `waterway_sim.py` (native, editable, new ~150 lines of physics; recommended as the follow-up
   or if A is too slow) vs **C** `qemu-user-static` for the x86 solver inside the arm64 bennu guest
   (keeps shm/semaphore IPC with a native provider — `bennu-simulink-provider/main.cpp:28-36`; fiddly multiarch libs, not recommended).
3. **Engineer workstation.** Keep as a Linux xfce desktop with brash terminals (recommended, cheap on arm64) vs drop it.
4. **sceptre-app integration.** Static injections rendered by `scada/gen_configs.py` from the app's own
   `reg_addrs.json` (recommended now: zero coupling to upstream release cadence) → later upstream
   `os_type`-aware templates (Phase 7.1) once the configs are proven.
5. **OPC role.** Python `asyncua` server + `pymodbus` poller (recommended; ~150 lines, same language as the app and pybennu)
   vs Node-RED (`node-red-contrib-opcua` server node + `node-red-contrib-modbus`) vs FUXA (not possible: client-only).
6. **Historian.** Telegraf `inputs.opcua` → InfluxDB 2 on its own VM (recommended; mirrors the original OPC→historian flow)
   vs FUXA's DAQ (collapses historian into the SCADA VM).
7. **Storage layout.** `/phenix/images` on a Lima data disk, `/phenix/topologies` = virtiofs of `~/phenix/topologies`,
   `~/git` mounted at the same path (recommended) vs everything on virtiofs (simpler, risk 7).
8. **Linux VM tool.** Lima vz (recommended) vs `apple/container` or Tart (both also vz; less tooling for a persistent dev VM).
   Docker Desktop stays installed but is not used for this.
9. **FUXA deployment.** Native Node in the scada image (recommended) vs Docker-in-guest with `frangoteam/fuxa` (arm64 image exists; adds a daemon to the VM).
10. **Hostname.** Rename `simulink-provider` → `waterway-provider` (required for 2-B, harmless for 2-A).

Not a decision: the DNP3 variant project (`waterway-dnp3.mep`) is out of scope — the scenario is Modbus-only and FUXA has no DNP3.

---

## 7. Work tracking
This repo already has `.beads/`. Suggested shape when work starts (not created in this planning
pass): one epic "waterway range on Apple Silicon" with one child per phase and `blocks` edges
0→1→2→3→{4,5}→6; Phase 7 items as independent beads.

## 8. Decisions taken (2026-11-07)
1. arm64-native guests (gated by Phase 1).
2. Physics: new Rust `simulinksolver` drop-in over the bennu-simulink-provider shm/semaphore contract (Phase 4).
3. Engineer workstation: Linux xfce desktop with brash terminals.
4-10. Plan recommendations accepted as written.
