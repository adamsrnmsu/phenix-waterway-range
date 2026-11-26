<!-- WITHDRAWN 2026-11-26, never posted: not a shirudo bug. swtpm sends TPM2_Shutdown(SU_STATE) when QEMU
     disconnects, so the next Startup(CLEAR) is a TPM restart (reset count unchanged), the case shirudo documents as
     EUCLEAN until a reset. With swtpm killed first (no Shutdown, as a real power loss) the target boots ok.
     See docs/shirudo-evidence.md, Power loss, and shirudo/spike/power-loss-e7.txt. Kept for the record. -->

<!-- DRAFT for shirudo-dev/shirudo issues. Not posted. Review before filing. -->

# init fails with EUCLEAN after a power loss; target stays tampered across reboots until a clean shutdown

## Summary

After a hard power-off (QEMU killed, no guest shutdown), the next boot's `shirudo init` in the initrd fails with

```
init: loading authenticated boot settings failed: Structure needs cleaning
```

`shirudo status` then reports `tampered` (ConfigActive ALERT "the config PCR, activation records and mounted config
disagree"; ChainIntact, UpatchesMeasured and TpmMeasured WARN, register not bound), and `shirudo.service` fails.
Another hard power-off and boot leaves it in the same state. Only a clean shutdown followed by a boot brings it back
to `ok`. No config update or image activation was in progress at any of the power cuts.

The threat model (T12, "Interrupted image activation") describes a power loss during an activation as leaving
`reboot-pending`, cleared at the next boot. Here no activation was running, the state is `tampered`, and a reboot
does not clear it.

## Environment

- shirudo `8c35953fa779` (main, 2026-11-26), test bundle from `make -C testing vm` (verity mode)
- CI arm64 test kernel `7.4-shirudo-ci-20261123`
- Target: shirudo's own test VM disk, initrd and vTPM (`tpm-builder.sh`), booted with QEMU 6.2 (`virt,its=off`,
  `gic-version=host`, `-cpu host`, direct kernel/initrd, `tpm-tis-device` on a `swtpm` 0.10.1 socket) under nested KVM
  on Apple Silicon (Lima vz). The same target boots and attests `ok` on every boot after a clean shutdown.

## Steps

1. Boot the target; `shirudo status`: `ok`, `init: complete (LSM active, writable state sealed)`.
2. Kill QEMU (no guest shutdown). Restart swtpm on the same state directory (as after a power cut) and boot.
3. Observe `init: loading authenticated boot settings failed: Structure needs cleaning`, status `tampered`.
4. Kill QEMU again and boot: same failure, same status.
5. `systemctl poweroff` is refused with `Call to PowerOff failed: Operation denied due to active block inhibitor`
   in this state only (a plain `systemctl poweroff` on a healthy boot shuts down normally).
   `systemctl poweroff --check-inhibitors=no` shuts down.
6. Boot: `ok`, `init: complete`.

## Observed (scripted run, one target)

```
boot 1 (baseline)                       ok          init: complete
  plain systemctl poweroff              accepted, VM off
boot 2 (after a clean poweroff)         ok          init: complete
  hard kill
boot 3 (after kill #1)                  tampered    init: loading authenticated boot settings failed: Structure needs cleaning
  hard kill
boot 4 (after kill #2)                  tampered    (same)
  systemctl poweroff --check-inhibitors=no
boot 5 (after a clean poweroff)         ok          init: complete
```

Earlier runs on two other targets (fresh bundles, the same pin) gave the same result: every hard kill tested (3/3)
led to a tampered boot, and every clean shutdown afterwards (3/3) to an `ok` boot.

## Expected

Either (a) the boot after a power loss recovers on its own, discarding a torn trailing record as
`util/config_update.c` ("A trailing partial append can be discarded only on a later trusted boot") suggests, or
(b) a documented recovery path for power loss outside an activation, with a status other than `tampered` (which an
operator would read as an attack).

## Why it matters

Field devices in industrial (OT) networks lose power without warning as a matter of course, and are often unattended.
A device that reports `tampered` and refuses state changes after every power cut until someone logs in and shuts it
down cleanly would need a site visit or remote shell each time, and trains operators to ignore `tampered`.

## Questions

- Is EUCLEAN here from `event_follows()` / `config_mount_check()` in `util/config_update.c` / `util/image_runtime.c`,
  i.e. a config record the clean shutdown completes or repairs? What does shutdown write that a power cut loses?
- Is the block inhibitor in the failed state shirudo's (to stop a reboot that would lose evidence), and is
  `--check-inhibitors=no` the intended way past it?
