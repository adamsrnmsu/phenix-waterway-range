#!/usr/bin/env python3
"""Walk through a MITM capture and explain why it proves the ettercap attack worked.

Reads the pcap that `mitm-capture` took on kali's interface during the PR #31 test
(docs/mitm-capture.pcap) and builds the argument one step at a time:

  1. What is in the capture.
  2. Whose interface it is: one MAC sits in every frame, but never as an IP endpoint.
  3. The double take: each IP packet shows up twice, once arriving at kali's MAC and once
     leaving kali toward the real host, with the IP layer untouched. That is forwarding.
  4. What the victims believe: whose IP each victim was sending to, behind which MAC.
  5. Kali can read the process: Modbus decoded into waterway tags and values.
  6. The data path survived: every poll answered, no resets.

Standard library only. Usage:
  python3 scripts/pcap_walkthrough.py [docs/mitm-capture.pcap] [--no-pause]
  python3 scripts/pcap_walkthrough.py --self-test
"""

from __future__ import annotations

import argparse
import json
import statistics
import struct
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_PCAP = REPO / "docs" / "mitm-capture.pcap"
DEFAULT_REGS = REPO / "topologies" / "waterway-arm64" / "reg_addrs.json"
SCALE = (0.0, 1000.0)  # bennu scales registers linearly over this range to 16 bit
KNOWN = {"10.1.1.200": "kali", "10.1.2.50": "opc", "10.1.1.101": "rtu-1", "10.1.1.102": "rtu-2", "10.1.1.1": "router"}
FC_NAMES = {1: "read coils", 2: "read discrete inputs", 3: "read holding registers",
            4: "read input registers", 5: "write single coil", 6: "write single register",
            15: "write multiple coils", 16: "write multiple registers"}


# ---------------------------------------------------------------- parsing

@dataclass
class Frame:
    n: int
    ts: float
    src_mac: str
    dst_mac: str
    src_ip: str = ""
    dst_ip: str = ""
    ip_id: int = 0
    sport: int = 0
    dport: int = 0
    seq: int = 0
    flags: int = 0
    payload: bytes = b""

    @property
    def ip_key(self):
        """What survives forwarding unchanged: the IP packet's identity and content."""
        return (self.src_ip, self.dst_ip, self.ip_id, self.sport, self.dport, self.seq, self.payload)


def mac(b: bytes) -> str:
    return ":".join(f"{x:02x}" for x in b)


def ip(b: bytes) -> str:
    return ".".join(str(x) for x in b)


def read_pcap(data: bytes) -> list[Frame]:
    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        end, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        end, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
    else:
        raise SystemExit("not a classic pcap file (pcapng? convert with: editcap -F pcap in out)")
    linktype = struct.unpack(end + "I", data[20:24])[0]
    if linktype != 1:
        raise SystemExit(f"expected Ethernet (linktype 1), got {linktype}")
    frames, off, n = [], 24, 0
    while off + 16 <= len(data):
        sec, frac, incl, _ = struct.unpack(end + "IIII", data[off:off + 16])
        pkt = data[off + 16: off + 16 + incl]
        off += 16 + incl
        n += 1
        f = Frame(n, sec + frac / (1e9 if nano else 1e6), mac(pkt[6:12]), mac(pkt[0:6]))
        etype = struct.unpack("!H", pkt[12:14])[0]
        if etype == 0x0800 and len(pkt) >= 34:
            ihl = (pkt[14] & 0x0F) * 4
            total = struct.unpack("!H", pkt[16:18])[0]
            f.ip_id = struct.unpack("!H", pkt[18:20])[0]
            proto = pkt[23]
            f.src_ip, f.dst_ip = ip(pkt[26:30]), ip(pkt[30:34])
            t = 14 + ihl
            if proto == 6 and len(pkt) >= t + 20:
                f.sport, f.dport, f.seq = struct.unpack("!HHI", pkt[t:t + 8])
                f.flags = pkt[t + 13]
                doff = (pkt[t + 12] >> 4) * 4
                f.payload = pkt[t + doff: 14 + total]
        frames.append(f)
    return frames


@dataclass
class Adu:
    ts: float
    client: str
    server: str
    tid: int
    unit: int
    fc: int
    is_request: bool
    start: int = 0
    qty: int = 0
    values: list[int] = field(default_factory=list)
    exception: int = 0


