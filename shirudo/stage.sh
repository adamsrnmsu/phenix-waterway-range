#!/usr/bin/env bash
# usage: shirudo/stage.sh [--rebuild-tpm] [vm]   (run on the Mac; vm defaults to ref; options in any order)
# Copies one shirudo test target from shirudo-dev into /phenix/shirudo/<pin>/ on the phenix VM, where minimega reads it
# (the minimega container mounts /phenix at the same path):
#   kernel/          the CI test kernel (artifacts/bpf-next-kernel-debs)
#   bundle/          the target bundle (build/test-vm/host-bundle-bpf-next-verity)
#   src/             the checkout without build/ and .git, shared into the guest as /workspace/shirudo
#   vms/<vm>/        the target's disk, cloud-init seed, initrd, SSH key, CA dirs and result dir
#   tpm/<vm>/        its vTPM state (made by shirudo's tpm-builder.sh for that name) and version_id
#   MANIFEST         "sha256  path" for every staged file
# kernel/, bundle/ and src/ are refreshed on every run. vms/<vm> and tpm/<vm> are per-target state that persists
# across experiment restarts: they are copied only when not staged yet, or with --rebuild-tpm. A staged TPM whose
# version_id is not the incoming bundle's is refused unless --rebuild-tpm.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rebuild=0 vm=ref
for a in "$@"; do case $a in --rebuild-tpm) rebuild=1 ;; -*) echo "unknown option $a" >&2; exit 2 ;; *) vm=$a ;; esac; done
src=${SHIRUDO_SRC:-$HOME/git/shirudo}
pin=$(cat "$here/PIN")
dest=/phenix/shirudo/$pin
"$here/fetch-build.sh" --check-only

dev() { limactl shell --workdir "$src" shirudo-dev bash -lc "$*"; }
px() { limactl shell phenix sudo "$@"; }
wvm=build/test-vm/vms/$vm bundle=build/test-vm/host-bundle-bpf-next-verity

dev "test -d $wvm && test -d $bundle" || { echo "shirudo-dev has no target $vm or no bundle; run fetch-build.sh" >&2; exit 1; }
incoming=$(dev "$bundle/root/usr/local/bin/shirudo version --version-id")
[ "$(dev "cat $wvm/shirudo-build")" = "$incoming" ] ||
  { echo "shirudo-dev target $vm was provisioned for another bundle; recreate it there (make -C testing vm-clean vm)" >&2; exit 1; }

staged=$(px cat "$dest/tpm/$vm/version_id" 2>/dev/null || true)
copy_state=1
if [ -n "$staged" ]; then
  if [ "$staged" != "$incoming" ] && [ "$rebuild" = 0 ]; then
    echo "staged vTPM for $vm is for version_id $staged, the bundle is $incoming; rerun with --rebuild-tpm" >&2
    exit 1
  fi
  [ "$rebuild" = 0 ] && copy_state=0
fi
if [ "$copy_state" = 1 ] && px systemctl is-active -q "shirudo-swtpm-$vm"; then
  echo "swtpm for $vm is running; stop it (shirudo/swtpm.sh stop $vm) before replacing its state" >&2; exit 1
fi

px mkdir -p "$dest"
px rm -rf "$dest/kernel" "$dest/bundle" "$dest/src"
px mkdir -p "$dest/kernel" "$dest/bundle" "$dest/src"
dev "tar -C artifacts/bpf-next-kernel-debs -cf - ." | px tar -C "$dest/kernel" -xf -
dev "tar -C $bundle -cf - ." | px tar -C "$dest/bundle" -xf -
dev "tar --exclude=./build --exclude=./.git -cf - ." | px tar -C "$dest/src" -xf -
# the copies must match their sources in shirudo-dev byte for byte
want=$( { dev "cd artifacts/bpf-next-kernel-debs && find . -type f -print0 | xargs -0 sha256sum" | sed 's#  \./#  kernel/#'
          dev "cd $bundle && find . -type f -print0 | xargs -0 sha256sum" | sed 's#  \./#  bundle/#'; } | sort -k2)
got=$(px sh -c "cd '$dest' && find kernel bundle -type f -print0 | xargs -0 sha256sum" | sort -k2)
[ "$want" = "$got" ] || { echo "staged kernel/ or bundle/ differs from shirudo-dev:" >&2; diff <(echo "$want") <(echo "$got") | head -5 >&2; exit 1; }

if [ "$copy_state" = 1 ]; then
  # shut the guest down cleanly before copying: run.sh's vm-stop kills QEMU, a power loss for the target's state
  dev "VM_NAME=$vm VM_SSH_COMMAND='systemctl poweroff --check-inhibitors=no' make -s -C testing vm-ssh >/dev/null 2>&1 || true"
  dev "for i in \$(seq 60); do p=\$(cat $wvm/qemu.pid 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null || exit 0; sleep 1; done; echo 'guest did not power off' >&2; exit 1" ||
    { echo "shirudo-dev target $vm did not power off cleanly" >&2; exit 1; }
  dev "make -s -C testing vm-stop VM_NAME=$vm >/dev/null 2>&1 || true"
  px rm -rf "$dest/vms/$vm" "$dest/tpm/$vm"
  px mkdir -p "$dest/vms/$vm" "$dest/tpm/$vm"
  dev "tar -C $wvm --exclude=./tpm --exclude=./rootfs.qcow2 --exclude='*.sock' --exclude='*.pid' --exclude='*.unit' --exclude='*.log' -cf - ." |
    px tar -C "$dest/vms/$vm" -xf -
  # shirudo-dev's disk is an overlay on a cache image; stage a standalone copy
  dev "rm -f $wvm/../$vm-flat.qcow2 && qemu-img convert -O qcow2 $wvm/rootfs.qcow2 $wvm/../$vm-flat.qcow2"
  dev "tar -C $wvm/.. -cf - $vm-flat.qcow2" | px tar -C "$dest/vms/$vm" -xf -
  px mv "$dest/vms/$vm/$vm-flat.qcow2" "$dest/vms/$vm/rootfs.qcow2"
  dev "rm -f $wvm/../$vm-flat.qcow2"
  dev "tar -C $wvm/tpm --exclude='*sock' --exclude='*.pid' -cf - ." | px tar -C "$dest/tpm/$vm" -xf -
  px chmod 0700 "$dest/tpm/$vm"
  px sh -c "printf '%s\n' '$incoming' > '$dest/tpm/$vm/version_id'"
fi

px sh -c "cd '$dest' && find . -type f ! -name MANIFEST ! -name '*.sock' ! -name '*.log' -print0 | sort -z | xargs -0 sha256sum > MANIFEST"
echo "staged $vm (version_id $incoming) at $dest: $(px sh -c "wc -l < '$dest/MANIFEST'") files; kernel and bundle copies verified against shirudo-dev"
