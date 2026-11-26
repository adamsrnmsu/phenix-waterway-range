# shirudo on an OT field device: evidence

Captured 2026-11-25 on the arm64 rig (Lima `phenix`), experiment `shirudo-arm64`. shirudo pinned at `8c35953fa779`
(pre-release, CI arm64 test kernel `7.4-shirudo-ci-20261123`), ferrofire RTU 2026.11.15 as the field device, parseus
`1f39fb8` (PR #4, Zeek DPI), Suricata 8.0.8. Design: `docs/specs/2026-11-25-shirudo-range-design.md`. How to rerun:
`shirudo/README.md`. Raw data: `docs/shirudo/raw/`. Every number below comes from a file there. `r1` and `r2-*` are
the first pass; a review found collection faults in them (`raw/r1/notes.md`, addendum). The tables use `r3` and `r4-*`.

## How

- **Target.** `rtu-s` is shirudo's own test target with ferrofire's RTU added. Its Ubuntu disk, initrd and vTPM come
  from shirudo's `testing/vm` tooling, built in a separate Lima VM (`shirudo-dev`). phenix/minimega boots it with
  shirudo's kernel (direct kernel/initrd) and a `swtpm` on the phenix VM host. shirudo enforces from the initrd: BPF
  LSM attached, keyrings sealed, a TPM register bound and measured.
- **Range.** One OT VLAN holds:
  - a provider (live tag values);
  - Kali, as the master at 10.1.1.50 polling Modbus FC4 and DNP3 class 0 at 1 Hz, and as the attacker at 10.1.1.66;
  - Kali Purple.
- **Watching.** OVS mirrors the VLAN to purple's capture NIC, and Suricata runs there. parseus's Zeek DPI and
  ingestor run beside it, in the phenix VM, on the same tap (the parseus in the purple image has no DPI).
  `kernel-obs` runs on `rtu-s` itself.
- **Management.** `rtu-s` is managed over a host-only QEMU user-net NIC with SSH; its egress is blocked.
- **Runs.** `shirudo/attack.sh` drives each phase from Kali through minimega's cc. After each phase it saves:
  - `rtu-s`'s shirudo status;
  - the `kernel-obs` tables, drained (shirudo's map-export timer is stopped for the run, so each file covers its
    phase);
  - the field-device state.

  `shirudo/collect.sh` adds the pcap, Suricata events and parseus counts per phase. `shirudo/tests/run-evidence.sh`
  checks each run: every view covers every phase, every tamper attempt failed with its refusal message, and every
  Suricata event falls in some phase.

## Results: r3, one attack run, every view (`raw/r3/summary.tsv`, files `raw/r3/<n>-<phase>-*`)

| phase | what Kali did | field device | pcap: attacker pkts | Suricata | parseus docs | kernel-obs accepts from attacker | shirudo |
|---|---|---|---|---|---|---|---|
| baseline | 30 s of master polling | answers | 0 | 0 | 612 | 0 | ok |
| recon | nmap SYN + version scan | 22, 502, 20000 open | 2110 | 9 (non-master connects, SSH SYNs) | 444 | 6 | ok |
| write | FC5 coil, FC6, FC16 | **FC6 write to 40000 accepted**; FC5/FC16 exception 2 | 30 | 6 (3 write function codes, 3 non-master connects) | 196 | 3 | ok |
| malformed | sceptre-bennu #81 cases + FC 0x00/0x2B/0x5A/0x7F | waits or closes; **unassigned FCs get an empty PDU**, not exception 1 | 72 | 11 | 227 | 8 | ok |
| dnp3 | DIRECT_OPERATE, COLD/WARM_RESTART | **connection reset** (master holds the session) | 18 | 6 (operate, cold, warm restart, 3 connects) | 190 | 3 | ok |
| fuzz | 300 random Modbus PDUs, 300 random DNP3 frames | Modbus 288 resp, 12 exc; DNP3 238 resets, 62 closed; process unchanged | 4842 | 744 (600 non-master connects, 4 function-code rules, 140 Modbus/DNP3 protocol events) | 471 | 600 | ok |
| ssh | hydra, 20 root passwords (from 10.1.1.50) | refused at once: password auth disabled | 22 SSH pkts | 1 | 153 | 1 (from 10.1.1.50) | ok |
| tamper | root on `rtu-s`, 7 attacks on shirudo itself | unaffected | (management path, not mirrored) | 0 | 272 | 0 | **7/7 refused**, status ok |

**The tamper phase** (`raw/r3/8-tamper.txt`). Root without shirudo's runtime authority failed at all seven:

| attack | result |
|---|---|
| read a pin | Permission denied |
| unpin kernel-obs | Operation not permitted |
| unmount bpffs | "must be superuser", while root |
| unsigned `bpf(BPF_PROG_LOAD)` | errno 13 |
| load a forged upatch (one byte flipped) | "payload_sha256 does not match signed content; refusing" |
| write the sealed upatch archive | Permission denied |
| replace the runtime binary | read-only verity mount |

Listing the pins was allowed. shirudo's tamper counters rose by 49, from 337 to 386: PinUnlink +45, and +1 each for
LoadNotLoader, BpffsUmount, ObjGet and SealEntry. The register stayed bound and the eventlog replayed.

**kernel-obs** attributed the OT traffic: its `net` table counted the attacker's accepted connections in every attack
phase (600 in fuzz). Its `priv` table records `bpf()` calls, including a `BPF_PROG_LOAD` in the tamper window. shirudo's
own commands make the same calls (6 in the baseline), and the `priv` records carry the guest's wall clock, which ran
about 70 days behind. So this run cannot separate the tamper attempt from shirudo's own use by time alone.

## modbus-guard: one OT upatch, before and after (`shirudo/upatches/modbus-guard/`, `raw/r4-*`)

An XDP upatch: one program, signed with the bundle's key. On every virtio NIC it drops Modbus/TCP segments to port 502
unless they hold one well-formed request with function code 1-6, 15 or 16 and a payload of 8 to 260 bytes. It also
drops IPv4 TCP fragments. shirudo allows XDP upatches, and XDP sees the payload, so the plan's connection-level
fallback was not needed.

| case | before (`r4-before`) | loaded (`r4-after`) | unloaded (`r4-unloaded`) |
|---|---|---|---|
| FC 0x00 / 0x2B / 0x5A / 0x7F | empty-PDU reply | dropped | empty-PDU reply |
| MBAP length 0 | closed by server | dropped | closed by server |
| oversized PDU (302-byte FC16) | closed by server | dropped | closed by server |
| truncated MBAP, length > payload | server waits | server waits (dropped) | server waits |
| 300 random Modbus PDUs | 288 resp, 12 exc | 0 resp, 293 timeouts, 7 exc | 288 resp, 12 exc |
| FC6 write from the attacker | accepted | **accepted** (a valid request) | accepted |
| master FC4 polling, 1 Hz | 0 errors | 0 errors | 0 errors |

When loaded, shirudo reported `XdpCovered OK`, with the program on all three NICs (`mgmt`, `ot`, `prov`;
`raw/r4-load.txt`). The load and the unload were each measured into the register, and the unload detached it
everywhere. Suricata still saw every attack (the mirror copies frames before they reach the guest), minus the
server's replies. The fragment rule was checked by reading the code only: the stdlib attack tool cannot send
fragments inside an established TCP session.

## Cost (`raw/cost.txt`, 60 s vmstat per state, master polling at 1 Hz)

| upatches loaded | CPU us / sy / idle | memory used |
|---|---|---|
| kernel-obs | 0.95 / 6.13 / 86.32 % | 213 MiB |
| kernel-obs + modbus-guard (first build) | 0.92 / 5.75 / 86.65 % | 193 MiB |
| none | 0.87 / 7.17 / 85.27 % | 185 MiB |

At this load the difference is within the noise of one sample per state. ferrofire's RSS was 2800 KiB in all three.

## Power loss (`shirudo/spike/power-loss*.txt`, bead ww-hubl): a test-rig artifact, not a shirudo bug

Killing QEMU (minimega `vm kill`, `phenix exp stop`, shirudo's own `vm-stop`) left the next boot `tampered`:
`init: loading authenticated boot settings failed: Structure needs cleaning` (EUCLEAN), ConfigActive ALERT, and
shirudo.service failed. It stayed so across further kills and cleared only after a clean poweroff and a boot.

The cause is swtpm, not shirudo. When its client (QEMU) disconnects, swtpm sends the TPM a `TPM2_Shutdown(SU_STATE)`
of its own unless the last command was a Shutdown (`tpmlib_maybe_send_tpm2_shutdown` in swtpm's `tpmlib.c`; the
swtpm log shows `Data client disconnected` and then a Shutdown). The guest's next `TPM2_Startup(CLEAR)` is then a
TPM *restart* (libtpms `TPM2_Startup`: a restart exactly when the saved state is `SU_STATE`), so the reset count
stays and only the restart count moves. shirudo documents that case (`Documentation/concepts/background/tpm.rst`,
Table 2): the TPM boot goes on with the config PCR cleared, so commands refuse with EUCLEAN and `init` does not bind
the register again until a real reset. A clean guest poweroff ends with the kernel's `Shutdown(CLEAR)`, so swtpm sends
nothing and the next startup is a reset.

| test | how the power was cut | next boot | TPM reset / restart count |
|---|---|---|---|
| E2, E4, E5, E6 | QEMU killed, swtpm alive (E4: `sync` first; E5: swtpm kept running; E6: same as E2) | `tampered` 5/5 | reset unchanged, restart +1 (E6) |
| E7 | swtpm SIGKILLed first, then QEMU (as a real TPM losing power: no Shutdown at all) | `ok` | reset 6 -> 7, restart 0 |
| E7 control | QEMU killed, swtpm alive | `tampered` | reset 7, restart 1 |

A real TPM that loses power gets no Shutdown, so its next startup is a reset and shirudo comes up `ok`. The one
real-hardware path to the same state is a power loss while suspended to RAM (the kernel sends `Shutdown(STATE)`
before a suspend), which a field device rarely does. The range scripts still power `rtu-s` off cleanly, because a
phenix or minimega stop kills QEMU with swtpm alive.

## Method notes and limits

- One target, one field-device implementation (ferrofire, not bennu's C++ servers), one run per condition. The
  provider kept the lock at rest, so register values were steady.
- DNP3 commands only reach the outstation when no master holds its session: in r3 every attacker connection was
  reset while the master polled. With the master poll off (`raw/r5`, `raw/r7`, `NO_POLL=1`):
  - **DIRECT_OPERATE of analog output 3 (g41v2, value 0) from 10.1.1.66 succeeded** (status 0, SUCCESS; `raw/r7`): an
    unauthenticated DNP3 control, the DNP3 twin of the Modbus FC6 write;
  - DIRECT_OPERATE of binary output 0 got status 12 (OUT_OF_RANGE: the RTU has no such point);
  - COLD_RESTART and WARM_RESTART were answered with IIN2 "function code not supported";
  - 300 random DNP3 frames: 8 responses, 289 timeouts, 3 resets (`raw/r5`); the field device kept running and shirudo
    stayed ok.
- The vTPM is software and boot is direct kernel/initrd, not a signed UKI, so PCR 11 measures nothing. The boot chain
  itself is not attested, only what shirudo's init loads and measures.
- `rtu-s`'s wall clock was wrong (no time source on an isolated range), so time-based attribution of its own logs
  is unreliable. The `net` table, the pcap and the Mac-side phase windows agree to within about 1 s.

## OT fit

**What held up.**
- Against an attacker who already has root on the field device, shirudo's own guarantees held. Its pins, mounts,
  archive, runtime image and BPF loader path refused root (7/7), it counted every attempt, and its TPM-backed
  evidence would show a verifier what was loaded.
- `kernel-obs` gave a host-side view of the OT traffic per peer, matching what the network saw.
- A upatch gave a protocol-aware shield in an afternoon: about 90 lines of BPF C, loaded and unloaded without a
  reboot, measured each time. The field device kept serving the master throughout.
- That is the README's "long update cycles" pitch working: a mitigation for a parser bug (here, ferrofire's
  empty-PDU reply) without touching the firmware.

**What it did not do.**
- shirudo does not protect the workload's protocol by itself. Without the upatch, every unauthenticated Modbus write
  (and, with no master connected, a DNP3 analog-output operate),
  scan, malformed request and fuzz frame reached the field device.
- The upatch we wrote stops shapes, not intent: a valid FC6 write from any peer still passes.
- The network views (Suricata, parseus) and the host view (`kernel-obs`) all saw the attacks. None of them stopped
  anything.

**Where it assumes IT.**
- **Hardware.** It needs a bpf-next kernel with shirudo's patches, the BPF LSM and a TPM 2.0. A PLC, RTU or relay
  runs a vendor RTOS or an old vendor Linux, has no TPM and ships its kernel as firmware. Today shirudo fits
  Linux-based gateways, HMIs, historians and industrial PCs with a modern kernel, not field devices.
- **Power loss.** An unclean power cut is routine at a substation or pump station. On the range a QEMU kill left
  the device `tampered` until a clean shutdown, but that came from swtpm saving TPM state when QEMU disconnects (see
  Power loss above). With the TPM losing power first, as real hardware does, shirudo came up `ok`. Left for OT: a
  power loss during suspend to RAM would still leave it `tampered`, so a field device should not suspend.
- **Delivery.** Upatches are pulled from an OCI registry and telemetry goes to an OpenTelemetry collector. An
  air-gapped OT network needs both inside the enclave. Here upatches were copied over a management link by hand, and
  the map-export timer had nowhere to send.
- **Authoring.** A useful OT shield needs someone who knows both BPF and the protocol. XDP sees one segment at a time,
  so anything that needs reassembly (pipelined Modbus, DNP3 fragments) is harder. Their agent-written-shield story
  would fit here, but each shield needs testing against the real master's traffic first, as modbus-guard had.

**Bottom line.** shirudo is a strong integrity layer for Linux OT hosts that can run its kernel, and a credible way
to ship protocol shields between firmware releases. It is not a field-device protection product yet, mainly because
of the kernel and TPM requirements.