def modbus_adus(frames: list[Frame]) -> list[Adu]:
    """Decode Modbus/TCP from the packets kali forwarded (each counted once)."""
    out, seen = [], set()
    for f in frames:
        if not f.payload or 502 not in (f.sport, f.dport) or f.ip_key in seen:
            continue
        seen.add(f.ip_key)
        req = f.dport == 502
        client, server = (f.src_ip, f.dst_ip) if req else (f.dst_ip, f.src_ip)
        p = f.payload
        while len(p) >= 8:
            tid, _pid, length, unit = struct.unpack("!HHHB", p[:7])
            pdu, p = p[7:6 + length], p[6 + length:]
            fc = pdu[0]
            a = Adu(f.ts, client, server, tid, unit, fc & 0x7F, req)
            if fc & 0x80:
                a.exception = pdu[1] if len(pdu) > 1 else -1
            elif req and fc in (3, 4) and len(pdu) >= 5:
                a.start, a.qty = struct.unpack("!HH", pdu[1:5])
            elif req and fc == 6 and len(pdu) >= 5:
                a.start, v = struct.unpack("!HH", pdu[1:5])
                a.qty, a.values = 1, [v]
            elif req and fc == 16 and len(pdu) >= 6:
                a.start, a.qty = struct.unpack("!HH", pdu[1:5])
                a.values = list(struct.unpack(f"!{a.qty}H", pdu[6:6 + 2 * a.qty]))
            elif not req and fc in (3, 4) and len(pdu) >= 2:
                a.values = list(struct.unpack(f"!{pdu[1] // 2}H", pdu[2:2 + pdu[1]]))
            out.append(a)
    return out


def to_eng(raw: int) -> float:
    lo, hi = SCALE
    return lo + raw / 65535 * (hi - lo)


def tag_map(path: Path) -> dict:
    if not path.exists():
        return {}
    return {(r["ip"], r["register_type"], r["address"]): f'{r["name"]}.{r["field"]}'
            for r in json.loads(path.read_text())}


# ---------------------------------------------------------------- analysis

@dataclass
class Findings:
    kali_mac: str = ""
    pairs: int = 0
    unpaired: int = 0
    fwd_ms: list[float] = field(default_factory=list)
    kali_is_endpoint: bool = False
    beliefs: list[tuple[str, str, str]] = field(default_factory=list)  # (victim, ip it sends to, mac it uses)
    requests: int = 0
    answered: int = 0
    exceptions: int = 0
    resets: int = 0
    reads: dict = field(default_factory=dict)  # tag -> [(ts, eng)]
    checks: dict = field(default_factory=dict)


def analyze(frames: list[Frame], tags: dict, kali_ip: str = "10.1.1.200", gateway: str = "10.1.1.1") -> Findings:
    fd = Findings()
    ip_frames = [f for f in frames if f.src_ip]
    macs = Counter()
    for f in ip_frames:
        macs[f.src_mac] += 1
        macs[f.dst_mac] += 1
    fd.kali_mac = next((m for m, c in macs.items() if c == len(ip_frames)), "")
    k = fd.kali_mac

    # the double take: same IP packet in (to kali) and out (from kali)
    inbound = defaultdict(list)
    for f in ip_frames:
        if f.dst_mac == k:
            inbound[f.ip_key].append(f)
    for f in ip_frames:
        if f.src_mac == k and inbound.get(f.ip_key):
            first = inbound[f.ip_key].pop(0)
            fd.pairs += 1
            fd.fwd_ms.append((f.ts - first.ts) * 1000)
    fd.unpaired = len(ip_frames) - 2 * fd.pairs

    # kali never appears as an IP endpoint: none of these packets is from or to kali's own IP
    fd.kali_is_endpoint = any(kali_ip in (f.src_ip, f.dst_ip) for f in ip_frames)

    # what each victim believes. On kali's segment, a packet from another subnet was put on
    # the wire by the gateway, and a packet for another subnet is sent to the gateway's MAC.
    # So the IP whose MAC a sender resolved is the destination itself if it is local, else
    # the gateway; and the L2 sender is the source itself if local, else the gateway.
    def local(addr):
        return addr.rsplit(".", 1)[0] == kali_ip.rsplit(".", 1)[0]

    seen = set()
    for f in ip_frames:
        if f.dst_mac == k:
            sender = f.src_ip if local(f.src_ip) else gateway
            resolved = f.dst_ip if local(f.dst_ip) else gateway
            belief = (f"{KNOWN.get(sender, sender)} ({f.src_mac})", resolved, k)
            if belief not in seen:
                seen.add(belief)
                fd.beliefs.append(belief)

    adus = modbus_adus(frames)
    reqs = {(a.client, a.server, a.tid): a for a in adus if a.is_request}
    fd.requests = len(reqs)
    for a in adus:
        if a.is_request:
            continue
        rq = reqs.get((a.client, a.server, a.tid))
        if not rq:
            continue
        fd.answered += 1
        if a.exception:
            fd.exceptions += 1
            continue
        rtype = "input-register" if rq.fc == 4 else "holding-register"
        for i, raw in enumerate(a.values):
            name = tags.get((rq.server, rtype, rq.start + i), f"{rtype}@{rq.start + i}")
            fd.reads.setdefault(f"{KNOWN.get(rq.server, rq.server)}.{name}", []).append((a.ts, to_eng(raw)))
    fd.resets = sum(1 for f in ip_frames if f.flags & 0x04)

    fd.checks = {
        "one MAC in every frame (kali's interface)": bool(k),
        "kali is never an IP endpoint": not fd.kali_is_endpoint,
        "every packet seen twice: in to kali, out from kali": fd.pairs > 0 and fd.unpaired == 0,
        "victims address each other's IPs to kali's MAC": len(fd.beliefs) >= 2,
        "Modbus polls decoded from the stolen traffic": fd.requests > 0,
        "every poll answered (data path intact)": fd.requests > 0 and fd.answered == fd.requests,
        "no TCP resets": fd.resets == 0,
    }
    return fd


