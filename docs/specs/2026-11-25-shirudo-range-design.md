# shirudo on the waterway range: design

Date: 2026-11-25. Status: draft for approval.

## Intent

[shirudo](https://github.com/shirudo-dev/shirudo) (Cisco/Isovalent + OpenAI, pre-release, announced 2026-11-23) is a
BPF-based Linux security platform: after boot only signed BPF loaders run, operators ship signed micropatches
("upatches") that observe or block kernel and application paths, and a TPM measures what is loaded. Its README pitches
"embedded and edge devices with long update cycles", which is the OT field-device story, but every published example is
IT (Java4Shell on Elasticsearch, Kubernetes, containers).

The user wants to **see how it works**, not ship it:

1. Watch shirudo run on a range VM end to end: boot under enforcement, load and unload a upatch, attest.
2. Point the range's existing tools at it: Kali attacks it, and parseus (Zeek DPI) and the rest of the Kali Purple
   image watch the network while shirudo's own telemetry watches the host.
3. Judge whether shirudo's designers considered OT/ICS networks: what it sees and blocks on a simulated field device,
   and which of its assumptions break on real OT gear.

## Goals

- One shirudo-protected arm64 VM on the Lima `phenix` rig, running a simulated field device (Modbus and DNP3 server),
  booted by phenix/minimega with shirudo's kernel, initrd and a software TPM.
- Kali (offense) and Kali Purple + parseus on the same experiment, with the field device's traffic mirrored to the
  purple capture NIC.
- At least one upatch loaded on the field device VM (`kernel-obs` for host telemetry), and one attempt at an OT-specific
  upatch (for example refusing a malformed or out-of-range Modbus request at a socket/LSM hook).
- A short evidence write-up in `docs/` in the style of `docs/dnp3-parseus-evidence.md`: what shirudo saw and blocked
  during Kali attacks, what parseus saw at the same time, and an OT-fit assessment.

## Non-goals

- A reusable phenix app in sceptre-phenix-apps (that is approach B; revisit only if the findings justify it).
- Production hardening: signed UKI boot, real TPM, key management, PCR 11 measurement.
- amd64 or multi-host mesh support.
- Changing parseus, bennu or ferrofire.

## Anti-goals

- Weeks of kernel work before anything boots. If shirudo's prebuilt arm64 test kernel cannot boot under minimega, stop
  and report rather than building a kernel from source.
- Touching other experiments or images on the rig: no reuse of existing image names, no edits to waterway topologies.
- A write-up that claims shirudo "protects OT" from one demo: findings must state what was and was not tested.

## Constraints (from recon, 2026-11-25)

- shirudo targets need a bpf-next kernel with the signed-loader ABI and shirudo's kernel patches (stock Ubuntu kernels
  fail), the BPF LSM, and a TPM 2.0. arm64 is a supported target and its test VM boots on arm64 hosts. shirudo binaries
  need `ulimit -l unlimited`. Source: `Documentation/operate/plan/system-requirements.rst` and
  `Documentation/start/quickstart.rst` in shirudo-dev/shirudo.
- shirudo's test VM (`make -C testing vm`) boots QEMU with direct kernel + initrd and a `swtpm` socket, builds an
  Ubuntu disk, a dm-verity runtime image, signed config images and a throwaway signing key. Its first run downloads an
  Ubuntu cloud image (needs internet; fine on the Lima host, not inside the range).
- Lima `phenix` VM: KVM present, QEMU 10.2.1, kernel 7.0.0-44-generic. `swtpm` is **not** installed. Locked-memory
  limit is 8192 KiB. minimega runs in container `minimega` (image `minimega:arm64-kvm`), phenix in container `phenix`.
- minimega supports `vm config tpm-socket <path>` (`cmd/minimega/kvm.go:1467`, emits `-chardev socket ... -tpmdev
  emulator -device tpm-tis`) but does not start `swtpm`. It supports `vm config kernel/initrd/append`. On aarch64 the
  `tpm-tis` device name may need `tpm-tis-device` (sysbus) instead; check in the spike.
- phenix renders each node's `advanced` map as `vm config <key> <value>` (`tmpl/templates/minimega_script.tmpl:63`), so
  a topology can set kernel, initrd, append and tpm-socket per node with no phenix changes.
- Range assets in this repo: arm64 images `bennu-ferrofire-arm64.qc2`, `ferrofire-rtu-arm64.qc2`,
  `kali-offense-arm64.qc2`, `kali-purple-parseus-arm64.qc2`; `scripts/mirror.sh` (OVS mirror to a VM capture NIC or an
  internal port); topologies `ferrofire-rtu-test`, `kali-offense-test`, `blue-test`, `waterway-arm64`.
