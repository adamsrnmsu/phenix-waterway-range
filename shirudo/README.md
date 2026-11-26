# shirudo on the waterway range

Exploration of [shirudo](https://github.com/shirudo-dev/shirudo) (pre-release BPF security platform) on the arm64
rig: a shirudo-protected field device (`rtu-s`, ferrofire RTU) attacked from Kali and watched by Suricata, parseus
and shirudo's own `kernel-obs`. Design: `docs/specs/2026-11-25-shirudo-range-design.md`. Plan:
`docs/plans/2026-11-25-shirudo-range.md`. Results: `docs/shirudo-evidence.md`.

> **Never stop `rtu-s` by killing it.** `phenix exp stop`, the phenix UI's stop, minimega `vm kill` and
> `limactl stop phenix` all kill QEMU while swtpm runs on, and swtpm then saves the TPM's state (`Shutdown(STATE)`), so
> the next boot is a TPM restart, not a reset. shirudo then cannot bind its TPM register: it reports `tampered` and
> refuses most commands (see Power loss in `docs/shirudo-evidence.md`; a real power loss does not do this). Stop the experiment with `shirudo/down.sh`, which powers `rtu-s` off first. To
> recover from a hard kill, boot it, run `systemctl poweroff --check-inhibitors=no` on it (host-only SSH, below), then
> `shirudo/up.sh` again.

## Workflow (all from the Mac, in this repo)

```bash
# 1. once: build shirudo at the pin in its own Lima VM, prove its reference boot
cd ~/git/shirudo && git checkout --detach "$(cat ~/git/phenix-waterway-range/shirudo/PIN)"
limactl start --name=shirudo-dev --param checkout="$PWD" infra/lima/shirudo.yaml   # then: limactl start shirudo-dev
shirudo/fetch-build.sh                 # pin check, CI arm64 test kernel, build, shirudo's test VM "ref"
shirudo/pass-check.sh ref              # status ok, signed upatch load + unload, TPM evidence verifies
# 2. build the target: shirudo's test target "rtu-s" + ferrofire RTU, staged into the phenix VM
images/ferrofire-shirudo.sh                # also links /phenix/images/ferrofire-shirudo-arm64.qc2 to the staged disk
# 3. run the range
shirudo/up.sh                          # refuses if another experiment is started; rtu-s status must be ok
shirudo/parseus.sh up                  # parseus Zeek DPI on purple's capture tap (phenix VM, 127.0.0.1:9207)
shirudo/attack.sh r3 && shirudo/collect.sh r3 && shirudo/tests/run-evidence.sh r3
shirudo/parseus.sh down
shirudo/down.sh                        # powers rtu-s off cleanly, then stops the experiment
```

`rtu-s` management is a host-only QEMU user-net NIC (`restrict=on`, no egress) with root SSH on the phenix VM's
`127.0.0.1:22110`, key `/phenix/shirudo/<pin>/vms/rtu-s/ssh/id_ed25519`. Its addresses (10.1.1.101 OT, 172.16.1.101
provider) and `/etc/sceptre/config.xml` are baked into the image; changing them means rerunning `images/ferrofire-shirudo.sh`.

## Pieces

| file | what |
|---|---|
| `PIN` | shirudo commit; `~/git/shirudo` must be checked out there with no uncommitted changes |
| `fetch-build.sh` | pin and clean-tree check, then the build and reference boot in `shirudo-dev` |
| `reference/` | shirudo's own boot of the target: QEMU argv, kernel cmdline, swtpm/tpm-builder calls, `pass.txt` |
| `stage.sh [--rebuild-tpm] <vm>` | copies a `shirudo-dev` target into `/phenix/shirudo/<pin>/` (kernel, bundle, disk, vTPM); keeps a staged vTPM unless `--rebuild-tpm`, refuses a vTPM made for another bundle |
| `swtpm.sh start\|stop\|status <vm>` | the target's swtpm on the phenix VM host (systemd unit `shirudo-swtpm-<vm>`) |
| `spike/power-loss.sh` | power-loss characterisation (bead ww-hubl): `spike/power-loss.txt` (E1-E3), `isolate` mode `spike/power-loss-isolate.txt` (E4-E5); `power-loss-e6.txt`, `power-loss-e7.txt` (TPM counts; E7 kills swtpm first) |
| `upstream/` | drafts for shirudo upstream (not posted) |
| `spike/` | the Task 2 gate: `rtu-s.mm` + `launch.sh` boot a target under plain minimega (namespace `shirudo-spike`); `pass.txt`, including the power-loss finding |
| `pass-check.sh [--mm <port>] <vm>` | the pass condition, on shirudo's own VM or a minimega-booted one |
| `up.sh`, `down.sh` | the `shirudo-arm64` experiment (`topologies/shirudo-arm64`) |
| `parseus.sh up\|down\|counts` | parseus DPI pipeline beside the range |
| `attack.sh <run> [phase...]`, `collect.sh [--aggregate-only] <run>` | one recorded attack run into `docs/shirudo/raw/<run>/`; `NO_POLL=1` runs without the master poll (DNP3 commands only reach the outstation when no master holds its session) |
| `cc.sh <vm> <script> [file...]` | run a script on a range VM through minimega cc |
| `tools/` | `ot_poll.py` (master), `ot_attack.py` (phases), `tamper.sh` (root on rtu-s), `shirudo.rules` (Suricata) |
| `upatches/modbus-guard/` | the OT upatch (XDP), with its before/after |
| `tests/` | one check per behaviour; `run-evidence.sh <run>` validates a run |

## Where things live

- `shirudo-dev`: `~/git/shirudo/build/test-vm` is a symlink to the VM's own disk; the bundle, each test target's
  state (`vms/<name>/`) and the signing key (`/tmp/shirudo-test-vm-private-<uid>/`) exist only there. Its first start
  on this Mac needed shirudo's GICv3 traps (`sudo sh infra/lima/enable-gicv3-traps.sh` inside it, then restart).
- phenix VM: `/phenix/shirudo/<pin>/` (staged targets, vTPMs, MANIFEST), `/var/lib/shirudo-range/` (pcaps, Zeek logs),
  `swtpm` + a local AppArmor rule (`/etc/apparmor.d/local/usr.bin.swtpm`, lines marked `shirudo-range`).
- During an attack run `attack.sh` stops `rtu-s`'s `shirudo-map-export.timer` (it drains the kernel-obs tables every
  ~10 s); `collect.sh` starts it again.
