#!/usr/bin/env python3
import os, socket, struct, subprocess, sys, tempfile, time
HOST = sys.argv[1]; PORT = int(sys.argv[2])

def crc(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA6BC if c & 1 else c >> 1
    return ~c & 0xFFFF

def frame(app, seq=0):
    user = bytes([0xC0 | seq]) + app
    hdr = bytes([0x05, 0x64, 5 + len(user), 0xC4]) + (10).to_bytes(2, "little") + (1).to_bytes(2, "little")
    out = hdr + crc(hdr).to_bytes(2, "little")
    for i in range(0, len(user), 16):
        blk = user[i:i + 16]
        out += blk + crc(blk).to_bytes(2, "little")
    return out

def deframe(buf):
    out = b""; i = 0
    while i + 10 <= len(buf):
        n = buf[i + 2] - 5; i += 10
        while n > 0:
            k = min(16, n); out += buf[i:i + k]; i += k + 2; n -= k
    return out  # transport hdr + app

class M:
    def __init__(s):
        s.s = socket.create_connection((HOST, PORT), timeout=5); s.seq = 0
    def xfer(s, fc, objs):
        app = bytes([0xC0 | s.seq, fc]) + objs; s.seq = (s.seq + 1) & 15
        s.s.sendall(frame(app)); time.sleep(0.4)
        s.s.settimeout(2); d = b""
        try:
            while True:
                c = s.s.recv(4096)
                if not c: break
                d += c
                if len(d) > 0 and d.count(b"\x05\x64") and len(deframe(d)) >= 5: break
        except socket.timeout: pass
        return deframe(d)

def ao(var, idx, fmt, val):
    return bytes([41, var, 0x17, 1, idx]) + struct.pack(fmt, val) + b"\x00"

VARS = (("Int32 g41v1", 1, "<i", 77), ("Int16 g41v2", 2, "<h", 77), ("Double g41v4", 4, "<d", 77.0))


def status(r, var, idx, fmt):
    j = r.find(bytes([41, var, 0x17, 1, idx]))
    return r[j + 5 + struct.calcsize(fmt)] if j >= 0 else None


def readback(m):
    r = m.xfer(1, bytes([40, 0, 0x00, 1, 1]))
    j = r.find(bytes([40, 1, 0x00, 1, 1]))
    # g40v1 is a flag byte + 32-bit int
    return struct.unpack("<i", r[j + 6:j + 10])[0] if j >= 0 else None



def run(sbo, bad):
    m = M()
    ref = status(m.xfer(5, ao(3, 99, "<f", 5.0)), 3, 99, "<f")  # Float32 is the reference
    for name, var, fmt, v in VARS:
        st = status(m.xfer(5, ao(var, 99, fmt, v)), var, 99, fmt)
        print(f"sbo={sbo} {name} idx99 status={st} (Float32 reference {ref})")
        if st != ref or st == 0:
            bad.append(f"{name} to nonexistent idx 99 returned {st}, expected {ref}")
        st = status(m.xfer(5, ao(var, 1, fmt, v)), var, 1, fmt)
        val = readback(m)
        print(f"sbo={sbo} {name} idx1 direct operate status={st} readback={val}")
        if sbo and (st != 2 or val == v):
            bad.append(f"{name} direct operate on SBO point: status {st}, readback {val} (want NO_SELECT=2, not applied)")
        if not sbo and (st != 0 or val != v):
            bad.append(f"{name} direct operate on idx 1: status {st}, readback {val}, want 0 and {v}")
        if not sbo:
            m.xfer(5, ao(3, 1, "<f", 0.0))
bad = []
run(bool(int(sys.argv[3])), bad)
print("FAIL:" if bad else "PASS", *bad, sep="\n  ")
