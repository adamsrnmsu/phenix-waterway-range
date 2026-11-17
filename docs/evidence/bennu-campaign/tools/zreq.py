#!/usr/bin/env python3
"""zreq.py <host> <port> <request> [nonul] : minimal ZMTP 3.0 NULL-mechanism REQ client (no pyzmq on kali).
Sends <request> (+ trailing NUL unless 'nonul'), prints the reply."""
import socket, sys
def frame(b, more=False, cmd=False):
    f = (1 if more else 0) | (4 if cmd else 0)
    return (bytes([f | 2]) + len(b).to_bytes(8, "big") if len(b) > 255 else bytes([f, len(b)])) + b
def rd(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("closed")
        b += c
    return b
def rframe(s):
    f = rd(s, 1)[0]; n = int.from_bytes(rd(s, 8), "big") if f & 2 else rd(s, 1)[0]
    return f, rd(s, n)
host, port, req = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()
if not (len(sys.argv) > 4 and sys.argv[4] == "nonul"): req += b"\0"
s = socket.create_connection((host, port), timeout=5)
s.sendall(b"\xff" + b"\0" * 8 + b"\x7f" + b"\x03\x00" + b"NULL" + b"\0" * 16 + b"\0" + b"\0" * 31)
rd(s, 64)
s.sendall(frame(b"\x05READY" + b"\x0bSocket-Type" + (3).to_bytes(4, "big") + b"REQ", cmd=True))
while True:
    f, b = rframe(s)
    if f & 4: break
s.sendall(frame(b"", more=True) + frame(req))
parts = []
while True:
    f, b = rframe(s)
    if f & 4: continue
    parts.append(b)
    if not f & 1: break
print("REQ", req, "-> REPLY", parts[-1])
