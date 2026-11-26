# minimega script: shirudo's reference test target, booted by minimega instead of shirudo's run.sh.
# Each line maps one option of shirudo/reference/qemu-cmdline.txt. @D@ = /phenix/shirudo/<pin>, @VM@ = staged target,
# @NAME@ = minimega VM name, @SSH@ = host port forwarded to the guest's sshd. Rendered and read by spike/launch.sh.
# Option mapping (reference -> here):
#   -cpu host / -smp 4 / -m 4G             -> vm config cpu/vcpus/memory
#   -machine virt,gic-version=host          -> vm config machine virt (the kvm wrapper adds its=off) + -machine gic-version=host
#   -drive rootfs.qcow2 + seed.img          -> vm config disks (virtio); snapshot false so the target's disk persists
#   -kernel / -initrd / -append             -> vm config kernel / initrd / append (append copied verbatim)
#   -netdev user,hostfwd / virtio-net-pci   -> qemu-append (minimega only makes tap NICs)
#   -virtfs x6                              -> dropped: run.sh mounts them over SSH each boot for its tests; init
#                                              does not need them. Files move over SSH instead (pass-check.sh --mm)
#   -chardev chrtpm/-tpmdev/tpm-tis-device  -> qemu-append (minimega's tpm-socket emits tpm-tis, which virt lacks)
#   -chardev console + -serial              -> qemu-append (console.sock + console.log under the staged VM dir)
namespace @NAME@
clear vm config
vm config cpu host
vm config vcpus 4
vm config memory 4096
vm config machine virt
vm config snapshot false
vm config qemu-override bus=usb-bus.0 bus=xhci.0
vm config disks @D@/vms/@VM@/rootfs.qcow2,virtio @D@/vms/@VM@/seed.img,virtio
vm config kernel @D@/kernel/Image
vm config initrd @D@/vms/@VM@/initrd.img
vm config append root=/dev/vda1 rootwait rw console=ttyAMA0,115200n8 loglevel=7 net.ifnames=0 lsm=bpf bpf.keyring_unsealed=1 dm_verity.keyring_unsealed=1 initcall_debug ignore_loglevel
vm config qemu-append -machine gic-version=host -netdev user,id=net0,hostfwd=tcp:127.0.0.1:@SSH@-:22 -device virtio-net-pci,netdev=net0 -chardev socket,id=chrtpm,path=@D@/tpm/@VM@/swtpm.sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0 -chardev socket,id=console,path=@D@/vms/@VM@/console.sock,server=on,wait=off,logfile=@D@/vms/@VM@/console.log,logappend=on -serial chardev:console
vm launch kvm @NAME@
vm start @NAME@
