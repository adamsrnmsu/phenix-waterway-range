#!/usr/bin/env python3
# Writes ./arp-clean.pcap and ./arp-attack.pcap (no scapy needed) for testing arp-spoof.zeek.
# MACs are the real ones from docs/mitm-evidence.md. The docs/mitm-capture.pcap itself is filtered to tcp/502 (no ARP).
import struct
def mac(s): return bytes(int(x,16) for x in s.split(':'))
def arp(op,smac,sip,tmac,tip,ethdst):
    ip=lambda s: bytes(map(int,s.split('.')))
    return mac(ethdst)+mac(smac)+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,op)+mac(smac)+ip(sip)+mac(tmac)+ip(tip)
R,T,K='00:e0:28:c2:a3:8c','04:96:45:fe:97:22','24:c0:b3:18:83:27'  # router, rtu-1, kali
def w(fn,pk):
    with open(fn,'wb') as f:
        f.write(struct.pack('<IHHiIII',0xa1b2c3d4,2,4,0,0,65535,1))
        for t,p in pk: f.write(struct.pack('<IIII',1700000000+t,0,len(p),len(p))+p)
clean=[(0,arp(1,'00:11:22:33:44:55','10.1.1.50','00:00:00:00:00:00','10.1.1.1','ff:ff:ff:ff:ff:ff')),
 (1,arp(2,R,'10.1.1.1','00:11:22:33:44:55','10.1.1.50','00:11:22:33:44:55')),
 (2,arp(2,T,'10.1.1.101','00:11:22:33:44:55','10.1.1.50','00:11:22:33:44:55')),
 (60,arp(2,R,'10.1.1.1',T,'10.1.1.101',T)),(61,arp(2,T,'10.1.1.101',R,'10.1.1.1',R))]
attack=clean+[(120,arp(2,K,'10.1.1.1',T,'10.1.1.101',T)),(120,arp(2,K,'10.1.1.101',R,'10.1.1.1',R)),
 (125,arp(2,K,'10.1.1.1',T,'10.1.1.101',T)),(125,arp(2,K,'10.1.1.101',R,'10.1.1.1',R))]
w('arp-clean.pcap',clean); w('arp-attack.pcap',attack)
