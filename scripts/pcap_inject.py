#!/usr/bin/env python3
"""Replay classic .pcap files as raw frames out of one interface (stdlib only, root, Linux).
usage: pcap_inject.py IFACE [--delay 0.0005] FILE.pcap...
Run in the Lima VM on a blue VM's capture tap (`mm vm info` / ovs list): the frames arrive in the guest as if received
on eth1, so Malcolm's live Zeek/Arkime see them with the current time (ww-otj.51)."""
import socket, struct, sys, time

def frames(path):
    with open(path, 'rb') as f:
        h = f.read(24)
        e = '<' if h[:4] in (b'\xd4\xc3\xb2\xa1', b'\x4d\x3c\xb2\xa1') else '>'
        while True:
            r = f.read(16)
            if len(r) < 16:
                return
            n = struct.unpack(e + 'IIII', r)[2]
            yield f.read(n)

if __name__ == '__main__':
    a = sys.argv[1:]
    iface = a.pop(0)
    delay = 0.0005
    if a[0] == '--delay':
        delay = float(a[1]); a = a[2:]
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((iface, 0))
    for p in a:
        n = 0
        for fr in frames(p):
            s.send(fr); n += 1; time.sleep(delay)
        print(f'{p}: {n} frames')
