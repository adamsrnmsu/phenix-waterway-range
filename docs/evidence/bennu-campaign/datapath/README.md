# Data-path fixes: evidence (sceptre-bennu branch fix-datapath-value-validation)

Commits on upstream main cd3bb5b, one per bug:
- 4337188 `fix(field-device): keep a point's configured type when a provider publishes another type`
- 9db6bb1 `fix(distributed): last value wins and malformed points reject a provider WRITE`
- ca93009 `fix(comms): reply ERR to a non-numeric CommandInterface WRITE instead of aborting`
- 4916cf2 `fix(comms): read CommandInterface and Provider requests by size, not up to a NUL`
- 1c7b11b `fix(field-deviced): treat a pidfile whose process is gone as stale`

BEFORE is upstream cd3bb5b and AFTER is the branch head. On the range both are native arm64 builds installed on simulink-provider, rtu-1 and rtu-2.

## 1. A wrong-typed provider value kills the field device

`InputModule` picks the stored type from the value text: `true`/`false` are stored as bool, anything else as double. `DataStore::setData` replaces the `std::variant` without checking the point's configured type. On the next scan, `getData<double>` calls `std::get` on a bool alternative, and the `bad_variant_access` it throws is never caught on the scan thread, so the process terminates. Any host that can send to the provider's multicast group (UDP 239.0.0.1:40000) can stop an RTU this way.

Container (`container/0-*.log`, `test_unit_datastore`):
- Before: `CHECK_NOTHROW( store.getData<double>("ana") ) THREW exception: "std::get: wrong index for variant"`.
- After: the value is coerced to the configured type (`true` becomes 1.0 on an analog point), and the test passes.

Range: kali joins the MGMT net and sends datagrams that look like the provider's. It learns the ZMQ group from one real datagram, then sends `lowersensor.active:true,` 500 times over 10 s. On rtu-1 `lowersensor.active` is `<analog>` and is read by the RTU logic. Script `../tools/ev-typecrash.sh`.
- BEFORE, daemon (`range-before/typecrash-*.txt`): port 502 refuses connections after the burst, and no field-device process is left.
- BEFORE, foreground run of the same binary so its stderr is kept (`range-before/fg/`, `../tools/fd-fg.sh`): `terminate called after throwing an instance of 'std::bad_variant_access'  what(): std::get: wrong index for variant`. Reproduced 3 of 3 times.
  - `range-before/fg/typecrash.pcap` holds the forged datagrams, then `RST, ACK` from 10.1.1.101:502 to every later Modbus connect.
- AFTER (`range-after/`): rtu-1 keeps answering Modbus during and after the burst. While the forged values arrive, input register 30004 reads `0x0041` (1.0 of 0..1000, the coerced `true`). Once the real provider value is back it reads `0x0000`.

## 2. Provider WRITE: malformed points are dropped and the batch is still ACKed; a duplicate tag keeps the first value

`Provider::messageHandler` collects points with `unordered_map::insert`, so the first value of a repeated tag wins. A point without `:` is printed and skipped, and `write()` and its ACK still run, even when no valid point is left.

Container (`container/3-*.log`, `test_unit_distributed`):
- Before: `WRITE=a:1,a:2` applies a=1. `WRITE=a:1,b`, `WRITE=junk` and `WRITE=` all get ACK, and write() is called.
- After: the last value wins. Those three requests get `ERR=Malformed WRITE payload` and write() is not called. A trailing comma (`p1:10,p2:20,`) still gets ACK.

Range: kali to the stock bennu-simulink-provider at tcp://172.16.1.2:5555, using a raw ZMTP REQ client (`../tools/zreq.py`; kali has no pyzmq). Script `../tools/ev-provwrite.sh`. pcaps: `range-*/provwrite.pcap`.

| request | BEFORE | AFTER |
|---|---|---|
| `WRITE=lowervalve.open:0,no-colon-here` | `ACK=Updated tags in Simulink provider` | `ERR=Malformed WRITE payload` |
| `WRITE=junk` | `ACK=Updated tags in Simulink provider` | `ERR=Malformed WRITE payload` |

Not shown on the range: the duplicate-tag value. The RTU logic and the solver rewrite these tags continuously, so a READ after the WRITE does not show which value was applied. The container test covers that part.

## 3. CommandInterface: a non-numeric WRITE aborts the client process

`std::stod` on the value had no catch, so `WRITE=<tag>:abc` threw out of the ZMQ handler thread and terminated every 104/BACnet/Modbus/DNP3 client that has a `<command-interface>`.

Container (`container/11-*.log`, `test_unit_commandinterface`):
- Before: `THREW exception: "stod"`. The hunt repro of the real client shows `terminate called after throwing an instance of 'std::invalid_argument' what(): stod`, rc -6.
- After: the reply is `ERR=...`, and a valid `12.5` still gets ACK.

Container only: the range RTUs are Modbus servers and have no command interface.

## 4. Requests are read up to a NUL, not by size (CommandInterface and Provider)

`std::string(req.data<char>())` reads until the first NUL. A request sent without one (pyzmq `send_string`, for example) reads past the end of the message.

Container (`container/12-*.log`, `container/nul-provider-*.log`):
- Before: `WRITE=load-breaker-toggle:true` with no NUL is parsed as tag `load-breaker-togglexxxxxxxx...`, i.e. the bytes after the message. The Provider gives the same result: `tag1xxxx... == tag1` fails.
- After: both tests pass.

Container only: libzmq usually leaves a zero after the buffer, so a live run rarely shows this.

## 5. A stale pidfile after a crash blocks `bennu-field-deviced --c start`

`isAlreadyRunning()` treats any nonzero pid in `/var/run/<env>.pid` as running, and `bennu-watcherd` does not restart a dead device. After the crash in section 1, the RTU stays down until someone runs `--c restart`. `stop()` would also signal whatever process now holds the stale pid.

Container (`container/pidfile-*.log`, `test/field_deviced_stale_pidfile.py`):
- Before: `start: rc=1 ... already running ... FAIL`.
- After: `start: rc=0 ... PASS`.

Range (`../tools/ev-pidfile.sh` on rtu-2): kill -9 the field device, then `--c start`.
- BEFORE (`range-before/pidfile-rtu2.txt`): start refuses, and nothing listens on 502.
- AFTER (`range-after/pidfile-rtu2.txt`): `rc=0`, and 502 is listening again.

Full suite: `container/final-ctest-throughput.log` passes 35/35 (33 upstream tests plus the new `test_unit_commandinterface` and `field_deviced_stale_pidfile`; other new cases are added to existing tests). Throughput is 466.48 tag writes/s and 0.107 s per cycle, against the cd3bb5b baseline of 466.50 and 0.107. Range latency with each build deployed is in `../bench/README.md`.