- Memory on the rig: the `phenix` Lima VM has 48 GiB; Kali Purple wants 24 GiB in `blue-test`. Run this experiment
  alone (see the burger memory note in beads).

## Approaches

| | Approach | Trade-off |
|---|---|---|
| **A (picked)** | Setup script on the rig + a phenix topology in this repo. shirudo's own test tooling builds kernel/initrd/bundle; the topology boots the VM via `advanced` settings next to Kali and Kali Purple. | Fastest to "see it work"; reuses phenix networking, mirror and parseus as-is. Not packaged for reuse. |
| B | Full `shirudo` phenix app (sceptre-phenix-apps), stage hooks, tests, upstream PR. | Reusable, but 2 to 4 more days on pre-release software before seeing anything. |
| C | Run shirudo's own test VM outside phenix and bridge it onto the phenix OVS bridge. | Least shirudo work, but phenix does not manage it, the bridging is hand-made and fragile, and the test VM assumes internet. |

The user picked **A**. It becomes B later if the findings are worth packaging.

## Design (approach A)

### Layout (all new files)

```
shirudo/
  README.md          how to run it, what each step proves
  fetch-build.sh     in a separate Lima VM `shirudo-dev` (shirudo's own infra/lima/shirudo.yaml: Ubuntu 26.04
                     arm64 with LLVM 23, which the phenix VM lacks): pinned build, test kernel, bundle, vTPM,
                     reference boot
  stage.sh           copy those outputs into /phenix/shirudo/<pin>/ on the phenix VM
  swtpm.sh           start|stop|status one swtpm per protected VM on the phenix VM host; socket under /phenix,
                     which is bind-mounted into the minimega container
  upatches/          our OT experiment upatch(es), built and signed with the bundle's throwaway key
topologies/shirudo-arm64/shirudo-arm64.yaml
docs/shirudo-evidence.md   the write-up (last)
```

### Experiment `shirudo-arm64` (4 VMs, own VLANs, no gateway, isolated like the arm64 test topologies)

| VM | Image | Role |
|---|---|---|
| `provider` | as in `waterway-arm64` (ferrofire simulink provider) | live tag values so Modbus/DNP3 registers change |
| `rtu-s` | shirudo kernel + initrd, root disk below | the protected field device: bennu field device (ferrofire), Modbus 502 + DNP3 20000 |
| `kali` | `kali-offense-arm64.qc2` | attacker and Modbus/DNP3 master (polling + attacks) |
| `purple` | `kali-purple-parseus-arm64.qc2` | parseus + Zeek DPI, Suricata, tcpdump/Wireshark on a capture NIC fed by `scripts/mirror.sh` |

