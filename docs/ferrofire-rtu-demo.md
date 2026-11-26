# ferrofire RTU image on waterway: PEAT pull/push demo, seen in parseus

Run 2026-11-14 (bead ww-4uy.9) as a separate experiment `wwff`, so the `waterway` experiment and its
`waterway-arm64` configs stayed untouched. rtu-1/rtu-2 boot `ferrofire-rtu-arm64.qc2` (Buildroot, read-only root,
firmware and config on the data partition under `/home/sceptre`); the provider, OPC gateway, SCADA and HMI are the
usual DNP3 waterway. A kali-purple box (`--purple`) runs PEAT and parseus. Times are UTC.

## 1. Generators

`--ferrofire-rtu` (default off) in both generators: `gen_topology.py` sets the rtu-1/rtu-2 image to
`ferrofire-rtu-arm64.qc2` and drops the `ferrofire` / `ferrofire-fd-shim.sh` injections (the image carries ferrofire);
`gen_scenario.py` adds `firmware: ferrofire` to both RTUs, which makes the sceptre app write
`/usr/sbin/ferrofire-rtu-start /etc/sceptre/config.xml` as their start script (sceptre-phenix-apps branch
`feat-sceptre-ferrofire-firmware`).

Parity: outputs for `""`, `--dnp3`, `--dnp3 --purple`, `--dnp3 --mqtt --purple`, `--linux-fuxa --dnp3`, `--mqtt` are
byte-identical before and after the change, and `--dnp3` still equals the committed yaml. With the flag:

```
$ diff <(gen_topology.py --dnp3 --purple) <(gen_topology.py --dnp3 --purple --ferrofire-rtu)
253c253   -       - image: bennu-arm64.qc2   +       - image: ferrofire-rtu-arm64.qc2
278,286d277  (rtu-1 injections: ferrofire, ferrofire-fd-shim.sh removed)
296c287   (rtu-2 image, same)
321,329d311  (rtu-2 injections removed)
$ diff <(gen_scenario.py --dnp3) <(gen_scenario.py --dnp3 --ferrofire-rtu)
54a55 >         firmware: ferrofire
86a88 >         firmware: ferrofire
```

## Prereq: SCEPTRE app template (until sceptre-phenix-apps a49f919 ships)

The phenix container has phenix-apps 2026.10.30, whose `sceptre_start.mako` has no `firmware: ferrofire` branch, so
the RTUs would get the bennu start script (`bennu-watcherd ...`), which does not exist on the ferrofire image. The fix
is sceptre-phenix-apps a49f919 (`feat-sceptre-ferrofire-firmware`). Until a release has it, patch the two lines in by
hand rather than pip-installing the branch into the shared container, and put the file back afterwards.

