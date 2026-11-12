# Blue-team evidence: PR #31 MITM with Malcolm live

## Run 3 (ww-ebo.10): all four detections live, query JSON saved (2026-11-09 UTC)

Setup: `mitm` (blue 24 GiB / 8 vCPU, kali-purple-arm64 from 20:10) started 05:19:24 UTC with the Lima host otherwise idle
(waterway and ign-* stopped). 22 of 22 Malcolm containers healthy by ~05:27 (+8 min), load average ~1.5. Mirror
`scripts/mirror.sh mitm blue 1` on 05:32:41; Zeek modbus docs were landing in OpenSearch (183 in 3 min) before the attack.

**Suricata fix.** The earlier "Duplicate signature" for all 9 `ics-mitm.rules` was a sid collision, not a double load: the
file is listed once in `rule-files`, but Malcolm ships `nsacyber/ELITEWOLF/SchweitzerEngineeringLaboratories.rules` with
sids 1000001-1001025, which overlap ours (1000001, 1000010-16, 1000020), so Suricata dropped our copies
(`8 rule files processed. 53384 rules successfully loaded, 9 rules failed`, 05:27:10). Our sids are now 9100001,
9100010-16 and 9100020. Proof after a live ruleset reload in the running blue (`suricatasc -c ruleset-reload-nonblocking`,
05:32:00): `8 rule files processed. 53393 rules successfully loaded, 0 rules failed, 0 rules skipped`. The reloaded file was
byte-identical to `images/malcolm-suricata/ics-mitm.rules`; `kali-purple-arm64` was then rebuilt so the sids are in the image.

| Event | Time (UTC) |
|---|---|
| `scorch -r 0` (ettercap ARP poison of rtu-1 <-> router) | 05:35:05 |
| one raw-socket Modbus/TCP FC6 write, kali 10.1.1.200 > rtu-1 10.1.1.101, register 40000 = 0 (RTU echoed it) | 05:36:03.3 |
| `scorch -r 1` (off) | 05:38:11 |
| `scripts/blue-evidence.sh -f 05:34:30Z -t 05:42:00Z` | ~05:50 (window ends 3 min after the attack) |

Saved query + result JSON: `docs/evidence/20261109-run3b/{queries,results}/` (`summary.txt` has the counts; the
`results/raw-cc-response.txt` is the unedited reply). Result per query:
* `01-arpspoof-notices`: **8** `ArpSpoof::Conflict` notices. 4 at 05:35:06-07, within 1-2 s of ettercap starting (10.1.1.1 and
  10.1.1.101 each claimed by the router/rtu-1 then by kali `60:ff:dd:7c:af:6a`, and back). 4 more at 05:37:18-40. As in Run 2,
  those are most likely Malcolm's offline Zeek pass over its netsniff pcaps (not separately verified).
* `02-zeek-modbus-by-src-dst`: 1830 modbus records in the window, 10.1.2.50 > rtu-1 922 / rtu-2 906 (incl. offline-pass
  duplicates) and **10.1.1.200 > 10.1.1.101: 2** (WRITE_SINGLE_REGISTER request + response, trans_id 2566, 05:36:04.128).
* `03-datasets-in-window`: modbus 1830, modbus_detailed 928, session 26, conn 16, notice 8, alert 1, known_modbus 5.
* `04-suricata-alerts`: **1** alert, `WATERWAY Modbus write to RTU from non-OPC host`, rule.id **9100001**, source 10.1.1.200,
  destination 10.1.1.101:502, 05:36:04.131. Exactly the one forged write; the OPC polling raised none.
* `05-arkime-tcp502-sessions`: 14 Arkime sessions (event.provider arkime, tcp, port 502): the kali > rtu-1 session
  10.1.1.200:40542 (9 packets, first 05:36:04.125, saved by Arkime at 05:37:17, 73 s later, with `tcpSaveTimeout=90`; Run 2 needed
  12 min), plus opc 10.1.2.50 > rtu-1/rtu-2 long-lived sessions saved every ~90 s (270 packets each).

Screenshots (blue VM Firefox, `mm vm screenshot`; time range 05:34-05:42 UTC): `docs/shots/malcolm-run3-suricata-alert.png`
(Suricata Alerts dashboard: 1 alert, "WATERWAY Modbus write to RTU from non-OPC host"), `docs/shots/malcolm-run3-arp-notices.png`
(Zeek Notices: ArpSpoof / Conflict, 8), `docs/shots/malcolm-run3-modbus.png` (Modbus dashboard: 1952 modbus records, MODBUS_CLIENT
10.1.1.200 observed), `docs/shots/malcolm-run3-arkime.png` (Arkime sessions: suricata alert row + arkime session
10.1.1.200:40542 > 10.1.1.101:502 at 05:36:04, and the opc sessions).

