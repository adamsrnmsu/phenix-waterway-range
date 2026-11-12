#!/usr/bin/env python3
"""Rewrite a phenix-generated msdos/grub-bios .vmdb into GPT + ESP + grub uefi (arm64).

usage: uefi_patch.py <file.vmdb>      patch in place (idempotent)
       python3 -I uefi_patch.py --self-test
"""
import re
import sys

ESP = """\
  - mkpart: primary
    device: "{{ output }}"
    start: 1M
    end: 257M
    tag: efi
  - mkpart: primary
    device: "{{ output }}"
    start: 257M
    end: 100%
    tag: root
"""


def patch(t):
    if "tag: efi" in t:
        return t  # already patched
    subs = [
        (r"mklabel: msdos", "mklabel: gpt"),
        # one root partition -> ESP + root
        (r"  - mkpart: primary\n    device: \"\{\{ output \}\}\"\n    start: 1M\n    end: 100%\n    tag: root\n", ESP),
        (r"(  - mkfs: ext4\n    partition: root\n)", "  - mkfs: vfat\n    partition: efi\n\\1"),
        # mount the ESP only after debootstrap (it needs an empty target)
        (r"(  - virtual-filesystems: root\n)", "  - mount: efi\n    mount-on: root\n    dirname: /boot/efi\n\\1"),
        (r"  - grub: bios\n    tag: root\n", "  - grub: uefi\n    tag: root\n    efi: efi\n"),
    ]
    for pat, rep in subs:
        t, n = re.subn(pat, rep, t, count=1)
        if n != 1:
            sys.exit(f"uefi_patch: pattern not found: {pat[:40]!r}")
    return t


SAMPLE = """\
steps:
  - mkimg: "{{ output }}"
    size: 10G
  - mklabel: msdos
    device: "{{ output }}"
  - mkpart: primary
    device: "{{ output }}"
    start: 1M
    end: 100%
    tag: root
  - kpartx: "{{ output }}"
  - mkfs: ext4
    partition: root
  - mount: root
  - unpack-rootfs: root
  - debootstrap: noble
    target: root
    unless: rootfs_unpacked
  - virtual-filesystems: root
  - fstab: root
  - grub: bios
    tag: root
"""


def self_test():
    o = patch(SAMPLE)
    for want in ("mklabel: gpt", "tag: efi", "end: 257M", "start: 257M", "mkfs: vfat",
                 "mount-on: root", "dirname: /boot/efi", "grub: uefi", "efi: efi"):
        assert want in o, want
    assert "msdos" not in o and "grub: bios" not in o
    assert o.index("mkfs: vfat") < o.index("mkfs: ext4")
    assert o.index("debootstrap") < o.index("mount: efi") < o.index("virtual-filesystems")
    assert patch(o) == o, "not idempotent"
    print("uefi_patch self-test OK")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        p = sys.argv[1]
        s = open(p).read()
        open(p, "w").write(patch(s))
    else:
        sys.exit(__doc__)