```bash
T=/usr/local/lib/python3.12/dist-packages/phenix_apps/apps/sceptre/templates/sceptre_start.mako
limactl shell phenix sudo docker exec phenix sh -c "sha256sum $T; cp -p $T /root/sceptre_start.mako.orig"
limactl shell phenix sudo docker exec phenix python3 -c "
p='$T'; s=open(p).read(); a=\"    % elif name.lower() == 'field-device':\n\"
assert s.count(a) == 1
open(p,'w').write(s.replace(a, \"    % elif name.lower() == 'field-device' and metadata.get('firmware', '').lower() == 'ferrofire':\n/usr/sbin/ferrofire-rtu-start /etc/sceptre/config.xml\n\" + a))"
limactl shell phenix sudo docker exec phenix sha256sum $T
```
The patch inserts exactly these two lines before the bennu `field-device` branch (the same lines as a49f919):
```
    % elif name.lower() == 'field-device' and metadata.get('firmware', '').lower() == 'ferrofire':
/usr/sbin/ferrofire-rtu-start /etc/sceptre/config.xml
```
sha256: original `f2a2eff52186eaf3268d57bb7ec19d1c32fccd0ae41836c875e171c74074dd07`, patched
`ee4760586842625181352e794034e192ac9ed48c7e111d595eeb586003fae1e7`. (The installed file differs from upstream 6ce9fc4
only by upstream's `simulator == 'ferrofire'` provider branch, which waterway does not use.) Restore it after teardown
(section 7).

## 2. Start a separate experiment

New config names, so `waterway-arm64` is never overwritten. All commands here run on the Mac; `px` and `mm` are the
README aliases (`limactl shell phenix sudo docker exec phenix phenix ...` / `... minimega mm ...`):

```bash
cd topologies/waterway-arm64
mkdir -p ~/phenix/topologies/wwff
uv run -q --with pyyaml python -I gen_topology.py --dnp3 --purple --ferrofire-rtu \
  | sed 's/^  name: waterway-arm64$/  name: waterway-arm64-ff/' > ~/phenix/topologies/wwff/topology.yaml
uv run -q --with pyyaml python -I gen_scenario.py --dnp3 --ferrofire-rtu \
  | sed -e 's/^  name: waterway-arm64$/  name: waterway-arm64-ff/' -e 's/^    topology: waterway-arm64$/    topology: waterway-arm64-ff/' \
  > ~/phenix/topologies/wwff/scenario.yaml
px cfg create /phenix/topologies/wwff/topology.yaml
px cfg create /phenix/topologies/wwff/scenario.yaml
px exp create wwff -t waterway-arm64-ff -s waterway-arm64-ff
px exp start wwff
scripts/mirror.sh wwff purple 2      # purple's capture NIC is index 2
```

Generated start script: `/phenix/experiments/wwff/startup/rtu-1-start.sh` = `/usr/sbin/ferrofire-rtu-start /etc/sceptre/config.xml`.

PEAT on purple: the branch wheel goes in through minimega's cc file path (`/phenix/images`), then
`cc send file:<dir>/peat-2026.9.3.dev7+g775c378-py3-none-any.whl` and on purple
`/opt/peat/bin/pip install --no-deps --force-reinstall <wheel>`:

```
e16c611c7b11eb5ddd97677cd72dddfef9dff9d88ff1162933962e8649dcba61  .../peat-2026.9.3.dev7+g775c378-py3-none-any.whl
Successfully uninstalled PEAT-2026.2.11.dev40+gf4bdc81
Successfully installed peat-2026.9.3.dev7+g775c378
PEAT 2026.9.3
```

Gotchas hit on the way:
- Both RTUs report hostname `ferrofire-rtu` (the phenix hostname script fails on the read-only root), so
  `cc filter hostname=rtu-1` matches nothing; filter on the VM uuid from `mm namespace wwff .columns name,uuid vm info`.
- `cc delete command all` right after start also deletes the vrouter app's queued minirouter config if the router
  has not fetched it yet: the router came up with no addresses. Re-apply by forcing an IP change, since `router commit`
  only writes `ip add` lines when the IPs changed:
  `mm namespace wwff clear router router interface 2 172.16.1.1/16; mm namespace wwff router router interface 2 172.16.1.1/16; mm namespace wwff router router commit`.

## 3. Swap: SCADA/HMI still update, provider unchanged

rtu-1 after boot (cc exec):
```
aarch64
2: eth0    inet 10.1.1.101/24 scope global eth0
3: eth1    inet 172.16.1.101/16 scope global eth1
watch: firmware sha256=9084f760a1ce1939b1c0df0700ad454056296e4786df197cff0dcc17b9cbf3bd
watch: started pid=155
Info: dnp3-server: starting
Info: modbus-server: starting
tcp 10.1.1.101:502 LISTEN / tcp 10.1.1.101:20000 LISTEN / :::22, :::23 LISTEN
```
OPC gateway (polls the RTUs over DNP3), `uaread` on opc:
```
15:41:08  rtu-1.lock.height 11.25   rtu-1.boat.location 165.5   rtu-1.lowergate.open 0.0  rtu-2.upperwater.height 15.0
15:41:12  rtu-1.lock.height 13.275  rtu-1.boat.location 185.75
15:41:16  rtu-1.lock.height 14.775  rtu-1.boat.location 202.75
15:41:19  rtu-1.lock.height 15.0    rtu-1.boat.location 217.75
```
The HMI (`mm vm screenshot hmi`) showed the lock view live (boat.location 297.75, levels 5/15/15/15). Provider:
`bennu-simulink-provider --server-endpoint tcp://172.16.1.2:5555 --publish-endpoint udp://*;239.0.0.1:40000` and
`./simulinksolver -tf inf` on `bennu-arm64.qc2`, as in waterway.

## 4. Pull

On purple, `peat scan -i 10.1.1.101-102`:
```
| ssh | 22 | 8 | SCEPTRE SSH | SCEPTRE |  (also SCEPTRE Telnet on 23)
SSH connected to 10.1.1.101:22
Identification method 'ssh' from module 'SCEPTRE' succeeded for 10.1.1.101
Identification method 'ssh' from module 'SCEPTRE' succeeded for 10.1.1.102
Completed scan of 2 devices in 25.64 seconds (2 results)
```
`peat pull -d sceptre -i 10.1.1.101` pulled `ssh_files/config.xml` and `ssh_files/ferrofire.firmware`; from
`device-data-full.json`:
```
name = rtu-1   ip = 10.1.1.101
description.model = ferrofire
os = Buildroot
firmware sha256 = 9084F760A1CE1939B1C0DF0700AD454056296E4786DF197CFF0DCC17B9CBF3BD (/home/sceptre/ferrofire.firmware, 8772512 bytes)
logic.original = var_rtu-1_O40000 = 1*((var_rtu-1_I30005 == 1) && (var_rtu-1_I30004 == 1) && ...
tags = 24 | registers = 20 | io = 24
services = ftp/21 (closed: the RTU runs no FTP server), ssh/22, telnet/23, modbus/502, dnp3/20000
```

## 5. Modify and push

The changed constant is the first term of rtu-1's lower-gate logic, `var_rtu-1_O40000 = 1*((var_rtu-1_I30005 == 1) ...`
(open the lower gate for a boat coming up from downstream). O40000 is Modbus holding register 40000, scaled 0-1000
to 0-65535, so the command value 1 reads 65, 2 reads 131 and 3 reads 196.

(a) Config, constant 1 -> 2:
```bash
sed 's/var_rtu-1_O40000 = 1\*((var_rtu-1_I30005 == 1)/var_rtu-1_O40000 = 2*((var_rtu-1_I30005 == 1)/' config-orig.xml > config-6a.xml
peat push -d sceptre -t config config-6a.xml -i 10.1.1.101
```
```
438c438  <  var_rtu-1_O40000 = 1*((...   >  var_rtu-1_O40000 = 2*((...
15:48:55.705 | SCEPTRE | Pushed config.xml (15047 bytes) to 10.1.1.101 over ssh
rtu-1: cb4205463ad7cf0f39782f92864acf7c6085975baf6acd5f7448ce8da6f38b59  /home/sceptre/config.xml  (= config-6a.xml)
watch: restart: config changed
watch: firmware sha256=9084f760a1ce1939b1c0df0700ad454056296e4786df197cff0dcc17b9cbf3bd
watch: started pid=214
```
Put the file before `-i`: `-i` takes several hosts, so a file after it is read as a host and PEAT pushes stdin. The
first attempt (`peat push -d sceptre -t config -i 10.1.1.101 config-6a.xml`) pushed `config.xml (0 bytes)`; the device
then looped on `config is not valid XML` until the correct push 76 s later.

(b) Firmware: a shell script that rewrites the same constant to 3 in a copy of the config and runs the factory binary:
```sh
#!/bin/sh
cfg=/home/sceptre/config.xml; prev=
for a in "$@"; do [ "$prev" = --file ] && cfg=$a; prev=$a; done
sed 's/var_rtu-1_O40000 = [0-9]*\*((var_rtu-1_I30005 == 1)/var_rtu-1_O40000 = 3*((var_rtu-1_I30005 == 1)/' "$cfg" > /tmp/ff-mod-config.xml
exec /usr/bin/ferrofire field-device --file /tmp/ff-mod-config.xml
```
`peat push -d sceptre -t firmware ferrofire-mod.firmware -i 10.1.1.101`:
```
15:50:25.132 | SCEPTRE | Pushed ferrofire.firmware (537 bytes) to 10.1.1.101 over ssh
45bc93d0f6d9c2c67fbf7897bd507ba6e7ad51d3930013280cf7f2778d0a8242  /home/sceptre/ferrofire.firmware
9084f760a1ce1939b1c0df0700ad454056296e4786df197cff0dcc17b9cbf3bd  /usr/bin/ferrofire   (factory, unchanged)
watch: restart: firmware changed
watch: firmware sha256=45bc93d0f6d9c2c67fbf7897bd507ba6e7ad51d3930013280cf7f2778d0a8242
watch: started pid=241
  241 root  /usr/bin/ferrofire field-device --file /tmp/ff-mod-config.xml
/tmp/ff-mod-config.xml:var_rtu-1_O40000 = 3*
```
Reboot (15:52:09: `cc delete command all`, `cc exec reboot`, `cc delete command all` so it is not replayed). After it:
```
 15:52:59 up 0 min
watch: firmware sha256=45bc93d0f6d9c2c67fbf7897bd507ba6e7ad51d3930013280cf7f2778d0a8242
watch: started pid=147
cb4205463ad7...b59  /home/sceptre/config.xml        (6a config kept)
45bc93d0f6d9...242  /home/sceptre/ferrofire.firmware (6b firmware kept)
  147 root  /usr/bin/ferrofire field-device --file /tmp/ff-mod-config.xml
tcp 10.1.1.101:502 LISTEN / 10.1.1.101:20000 LISTEN
```
The OPC gateway read rtu-1 again afterwards (15:58:15 lock.height 10.925, boat.location 163.5, no poll failures).

## 6. See it in parseus

parseus decodes Modbus from traffic; it does not poll. A 1 Hz stdlib poller on purple (10.1.1.250) read rtu-1
holding 40000-40001 (FC3) and input 30000-30009 (FC4) for the whole run, and `tcpdump -ni eth2 'tcp port 502'` on
purple's mirror NIC captured it (15:45:59-15:54:22, 2688 packets, 0 dropped,
sha256 aed237fef6dc73da2ae4c6af821b96872800384d23c7980f4ee0d62f7a118ba2).

