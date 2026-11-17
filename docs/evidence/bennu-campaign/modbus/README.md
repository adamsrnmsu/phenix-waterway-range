# Modbus fixes: evidence (sceptre-bennu branch fix-modbus-request-validation)

Commits on upstream main cd3bb5b, one per bug:
- 7aa78bd `fix(modbus): reject FC15/FC16 requests shorter than their byte count`
- bcc610a `fix(modbus): scale holding and input registers independently`

BEFORE is upstream cd3bb5b and AFTER is the branch head. On the range both are native arm64 builds (`../tools/build-arm64.sh`), installed on rtu-1 and rtu-2 with `../tools/mkdeploy.sh`. `range-*/rtu1-state.txt` shows the installed bundle and the md5s.

## 1. Truncated FC15/FC16 is answered with success and writes heap bytes

`Request_Handler<WRITE_MULTI_REG/WRITE_MULTI_COIL>` reads the byte count and deserializes `quantity` values from offset 6 without checking `request.size()`. The only length gate is the 12-byte ADU minimum, which an FC03-sized frame already meets. A frame that declares 1 register and 2 data bytes but carries no data passes. `deserialize()` then reads past the end of the vector, writes those bytes to the tag, and returns a success echo. The byte-count check is done in `uint8_t`, so qty 128 with byte count 0 also passes the check.

Container test `test/modbus_write_validation.py`:
- Before (`container/4-before.log`): FC16 with no data gets `00010000000601109c400001` (success echo), and FC15 with no data gets a success echo too. FAIL.
- After (`container/4-after.log`): all 7 malformed frames get exception 03 and the holding register is unchanged. A valid FC16 still succeeds. PASS.

Range: kali (10.1.1.200) sends to rtu-1 10.1.1.101:502, script `../tools/ev-fc16.sh`.

| request (PDU) | BEFORE `range-before/fc16-kali.txt` | AFTER `range-after/fc16-kali.txt` |
|---|---|---|
| FC16 addr 40000 qty 1 bytecount 2, no data `109c40000102` | `00010000000601109c400001` success echo | `000100000003019003` exception 03 |
| FC16 qty 128 bytecount 0 `109c40008000` | `019002` exception 02, after the over-read | `019003` exception 03 |
| FC15 qty 1 bytecount 1, no data `0f0000000101` | `018f02` | `018f03` |
| well-formed FC16, 1 and 2 registers (`range-after/validwrite-kali.txt`) | n/a | success echo `109c400001` / `109c400002` |

- `range-before/fc16.pcap` frame 29: Wireshark decodes the FC16 request as `Byte Count: 2, Data: <MISSING>`. Frame 31 is the server's normal Write Multiple Registers response. See `range-before/fc16-decode.txt`.
- `range-after/fc16.pcap`: the same requests get `Exception returned`.

## 2. Holding and input registers at the same address share one scaling entry

`addHoldingRegister` and `addInputRegister` both write `mScaledValues[address]`. Holding and input registers are separate Modbus tables, so a device may map both at one address. When it does, the register registered later sets the range for both.

Container test `test/modbus_scale_separate.py`:
- Before: holding@100 (500 of 0..1000) reads 65531, want 32767. FAIL.
- After: it reads 32767. PASS.

Range (`../tools/ev-collide-rtu2.sh`): the stock range configs never map one address twice, so for this test rtu-2 runs its own config with one change. The holding register for `uppergate.open` moves from 40000 to 30000 and gets range 0..1. Input register 30000 (`upperwater.height`, range 0..1000) is unchanged. kali reads both after the provider reports `uppergate.open=1` (`../tools/ev-collide-kali.sh`).

| | BEFORE `range-before/collide-kali.txt` | AFTER `range-after/collide-kali.txt` |
|---|---|---|
| provider `upperwater.height` / `uppergate.open` | 15 / 1 | 15 / 1 |
| FC04 input 30000 (15 of 0..1000, want 983 = `03d7`) | `03d7` | `03d7` |
| FC03 holding 30000 (1 of 0..1, want 65535 = `ffff`) | `0041`, i.e. 1 scaled with the input register's 0..1000 range | `ffff` |

Full suite: `container/ctest.log` passes 35/35 (33 upstream tests plus the 2 new ones). Throughput (`container/throughput.log`) is 482.48 tag writes/s and 0.104 s per cycle, against the cd3bb5b baseline of 466.50 and 0.107. Range latency with each build deployed is in `../bench/README.md`.
