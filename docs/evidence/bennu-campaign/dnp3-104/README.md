# DNP3 / IEC-104 fixes: before/after on the live arm64 bennucamp range

Branch fix-dnp3-104-commands (a39c7d2, 263e8ff, cc56e96). BEFORE = bundle bennu-cd3bb5b-arm64 (unfixed upstream),
AFTER = bennu-dnp3-104-cc56e96-arm64, both installed on rtu-1 and rtu-2 via `SEND=<bundle> ccrun.sh <host> deploy-<bundle>.sh 30`
(`range-*/state-rtu-*.txt` show /etc/bennu-bundle and md5s). The Modbus field device kept running throughout;
all extra field devices were started as `bennu-field-device --f <xml>` and killed at the end of each phase.
Both phases are produced by one script: `../tools/ev-dnp3-104-phase.sh before|after` (helpers ev-dnp3-*.sh, ev-104-*.sh, ev-dnp3-master.py, ev-104-master.py;
configs = the data/configs/ep XMLs with endpoints rewritten by sed to 10.1.1.102 / new ports, multicast input and provider output
pointed at unused ports 239.0.0.9x:49xxx / 127.0.0.1:5xxx so nothing real is touched; the provider is simply not there, same as the container tests).
The masters are the container tests' raw-frame python code with the host/port parametrised (ev-dnp3-master.py from test/dnp3_ao_variations.py,
ev-104-master.py from test/iec104_ioa_alias.py). Pcaps were taken with tcpdump on the sending host; tshark checked on the Mac.
Files per phase: range-before/, range-after/.

## 1. DNP3 AnalogOutput Int32/Int16/Double64 (a39c7d2, ww-bb5.6)
Topology: outstations on rtu-2 10.1.1.102:20997 (direct-operate AO idx 1) and :20998 (same AO with `<sbo>1</sbo>`); master = kali 10.1.1.200 across the net.
Command: `ev-dnp3-kali.sh` on kali = `python3 ev-dnp3-master.py 10.1.1.102 20997 0` then `... 20998 1`. Logs: `dnp3-kali.txt`, rtu-2 outstation logs `dnp3-rtu2-stop.txt`.
Each variation (g41v1 Int32, g41v2 Int16, g41v4 Double) is sent as direct operate (FC5) to idx 99 (nonexistent) and idx 1, followed by g40v1 readback; Float32 idx 99 is the reference.

| line (dnp3-kali.txt) | BEFORE | AFTER |
|---|---|---|
| `sbo=False Int32 g41v1 idx99 status=` (Float32 reference 12 OUT_OF_RANGE) | 0 (SUCCESS, never applied) | 12 |
| `sbo=False Int32 g41v1 idx1 direct operate status=..readback=` | status=0 readback=0 | status=0 readback=77 |
| same for Int16 / Double | status=0 readback=0 | status=0 readback=77 |
| `sbo=True ... idx1 direct operate` (SBO point, want NO_SELECT=2) | status=0 readback=0 | status=2 readback=0 |
| verdict line | `FAIL:` (6 findings per port) | `PASS` on both ports |

Pcap `dnp3.pcap` (kali side, both ports, tcp filter host 10.1.1.102): FC5 requests 10.1.1.200 -> :20997 (g41 = bytes `29 01 17 01 63 4d000000` etc.) and the responses.
Decisive frame: response to g41v1 idx 99, payload `...2901 17 01 63 4d000000 <status>`: BEFORE frame 6 status byte 00, AFTER 0c (12). The g40v1 readback response
(`28 01 00 01 01 ..`): BEFORE `01 00000000` (value 0), AFTER `01 4d000000` (value 77). tshark: `tshark -r dnp3.pcap -d tcp.port==20997,dnp3 -Y 'tcp.srcport==20997 && tcp.len>0' -T fields -e frame.number -e tcp.payload`.

