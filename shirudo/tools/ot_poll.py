#!/usr/bin/env python3
"""Poll the field device like a master: Modbus FC4 and a DNP3 class 0 read, once per second. Standard library only
(runs on the Kali image, which has no pymodbus).

usage: ot_poll.py <ip> <seconds> <out.csv> [--unit 1 --start 30000 --count 10 --dnp3-dest 10 --dnp3-src 1]
       ot_poll.py --selftest
CSV rows: epoch,proto,item,value. Modbus rows carry each register; DNP3 rows carry the response length and whether
every link CRC checked ("dnp3,response,<bytes>,<crc_ok>"). Errors are rows too ("modbus,error,<msg>,").
"""
import argparse, socket, struct, sys, time


def crc_dnp(data: bytes) -> int:
    """CRC-16/DNP: poly 0x3D65 reflected (0xA6BC), init 0, xorout 0xFFFF."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA6BC if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def dnp3_frame(dest: int, src: int, user: bytes, ctrl: int = 0xC4) -> bytes:
    """Link frame: header + CRC, then user data in 16-byte blocks, each followed by its CRC (little-endian)."""
    head = bytes([0x05, 0x64, 5 + len(user), ctrl]) + struct.pack("<HH", dest, src)
    out = head + struct.pack("<H", crc_dnp(head))
    for i in range(0, len(user), 16):
        block = user[i:i + 16]
        out += block + struct.pack("<H", crc_dnp(block))
    return out


def dnp3_class0_read(dest: int, src: int, seq: int) -> bytes:
    # transport FIR|FIN|seq, application FIR|FIN|seq, READ, group 60 var 1 (class 0), qualifier 0x06 (all)
    return dnp3_frame(dest, src, bytes([0xC0 | (seq & 0x3F), 0xC0 | (seq & 0x0F), 0x01, 0x3C, 0x01, 0x06]))


def dnp3_crc_ok(frame: bytes) -> bool:
    if len(frame) < 10 or frame[:2] != b"\x05\x64":
        return False
    if struct.unpack("<H", frame[8:10])[0] != crc_dnp(frame[:8]):
        return False
    user_len, pos = frame[2] - 5, 10
    while user_len > 0:
        n = min(16, user_len)
        block, crc = frame[pos:pos + n], frame[pos + n:pos + n + 2]
        if len(crc) < 2 or struct.unpack("<H", crc)[0] != crc_dnp(block):
            return False
        pos, user_len = pos + n + 2, user_len - n
    return True


def modbus_fc4(tid: int, unit: int, start: int, count: int) -> bytes:
    return struct.pack(">HHHBBHH", tid, 0, 6, unit, 4, start, count)


def recv_exact(s: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def selftest() -> None:
    assert crc_dnp(b"123456789") == 0xEA82  # CRC catalogue check value for CRC-16/DNP
    f = dnp3_class0_read(10, 1, 0)
    assert f[:8] == bytes([0x05, 0x64, 0x0B, 0xC4, 0x0A, 0x00, 0x01, 0x00]) and len(f) == 10 + 6 + 2
    assert dnp3_crc_ok(f) and not dnp3_crc_ok(f[:-1] + bytes([f[-1] ^ 1]))
    assert modbus_fc4(7, 1, 30000, 10) == bytes.fromhex("000700000006010475300 00a".replace(" ", ""))
    print("selftest ok")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("ip", nargs="?"); p.add_argument("seconds", nargs="?", type=float); p.add_argument("out", nargs="?")
    p.add_argument("--unit", type=int, default=1); p.add_argument("--start", type=int, default=30000)
    p.add_argument("--count", type=int, default=10); p.add_argument("--dnp3-dest", type=int, default=10)
    p.add_argument("--dnp3-src", type=int, default=1); p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    out = open(a.out, "w", buffering=1)
    t0, tid, seq = time.time(), 0, 0
    mb = dn = None
    while time.time() - t0 < a.seconds:
        ts = time.time()
        try:
            mb = mb or socket.create_connection((a.ip, 502), timeout=3)
            tid = (tid + 1) & 0xFFFF
            mb.sendall(modbus_fc4(tid, a.unit, a.start, a.count))
            _, _, length = struct.unpack(">HHH", recv_exact(mb, 6))
            pdu = recv_exact(mb, length)
            if pdu[1] & 0x80:
                out.write("%.4f,modbus,exception,%d\n" % (ts, pdu[2]))
            else:
                for i in range(pdu[2] // 2):
                    out.write("%.4f,modbus,%d,%d\n" % (ts, a.start + i, struct.unpack(">H", pdu[3 + 2 * i:5 + 2 * i])[0]))
        except (OSError, ConnectionError, struct.error) as e:
            out.write("%.4f,modbus,error,%s\n" % (ts, str(e).replace(",", ";"))); mb = None
        try:
            dn = dn or socket.create_connection((a.ip, 20000), timeout=3)
            dn.sendall(dnp3_class0_read(a.dnp3_dest, a.dnp3_src, seq)); seq += 1
            head = recv_exact(dn, 10)
            user = head[2] - 5
            body = recv_exact(dn, user + 2 * ((user + 15) // 16))
            out.write("%.4f,dnp3,response,%d,%s\n" % (ts, 10 + len(body), dnp3_crc_ok(head + body)))
        except (OSError, ConnectionError) as e:
            out.write("%.4f,dnp3,error,%s\n" % (ts, str(e).replace(",", ";"))); dn = None
        time.sleep(max(0.0, 1.0 - (time.time() - ts)))


if __name__ == "__main__":
    main()