# ---------------------------------------------------------------- the walkthrough

def walkthrough(frames: list[Frame], fd: Findings, pause: bool, kali_ip: str = "10.1.1.200") -> bool:
    def step(title: str):
        if pause:
            input("\n  [Enter for the next step] ")
        print(f"\n=== {title} " + "=" * max(0, 70 - len(title)))

    ip_frames = [f for f in frames if f.src_ip]
    span = frames[-1].ts - frames[0].ts if frames else 0
    step("1. What is in the capture")
    print(f"  {len(frames)} frames over {span:.1f} s, {len(ip_frames)} of them IPv4.")
    convs = Counter((KNOWN.get(f.src_ip, f.src_ip), KNOWN.get(f.dst_ip, f.dst_ip), f.dport or f.sport) for f in ip_frames)
    for (s, d, port), c in convs.most_common(6):
        print(f"    {c:4d}  {s:>8} -> {d:<8} port {port}")
    print("  This was recorded on kali. Kali is not part of this conversation, so it should")
    print("  never have seen any of it.")

    step("2. Whose interface is this?")
    print(f"  The MAC {fd.kali_mac} is in every frame, as either sender or receiver.")
    print("  That makes it the capturing interface, which is kali's. Yet no packet is")
    print(f"  addressed to or from kali's own IP ({kali_ip}): kali" + (" IS" if fd.kali_is_endpoint else " is never") + " an IP endpoint.")
    print("  Frames delivered to a machine that is not the IP destination mean someone")
    print("  told the sender to use that machine's MAC. That is ARP poisoning.")

    step("3. The double take: kali forwards every packet")
    print(f"  {fd.pairs} IP packets appear twice: once arriving at kali, once leaving kali.")
    print("  The IP layer is byte-identical (same IP id, TCP seq, payload) and only the")
    print("  Ethernet header changes. Example:")
    ex_in = next((f for f in ip_frames if f.dst_mac == fd.kali_mac and f.payload), None)
    if ex_in:
        ex_out = next((f for f in ip_frames if f.src_mac == fd.kali_mac and f.ip_key == ex_in.ip_key), None)
        for tag, f in (("in ", ex_in), ("out", ex_out)):
            if f:
                print(f"    #{f.n:<4} {tag} {f.src_mac} -> {f.dst_mac}   {f.src_ip}:{f.sport} -> {f.dst_ip}:{f.dport}  ipid={f.ip_id} seq={f.seq}")
    if fd.fwd_ms:
        print(f"  Kali's forwarding delay: median {statistics.median(fd.fwd_ms):.2f} ms, max {max(fd.fwd_ms):.2f} ms.")
    print(f"  Packets without a twin: {fd.unpaired}.")
    print("  That pattern is a man in the middle relaying traffic: it receives, then resends.")

    step("4. What the victims believe")
    for victim, resolved, m in fd.beliefs:
        print(f"  {victim} believes {resolved} ({KNOWN.get(resolved, '?')}) is at {m}, which is kali.")
    print("  opc lives on another subnet (10.1.2.0/24), so on kali's segment its packets are")
    print("  carried by the router, and rtu-1 answers opc through its gateway, the router.")
    print("  Both the router and rtu-1 now map each other to kali's MAC: the two-way ARP")
    print("  poison ettercap was told to do (targets /10.1.1.101// /10.1.1.1//).")

    step("5. Kali can read the process")
    print(f"  Modbus/TCP decoded: {fd.requests} requests, {fd.answered} responses, {fd.exceptions} exceptions.")
    for name, vals in sorted(fd.reads.items()):
        nums = [round(v, 2) for _, v in vals]
        uniq = sorted(set(nums))
        rng = f"{uniq[0]} .. {uniq[-1]}" if len(uniq) > 1 else f"{uniq[0]}"
        print(f"    {name:<34} {len(vals):3d} reads   {rng}")
    lh = fd.reads.get("rtu-1.lock.height")
    if lh:
        print("  rtu-1 lock.height over time, as kali saw it:")
        t0 = lh[0][0]
        for ts, v in lh[:: max(1, len(lh) // 10)]:
            print(f"    t+{ts - t0:6.1f}s  {v:7.2f}  " + "#" * int(v * 2))
    print("  On/off points (gates, valves, sensors) go through the same 0-1000 scaling as the")
    print("  heights, so 'true' decodes as 0.99 and 'false' as 0.")
    print("  Kali sees every value the OPC server polls, and could rewrite any of them.")

    step("6. The data path survived")
    print(f"  Polls answered: {fd.answered}/{fd.requests}. TCP resets: {fd.resets}.")
    print("  The OPC server kept getting answers through kali, so nothing on the HMI")
    print("  looked wrong. A silent relay is what makes a MITM dangerous.")

    step("Verdict")
    for name, ok in fd.checks.items():
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    ok = all(fd.checks.values())
    print("\n  " + ("The capture proves the MITM worked." if ok else "Some checks failed; see above."))
    return ok


# ---------------------------------------------------------------- self-test

def _synthetic_pcap() -> bytes:
    """opc->rtu-1 read of 30001 relayed by kali, plus the answer, as four frames."""
    K, R, RTU = bytes.fromhex("24c0b3188327"), bytes.fromhex("00e028c2a38c"), bytes.fromhex("049645fe9722")
    opc, rtu = bytes([10, 1, 2, 50]), bytes([10, 1, 1, 101])

    def frame(src, dst, sip, dip, sport, dport, seq, ipid, payload):
        tcp = struct.pack("!HHIIBBHHH", sport, dport, seq, 0, 5 << 4, 0x18, 502, 0, 0) + payload
        iph = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), ipid, 0, 64, 6, 0, sip, dip)
        return dst + src + b"\x08\x00" + iph + tcp

    req = struct.pack("!HHHBBHH", 7, 0, 6, 1, 4, 30001, 1)
    resp = struct.pack("!HHHBBBH", 7, 0, 5, 1, 4, 2, 32768)
    pkts = [frame(R, K, opc, rtu, 40000, 502, 1, 11, req), frame(K, RTU, opc, rtu, 40000, 502, 1, 11, req),
            frame(RTU, K, rtu, opc, 502, 40000, 9, 22, resp), frame(K, R, rtu, opc, 502, 40000, 9, 22, resp)]
    out = struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
    for i, p in enumerate(pkts):
        out += struct.pack("<IIII", 100, i * 1000, len(p), len(p)) + p
    return out