The poller, written to purple as `/root/cap/mbpoll.py` (args: RTU IP, seconds, output CSV of
`epoch,fc,addr,value`; it reconnects when the RTU restarts):
```python
# Modbus/TCP poller for parseus (it analyzes traffic, it does not poll): every 1 s read rtu-1 holding 40000-40001 (FC3)
# and input 30000-30009 (FC4); log "epoch,fc,addr,value" (client-side truth). Reconnects when the RTU restarts.
import socket, struct, sys, time
ip, dur, out = sys.argv[1], float(sys.argv[2]), open(sys.argv[3], "a", buffering=1)
def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise OSError("closed")
        b += c
    return b
s, tid, t0 = None, 0, time.time()
while time.time() - t0 < dur:
    try:
        s = s or socket.create_connection((ip, 502), timeout=3)
        for fc, addr, n in ((3, 40000, 2), (4, 30000, 10)):
            tid = (tid + 1) & 0xFFFF
            s.sendall(struct.pack(">HHHBBHH", tid, 0, 6, 1, fc, addr, n))
            _, _, ln = struct.unpack(">HHH", rx(s, 6)); body = rx(s, ln)
            if body[1] & 0x80: out.write("%.3f,%d,%d,EXC%d\n" % (time.time(), fc, addr, body[2])); continue
            for i, v in enumerate(struct.unpack(">%dH" % (body[2] // 2), body[3:3 + body[2]])):
                out.write("%.3f,%d,%d,%d\n" % (time.time(), fc, addr + i, v))
    except OSError as e:
        out.write("%.3f,ERR,%s\n" % (time.time(), e)); s and s.close(); s = None
    time.sleep(1)
```
Started before section 5 and stopped after the reboot (on purple, via `cc exec` as root):
```bash
mkdir -p /root/cap
nohup tcpdump -ni eth2 -s 0 -w /root/cap/wwff-mirror.pcap "tcp port 502" > /root/cap/tcpdump.err 2>&1 &
nohup python3 /root/cap/mbpoll.py 10.1.1.101 3600 /root/cap/mb.csv > /root/cap/mb.err 2>&1 &
# ... section 5: (a) config push, (b) firmware push, reboot ...
pkill -f mbpoll.py; pkill -INT tcpdump
```