`rtu-s` advanced settings: `kernel`, `initrd`, `append` (shirudo's test-VM command line plus root and console),
`tpm-socket`, extra disks for the dm-verity runtime image and the signed config image, `machine: virt`.

Sizing (Claude's call): `purple` 8 vCPU / 24 GiB (as `blue-test`), `kali` 4 / 4 GiB, `rtu-s` 4 / 4 GiB (shirudo's
test-VM default), `provider` 2 / 2 GiB: 34 GiB of the Lima VM's 48. No other experiment runs at the same time.

### Management path (Claude's call)

shirudo's test VM is driven over SSH through QEMU user-net forwarding and provisioned by `guest.sh` over that SSH with
a 9p share of the checkout; phenix cannot inject miniccc, IPs or keys into a non-phenix root. So `rtu-s` gets a second
NIC on a management VLAN `SHMGMT` that is reachable only from the Lima host, through an OVS internal port on the
`phenix` bridge (the same mechanism `scripts/mirror.sh port:<name>` uses). Operator commands (`shirudo load`,
`unload`, `attest`, `status`) run on the Lima host and reach the target over SSH on that port. "Isolated, no gateway"
means no route to other experiments or the internet; a host-only management link is allowed. The OT VLAN that Kali,
purple's mirror and the provider share has no host access.

### Field device choice (Claude's call)

The user agreed to "a simulated field device". This design uses the range's **bennu/ferrofire** field device rather than
ot-sim: arm64 builds and configs already exist here, parseus/Zeek already parse its Modbus and DNP3
(`docs/dnp3-parseus-evidence.md`), and bennu's network parsers are the code an attacker reaches first (sceptre-bennu
#81). ot-sim would need a new arm64 install with no prior evidence.

### Root disk for `rtu-s` (decided by the spike, in this order)

1. **Baseline:** shirudo's test-VM Ubuntu disk, provisioned by shirudo's own `guest.sh`, with the bennu field device
   installed (arm64 debs from everything-burger-with-extra-sauce), saved under a new image name
   `bennu-shirudo-arm64.qc2`. shirudo's initrd, BTF, modules and guest setup all assume this disk.
2. **Optional shortcut, time-boxed to half a day:** existing `bennu-ferrofire-arm64.qc2` booted with shirudo's kernel
   and initrd. Drop it at the time box; it is not needed for any goal.

### Steps, each with a stop condition

1. **Spike (gate).** On the rig, in two halves:
   - 1a. Run shirudo's own `make -C testing vm` on the Lima VM (outside minimega) and save its exact QEMU command line,
     kernel command line and swtpm/`tpm-builder.sh` invocation as the reference. This proves the pinned arm64 kernel
     and bundle work on this host at all.
   - 1b. Reproduce that boot under minimega with hand-written `vm config` (kernel, initrd, append, disks,
     tpm-socket, machine/CPU options mapped from the reference), using the same bundle and a TPM provisioned the same
     way.
   - **Pass:** under minimega, `shirudo status` reports enforcement active with the TPM register bound; the stock
     `kernel-obs` upatch loads and unloads; `shirudo attest` evidence verifies on the host.
   - **Stop and report** if 1a fails, or if 1b cannot reach the pass condition after the minimega arguments match the
     reference.
2. **Field device on shirudo.** Pick the root disk (above); bennu serves Modbus and DNP3 with live values from the
   provider.
3. **Topology.** `shirudo-arm64` boots all four VMs through phenix; mirror to purple; parseus shows `rtu-s` registers
   and DNP3 points.
4. **Watch and attack.** From Kali: scans, Modbus/DNP3 writes, malformed and oversized requests (the #81 cases),
   fuzzing, attempts to tamper with shirudo as root on `rtu-s`. Capture `kernel-obs` telemetry (OTel export to a
   collector on the Lima host, or shirudo's local log if simpler), parseus/Zeek and Suricata views side by side.
5. **OT upatch.** Write one upatch targeting the field device (for example drop a Modbus request with an out-of-range
   function code at the socket layer), sign it, load it, rerun the attack, record before and after. If payload-level
   filtering is not feasible from the hooks shirudo allows, that is itself a finding: record why, then fall back to a
   connection-level OT policy (for example refuse Modbus/DNP3 connections to `rtu-s` from any peer but the master) so
   there is still one before/after result.
6. **Write-up.** `docs/shirudo-evidence.md`: what each view saw, what shirudo blocked, cost, and an OT-fit list
   (custom kernel and TPM requirement vs real PLC/RTU hardware, pull-from-registry vs air-gapped OT, Linux-only, upatch
   authoring effort).

## Decided

- Approach A, in `phenix-waterway-range` (user's own range repo), arm64 on the Lima `phenix` rig only.
- Purpose: exploration and an OT-fit judgment, with parseus and the Kali Purple tools watching.
- Simulated field device as the protected workload.

## Claude's calls (correctable)

- bennu/ferrofire field device instead of ot-sim (reason above).
- Pin shirudo to the commit current at spike time and use its CI arm64 test kernel; never build a kernel from source in
  this effort.
- New image names only (`bennu-shirudo-arm64.qc2`); new experiment name `shirudo-arm64`.
- Telemetry: start with shirudo's local output; add an OTel collector on the Lima host only if local output is not
  enough to compare against parseus.
- Nothing is committed or pushed without the user's go-ahead.
- Reuse shirudo's own scripts (`kernel-artifact.sh`, bundle builders, `tpm-builder.sh`, `guest.sh`) at the pinned
  commit, called from our wrappers. Where they insist on launching their own QEMU, carry small patches in
  `shirudo/patches/` against the pinned commit rather than reimplementing them.
- The vTPM is provisioned with shirudo's `tpm-builder.sh` against the bundle, not a bare `swtpm`. TPM state lives
  under `/phenix/shirudo/<pin>/tpm/rtu-s/`, persists across experiment stop/start, and is rebuilt only when the bundle
  is rebuilt.

## Left to the builder

- Where `swtpm` runs (installed in the minimega container, or on the Lima host with the socket under a path bind-mounted
  into the container) and the exact socket path.
- Exact kernel command line, extra-disk wiring and whether `tpm-tis-device` is needed on aarch64.
- How to raise the locked-memory limit for shirudo's operator-side binaries (shell `ulimit`, `limits.conf`, or running
  them inside a container).
- Attack tool selection on Kali and the specific OT upatch.
