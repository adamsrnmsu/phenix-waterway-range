#!/usr/bin/env python3
"""Raw Modbus TCP client for the bennucamp range (no deps).
mb.py bench <host> <fc> <addr> <n>       : n reads, print ok/err/timeout counts and latency p50/p99 (ms)
mb.py raw <host> <hex-pdu> [unit]          : send one ADU with the given PDU, print the reply hex
"""
import socket, struct, sys, time

def adu(tid, pdu, unit=1):
    return struct.pack(">HHHB", tid, 0, len(pdu) + 1, unit) + pdu

def xfer(s, tid, pdu, unit=1):
    s.sendall(adu(tid, pdu, unit))
    h = b""
    while len(h) < 7:
        c = s.recv(7 - len(h))
        if not c: raise ConnectionError("closed")
        h += c
    n = struct.unpack(">H", h[4:6])[0] - 1
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("closed")
        b += c
    return h + b

def bench(host, fc, addr, n):
    ok = err = to = 0; lat = []
    s = socket.create_connection((host, 502), timeout=2)
    for i in range(n):
        t = time.perf_counter()
        try:
            r = xfer(s, i & 0xFFFF, struct.pack(">BHH", fc, addr, 1))
            lat.append((time.perf_counter() - t) * 1000)
            if r[7] & 0x80: err += 1
            else: ok += 1
        except (socket.timeout, ConnectionError):
            to += 1
            s.close(); s = socket.create_connection((host, 502), timeout=2)
    lat.sort()
    p = lambda q: lat[min(len(lat) - 1, int(q * len(lat)))] if lat else float("nan")
    print(f"BENCH host={host} fc={fc} addr={addr} n={n} ok={ok} exc={err} timeout={to} p50_ms={p(.5):.2f} p99_ms={p(.99):.2f}")

if __name__ == "__main__":
    a = sys.argv
    if a[1] == "bench": bench(a[2], int(a[3]), int(a[4]), int(a[5]))
    elif a[1] == "raw":
        s = socket.create_connection((a[2], 502), timeout=3)
        try: print("REPLY", xfer(s, 1, bytes.fromhex(a[3]), int(a[4]) if len(a) > 4 else 1).hex())
        except Exception as e: print("REPLY-ERR", type(e).__name__, e)