**The decode and ingest were done out of band.** The parseus bundled in `kali-purple-parseus-arm64` (branch
`fix-docker-arm64-build`) has no Zeek DPI, so nothing on the stock box turns a pcap into register values. I used
parseus PR #4's branch `feat/zeek-ics-dpi` (79ffc95, `deploy/integrations/zeek`): its `parseus.zeek` script and its
`parseus.ingestors.zeek` ingestor. Zeek ran in the Lima VM; the ingest, datastore and query ran on purple.

1. pcap from purple to Lima with `cc recv` (minimega writes it under its cc file path). `mm` here and below is the
   README alias, run on the Mac (`limactl shell phenix sudo docker exec minimega mm ...`):
   ```bash
   mm namespace wwff clear cc filter
   mm namespace wwff cc filter uuid=<purple uuid>
   mm namespace wwff cc recv /root/cap/wwff-mirror.pcap
   # -> /phenix/images/wwff/miniccc_responses/<cmd id>/<purple uuid>/root/cap/wwff-mirror.pcap (sha256 aed237fe...8ba2)
   ```
2. Zeek in the Lima VM. Image `ff-zeek:latest` was already in the VM's docker: it is `zeek/zeek:9.0.1` (labels:
   version 9.0.1, The Zeek Project) plus one layer adding g++/make/cmake/libpcap-dev/tcpdump. `docker pull
   zeek/zeek:9.0.1` decodes the same, and so does the branch's own image (`docker build -t parseus-zeek:dev
   deploy/integrations/zeek`, `FROM zeek/zeek:9.0.1`). The script came straight from the branch; first it passed the
   branch's ground-truth check (`make_test_pcap.py`, then `--check` on the logs: `OK: 7 modbus rows, 26 dnp3 points match`).
   ```bash
   # Mac: script into the VM
   git -C ~/git/parseus show feat/zeek-ics-dpi:deploy/integrations/zeek/zeek/parseus.zeek \
     | limactl shell phenix sh -c 'mkdir -p /tmp/wwff-zeek/pcap /tmp/wwff-zeek/logs && cat > /tmp/wwff-zeek/parseus.zeek'
   # Lima VM: what the branch's entrypoint.sh / replay_pcap.sh run for ZEEK_PCAP
   sudo cp /phenix/images/wwff/miniccc_responses/*/*/root/cap/wwff-mirror.pcap /tmp/wwff-zeek/pcap/
   sudo docker run --rm -v /tmp/wwff-zeek/pcap:/pcap:ro \
     -v /tmp/wwff-zeek/parseus.zeek:/opt/parseus/zeek/parseus.zeek:ro -v /tmp/wwff-zeek/logs:/zeek/logs -w /zeek/logs \
     ff-zeek:latest zeek -C -r /pcap/wwff-mirror.pcap /opt/parseus/zeek/parseus.zeek "Log::default_rotation_interval=0sec"
   # -> modbus.log 1659 rows, modbus_detailed.log 1659 rows (831 for address 40000)
   ```
3. Logs and the ingestor module back onto purple through the cc file path (`/phenix/images/<dir>`), then `cc send`:
   ```bash
   # Lima VM
   sudo mkdir -p /phenix/images/wwff-cc
   cd /tmp/wwff-zeek/logs && sudo tar -czf /phenix/images/wwff-cc/zeek-logs.tgz modbus.log modbus_detailed.log conn.log
   # Mac: the branch's ingestor package
   mkdir -p /tmp/zing && git -C ~/git/parseus archive feat/zeek-ics-dpi src/parseus/ingestors/zeek | tar -x -C /tmp/zing
   tar -C /tmp/zing/src/parseus/ingestors -czf - zeek | limactl shell phenix sudo sh -c 'mkdir -p /phenix/images/wwff-cc && cat > /phenix/images/wwff-cc/zeek-ingestor.tgz'
   # Mac (mm alias), purple selected with cc filter uuid=<purple uuid> as in step 1
   mm namespace wwff cc send file:wwff-cc/zeek-logs.tgz file:wwff-cc/zeek-ingestor.tgz   # -> /tmp/miniccc/files/wwff-cc/ on purple
   ```
4. Ingest on purple: the branch's module mounted over the bundled image's `parseus/ingestors/zeek`, on the parseus
   compose network so `elasticsearch.local` resolves (the same URL `parseus_web` uses):
   ```bash
   F=/tmp/miniccc/files/wwff-cc; mkdir -p /root/cap/zeek-logs /root/cap/zing
   tar -xzf $F/zeek-logs.tgz -C /root/cap/zeek-logs; tar -xzf $F/zeek-ingestor.tgz -C /root/cap/zing
   # lab-only: the parseus image runs as a non-root user, so it needs to read the files and traverse /root.
   # On a box you keep, extract outside /root instead (e.g. /srv/wwff) and skip the chmod on /root.
   chmod -R a+rX /root/cap/zeek-logs /root/cap/zing; chmod a+x /root /root/cap
   docker run -d --name wwff_zeek_ingestor --network parseus_zebra_crossing \
     -e DATASTORE_HOST_URL=http://elasticsearch.local:9200 -e DATASTORE_TYPE=elasticsearch \
     -e INGESTOR_ZEEK_LOG_DIR=/zeek/logs -e INGESTOR_ZEEK_STATE_FILE=/tmp/zeek_state.json \
     -v /root/cap/zeek-logs:/zeek/logs:ro -v /root/cap/zing/zeek:/app/src/parseus/ingestors/zeek:ro \
     --entrypoint python parseus:1.0.0 -m parseus.ingestors.zeek
   sleep 25   # ingestor polls every 2 s; done when its state file reaches the log sizes:
   docker exec wwff_zeek_ingestor cat /tmp/zeek_state.json   # offsets 412594 (modbus_detailed) and 336371 (modbus) = file sizes
   docker exec parseus_web python -c "import urllib.request as u; print(u.urlopen('http://elasticsearch.local:9200/arkime_sessions3-parseus-zeek-*/_count?q=event.dataset:modbus_detailed').read().decode())"
   # {"count":1659,...}
   docker rm -f wwff_zeek_ingestor
   ```
5. parseus Registers API on purple (the bundled webapp, unchanged; no login needed for this endpoint):
   `curl -sk 'https://127.0.0.1/registers/query/?index=arkime_sessions3-parseus-zeek-*'` -> HTTP 200, 213354 bytes.

rtu-1 holding register 40000 from that response, as runs of equal values (`value xN first .. last`). The changed
values show up as **short pulses between zeros**. The gate command is non-zero only in a window of about 20 s while a
boat comes up from downstream (some phases give a single 1-2 s blip of 65). With the original logic it holds 65 for that
window (x21); after each push the new value appears in pulses of 2-4 s (x2-x4) that alternate with 1-2 s of 65 inside
the window. So this is a change in the pulse value (65, then 131, then 196), not a steady level:
```
summary: 08:23.848 timeline 15:45:59.097 - 15:54:22.945, 13 conversations, 462 timestamps
10.1.1.250->10.1.1.101 modbus_HR_40000: 462 points, min=0.0 max=196.0
       0 x22   15:45:59.097 .. 15:46:18.171      original logic: gate command 1 (65)
      65 x21   15:46:40.249 .. 15:46:59.319
       0 x62   15:47:00.321 .. 15:49:16.669      15:48:55 config push (6a)
      65 x2    15:49:17.672 .. 15:49:17.673
       0 x20   15:49:18.676 .. 15:49:37.746
     131 x3    15:49:38.749 .. 15:49:39.753      6a: first term now 2 (131)
      65 x2    15:49:40.755 .. 15:49:40.756
     131 x3    15:49:44.769 .. 15:49:45.773      (131/65 alternate while the boat enters)
       0 x81   15:49:58.820 .. 15:51:18.204      15:50:25 firmware push (6b)
     196 x3    15:51:40.331 .. 15:51:41.342      6b: first term now 3 (196)
      65 x2    15:51:42.345 .. 15:51:42.347
     196 x3    15:51:43.352 .. 15:51:44.360
       0 x70   15:52:00.474 .. 15:53:19.687      15:52:09 reboot
     196 x3    15:53:41.791 .. 15:53:42.801      after reboot: still 3 (196)
     196 x4    15:53:50.829 .. 15:53:53.839
       0 x23   15:54:01.866 .. 15:54:22.945
