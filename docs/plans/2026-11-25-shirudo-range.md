# shirudo on the waterway range: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Boot a shirudo-protected arm64 field device (bennu/ferrofire) on the Lima `phenix` rig, attack it from Kali,
watch it with parseus and shirudo's own telemetry, and write up whether shirudo fits OT networks.

**Architecture:** shirudo's own tooling builds and proves the kernel, initrd, bundle and vTPM in a separate Lima VM
(`shirudo-dev`, their supported setup). The artifacts are staged into `/phenix/shirudo/<pin>/` on the `phenix` Lima VM,
where `swtpm` runs on the host and minimega boots the VM through a phenix topology's `advanced` settings. Nothing in
phenix, minimega, parseus or bennu changes.

**Tech Stack:** bash, shirudo `testing/vm` scripts at a pinned commit, swtpm, minimega/phenix (arm64 KVM), OVS,
bennu field device (arm64 debs), parseus Zeek DPI on `kali-purple-parseus-arm64.qc2`, BPF C for the upatch.

**Spec:** `docs/specs/2026-11-25-shirudo-range-design.md`

## Global Constraints

- arm64 only, on the Lima `phenix` rig; operator-side builds in a separate Lima VM `shirudo-dev` from shirudo's
  `infra/lima/shirudo.yaml` (Ubuntu 26.04 arm64, LLVM 23, `ulimit -l unlimited`).
- shirudo pinned to one commit recorded in `shirudo/PIN` (main was `8c35953fa779` on 2026-11-25; pin whatever is HEAD
  when Task 1 starts). Use its CI arm64 test kernel via `testing/vm/kernel-artifact.sh fetch`. Never build a kernel
  from source.
- New names only: experiment and topology `shirudo-arm64`, image `bennu-shirudo-arm64.qc2`, VLANs `SHOT` (OT) and
  `SHMGMT` (host-only management), artifacts under `/phenix/shirudo/<pin>/`. Never touch waterway, bennucamp or
  existing images.
- No other experiment started while `shirudo-arm64` runs. Sizing: purple 8 vCPU/24 GiB, kali 4/4, rtu-s 4/4,
  provider 2/2.
- vTPM provisioned by shirudo's `tpm-builder.sh`, state in `/phenix/shirudo/<pin>/tpm/rtu-s/`, persisted across
  experiment stop/start, rebuilt only with the bundle.
- Reuse shirudo scripts unmodified where possible; any change is a patch in `shirudo/patches/` against the pin.
- Stop and report (do not push on) if the spike's gate fails (Task 2).
- Git: this repo's conservative profile. Commit steps below run only after the user says to commit; until then leave
  changes in the working tree and report them.

## Review Focus

1. Experiment stop then start: rtu-s must boot and re-attest with the persisted TPM state, not fail or silently
   re-provision. Tested in Task 4.
2. Bundle rebuilt while old TPM state exists: `stage.sh` must refuse to stage a bundle whose `version_id` does not
   match the TPM state unless `--rebuild-tpm` is given. Tested in Task 2.
3. `swtpm` not running (or a stale socket) when phenix launches the VM: `swtpm.sh start` is idempotent and
   `swtpm.sh status` fails loudly; the topology start wrapper calls both. Tested in Task 2.
4. Installing an image or starting the experiment while another experiment is started: scripts refuse, like
   `images/ferrofire-rtu.sh` does. Tested in Tasks 3 and 4.
5. Checkout drift: `fetch-build.sh` refuses to build if the shirudo checkout HEAD differs from `shirudo/PIN`.
   Tested in Task 1.

---

### Task 1: Pinned shirudo build and reference boot in `shirudo-dev` (spike half 1)

**Files:**
- Create: `shirudo/PIN`, `shirudo/fetch-build.sh`, `shirudo/README.md`
- Create (outputs, committed as text): `shirudo/reference/qemu-cmdline.txt`, `shirudo/reference/kernel-cmdline.txt`,
  `shirudo/reference/tpm-builder.txt`, `shirudo/reference/pass.txt`

**Interfaces:**
- Produces: `fetch-build.sh [--check-only]`, run on the Mac; drives `limactl shell shirudo-dev`. Leaves the bundle
  (kernel `Image`, initrd, runtime image, config images, signing key, cert), the built `shirudo` and `shirudo-build`
  binaries and the provisioned TPM state in `~/shirudo-out/<pin>/` inside `shirudo-dev`, plus a manifest
  `~/shirudo-out/<pin>/MANIFEST` (one `relative-path sha256` line per file).