Caveats: (a) The first `blue-evidence.sh` runs used `network.transport:tcp`, which Arkime docs do not have (they carry
`ipProtocol`), and the script's regex missed the `lima-phenix:` prefix on the first section; both fixed in the script. It
also re-sends a cached script when `-r` run ids repeat (cc does not overwrite delivered files): always pass a fresh run id.
(b) The Zeek notice/modbus counts include Malcolm's offline pass duplicates, so absolute numbers run ~2x Run 2's. (c) The
Suricata alert fires on the forged write's source IP; the MITM relay itself keeps the OPC source IP at L3, so relayed
writes would not alert (documented in the rules file). (d) Experiment stopped, mirror off at 06:10.

---

## Run 2 (ww-ebo.9): live detection, no re-ingest (2026-11-09 UTC)

Setup: Lima 16 vCPU / 80 GiB; `mitm` re-created from `topologies/mitm-arm64/mitm-topology.yaml` with blue at
20 GiB / 8 vCPU (kali-purple-arm64 built 18:19 with Logstash 2g and the `ArpSpoof` Zeek script). Started 01:58:20
UTC; cc client up in under 1 min, Docker images loaded, 21 of 22 containers healthy at +10 min (Logstash last).
Mirror `scripts/mirror.sh mitm blue 1` on at ~02:09; Zeek modbus records were in OpenSearch within 1 min
(485 docs at 02:10), so the pipeline was flowing 5 min before the attack. Nothing was re-ingested or copied.

| Event | Time (UTC) |
|---|---|
| `scorch -r 0` (ettercap on) | 02:14:42 |
| `scorch -r 1` (off) | 02:17:36 |

Result: **detected live.**
* Zeek notice `ArpSpoof::Conflict` x4 at 02:14:42-43, within 1 s of ettercap starting, in `arkime_sessions3-*`
  (`event.dataset: notice`): 10.1.1.1 claimed by router `00:04:3c:5b:ce:d4` then kali `00:10:5b:d9:ad:9b`
  (and back), 10.1.1.101 claimed by rtu-1 `00:11:9b:d3:71:b4` then kali (and back). Seen at 02:16:28, mid-attack.
  Malcolm's own offline Zeek pass over its netsniff pcaps later added 4 more copies of the same notice (02:16:32-45).
* Zeek modbus: 726 `modbus` + 367 `modbus_detailed` records in the attack window (02:14:40-02:17:40),
  opc 10.1.2.50 to rtu-1 (557 docs) and rtu-2 (546). 762 modbus rows in the Arkime view 02:14:30-02:17:40.
* Arkime (live capture): ICMP 10.1.1.1 > 10.1.1.101 (4 pkts) at 02:14:42, the ettercap start; tcp/502 sessions
  10.1.2.50 > 10.1.1.101 and > .102 (first packet 02:09:06, partial saves at 02:21:07 and 02:26:37 per
  `tcpSaveTimeout=720`) span the window. Sessions for a long-lived connection appear only after the 12 min save
  timeout, so the Arkime rows showed up ~4 min after the attack ended, not during it.
* Suricata: engine started 02:07:14 (before the attack), 53,384 rules, `eve.json` 0 bytes: **no alerts**. ET Open has
  no ARP-spoof rule, and none was added.
* Logstash: no `OutOfMemoryError`; free memory at the end 2 GiB available, no swap.

Screenshots (blue VM Firefox, `mm vm screenshot`): `docs/shots/malcolm-live-arp-notice.png` (Zeek Notices:
ArpSpoof / Conflict, 4), `docs/shots/malcolm-live-arkime-sessions.png` (Arkime sessions, provider arkime),
`docs/shots/malcolm-live-zeek-modbus.png` (Zeek modbus rows in the window), `docs/shots/malcolm-live-overview.png`.
Experiment stopped at the end; waterway (9 VMs) kept running.

Caveats: the notice `event.ingested` shows 02:17:03 although it was queryable at 02:16:28 (same doc IDs reprocessed).
First real-capture test of the ARP script. The 4-notice count is per direction per IP, by design (`ArpSpoof::window`).

