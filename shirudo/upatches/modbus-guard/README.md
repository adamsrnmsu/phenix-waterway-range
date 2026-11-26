# modbus-guard

An XDP upatch (`SEC("xdp/8")`: every virtio-net NIC) that makes a Modbus/TCP field device answer only well-formed
requests. Each IPv4 TCP segment to port 502 that carries data must hold one Modbus request: MBAP header plus a function
code (8 to 260 bytes), protocol id 0, MBAP length equal to the payload length minus 6, and function code 1, 2, 3, 4,
5, 6, 15 or 16. Anything else is dropped before the field device sees it, and so is every IPv4 TCP fragment (a
split request could hide a second ADU; non-first fragments carry no port). Other traffic passes. A `verdicts` array
counts passed / short / bad header / bad function code.

It is a shape guard, not authorisation: valid writes (FC5, FC6, FC16) from any peer still pass. Ceiling: one ADU per
segment; pipelined or split requests are dropped (reassembly needs a socket-level program).

Payload inspection was possible: shirudo allows XDP upatches, and XDP sees the packet bytes. The connection-level
fallback in the plan was not needed.

## Build, load, unload (pin 8c35953fa779; key = the shirudo-dev bundle's operator key)

```bash
# in shirudo-dev, from ~/git/shirudo, with $K the bundle's operator key dir
shirudo build modbus-guard.bpf.c --keys-dir "$K" --vmlinux vendor/linux/vmlinux.h -o modbus-guard.upatch
shirudo build --unload modbus-guard --payload-sha256 "$(shirudo upatch info --json modbus-guard.upatch | jq -r .payload_sha256)" \
  --keys-dir "$K" -o modbus-guard.unload.upatch
# on rtu-s (host-only SSH)
shirudo-runtime upatch load modbus-guard.upatch        # XdpCovered OK; ip -d link show ot: prog/xdp
shirudo-runtime upatch unload modbus-guard.unload.upatch
```
Current build (after the final review added the fragment and 260-byte checks): see SHA256SUMS. The first build
(r2-* runs) lacked both checks: a 302-byte PDU reached the server there.

## Result (docs/shirudo/raw/r4-before, r4-after, r4-unloaded; phases baseline write malformed fuzz)

| case | before | loaded | unloaded |
|---|---|---|---|
| FC5 coil / FC6 / FC16 writes | exc 2 / accepted / exc 2 | same | same |
| truncated MBAP, length > payload | server waits | server waits (dropped) | server waits |
| oversized PDU (302-byte FC16) | closed by server | dropped | closed by server |
| MBAP length 0 | closed by server | dropped | closed by server |
| FC 0x00 / 0x2B / 0x5A / 0x7F | empty-PDU reply | dropped | empty-PDU reply |
| 300 random Modbus PDUs | 288 resp, 12 exc | 0 resp, 293 timeout, 7 exc | 288 resp, 12 exc |
| master FC4 polling, 1 Hz | 0 errors | 0 errors | 0 errors |

Loaded: XdpCovered OK, program on mgmt, ot and prov (raw/r4-load.txt); unloaded: detached from all three
(raw/r4-unload.txt). The fragment rule is checked by code reading only (no fragment attack in the tools). shirudo
status stayed ok; the load and unload were measured into the TPM register. Suricata on purple still saw every attack
(the mirror copies frames before the guest), minus the server's replies.
