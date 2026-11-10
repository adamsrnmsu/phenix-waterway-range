#!/bin/bash
# /usr/local/bin/kvm on arm64: minimega's default `qemu` is "kvm".
# - adds `-M virt,its=off` when no machine given (`-cpu ?` probes run with no -M; aarch64 has no default machine)
# - rewrites `-M virt` -> `virt,its=off`: nested KVM on Apple vz hangs in early boot with the GICv3 ITS (see spike/vmconfig-aarch64.txt)
# - rewrites the bare empty-cdrom arg `media=cdrom` -> `media=cdrom,if=none` (virt has no IDE controller; qemu errors 'Device needs media')
# - rewrites `-vga <x>` -> `-device virtio-gpu-pci -device usb-kbd,bus=xhci.0`: virt has no VGA bus, so qemu drops -vga
#   silently and the guest has no display (no screenshots, no VNC). Skipped if a virtio-gpu device is already given.
# minimega validates machine names against `-M ?`, so the option must be injected here, not in `vm config machine`.
# shellcheck disable=SC2054  # commas are qemu option syntax, not array separators
args=(); have_m=0; next_m=0; next_vga=0; want_gpu=0; have_gpu=0
for a in "$@"; do
  if [ $next_m = 1 ]; then
    next_m=0; [ "$a" = virt ] && a=virt,its=off; args+=("$a"); continue
  fi
  if [ $next_vga = 1 ]; then next_vga=0; [ "$a" = none ] || want_gpu=1; continue; fi
  [ "$a" = -vga ] && { next_vga=1; continue; }
  case "$a" in virtio-gpu*) have_gpu=1 ;; esac
  [ "$a" = media=cdrom ] && a=media=cdrom,if=none
  case "$a" in
    -M|-machine) have_m=1; next_m=1 ;;
  esac
  args+=("$a")
done
[ $have_m = 1 ] || args=(-M virt,its=off "${args[@]}")
[ $want_gpu = 1 ] && [ $have_gpu = 0 ] && args+=(-device virtio-gpu-pci -device usb-kbd,bus=xhci.0)
exec qemu-system-aarch64 -enable-kvm "${args[@]}"