---

# Run 1 (ww-ebo.6): superseded by run 2; kept for the resource failure analysis


Bead: ww-ebo.6. Setup: `topologies/mitm-arm64` with the `blue` VM (kali-purple-arm64, Malcolm v26.10.0),
`scripts/mirror.sh mitm blue 1` ON (mirror `mir-mitm`, per-port mirror of every non-MGMT tap into blue's eth1).
Attack as in `docs/mitm-evidence.md`: `phenix experiment scorch mitm -r 0` (ettercap ARP poison of rtu-1 <-> router
from kali), left running 2m35s, then `-r 1`. Times are UTC (guest clock).

| Event | Time (UTC) |
|---|---|
| `scorch -r 0` (attack on) | 22:09:59 |
| `scorch -r 1` (attack off) | 22:12:35-41 |

Verdict: **Malcolm captured the attack traffic and its Zeek/Arkime data show the Modbus polling of rtu-1/rtu-2 in the
attack window; nothing in Malcolm flagged the ARP spoofing.** Zeek, Suricata and Arkime have no ARP-spoof detection out
of the box here (no Zeek `weird`/`notice` for it, no Suricata alerts). The spoof is visible only in the raw capture
(two MACs for one IP), shown below. A custom Zeek/Suricata rule would be needed to alert on it.

## 1. What went wrong first (read before trusting the numbers)

Blue has 16 GiB and 6 vCPU, and the whole Lima VM was running 16 guests. During and right after the attack the
Malcolm stack was still thrashing from first boot (load average 90-100):

* Suricata only finished loading its 53k rules and started capturing at 22:10:42, 43 s into the attack, and
  `eve.json` stayed empty (0 events, 0 alerts) for the whole session.
* Arkime-live and the first pcap imports were not up in time, so **no Arkime sessions existed for the window** at first.
* Logstash (`-Xmx1g`) hit `java.lang.OutOfMemoryError` loading the `zeek-parse` pipeline, so no Zeek log reached
  OpenSearch (`event.dataset` only ever showed `session`). Fixed by raising LS to 2g in the running VM and in
  `images/malcolm-stage.sh` (the image itself is NOT rebuilt; see Follow-ups).
* That raised memory use to ~14.6 GB and the blue guest hung (cc client lost). I reset it (QMP `system_reset`; disk
  kept), then stopped the `*-live` capture containers (zeek-live, suricata-live, arkime-live, pcap-capture, about
  4.5 GB) to let Logstash and Zeek ingestion finish.
* The attack-window pcaps Malcolm itself had captured on eth1 (`pcap/processed/mnetsniff-eth1_1794175387.pcap` and
  `..._1794175996.pcap`, 22:03:07-22:23:30) were copied back into `pcap/upload/` as
  `mitm-attack-a,mitm-ettercap,reingest.pcap` / `-b` so Malcolm's Arkime and Zeek indexed them (tags `attack`, `mitm`,
  `ettercap`, `reingest`). So the Arkime sessions and Zeek logs below come from Malcolm's own capture of eth1,
  re-ingested after the fact, not from live-indexing during the attack.

## 2. ARP spoofing: raw evidence (not detected by Malcolm)

Poisoned caches during the attack (cc `arp.sh`, 22:10:29-34). Kali's MAC is `30:fb:b8:1e:f9:31`:
```
rtu-1:  10.1.1.1   dev eth0 lladdr 30:fb:b8:1e:f9:31 REACHABLE   # router's IP, kali's MAC (router really 00:07:e3:ad:5b:13)
router: 10.1.1.101 dev eth1 lladdr 30:fb:b8:1e:f9:31 REACHABLE   # rtu-1's IP, kali's MAC (rtu-1 really 00:0b:42:ff:d5:85)
kali:   10.1.1.1 -> 00:07:e3:ad:5b:13, 10.1.1.101 -> 00:0b:42:ff:d5:85                    # kali knows the real MACs
```
The same conflict in blue's capture (`tcpdump -nn -e -r mnetsniff-eth1_1794175387.pcap arp`, ARP replies by
sender IP and MAC, 22:03-22:13):
```
 9  10.1.1.1   is-at 00:07:e3:ad:5b:13  first 22:10:06 last 22:12:37   (router, real)
19  10.1.1.1   is-at 30:fb:b8:1e:f9:31  first 22:10:06 last 22:12:31   (kali, spoofed)
25  10.1.1.101 is-at 00:0b:42:ff:d5:85  first 22:03:30 last 22:13:03   (rtu-1, real)
19  10.1.1.101 is-at 30:fb:b8:1e:f9:31  first 22:10:06 last 22:12:31   (kali, spoofed)
```
Same IP, two MACs, kali's appearing from 22:10:06 to 22:12:31 only: the poison window. Modbus frames for
10.1.2.50 -> 10.1.1.101 on the ICS segment, by L2 pair:
```
275 router(00:07:e3:ad:5b:13) > rtu-1(00:0b:42:ff:d5:85)   direct, before and after
 71 router(00:07:e3:ad:5b:13) > kali(30:fb:b8:1e:f9:31)     redirected into kali
 71 kali(30:fb:b8:1e:f9:31)   > rtu-1(00:0b:42:ff:d5:85)    relayed on
```
71 packets each way via kali: the MITM relay, seen from a passive mirror.

