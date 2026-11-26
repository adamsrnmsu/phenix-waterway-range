# r1 notes (2026-11-25, pin 8c35953fa779, ferrofire 2026.11.15, parseus 1f39fb8, Suricata 8.0.8)

Attacker 10.1.1.66 (Kali alias), master 10.1.1.50 polling FC4 + DNP3 class 0 at 1 Hz throughout. kernel-obs loaded.

- recon: nmap saw 22/ssh, 502/mbap, 20000/dnp open (2-recon-nmap.txt).
- write: FC6 write of 1234 to holding register 40000 accepted (echo response); FC5 coil 0 and FC16 40000x3 got
  exception 2 (illegal data address). No authentication on writes: any peer on the OT VLAN can write.
- malformed: truncated MBAP and length>payload: server waits (timeout); oversized PDU and length 0: server closes.
  Unassigned function codes 0x00/0x2B/0x5A/0x7F: server answers with an MBAP header of length 1 and no PDU
  (000a0000000101), not exception 1 (illegal function): a protocol bug in ferrofire's Modbus server.
- dnp3: every connection from 10.1.1.66 was reset (operate, cold/warm restart, all 300 fuzz frames) while the master's
  session was open: the outstation takes one master session; DNP3 command handling was not exercised (gap).
- fuzz: Modbus 288 responses, 12 exceptions, 21 closes; DNP3 279 resets. Field device process unchanged (pid 627)
  through every phase; DNP3 and Modbus kept listening.
- ssh: hydra (from 10.1.1.50, not the alias) stopped at once: password authentication disabled (key-only root).
- tamper (root over the host-only SSH): all 8 refused (read pin, unpin kernel-obs, umount bpffs, unsigned bpf()
  load errno 13, forged upatch "payload_sha256 does not match signed content", archive write, runtime binary write
  on a read-only verity mount). Status stayed ok; counters LoadNotLoader 46, PinUnlink 45, BpffsUmount 1, ObjGet 1.
- Views: Suricata (local rules + its modbus/dnp3/decoder event rules) alerted on every write, the unassigned FCs it
  accepts (43, 90, 127; function 0 is not a valid rule value), DNP3 operate/cold/warm restart, non-master connects,
  and fuzz anomalies; parseus DPI counted modbus/dnp3 documents in every phase (parseus.tsv); kernel-obs's net table
  never listed 10.1.1.66 and showed the master's accepted session with count 0, so it did not attribute the OT attack
  traffic to a peer (cause not established); its priv table counted the root tamper bpf() attempts (8-tamper-kobs-priv).
- Isolation: rtu-s's QEMU user-net management NIC NATed outbound traffic (an NTP attempt to 185.125.190.121 in the
  fuzz window). Fixed after r1: restrict=on in topologies/shirudo-arm64 (egress blocked, SSH kept).
- Suricata timestamps alerts on reset flows at flow timeout (~60 s late); collect.sh attributes by flow.start.
- pcap, ssh phase window: 22 packets on tcp port 22 (hydra from 10.1.1.50; no packets from 10.1.1.66).

## Addendum (final review, 2026-11-25)
- The kernel-obs files in this run do not cover their phases: rtu-s's shirudo-map-export.timer drains every table about
  every 10 s, so each read after a phase held only the last seconds (every interval starts after its phase ended).
  The "kernel-obs did not record the attacker" observation above is wrong; it was the collection. Fixed in attack.sh
  (timer stopped during a run); see r3, where the attacker's accepts appear per phase.
- "Fuzz: Modbus ... 21 closed": the 21 closes were DNP3 frames; Modbus was 288 resp and 12 exc.
- The tamper phase is 7 refused attacks plus a pin listing (list_pins, rc=0), not 8 refusals.
- Suricata events were attributed by a window that dropped 15 edge events (guest clocks run ~1 s off); r3 uses
  collect.sh's last-started-phase attribution.
