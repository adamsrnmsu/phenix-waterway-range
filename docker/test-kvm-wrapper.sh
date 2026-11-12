#!/bin/bash
# self-check: stub qemu-system-aarch64 on PATH echoes its args; run: bash docker/test-kvm-wrapper.sh
d=$(mktemp -d); trap 'rm -r "$d"' EXIT
printf '#!/bin/sh\necho "$*"\n' > $d/qemu-system-aarch64; chmod +x $d/qemu-system-aarch64
w=$(dirname "$0")/kvm-wrapper.sh
t() { got=$(PATH=$d:$PATH "$w" "${@:2}"); [ "$got" = "$1" ] || { echo "FAIL: got [$got] want [$1]"; exit 1; }; }
t "-enable-kvm -M virt,its=off -cpu ?" -cpu ?
t "-enable-kvm -M virt,its=off -m 1" -M virt -m 1
t "-enable-kvm -machine virt,its=off" -machine virt
t "-enable-kvm -M virt,gic-version=3 -drive media=cdrom,if=none" -M virt,gic-version=3 -drive media=cdrom
t "-enable-kvm -M virt,its=off -m 1 -device virtio-gpu-pci -device usb-kbd,bus=xhci.0" -M virt -vga virtio -m 1
t "-enable-kvm -M virt,its=off -vnc :1" -M virt -vga none -vnc :1
t "-enable-kvm -M virt,its=off -device virtio-gpu-pci -device usb-kbd,bus=xhci.0" -M virt -vga virtio -device virtio-gpu-pci -device usb-kbd,bus=xhci.0
echo kvm-wrapper OK
