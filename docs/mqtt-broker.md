# MQTT broker image (ww-ko6)

`mqtt-arm64.qc2` / `mqtt-amd64.qc2`: Ubuntu 24.04 noble minbase + the distro `mosquitto` 2.0.18 and
`mosquitto-clients` packages, unmodified (Eclipse Mosquitto, EPL-2.0 / EDL-1.0). Recipes `images/recipes/mqtt-{arm64,amd64}.env`,
build step `images/scripts/mqtt.sh`, build with `images/build.sh mqtt-arm64` (about 3 min, 1.0 GB qc2) or `mqtt-amd64`
(about 10 min under qemu-user, 1.0 GB qc2; built only, not booted). 4 GB disk, miniccc injected, systemd enabled.

## Use in the range
`gen_topology.py --mqtt` adds node `mqtt-broker`: ICS VLAN `10.1.1.60/24` (gw 10.1.1.1), mgmt `172.16.1.60/16`, 512 MB, 1 vCPU.
(10.1.1.0/24 holds the router .1 and the RTUs .101/.102; the SCADA historian's .60 is a different subnet, 10.1.2.60.)
`gen_scenario.py --mqtt` is accepted so one flag set drives both generators; the broker is not a sceptre host, so the
scenario output is identical. Default output of both generators is unchanged; `gen_topology.py [--mqtt] --self-test`
checks node count and duplicate addresses.

    gen_topology.py --mqtt > waterway-topology.yaml     # then px config create / exp create as usual

Clients: `mosquitto_pub -h 10.1.1.60 -t waterway/rtu-1/level -m 4.2`, `mosquitto_sub -h 10.1.1.60 -v -t 'waterway/#'`
(the broker image carries both; other range images do not).

## Config and lab-default security
`/etc/mosquitto/mosquitto.conf` (replaced: the distro one logs to an unbounded file and enables persistence) holds
`persistence false`, `log_dest syslog` and `include_dir conf.d`. `/etc/mosquitto/conf.d/ferrofire.conf` is regenerated at every
service start by `ExecStartPre=+/usr/local/sbin/ferrofire-mqtt-conf` from whatever files are present:

| Injected file | Effect |
| --- | --- |
| none | **LAB DEFAULT: `allow_anonymous true`, plaintext `listener 1883` on all interfaces, any host on the lab network can publish/subscribe.** |
| `/etc/mosquitto/passwd` (mosquitto_passwd file) | `password_file`, `allow_anonymous false` |
| `/etc/mosquitto/acl` | `acl_file` |
| `/etc/mosquitto/certs/{ca.crt,server.crt,server.key}` | extra TLS `listener 8883` (1883 stays on; firewall it or drop it by editing the script if TLS-only is wanted) |

Inject with phenix injections, or `cc send` + `systemctl restart mosquitto`. The script chowns/chmods injected secrets to
root:mosquitto 0640. Logs go to the journal, capped by `journald.conf.d/ferrofire.conf` (`SystemMaxUse=RuntimeMaxUse=32M`);
no log file or persistence db exists, so the broker cannot fill the disk (idle: 66 MB used of 450 MB RAM, 1.7 GB of 3.7 GB disk, mostly the base OS).

## Pointing a field device / ferrofire MQTT module at it
Host `10.1.1.60` (from the ICS VLAN; the SCADA VLAN reaches it through the router), port 1883 (8883 with TLS and a CA file),
no credentials in the lab default; set username/password once `passwd` is injected. Suggested topic root `waterway/<rtu>/<point>`;
retained messages work (below), so a device can publish last-known state with retain.

## Evidence (experiment `wwmqtt`, topology from `gen_topology.py --mqtt`, 10 VMs; stopped and deleted afterwards)
- Broker up: `systemctl is-active mosquitto` active, `ss -ltn` shows `0.0.0.0:1883` and `[::]:1883`; conf = the anonymous lab default.
- Cross-VM: `mosquitto_sub -v -t 'waterway/#'` on scada-server (10.1.2.71, via the router) printed
  `waterway/test hello-from-engineer` and `waterway/retained retained-1`, published by engineer-workstation (10.1.2.72).
  (Those two images lack the clients; static noble `mosquitto_pub/sub` + libs were `cc send`-ed to `/opt/mq` for the test.)
- Retained: a subscriber started after the publish (`mosquitto_sub -W 5 -C 1 -t waterway/retained` on scada-server) received `waterway/retained retained-1`.
- Capture: tcpdump on the broker, `docs/mqtt-broker.pcap` (CONNECT, SUBSCRIBE, PUBLISH QoS 0/1/2, retain flag, PUBACK/PUBREC/PUBREL/PUBCOMP, DISCONNECT).
  `tshark -r docs/mqtt-broker.pcap -Y _ws.malformed` returns 0 frames; `-Y mqtt` decodes 34 MQTT frames, topics and payloads readable.
- Lockdown (on the broker): injecting `passwd` + `acl` and restarting: anonymous publish -> `Connection Refused: not authorised`,
  `-u ff -P ffpass` ok. Injecting `certs/`: 8883 listens, publish with `--cafile ca.crt` ok, without the CA -> `Protocol error` (verify failure).
- Disk: no `/var/log/mosquitto`; `journalctl --disk-usage` 4.0 MB with the 32 MB cap configured.
- amd64: `images/build.sh mqtt-amd64` finished (BIOS/msdos qcow2, 1.0 GB); not booted.