def self_test():
    frames = read_pcap(_synthetic_pcap())
    fd = analyze(frames, {("10.1.1.101", "input-register", 30001): "lock.height"})
    assert fd.kali_mac == "24:c0:b3:18:83:27", fd.kali_mac
    assert fd.pairs == 2 and fd.unpaired == 0, (fd.pairs, fd.unpaired)
    assert not fd.kali_is_endpoint
    assert {b[1] for b in fd.beliefs} == {"10.1.1.101", "10.1.1.1"}, fd.beliefs
    assert fd.beliefs[0][0].startswith("router"), fd.beliefs
    assert fd.requests == 1 and fd.answered == 1
    (_ts, v), = fd.reads["rtu-1.lock.height"]
    assert abs(v - 500.0) < 0.1, v
    assert all(fd.checks.values()), fd.checks
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap", nargs="?", default=str(DEFAULT_PCAP))
    ap.add_argument("--regs", default=str(DEFAULT_REGS), help="reg_addrs.json for tag names")
    ap.add_argument("--kali-ip", default="10.1.1.200", help="kali's own IP (mitm topology IF0)")
    ap.add_argument("--no-pause", action="store_true", help="print every step without waiting")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    frames = read_pcap(Path(a.pcap).read_bytes())
    fd = analyze(frames, tag_map(Path(a.regs)), a.kali_ip)
    ok = walkthrough(frames, fd, pause=not a.no_pause and sys.stdin.isatty(), kali_ip=a.kali_ip)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