- [ ] **Step 1:** Clone shirudo to `~/git/shirudo`, check out the pin, write `shirudo/PIN` (full 40-char sha).
- [ ] **Step 2:** `limactl start --name=shirudo-dev --param checkout=$HOME/git/shirudo infra/lima/shirudo.yaml`
  (from the shirudo checkout). Expected: `limactl list` shows `shirudo-dev Running`.
- [ ] **Step 3:** Write `fetch-build.sh`: verify pin, then inside `shirudo-dev` run `testing/vm/kernel-artifact.sh
  fetch`, `make`, `make shirudo-build`, `make -C testing vm VM_NAME=ref`, then copy the bundle, binaries and TPM state
  to `~/shirudo-out/<pin>/` and write `MANIFEST`.
- [ ] **Step 4: Drift check.** Check out `HEAD~1` in `~/git/shirudo`, run `shirudo/fetch-build.sh --check-only`.
  Expected: exit 1, message names both shas. Check the pin back out; `--check-only` exits 0.
- [ ] **Step 5:** Run `shirudo/fetch-build.sh`. Expected: `[test-vm] VM ready: name=ref`.
- [ ] **Step 6:** Capture the reference: QEMU argv (`/proc/<qemu_pid>/cmdline`), kernel cmdline (`/proc/cmdline` in
  the guest via `make -C testing vm-ssh`), the `tpm-builder.sh` and `swtpm` invocations from `run.sh`'s log, into
  `shirudo/reference/*.txt`.
- [ ] **Step 7: Pass check in their VM.** In the guest: `shirudo status` shows enforcement active and the TPM
  register bound; load then unload `upatches/kernel-obs` per the quickstart; `shirudo attest` evidence verifies on
  the operator side. Paste the three outputs into `shirudo/reference/pass.txt`. If any fails: stop, report, file a
  bead, do not start Task 2.
- [ ] **Step 8:** `README.md`: what `shirudo-dev` is, how to rerun, where outputs live.
- [ ] **Step 9: Commit** (with go-ahead): `git add shirudo/ && git commit -m "feat(shirudo): pinned build and reference boot"`.

### Task 2: Stage into the rig and boot under minimega (spike half 2, GATE)

**Files:**
- Create: `shirudo/stage.sh`, `shirudo/swtpm.sh`, `shirudo/spike/rtu-s.mm`, `shirudo/spike/pass.txt`

**Interfaces:**
- Consumes: Task 1's `~/shirudo-out/<pin>/` and `MANIFEST`; `shirudo/reference/*.txt`.
- Produces:
  - `stage.sh [--rebuild-tpm]` (Mac): copies Task 1 outputs into `/phenix/shirudo/<pin>/` on the `phenix` VM,
    verifies `MANIFEST`, refuses on a bundle/TPM `version_id` mismatch unless `--rebuild-tpm`.
  - `swtpm.sh start|stop|status <vm>` (Mac): runs swtpm on the `phenix` VM host with state
    `/phenix/shirudo/<pin>/tpm/<vm>/` and socket `/phenix/shirudo/<pin>/tpm/<vm>/swtpm.sock` (the `/phenix` path is
    bind-mounted into the minimega container at the same path). `start` is idempotent; `status` exits non-zero
    unless the process is running and the socket accepts.
  - `spike/rtu-s.mm`: the hand-written minimega `vm config` script that Task 4 turns into topology `advanced` keys.

- [ ] **Step 1:** `apt-get install swtpm swtpm-tools` on the `phenix` VM (host, not container).
- [ ] **Step 2: Mismatch test.** Write `stage.sh`, then stage once, alter the staged TPM state's recorded
  `version_id`, and rerun `stage.sh`. Expected: exit 1, message names both ids. With `--rebuild-tpm`: exit 0.
- [ ] **Step 3: swtpm tests.** Write `swtpm.sh`. `status rtu-s` before start: exit 1. `start` twice: second is a
  no-op, one process. Kill swtpm, leave the socket file: `status` exits 1 and `start` replaces the stale socket.