## 2. IEC-104 24-bit IOA truncated to 16 bits (263e8ff, ww-bb5.9)
Topology: 104 server on rtu-2 10.1.1.102:25405 (`/tmp/ev-104-25405.xml`, double subtype, direct operate), raw master on kali. IOA 0 is a configured binary output; 65536 is not configured.
Command: `ev-104-master-kali.sh` on kali = `python3 ev-104-master.py 10.1.1.102 25405` (C_SC_NA_1 ON to IOA 65536, then IOA 0). Files `104-ioa-kali.txt`, `104-rtu2-stop.txt` (server log).

| | BEFORE | AFTER |
|---|---|---|
| master output | `IOA 65536 ACT_CON negative=False; IOA 0 ACT_CON negative=False` | `IOA 65536 ACT_CON negative=True; IOA 0 ACT_CON negative=False` |
| server log (rtu-2) | `IOA: 0 switch to 1` twice, `switch-to count on 25405: 2` | once, `switch-to count on 25405: 1` |

Pcap `104-ioa.pcap` (kali side, port 25405): `tshark -r 104-ioa.pcap -d tcp.port==25405,iec60870_104 -Y 'iec60870_asdu.typeid==45 && ip.src==10.1.1.102' -T fields -e frame.number -e iec60870_asdu.causetx -e iec60870_asdu.nega -e iec60870_asdu.ioa`
BEFORE: frames 22 (ACT_CON, nega=False, ioa 65536), 23 (ACT_TERM), 27/28 for IOA 0. AFTER: frame 21 ACT_CON nega=True for 65536, no ACT_TERM, then 27/29 normal for IOA 0.
(The "write" is visible in the server log, not on the wire: the wire shows the positive vs negative confirmation.)

## 3. IEC-104 client ignores periodic binary ASDUs (cc56e96, ww-bb5.10)
Topology: servers on rtu-2 10.1.1.102:25407 (subtype double, reverse-polls M_DP_TB_1) and :25408 (subtype single, M_SP_NA_1), rpoll-rate 1 s;
stock 104 client field device on rtu-1 (`/tmp/ev-104cl-<port>.xml`, endpoint rewritten to the rtu-2 server, command-interface 127.0.0.1:2<port>), 9 s per server.
Command: `ev-104-client-rtu1.sh` on rtu-1; evidence = client log lines `IOA: 100 value:` as in test/iec104_client_binary_updates.py. Files `104-client-rtu1.txt` (counts + first 40 log lines), `104-client.pcap` (rtu-1 side, ports 25407/25408).

| | BEFORE | AFTER |
|---|---|---|
| double server, "IOA 100 value lines" | 1 (only the interrogation response, `M_DP_NA_1(3)`) although 36 `M_DP_TB_1(31)` ASDUs were received | 10 |
| single server, "IOA 100 value lines" | 0 although 10 `M_SP_NA_1(1)` received (not even the interrogation shows IOA 100) | 10 |

Pcap: the periodic binary ASDUs do reach rtu-1 in both phases (tshark, server->client typeids: 31 and 1 present in before AND after), so the pcap is the proof that the data
is on the wire and the log difference is client-side decoding: `tshark -r 104-client.pcap -d tcp.port==25407,iec60870_104 -d tcp.port==25408,iec60870_104 -Y iec60870_asdu.typeid -T fields -e tcp.srcport -e iec60870_asdu.typeid | sort | uniq -c`.
The wire is identical between phases (the fix is purely in the client); the pcap alone cannot show the bug, the client log lines do.
The client's tag value is not read via its command interface (the test does not, and the servers have no provider so values stay 0/idle); "IOA: 100 value:" log lines are the decoded updates.

## Caveats
- Binary values never change (no simulink provider/multicast data for the extra devices), so "update" means the client decoded the periodic ASDU and logged it, not that a changing value propagated.
- Evidence of "applied/not applied" for DNP3 is the g40v1 readback over the network; for 104 it is the server-side log (`switch to`) retrieved from rtu-2.
- Final state: rtu-1 and rtu-2 run the AFTER bundle, Modbus field device on :502, no extra processes.