```
(abridged; every run is in the client-side poller log too, which matches). Input register 30002 (lowergate.open read
back from the provider) shows the same 65 / 131 / 196 pulses one poll later.

## 7. Teardown

```bash
scripts/mirror.sh wwff purple 2 --off
scripts/exp-down.sh wwff   # stop + delete, then checks minimega really holds no VMs (ww-585.39)
px cfg delete scenario/waterway-arm64-ff && px cfg delete topology/waterway-arm64-ff
mm clear namespace wwff
rm -rf ~/phenix/topologies/wwff     # and the cc scratch dirs under /phenix/images
# put the app template back, check it against the backup, then drop the backup
T=/usr/local/lib/python3.12/dist-packages/phenix_apps/apps/sceptre/templates/sceptre_start.mako
limactl shell phenix sudo docker exec phenix sh -c "cp -p /root/sceptre_start.mako.orig $T && sha256sum $T && cmp $T /root/sceptre_start.mako.orig && rm /root/sceptre_start.mako.orig"
```
Template after restore: `f2a2eff52186eaf3268d57bb7ec19d1c32fccd0ae41836c875e171c74074dd07`, equal to the original;
`cmp` against the backup was clean before the backup was removed. (`px`/`mm` in this section are the README aliases,
run on the Mac.)
`px exp list` afterwards: only `waterway` (not started). No image was installed or changed.