- [ ] **Step 4:** Write `spike/rtu-s.mm` mapping each reference QEMU option to minimega: `vm config kernel`,
  `initrd`, `append` (reference kernel cmdline), `disk` (root + runtime + config images), `tpm-socket`, `machine virt`,
  `cpu host`, `vcpus 4`, `memory 4096`, a NIC on a scratch VLAN; anything with no `vm config` key goes in
  `qemu-append`/`qemu-override`. If minimega's `-device tpm-tis` fails on `virt`, override it to `tpm-tis-device`.
- [ ] **Step 5:** Launch it in a scratch minimega namespace `shirudo-spike` (`sudo docker exec minimega mm read
  ...`). Diff the resulting QEMU argv against `reference/qemu-cmdline.txt`; every remaining difference is listed in
  `spike/pass.txt` with a reason.
- [ ] **Step 6: GATE.** Over the console (`vnc`/serial) or a host-only tap: same three checks as Task 1 Step 7.
  Pass: record in `spike/pass.txt`. Fail after the argv matches the reference: stop, report to the user, file a bead,
  do not start Task 3. Either way `mm namespace shirudo-spike vm kill all` and `swtpm.sh stop rtu-s` after.
- [ ] **Step 7: Commit** (with go-ahead).

### Task 3: `bennu-shirudo-arm64.qc2`

**Files:**
- Create: `images/bennu-shirudo.sh`

**Interfaces:**
- Consumes: shirudo's test-VM Ubuntu disk from Task 1 outputs; bennu arm64 debs from
  `~/git/everything-burger-with-extra-sauce` (use its arm64 bennu build output; record the version in the script).
- Produces: `/phenix/images/bennu-shirudo-arm64.qc2` with `bennu-field-deviced` installed and enabled, plus the
  `ferrofire-rtu` start/config layout from `topologies/ferrofire-rtu-test/injects/` so the same `config.xml` works.

- [ ] **Step 1: Refusal test.** Write `images/bennu-shirudo.sh` with the started-experiment check copied from
  `images/ferrofire-rtu.sh`. Start any experiment using a dummy topology that names `bennu-shirudo-arm64.qc2`; run the
  script. Expected: `refusing: a started experiment uses ...`, exit 1. Stop it.
- [ ] **Step 2:** Build the image (copy shirudo's disk, install debs with `virt-customize` or in a booted
  `shirudo-dev` guest, inject miniccc per `images/ferrofire-rtu.sh`).
- [ ] **Step 3: Check.** Boot it with `spike/rtu-s.mm` (root disk swapped) plus `rtu-1-config.xml`. Expected: Task 2
  gate checks still pass, and `ss -ltn` in the guest shows `:502` and `:20000`.
- [ ] **Step 4 (optional, time box half a day):** try `bennu-ferrofire-arm64.qc2` as root with shirudo's kernel and
  initrd. Record the result in `shirudo/README.md` whatever it is; drop it at the time box.
- [ ] **Step 5: Commit** (with go-ahead).

### Task 4: Topology `shirudo-arm64` and management path

**Files:**
- Create: `topologies/shirudo-arm64/shirudo-arm64.yaml`, `topologies/shirudo-arm64/injects/` (rtu-s `config.xml`,
  start script), `shirudo/up.sh`, `shirudo/down.sh`

**Interfaces:**
- Consumes: Task 2 `swtpm.sh`, `spike/rtu-s.mm`; Task 3 image; `scripts/mirror.sh`.
- Produces: `up.sh` (Mac): refuse if any other experiment is started; `swtpm.sh start rtu-s` and `status`; create OVS
  internal port `shmgmt0` on bridge `phenix`, tagged with the `SHMGMT` VLAN id, address `172.31.0.1/24`;
  `phenix exp start shirudo-arm64`; `VLAN=SHOT scripts/mirror.sh shirudo-arm64 purple 1`. `down.sh` reverses it
  and keeps TPM state.
- Topology nodes (images and sizes per Global Constraints): `provider` (as in `waterway-arm64`), `rtu-s`
  (`advanced` from `spike/rtu-s.mm`; NICs `SHOT 10.1.1.101/24` and `SHMGMT 172.31.0.10/24`), `kali` (`SHOT
  10.1.1.50/24`), `purple` (mgmt NIC + capture NIC on its own VLAN, as `blue-test`). Provider reach for rtu-s follows
  `waterway-arm64`'s addressing.

- [ ] **Step 1: Refusal test.** Start `bennucamp`; run `shirudo/up.sh`. Expected: exit 1 naming `bennucamp`. Stop
  it.
