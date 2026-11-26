#!/bin/sh
# Root-on-the-target tamper attempts against shirudo, run on rtu-s over its host-only SSH by attack.sh. Each attempt
# prints "## <name>", its exit code and the first lines of its output. Assumes an attacker who already has root.
# An attempt whose precondition is missing prints SKIP; tests/run-evidence.sh fails on it.
t() { name=$1; shift; echo "## $name"; sh -c "$*" >/tmp/tamper.out 2>&1; echo "rc=$?"; head -3 /tmp/tamper.out; }

t read_pin 'cat /run/shirudo/bpffs/tamper'
t list_pins 'ls /run/shirudo/bpffs/upatches'
t unpin_kernel_obs 'rm -rf /run/shirudo/bpffs/upatches/kernel-obs'
t umount_bpffs 'umount /run/shirudo/bpffs'
# BPF_PROG_LOAD (5) of "r0 = 0; exit" as a socket filter, straight through bpf(2) (arm64 syscall 280): not a signed loader
t unsigned_bpf_load 'python3 -c "
import ctypes, struct
libc = ctypes.CDLL(None, use_errno=True)
insns = ctypes.create_string_buffer(struct.pack(\"<BBhi\", 0xb7, 0, 0, 0) + struct.pack(\"<BBhi\", 0x95, 0, 0, 0))
lic = ctypes.create_string_buffer(b\"GPL\")
attr = ctypes.create_string_buffer(struct.pack(\"<IIQQIIQ\", 1, 2, ctypes.addressof(insns), ctypes.addressof(lic), 0, 0, 0).ljust(128, b\"\0\"))
fd = libc.syscall(280, 5, attr, 128)
print(\"fd\", fd, \"errno\", ctypes.get_errno())
raise SystemExit(0 if fd >= 0 else 1)
"'
t forged_upatch 'f=/root/mg/modbus-guard.upatch; [ -f "$f" ] || { echo "SKIP: no signed upatch at $f"; exit 2; }; shirudo-runtime upatch list 2>/dev/null | grep -q "^ *modbus-guard *yes" && { echo "SKIP: modbus-guard is loaded, so a forged copy would be refused by name first"; exit 2; }; cp "$f" /tmp/forged.upatch; python3 -c "b=bytearray(open(\"/tmp/forged.upatch\",\"rb\").read()); b[-20]^=0xff; open(\"/tmp/forged.upatch\",\"wb\").write(b)"; shirudo-runtime upatch load /tmp/forged.upatch'
t archive_write 'touch /var/lib/shirudo/upatches/evil.upatch'
t runtime_binary_write 'cp /bin/true /run/shirudo/runtime/usr/bin/shirudo'
echo "## status"
shirudo-runtime status --json
