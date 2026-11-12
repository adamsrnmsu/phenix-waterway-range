#!/usr/bin/env python3
"""Writes ./modbus-test.pcap (stdlib only): Modbus/TCP flows to rtu-1/rtu-2 for testing ics-mitm.rules.
Flow names and the sid expected to fire are printed. Run: python3 -I mkmodbus.py"""
import struct
def mac(s): return bytes(int(x, 16) for x in s.split(':'))
def ip(s): return bytes(map(int, s.split('.')))
def csum(b):
    if len(b) % 2: b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff
M = {'10.1.1.200': '24:c0:b3:18:83:27', '10.1.2.50': '00:e0:28:c2:a3:8c', '10.1.1.101': '04:96:45:fe:97:22', '10.1.1.102': '04:96:45:fe:97:23'}
pkts, t = [], [0]
def frame(src, dst, sp, dp, seq, ack, flags, data=b''):
    tcp = struct.pack('!HHIIBBHHH', sp, dp, seq, ack, 5 << 4, flags, 65535, 0, 0) + data
    ps = ip(src) + ip(dst) + struct.pack('!BBH', 0, 6, len(tcp))
    tcp = tcp[:16] + struct.pack('!H', csum(ps + tcp)) + tcp[18:]
    h = struct.pack('!BBHHHBBH', 0x45, 0, 20 + len(tcp), 1, 0, 64, 6, 0) + ip(src) + ip(dst)
    h = h[:10] + struct.pack('!H', csum(h)) + h[12:]
    t[0] += 1
    pkts.append((t[0], mac(M[dst]) + mac(M[src]) + b'\x08\x00' + h + tcp))
def flow(cport, src, dst, txns):
    """txns: list of (request PDU, response PDU or None); unit 1."""
    cs, ss = 1000, 5000
    frame(src, dst, cport, 502, cs, 0, 2); frame(dst, src, 502, cport, ss, cs + 1, 0x12)
    cs += 1; ss += 1; frame(src, dst, cport, 502, cs, ss, 0x10)
    for tid, (rq, rs) in enumerate(txns, 1):
        d = struct.pack('!HHHB', tid, 0, len(rq) + 1, 1) + rq
        frame(src, dst, cport, 502, cs, ss, 0x18, d); cs += len(d)
        frame(dst, src, 502, cport, ss, cs, 0x10)
        if rs:
            d = struct.pack('!HHHB', tid, 0, len(rs) + 1, 1) + rs
            frame(dst, src, 502, cport, ss, cs, 0x18, d); ss += len(d)
            frame(src, dst, cport, 502, cs, ss, 0x10)
    frame(src, dst, cport, 502, cs, ss, 0x11); frame(dst, src, 502, cport, ss, cs + 1, 0x11); frame(src, dst, cport, 502, cs + 1, ss + 1, 0x10)
H = struct.pack
rd = (H('!BHH', 3, 0, 2), H('!BBHH', 3, 4, 1, 2))          # FC3 read, benign
fc = {5: (H('!BHH', 5, 1, 0xff00),) * 2, 6: (H('!BHH', 6, 1, 5),) * 2,
      15: (H('!BHHBB', 15, 0, 8, 1, 0xff), H('!BHH', 15, 0, 8)),
      16: (H('!BHHBHH', 16, 0, 2, 4, 1, 2), H('!BHH', 16, 0, 2)),
      22: (H('!BHHH', 22, 1, 0xf2, 0x25),) * 2,
      23: (H('!BHHHHBHH', 23, 0, 2, 1, 2, 4, 1, 2), H('!BBHH', 23, 4, 1, 2)),
      8: (H('!BHH', 8, 0, 0x1234),) * 2, 43: (H('!BBB', 43, 14, 1), None), 17: (H('!B', 17), H('!BBBB', 17, 2, 1, 255)),
      7: (H('!B', 7), H('!BB', 7, 0)), 99: (H('!BH', 99, 0), None)}
exc = (H('!BHH', 3, 0, 2), H('!BB', 0x83, 2))             # exception response from the RTU
flow(40001, '10.1.1.200', '10.1.1.101', [fc[6], fc[5]])                         # attacker writes rtu-1
flow(40002, '10.1.1.200', '10.1.1.102', [fc[15], fc[16], fc[22], fc[23]])      # attacker writes rtu-2
flow(41001, '10.1.2.50', '10.1.1.101', [rd, fc[6], fc[16]])                     # opc: reads + legit writes (no alert)
flow(41002, '10.1.2.50', '10.1.1.102', [rd, rd])                                # opc: reads only
flow(40003, '10.1.1.200', '10.1.1.101', [fc[8], fc[43], fc[17], fc[7], fc[99]]) # attacker: unusual function codes
flow(41003, '10.1.2.50', '10.1.1.102', [rd, exc, rd])                           # exception from rtu-2
with open('modbus-test.pcap', 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for n, p in pkts: f.write(struct.pack('<IIII', 1700000000 + n, 0, len(p), len(p)) + p)
print(len(pkts), 'packets -> modbus-test.pcap')
