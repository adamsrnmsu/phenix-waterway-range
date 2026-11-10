# Title: aarch64 guests on the `virt` machine get no display: `-vga` is silently ignored

## Summary

On an aarch64 host running minimega with `qemu-system-aarch64 -M virt`, `vm config vga` has no effect: the guest has no display device, so `vm screenshot` is black, VNC shows nothing and the guest has no keyboard. The `virt` machine has no VGA/PCI VGA bus, so qemu parses `-vga virtio` (or `std`) and drops it without an error.

Related x86-isms in the generated command line (`cmd/minimega/kvm.go`, `launch`, around the `-vga` / `-usb` block):
- `-vga <type>` (always emitted unless `Baremetal`)
- `-device usb-tablet,bus=usb-bus.0`: the bus `usb-bus.0` only exists with `-usb` on x86 `pc`; on `virt` the controller from `-device qemu-xhci,id=xhci` is `xhci.0`.

## Environment

aarch64 Linux (Lima VM on Apple Silicon, nested KVM), `qemu-system-aarch64 -M virt`, minimega master (66ed1aac), AAVMF UEFI firmware.

## What works today

`kvm` is resolved from `PATH`, so a small wrapper script named `kvm` that execs `qemu-system-aarch64 -enable-kvm "$@"` works, with these argument rewrites:

| minimega emits | wrapper passes | why |
| --- | --- | --- |
| `-vga <x>` (x != none) | `-device virtio-gpu-pci -device usb-kbd,bus=xhci.0` (skipped if a virtio-gpu device is already given) | `virt` has no VGA; virtio-gpu gives `vm screenshot`/VNC output, usb-kbd gives input |
| `-M virt` | `-M virt,its=off` | nested KVM on Apple's Virtualization.framework hangs in early boot with the GICv3 ITS (environment specific) |
| bare `media=cdrom` | `media=cdrom,if=none` | `virt` has no IDE controller |
| no `-M` at all (`-cpu ?` probes) | `-M virt,its=off` | aarch64 has no default machine |

On the phenix side, the topology also sets `overrides: {bus=usb-bus.0: bus=xhci.0}` for the usb-tablet device and `qemu-append: -bios /usr/share/AAVMF/AAVMF_CODE.fd`.

The wrapper is ~25 lines of bash; ours is `docker/kvm-wrapper.sh` in https://github.com/adamsrnmsu/phenix-waterway-range, with a test `docker/test-kvm-wrapper.sh`.

## Proposal

Let minimega generate the right display and input devices when the target is aarch64, so no wrapper is needed for these two items. Options, smallest first:

1. In `kvm.go`, when `vm.Vga != "none"` and the machine type is `virt` (or the host arch is aarch64): emit `-device virtio-gpu-pci` instead of `-vga <x>`, and attach `usb-tablet` / a keyboard to `xhci.0` rather than `usb-bus.0` (needs the xHCI controller, i.e. force `UsbUseXHCI`).
2. A `vm config vga` value (for example `virtio-gpu-pci`) that is passed as `-device`, leaving current behaviour untouched.
3. Document the limitation and the `qemu-append` workaround (`-device virtio-gpu-pci -device usb-kbd,bus=xhci.0`), which already works for GUI guests but leaves `-vga` in the command line.

I am happy to send a PR for option 1 or 2 if you tell me which fits minimega's direction. The `its=off` and `if=none` rewrites are environment specific and I would leave them out of minimega.

## Evidence

arm64 range with GUI guests (xfce desktops, FUXA kiosk) screenshots via `vm screenshot`: https://github.com/adamsrnmsu/phenix-waterway-range. Without the wrapper: blank screenshots, no keyboard (reproduce: `vm config vga virtio`, launch any aarch64 UEFI guest on `-M virt`, `vm screenshot`).

Not verified: option 1 is a design sketch; I have not changed or built minimega for it.