- [ ] **Step 2:** Write the topology and scripts; `up.sh`.
- [ ] **Step 3: Check.** From the `phenix` VM: `ssh root@172.31.0.10 shirudo status` shows enforcement active.
  From kali: Modbus FC3 read of `10.1.1.101:502` returns changing values. On purple: parseus shows `modbus` and
  `dnp3` docs with `destination.ip: 10.1.1.101`. From kali, `172.31.0.10` is unreachable.
- [ ] **Step 4: Restart test.** `down.sh`, `up.sh`. Expected: rtu-s boots, `shirudo status` shows the TPM register
  bound, `shirudo attest` verifies, and the TPM state directory's mtime predates the restart (not re-provisioned).
- [ ] **Step 5: Commit** (with go-ahead).

### Task 5: Attack and observe

**Files:**
- Create: `shirudo/attack.sh`, `shirudo/collect.sh`; outputs under `docs/shirudo/raw/<run-id>/` (pcap, kernel-obs
  output, parseus counts, Suricata `eve.json` excerpt, attack log with timestamps)

**Interfaces:**
- Consumes: Task 4 running experiment.
- Produces: `attack.sh <run-id>` runs from kali in timed phases: `nmap -sS -sV` of rtu-s; Modbus FC5/FC6/FC16
  writes; malformed and oversized Modbus requests (the sceptre-bennu #81 cases: truncated MBAP, length field larger
  than payload, oversized PDU); DNP3 unsolicited/operate attempts; a short Modbus fuzz run; then, over `SHMGMT` as
  root, attempts to tamper with shirudo (unload its guards, `bpftool prog load` an unsigned program, write its pins).
  `collect.sh <run-id>` pulls kernel-obs output (local log; add an OTel collector on the `phenix` VM only if the local
  log lacks per-event timestamps), parseus document counts by `event.dataset`, Suricata alerts and a pcap.

- [ ] **Step 1:** With kernel-obs loaded, run `attack.sh r1` then `collect.sh r1`.
- [ ] **Step 2: Check.** Each attack phase in the log has a matching window in at least the pcap; root tamper
  attempts each show shirudo's refusal (exit code and message) in the log. Gaps are recorded, not fixed.
- [ ] **Step 3: Commit** (with go-ahead).

### Task 6: OT upatch

**Files:**
- Create: `shirudo/upatches/modbus-guard/` (Beefile, BPF C, Makefile, README modeled on
  `upatches/kernel-obs/` at the pin)

**Interfaces:**
- Consumes: Task 1 `shirudo-build` and signing key; Task 5 `attack.sh`, `collect.sh`.
- Produces: signed `modbus-guard` upatch. Target policy: refuse Modbus requests to `:502` whose function code is
  not in {1,2,3,4,5,6,15,16} or whose MBAP length disagrees with the payload. Fallback (only if payload inspection
  is not possible from the hooks shirudo permits, with the reason written in its README): refuse connections to
  `:502` and `:20000` from any peer except the master address `10.1.1.50`.

- [ ] **Step 1:** Run `attack.sh r2-before` with modbus-guard not loaded; `collect.sh`.
- [ ] **Step 2:** Build, sign and load modbus-guard. Expected: `shirudo status` lists it.
- [ ] **Step 3:** Run `attack.sh r2-after`; `collect.sh`. Check: the malformed/bad-FC phase (or, for the fallback,
  connections from a non-master peer) is refused, and valid FC3/FC4 polling from the master still returns values.
- [ ] **Step 4:** Unload; confirm valid and invalid requests behave as in r2-before.
- [ ] **Step 5: Commit** (with go-ahead).

### Task 7: Evidence write-up

**Files:**
- Create: `docs/shirudo-evidence.md`

- [ ] **Step 1:** Write it in the shape of `docs/dnp3-parseus-evidence.md`: How, Results table (per attack phase:
  pcap/parseus/Suricata/kernel-obs/shirudo verdict), the modbus-guard before/after, cost (CPU/memory of rtu-s with
  and without upatches), Method notes and limits (stating exactly what was and was not tested), and an OT-fit section
  covering: custom bpf-next kernel and TPM vs real PLC/RTU hardware, pull-from-OCI vs air-gapped OT, Linux-only,
  upatch authoring effort, and what the payload-inspection result says about protocol-aware protection.
- [ ] **Step 2: Check.** Every number in the doc traces to a file under `docs/shirudo/raw/`.
- [ ] **Step 3: Commit** (with go-ahead).