## 3. What Malcolm did see

Zeek (raw `modbus` log in `zeek-logs/current`, and in OpenSearch via the Malcolm API
`GET /mapi/agg/event.dataset?from=1794175799&to=1794175955`, i.e. 22:09:59-22:12:35):
```
[('modbus', 138), ('modbus_detailed', 71), ('conn', 2), ('session', 2)]
modbus by source > destination:  10.1.2.50 > 10.1.1.101: 72    10.1.2.50 > 10.1.1.102: 66
1794175802.563997  10.1.2.50:46458 > 10.1.1.101:502  READ_INPUT_REGISTERS REQ
1794175803.354233  10.1.2.50:44178 > 10.1.1.102:502  READ_INPUT_REGISTERS REQ / RESP
```
The raw log and OpenSearch agree (138 entries). Opc <-> rtu-1 tcp/502 is visible in the window. Zeek does not
distinguish attacked from unattacked polls: the poll content is identical, only the L2 path differs.

Arkime sessions for tcp/502 covering the window (Malcolm Arkime API, 22:03-22:23):
```
22:03:08-22:13:17 10.1.2.50:46458 > 10.1.1.101:502  678 pkts  tags attack,mitm,ettercap,reingest,incomplete-tcp
22:03:08-22:13:14 10.1.2.50:44178 > 10.1.1.102:502  668 pkts
22:13:17-22:23:30 10.1.2.50:46458 > 10.1.1.101:502  948 pkts   (continuation, pcap b)
22:10:06-22:10:07 10.1.1.1 > 10.1.1.101 icmp  4 pkts   (ettercap-related ICMP at poison start)
```
(There are duplicate session rows because the same pcaps were indexed twice, from `upload` and from the earlier live
pass; OpenSearch showed 5-7 rows for the window.) The sessions are `incomplete-tcp` because they were long-lived and
begun before capture.

Screenshot from the blue VM, Arkime Sessions with `port.dst==502 && starttime in [22:09:50, 22:12:40]`, showing the
Zeek `modbus` / `modbus_detailed` records, opc 10.1.2.50 to rtu-1/rtu-2:
`docs/shots/malcolm-arkime-mitm.png` (landing page: `docs/shots/malcolm.png`).

## 4. What Malcolm did not flag

* Zeek `weird`, `arp`: no entries in the window (raw logs: `weird 0`, `arp 0`). Zeek has no ARP-spoof detector.
* Zeek `notice`: only `LongConnection::found` (10.1.2.50 -> 10.1.1.102:502, alive over 10 min). Nothing attack-specific.
* Suricata: `eve.json` had 0 events, 0 alerts, and the engine started at 22:10:42. ET Open has no ARP-spoof signature
  anyway; even a healthy Suricata would not alert on this ruleset.
* Arkime: no ARP detail (it shows IP sessions); the 4-packet ICMP row at 22:10:06 is the only IP-layer trace of the start.

## Follow-ups

* Rebuild kali-purple-arm64 with Logstash 2g (the `malcolm-stage.sh` change is made but the image is not rebuilt) and
  give blue 20 GiB, as the ww-ebo.2 notes recommended. 16 GiB plus 16 other guests thrashes for ~25 min at boot
  and the guest hung once.
* Add an ARP-spoof detection (Zeek script or Suricata rule) if the blue team should alert on it.
* Mirror dups: traffic crossing the router is seen once per segment (documented in README section 5).
* The mitm experiment is stopped and blue's disk (with the reingested data) is discarded on stop; waterway kept 9 VMs.
