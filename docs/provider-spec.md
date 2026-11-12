# ferrofire: the Field-to-Infrastructure Runtime Engine for phēnix/SCEPTRE ranges

*The fire phēnix rises from.*


Bead ww-1df.1 (epic ww-1df). Status: SPEC, nothing built. Answers Ryan's ask: "make our Rust provider similar
to PYPOWER (check the licence), incorporate what phenix and sceptre need, model simple processes — including
power — continuously, without MATLAB or PowerWorld".

Citation keys: `R:` = `provider/waterway-sim/` in this repo; `B:` = `~/git/sceptre-bennu` (Ryan's working tree
at `c9c2cf6` **with uncommitted edits** in `src/bennu/distributed/*` and the field-device io modules, so "stock"
below means this tree); `PB:` = `B:src/pybennu/pybennu`; `A:` = `~/git/sceptre-phenix-apps/src/python/phenix_apps/apps/sceptre`;
`T:` = `~/git/sceptre-phenix-topologies`. Web sources are cited by URL + function; no line numbers are
claimed for fetched files. Anything not checked first-hand is marked **UNVERIFIED**.

---

## 1. Goals / non-goals

Goals
- One Rust binary that (1) steps simple continuous processes (tanks, valves, pumps, locks, 1-D movers) at a fixed
  real-time step, (2) solves steady-state AC power flow on a MATPOWER/PYPOWER-style case, re-solved quasi-statically
  whenever an input or a process coupling changes, and (3) exposes both through bennu's provider interface so
  stock RTUs (`bennu-field-device`), `bennu-probe`, the OPC gateway, FUXA and the historian keep working unchanged.
- Models are data (one YAML file), not code. The waterway lock becomes the first model file; the current
  hand-written physics (`R:src/physics.rs`) is the acceptance oracle.
- Tag names stay exactly what existing sceptre RTU configs expect: the 15 waterway tags (`R:CONTRACT.md:86-90`) and
  pybennu's PYPOWER vocabulary (`bus-N.voltage`, `load-1_bus-N.mw`, `generator-1_bus-N.active`,
  `branch-1_F-T.active`, `bus-alert.active`; `PB:providers/power/solvers/python_power.py:41-196`).
- Three integration routes with phenix/sceptre, ordered so each ships without waiting on upstream.

Non-goals
- EMT or transient stability, frequency dynamics, protection modelling, OPF. Power is quasi-static AC power flow only
  (PYPOWER `runpf` scope), with DC as an optional fallback.
- A Simulink replacement for complex models. The process primitives are deliberately few (§3); anything that needs
  stiff DAEs or vendor block libraries stays in Simulink/HELICS.
- Distribution (three-phase unbalanced) power flow, i.e. the OpenDSS tag vocabulary (`A:configs/infrastructures.yaml:42-96`).
- Replacing bennu itself: RTUs, protocols (Modbus/DNP3), the OPC gateway and HMI are untouched.

---

## 2. Architecture

```
                 ┌──────────────────────── engine core (lib) ────────────────────────┐
 model.yaml ───► │ expr parser → model graph → stepper (RK4 / toward / body1d)        │
 case.py/.m  ──► │ power: case loader → ext2int → Ybus → Newton-Raphson → pfsoln      │ ─► snapshot {tag: Value}
 writes      ──► │ input latch (applied at the next step; power re-solve on change)   │    (Value = Analog f64 | Binary bool)
                 └────────────────────────────────────────────────────────────────────┘
                              ▲ writes                            │ snapshot
   ┌──────────────────────────┴────────────┐   ┌──────────────────▼───────────────────────────┐
   │ frontends (one binary, argv[0]/subcmd) │   │                                              │
   │ 1. native bennu provider  (primary)    │   │ REP tcp :5555 QUERY/READ/WRITE  +            │
   │ 2. simulink shm adapter   (compat)     │   │ UDP multicast datagrams in RADIO/DISH framing │
   │ 3. pybennu-power-solver CLI (compat)   │   │ or SysV shm + POSIX sem (today's contract)    │
   │ 4. HELICS federate (later, non-goal)   │   │                                              │
   └────────────────────────────────────────┘   └──────────────────────────────────────────────┘
```

- **Engine core** is a `lib` with no IO or clock (same discipline as `R:src/physics.rs:1-6`): `Model::load(yaml)`,
  `Model::apply_writes(&[(tag, Value)])`, `Model::step(dt)`, `Model::snapshot() -> Vec<(tag, Value)>`.
  Tests drive it offline at any speed.
- **Frontends** own threads and sockets. Shared state is one `Mutex<Shared>` holding the latest snapshot and a write
  queue; the engine thread drains the queue at the start of each step, then evaluates and publishes, then advances
  (§3.1). Today's loop is "publish → apply updates → advance" (`R:src/main.rs:71-90`, `R:CONTRACT.md:39-43`); the only
  observable difference is that an echoed input appears one step earlier.
- **CLI** (crate/binary name is Decision 1; `ferrofire` used below):
  - `ferrofire run model.yaml [--server tcp://0.0.0.0:5555] [--publish 'udp://*;239.0.0.1:40000'] [--rate 0.1]` — native provider.
  - `ferrofire simulink [-tf inf] [--model ./model.yaml]` — the shm adapter; also selected when `argv[0]` ends in
    `simulinksolver`, so today's launch line `./simulinksolver -tf inf` (`A:templates/sceptre_start.mako:16`) is unchanged.
    Model resolution: `--model`, else `./model.yaml`, else the embedded waterway model (`include_str!`), so the
    current zero-injection deployment keeps working.
  - `ferrofire pypower {start|stop|restart|status} -c /etc/sceptre/config.ini -e pybennu [-d] [-v]` — the
    `pybennu-power-solver` contract (`PB:providers/power/power_daemon.py:473-561`); also selected when `argv[0]` ends in
    `pybennu-power-solver`.
  - `ferrofire check model.yaml [--steps N] [--write tag=value@t]` — offline run printing the snapshot; used by tests and CI.
- **Threads** in native mode: engine step loop (real-time scheduler as `R:src/main.rs:91-95`), REP server, publisher.
  In simulink mode the stock `bennu-simulink-provider` is the network side (`R:CONTRACT.md:34-46`); we only fill shm.

### 2.1 Native bennu protocol — exact wire format

REP side (ZMQ REP over `tcp://<ip>:5555`; `A:metadata.py:17-23` derives the endpoint from the provider's IP):
- Request bytes are an ASCII string **plus a trailing NUL** (`B:src/bennu/distributed/Client.cpp:62` `msg + '\0'`;
  Python strips it `PB:distributed/server.py:52`). Forms (`B:…/Provider.cpp:27-30`, `PB:distributed/provider.py:84-93`):
  `QUERY=`, `READ=<tag>`, `WRITE=<tag>:<value>[,<tag>:<value>...]`. Op names are accepted in upper or lower case
  (`B:…/Provider.cpp:48-56`). WRITE values are `true`/`false` for binaries and `std::to_string(double)` (6 decimals)
  for analogs (`B:…/Client.hpp:35-48`); the Python helper is the same (`PB:distributed/utils.py:24-29`).
- Reply is `ACK=<payload>` or `ERR=<message>` **plus a trailing NUL** (`B:…/Provider.cpp:91`, `PB:distributed/server.py:59`).
  The client splits on the first `=` and treats anything but `ACK`/`ERR` as malformed (`B:…/Client.cpp:76-101`).
  `QUERY` → `ACK=tag1,tag2,...,` with trailing comma (`B:src/bennu/executables/bennu-simulink-provider/main.cpp:179-202`,
  `PB:…/python_power.py:267-273`). `READ` → `ACK=<value>` in the Simulink provider (`…/main.cpp:205-242`,
  `R:CONTRACT.md:61`) but `ACK=<tag>:<value>` in pybennu's PyPower (`PB:…/python_power.py:290`); we reproduce each per
  mode (native mode uses `ACK=<value>`, the form `B:…/Provider.hpp:40` documents). A REP socket must answer every
  request or it wedges (`PB:distributed/server.py:56-59`); malformed input gets `ERR=...`, never silence.
- The client is "lazy pirate": 5 s timeout, 3 retries, reconnect on each retry (`B:…/Client.cpp:11-12,54-127`).
  Field devices batch all pending outputs in one WRITE and, on an `ERR`, retry per point and drop rejected points
  (`B:src/bennu/devices/modules/io/OutputModule.cpp:48-91`). So: one invalid tag in a batch should make the whole
  batch fail (as PyPower does, `PB:…/python_power.py:330-333`), the retry logic then isolates it.

Publish side (what RTUs subscribe to):
- bennu uses the ZMQ **draft** RADIO/DISH sockets over UDP multicast: provider RADIO `connect`s to the endpoint
  (`B:…/Publisher.cpp:9-15`, `PB:distributed/publisher.py:43-44`), each RTU DISH `bind`s and `join`s one group
  (`B:…/Subscriber.cpp:6-21`, `PB:distributed/subscriber.py:31-36`). Default endpoint `udp://*;239.0.0.1:40000`
  (`A:metadata.py:14`; the RTU gets `*` replaced by its mgmt IP, `A:field_devices.py:114-117`).
- **Datagram framing** (libzmq `src/udp_engine.cpp`, `udp_engine_t::out_event` / `in_event`,
  https://github.com/zeromq/libzmq/blob/master/src/udp_engine.cpp): `[u8 group_len][group bytes][body bytes]`;
  the receiver rejects a datagram whose `group_len` exceeds `nbytes-1`; max datagram `MAX_UDP_MSG = 8192`
  (`src/udp_engine.hpp`). Multicast DISH binds the wildcard address on the port and joins the group with `IP_ADD_MEMBERSHIP`;
  the `iface;group:port` syntax is split at the last `;`, `*` meaning any interface (`src/udp_address.cpp`,
  `udp_address_t::resolve`). Nothing else is on the wire: no ZMTP handshake, no sequence numbers. **A plain
  `std::net::UdpSocket` sender is wire-compatible**; this is the route chosen (Decision 2).
- **Group name** = `hex(std::hash<std::string>(endpoint-without-iface))` with the last hex digit dropped (max group
  length 15; `B:…/Utils.hpp:44-66`). Both sides strip `<iface>;` first (`Utils.hpp:52-60`; the SWIG copy pybennu
  uses is identical, `PB:distributed/swig/Endpoint.i:13-28`), so provider and RTUs hash the same string
  `udp://239.0.0.1:40000`. `std::hash<std::string>` in libstdc++ is `_Hash_impl::hash(data, len)` =
  `_Hash_bytes(data, len, 0xc70f6907)` (`bits/basic_string.h` `__str_hash_base::operator()`,
  `bits/functional_hash.h` `_Hash_impl`), the 64-bit MurmurHash2 variant with
  `mul = 0xc6a4a793_5bd1e995` and `shift_mix(v) = v ^ (v >> 47)` (`libsupc++/hash_bytes.cc`,
  https://github.com/gcc-mirror/gcc/blob/master/libstdc%2B%2B-v3/libsupc%2B%2B/hash_bytes.cc).
  **Verified vector**: `udp://239.0.0.1:40000` → hash `54386972605942ba` → group `54386972605942b`;
  `udp://127.0.0.1:5556` → `5622dcba8d3e1def` → `5622dcba8d3e1de`. Produced by `g++ 11.4.0` (jammy, the toolchain the
  bennu images use) inside Docker Desktop (`burger-bennu-build:22.04`, amd64 under emulation — valid for aarch64 because
  `_Hash_bytes` depends only on 64-bit little-endian `size_t`, which both are), and reproduced bit-for-bit by a
  40-line Python port (kept in the spec's test plan as the oracle, §6.1). Note the hash is libstdc++-specific: a musl
  or libc++ build of *bennu* would disagree, our Rust code is independent of that.
- **Body**: `tag:value,tag:value,` with trailing comma, **NUL-terminated** (`B:…/Publisher.cpp:30,36`; the RTU reads it as a
  C string, `B:…/Subscriber.cpp:48`). Values: analog as decimal text, binary as `true`/`false`
  (`B:src/bennu/devices/modules/io/InputModule.cpp:37,95-105`). Long messages are split into datagrams on whole
  `tag:value,` parts, never mid-part (`B:…/Utils.hpp:85-113`, `PB:distributed/utils.py:4-21`); C++ uses MTU 1500
  (`Publisher.cpp:12`), Python 1465 (`publisher.py:25`). We chunk at **1400 bytes** so UDP+IP+group headers fit a
  1500-byte Ethernet MTU without fragmentation (the C++ value fragments).
- **Value typing is a correctness rule, not style**: the RTU routes `true/false` to `setDataByPoint<bool>` and
  anything else through `stod` (`InputModule.cpp:95-105`). Waterway device fields are all `analog-read` /
  `analog-read-write` (`A:configs/infrastructures.yaml:190-204`), and a `true`/`false` on an analog point aborts the
  field device (`R:CONTRACT.md:82`). Power `active`/`slack` are `binary-read` (`infrastructures.yaml:17-39`) and must be
  `true`/`false`. Hence every tag in the model carries a type (§3.1) and the formatter honours it.
- Multicast socket options: TTL 1 (libzmq default `multicast_hops`), loopback **on** so a same-host subscriber
  (the `ipc-test.sh` pattern, `R:ipc-test.sh:6-10`) works, `IP_MULTICAST_IF` set when the endpoint names an interface
  (`udp://10.1.1.2;239.0.0.1:40000`), default route otherwise.

### 2.2 Simulink shm adapter (today's provider, kept)

Exactly `R:CONTRACT.md` (keys 10610/10613, `/tmp/updates_fifo`, `publish_sem`/`updates_sem`, 256-byte slots,
`<tag>:DOUBLE:%f` / `<tag>:BOOLEAN:%d`, FIFO records `<tag>:<TYPE>:<val>`; `R:CONTRACT.md:9-71`). `R:src/ipc.rs` and
`R:src/contract.rs` move into the frontend unchanged; only `R:src/main.rs` changes to drive the engine instead of
`physics::step`. Slot order = `publishPoints.txt` line order (`R:CONTRACT.md:49`), falling back to the model's
declaration order. **glibc only**: the binary must stay `aarch64-unknown-linux-gnu` built against jammy glibc, because
musl's `sem_t` layout differs and hangs the stock provider (`R:CONTRACT.md:97-101`, `R:build-linux.sh:2-5`).

---

## 3. Model format (YAML)

### 3.1 Schema (v1)

```yaml
version: 1
dt: 0.05                 # engine step, seconds of model time per real-time step (R:src/main.rs:20 today)
substeps: 1              # RK4 sub-steps per dt for stiff tank/valve pairs
publish_rate: 0.1        # native/simulink default; pypower mode defaults to 1.0 (python_power.py:361)

inputs:                  # tags RTUs may WRITE; latched between writes (physics.rs:27-34)
  lowergate.open:  {type: analog, bool: true, default: 0}   # analog on the wire, boolean in meaning: nonzero -> 1 (physics.rs:125-135)
  valve.open:      {type: analog, default: 0.5}             # genuine analog, 0..1
  pump.run:        {type: binary, default: false}

states:                  # integrated variables, one entry each
  tank.level:            # kind "ode": dx/dt = expr, RK4
    ode: "(pump.flow - valve.flow) / tank.area"
    init: 2.0
    min: 0               # projection after each step (keeps mass balance exact at the bounds)
    max: 10
  lock.height:           # kind "toward": saturated approach with exact landing = physics.rs:55-58 move_toward
    toward: {target: "<expr>", rate: 0.5}
    init: 5.0

bodies:                  # the one special primitive: 1-D kinematics with barriers and end reversal (physics.rs:67-87)
  boat:
    speed: 5.0
    init: {x: 0, dir: 1}
    barriers: [{at: 100, open: lowergate.open}, {at: 200, open: uppergate.open}]   # closed barrier = clamp, EPS standoff downstream
    bounce: [0, 300]     # reverse dir at the ends
    # exposes boat.x, boat.dir

params:                  # named constants usable in expressions
  tank.area: 50
  valve.cv: 0.3

outputs:                 # algebraic tags = expressions; evaluated every step after inputs, before integration
  lock.height:      {type: analog}                    # a state republished as-is (type only)
  boat.location:    {type: analog, expr: boat.x}
  lowersensor.active: {type: analog, expr: "boat.x <= 100"}   # comparisons yield 1/0
  pump.flow:        {type: analog, expr: "if(pump.run && `bus-3`.voltage > 0.9, 0.5, 0)"}

power:                   # optional; absent for pure process models
  case: case300.py       # PYPOWER .py (restricted literal subset) | MATPOWER .m | inline (below); path relative to the model
  tags: pypower          # publish python_power.py's vocabulary (§3.4); the only vocabulary in v1
  resolve: on_change     # re-solve when any power input or drive changed; also at most every max_interval
  max_interval: 1.0
  dc_fallback: false
  islands: fail          # fail = PyPower-faithful (bus-alert); deenergize = VM=0 on islands without a reference gen (Decision 9)
  noise: 0.0             # pypower mode default 0.01 (python_power.py:363-369)
  drive:                 # process -> power couplings, applied before every solve (MW / Mvar)
    "load-1_bus-3.mw":   "pump.flow > 0 ? 1000*9.81*pump.flow*pump.head/(0.8*1e6) : 0"
    "load-1_bus-3.mvar": "`load-1_bus-3`.mw * 0.62"
  inline:                # alternative to case:
    baseMVA: 100
    buses:    [{id: 1, type: slack, vm: 1.0, base_kv: 13.8}, {id: 2, type: pq, base_kv: 13.8}, {id: 3, type: pq, pd: 0.4, qd: 0.2, base_kv: 13.8}]
    branches: [{from: 1, to: 2, r: 0.01, x: 0.05, b: 0.0, rate: 10}, {from: 2, to: 3, r: 0.02, x: 0.08, b: 0.0, rate: 10}]
    gens:     [{bus: 1, pg: 0, qg: 0, vg: 1.0, qmax: 50, qmin: -50, pmax: 50, pmin: 0}]

publish_order: [lowerwater.height, lock.height, ...]   # optional; default = declaration order (simulink mode: publishPoints.txt)
```

Rules
- Every published tag has a `type` (`analog` | `binary`) because of §2.1's typing rule. Power tags get types from the
  vocabulary table (§3.4). Waterway tags are all analog (`A:configs/infrastructures.yaml:190-204`).
- Identifiers are `[A-Za-z_][A-Za-z0-9_.]*`; tags containing `-` (every PYPOWER tag) are written back-quoted:
  `` `load-1_bus-3`.mw ``. Expressions see inputs, states, params, outputs, body fields and power result tags.
- Evaluation order per step at model time `t`: (1) drain the write queue into inputs, (2) evaluate `outputs` in
  dependency order from inputs, states, bodies and the **previous** solve's power results (a cycle among outputs is a
  load-time error), (3) evaluate `power.drive` from those outputs and run the power flow if any drive or power input
  changed or `max_interval` elapsed, (4) take the snapshot — inputs, states, bodies, outputs and power results, all
  at `t` — and publish from it, (5) advance `states`/`bodies` to `t + dt` (RK4 stages re-evaluate the `ode`
  expressions' referenced outputs per stage) and project onto `min`/`max`. Publish-before-advance is today's order
  (`R:src/main.rs:73-90`), so every published value comes from one instant. Power results referenced in expressions
  lag one step (quasi-static co-simulation: `pump.flow` at `t` uses the voltage solved at `t − dt`); the snapshot's
  own power values are current. Writes take effect within one step (≤ `dt`), the same latency as today.
- Inputs: `type` is the wire type (§2.1). `bool: true` marks an input that is boolean in meaning even when analog on
  the wire — it is latched as 0/1 (any nonzero write → 1) and echoed back as 0/1, exactly `R:src/physics.rs:96,125-135`.
  All four waterway inputs are such (the RTU writes `1.000000`, `B:…/Client.hpp:45`; the fields are analog,
  `A:configs/infrastructures.yaml:195-199`). `valve.open: 0.5` in §3.3 is a genuine analog.
- A `power.drive` target that names a `load-k_bus-N`/`shunt-k_bus-N` absent from the case (PyPower only creates loads
  where PD or QD ≠ 0, `python_power.py:87-97`) creates it with zero placeholders; a driven element is never silently
  dropped.
- Expression language (own ~250-line Pratt parser, Decision 4): numbers, identifiers, `+ - * / % ^`, unary `- !`,
  `< <= > >= == !=` (→ 1/0), `&& ||`, `c ? a : b` and `if(c, a, b)`, functions `min max abs sqrt exp ln pow clamp
  sign step floor`. No assignment, loops or strings. Precompiled to a tree once at load; evaluation is allocation-free.
  This is a superset of what the RTU `logic:` strings in the scenario use (`topologies/waterway-arm64/waterway-scenario.yaml:35,54`:
  `==`, `&&`, `*`, `+`, comparisons), so model-side test logic can be pasted from scenarios.
- "Library components" (tank, orifice valve, pump curve, pipe) are **not** engine types in v1. They are worked
  examples of `states`/`outputs` expressions in `models/README` (orifice `cv*sqrt(max(dp,0))`, tank `dV/dt = Σq`,
  pump `q = run * q_nom * f(voltage)`). ponytail: add a component type only when the same expression block is copied
  into a third model.

### 3.2 The waterway model in this format (must pass `R:src/physics.rs:159-176` unchanged)

```yaml
version: 1
dt: 0.05
params: {lowerpool: 5.0, upperpool: 15.0, fill_rate: 0.5}            # physics.rs:21-25 Params
inputs:                                                               # all four: analog on the wire, latched as 0/1 (physics.rs:125-135)
  lowergate.open:  {type: analog, bool: true, default: 0}
  lowervalve.open: {type: analog, bool: true, default: 0}
  uppergate.open:  {type: analog, bool: true, default: 0}
  uppervalve.open: {type: analog, bool: true, default: 0}
states:
  lock.height:                                                        # physics.rs:61-65: moves only when exactly one valve is open (0/1 compare)
    toward:
      target: "lowervalve.open != uppervalve.open ? (lowervalve.open ? lowerpool : upperpool) : lock.height"
      rate: fill_rate
    init: lowerpool
bodies:
  boat:                                                               # physics.rs:67-87
    speed: 5.0
    init: {x: 0, dir: 1}
    barriers: [{at: 100, open: lowergate.open}, {at: 200, open: uppergate.open}]
    bounce: [0, 300]
outputs:                                                              # physics.rs:99-122 read_point; order = injects/publishPoints.txt
  lowerwater.height:     {type: analog, expr: lowerpool}
  lock.height:           {type: analog}
  upperwater.height:     {type: analog, expr: upperpool}
  lowergate.open:        {type: analog}                               # inputs echoed back (all four)
  lowervalve.open:       {type: analog}
  uppergate.open:        {type: analog}
  uppervalve.open:       {type: analog}
  boat.direction:        {type: analog, expr: boat.dir}
  lowersensor.direction: {type: analog, expr: "boat.x <= 100 ? boat.dir : 0"}        # physics.rs:91-93 zone()
  locksensor.direction:  {type: analog, expr: "boat.x > 100 && boat.x <= 200 ? boat.dir : 0"}
  uppersensor.direction: {type: analog, expr: "boat.x > 200 ? boat.dir : 0"}
  boat.location:         {type: analog, expr: boat.x}
  lowersensor.active:    {type: analog, expr: "boat.x <= 100"}
  locksensor.active:     {type: analog, expr: "boat.x > 100 && boat.x <= 200"}
  uppersensor.active:    {type: analog, expr: "boat.x > 200"}
```

Body semantics to reproduce exactly: a closed barrier clamps an upstream-moving body at `at` and a downstream-moving
body at `at + 1e-3` so it stays in the zone it came from (`R:src/physics.rs:11-12,70-79`); `bounce` reverses `dir` at
either end (`physics.rs:80-86`). The RTU-written input is latched and any nonzero value is "on" (`physics.rs:125-135`).
The 15 tags above are byte-identical to `R:src/main.rs:19` so `topologies/waterway-arm64/reg_addrs.json` and the
RTU `modbus:` device lists (`waterway-scenario.yaml:21-33,40-52`; types `water/gate/valve/boat-sensor` from
`A:configs/infrastructures.yaml:190-204`) need no change. `boat.location`/`boat.direction` map to the `boat` type
(`infrastructures.yaml:203-204`) for a future RTU.

### 3.3 Pump station with power (new example, `models/pump-station.yaml`)

```yaml
version: 1
dt: 0.1
params: {tank.area: 50, valve.cv: 0.3, pump.q_nom: 0.5, pump.head: 30}
inputs:
  pump.run:   {type: binary, default: false}
  valve.open: {type: analog, default: 0.5}          # 0..1
states:
  tank.level: {ode: "(pump.flow - valve.flow) / tank.area", init: 2.0, min: 0, max: 10}
outputs:
  pump.flow:  {type: analog, expr: "pump.run && !`bus-alert`.active && `bus-3`.voltage > 0.9 ? pump.q_nom : 0"}   # m3/s; undervoltage trips the motor
  valve.flow: {type: analog, expr: "valve.open * valve.cv * sqrt(max(tank.level, 0))"}                                 # orifice
  tank.level: {type: analog}
power:
  tags: pypower
  islands: deenergize
  drive:
    "load-1_bus-3.mw":   "1000 * 9.81 * pump.flow * pump.head / (0.8 * 1e6)"   # hydraulic power / 80% efficiency, MW
    "load-1_bus-3.mvar": "`load-1_bus-3`.mw * 0.62"                             # pf 0.85
  inline:
    baseMVA: 100
    buses:    [{id: 1, type: slack, vm: 1.0, base_kv: 13.8}, {id: 2, type: pq, base_kv: 13.8}, {id: 3, type: pq, pd: 0.4, qd: 0.2, base_kv: 13.8}]
    branches: [{from: 1, to: 2, r: 0.01, x: 0.05, rate: 10}, {from: 2, to: 3, r: 0.02, x: 0.08, rate: 10}]
    gens:     [{bus: 1, pg: 0, qg: 0, vg: 1.0, qmax: 50, qmin: -50, pmax: 50, pmin: 0}]
```

RTU story: `pump.run`/`valve.open` are process writes (infrastructure `batch-process` has `pump` with
`binary-read-write: [control]` and `valve` with `open`, `A:configs/infrastructures.yaml:116-129`; the sceptre app needs
only a device entry naming these fields); `branch-1_2-3.active=false` (power-transmission `branch`,
`infrastructures.yaml:32-35`) opens the feeder → bus 3 islanded → with `islands: deenergize` its voltage is 0 → pump
flow 0 → tank drains through the valve. Mass balance: `d(level*area)/dt = pump.flow - valve.flow` exactly, which §6.4
checks. The 3-bus case is our own data (no provenance problem, §5-Licensing).

### 3.4 PYPOWER tag vocabulary (interface facts matched from `PB:…/python_power.py`)

| element (name rule) | analog fields | binary fields | writable (effect on solve) |
|---|---|---|---|
| `bus-N` (N = BUS_I; :49-51) | voltage, angle, gen_mw, gen_mvar, load_mw, load_mvar, shunt_mvar, base_kv (:76-83) | active, slack (:84-85) | active → BUS_TYPE 4/1/3 (:206-212), load_mw/load_mvar → PD/QD (:214-215), shunt_mvar → BS (:216), voltage/angle → VM/VA start (:217-218) |
| `load-1_bus-N` only if PD≠0 or QD≠0 (:87-97) | mw, mvar, bus | active | see Decision 8 (PyPower ignores load/shunt writes in the solve, :198-250) |
| `shunt-1_bus-N` only if BS≠0 (:99-109) | actual_mvar, nominal_mvar, bus | active | Decision 8 |
| `generator-k_bus-N`, k per bus in gen-row order (:111-144) | mw, mvar, mw_max, mw_min, mvar_max, mvar_min, voltage | active (GEN_STATUS>0, :122-125) | all → GEN row (:221-234) |
| `branch-k_F-T`, k per (F,T) pair in row order (:152-196) | source, target, resistance, reactance, charging, mva_max, turns_ratio, phase_angle | active (BR_STATUS, :168-171) | all → BRANCH row (:236-250) |
| `bus-alert` (:41-42) | – | active = last solve failed (:422-434) | read-only |

`generator` is accepted as `gen` in READ/WRITE (`:286-287,320`). Booleans are only accepted for `active`/`slack`
(`:322-326`, otherwise `ERR=Invalid value for tag`). RTU-side device types `bus/branch/generator/load/shunt` and their
field lists are in `A:configs/infrastructures.yaml:17-39`; the soap scenario shows the names in use
(`T:soap/scenario.yaml:36-60`: `bus-242`, `generator-1_bus-242`, `load-1_bus-243`, `branch-1_243-244`, `bus-alert`).

---

## 4. Solvers

### 4.1 Process integration

- Fixed step `dt` in real time (scheduler as `R:src/main.rs:91-95`); `--speed`/offline modes for tests. One RK4 over the
  `ode` state vector per sub-step, algebraic outputs recomputed at each RK stage from the stage state; `toward` states and
  bodies are discrete-time exact (`move_toward`, barrier clamps) so the waterway stays bit-identical to today.
  Then projection onto `[min, max]`. Events (gate closes, end stop, min/max hit) are handled by clamping at step
  boundaries — adequate at `dt ≤ 0.1 s` for these processes; no root finding.
- No ODE crate: `ode_solvers` 0.6.2 (Apache-2.0) needs `nalgebra` and `diffsol` 0.19.0 (MIT) is a BDF/SDIRK suite with
  ~10 runtime crates (docs.rs pages fetched 2026-11-08). Upgrade path if a model is stiff: implicit Euler with a
  finite-difference Jacobian and the same dense LU as §4.2, ~80 lines; `substeps` covers it until then.

### 4.2 AC power flow — port of PYPOWER (BSD-3), function by function

All from https://github.com/rwl/PYPOWER/tree/master/pypower (fetched 2026-11-08):

| PYPOWER | what we port | notes |
|---|---|---|
| `loadcase` | `.py` cases via a restricted-literal parser (§4.4), `.mat` **not** supported, `.m` MATPOWER parser, inline YAML | PYPOWER's loadcase itself accepts `.py`/`.mat` only, not `.m`; version-1 gen/branch arrays are padded (`ppc_1to2`) |
| `ext2int` | drop buses with `BUS_TYPE == 4`, gens with `GEN_STATUS <= 0` or on dropped buses, branches with `BR_STATUS <= 0` or touching dropped buses; renumber buses 0..nb-1 (`i2e`/`e2i`) | required by `makeYbus` ("buses must appear in order by bus number") |
| `bustypes` | `ref = REF ∧ has in-service gen`, `pv = PV ∧ has gen`, `pq = PQ ∨ no gen`; if no ref, promote the first PV | |
| `makeYbus` | `Ys = stat/(r+jx)`, `Bc = stat·b`, `tap = ratio·e^{jθ}` (ratio 0 → 1), `Ytt = Ys + jBc/2`, `Yff = Ytt/(tap·tap*)`, `Yft = -Ys/tap*`, `Ytf = -Ys/tap`, `Ysh = (Gs + jBs)/baseMVA`; `Ybus = Cfᵀ·Yf + Ctᵀ·Yt + diag(Ysh)` | dense complex nb×nb in v1 (Decision 5) |
| `makeSbus` | `Sbus = (Cg·(Pg + jQg) − (Pd + jQd))/baseMVA` over in-service gens | |
| `dSbus_dV` | `Ibus = Ybus·V`; `dS/dVm = diag(V)·conj(Ybus·diag(V/|V|)) + conj(diag(Ibus))·diag(V/|V|)`; `dS/dVa = j·diag(V)·conj(diag(Ibus) − Ybus·diag(V))` | |
| `newtonpf` | unknowns `[Va(pv,pq); Vm(pq)]`; `mis = V·conj(Ybus·V) − Sbus`; `F = [Re mis(pv,pq); Im mis(pq)]`; `J = [[J11 J12];[J21 J22]]` from the real/imag blocks; `dx = −J⁻¹F`; `V = Vm·e^{jVa}`; converged when `‖F‖∞ < PF_TOL`; loop `i < PF_MAX_IT` | defaults `PF_TOL = 1e-8`, `PF_MAX_IT = 10`, `PF_ALG = 1` (Newton), `ENFORCE_Q_LIMS = False`, `PF_DC = False` (`ppoption`) |
| `pfsoln` | `VM, VA` from V; `Qg` at gen buses = `Im(V·conj(Ybus·V))·baseMVA + Qd`, split equally then proportionally to Q range among several gens; slack `Pg` = injected P + Pd (other gens at the slack bus subtracted); branch `Sf = V_f·conj(Yf·V)·baseMVA`, `St` likewise; out-of-service branches zeroed | gives `source_mw`/`target_mw`-like quantities even though PyPower does not publish them (`python_power.py:184`) |
| `makeBdc` + `dcpf` | `b = stat/x/tap`, `Bf`, `Bbus = Cftᵀ·Bf`, `Pfinj = −b·shift`, `Pbusinj`; `Va(pvpq) = B(pvpq,pvpq)⁻¹(Pbus(pvpq) − B(pvpq,ref)·Va0(ref))` | used only when `dc_fallback: true` and NR failed, or `--dc` |
| `runpf` | the control flow above, `int2ext` back to external numbering, `success` flag; **not** the `ENFORCE_Q_LIMS` loop in v1 (PyPower runs with it off: `python_power.py:417-418` notes it crashed on case300) | Q-limit loop is a follow-up bead |

Linear algebra: dense LU with partial pivoting on the real Jacobian (≤ 600×600 for the 300-bus case that is the largest
in sceptre's topologies, `T:soap/injects/case300.py`) and a dense complex `Ybus`; own ~60-line LU plus `num-complex`
(or two `Vec<f64>`). Ceiling: ~2000 buses before a solve takes >100 ms. Upgrade path: `faer` 0.24.4 has
`sparse::linalg::solvers::{SymbolicLu, Lu, Qr, Llt}` (docs.rs; whether numeric refactorisation reuses the symbolic
analysis is **UNVERIFIED**); `sprs` 0.11.6 and `nalgebra-sparse` 0.12.0 ship no general sparse LU (docs.rs), so they
are not candidates.

### 4.3 Convergence handling and mid-run writes

- Warm start: like PyPower we solve from the case's current `VM/VA`, which after a solve hold the previous solution
  (`python_power.py:426-428` writes results back). Flat start (`1∠0`) is used only when a previous solution is
  absent or `islands` changed.
- Non-convergence or singular Jacobian: keep the last converged snapshot, set `bus-alert.active = true`
  (`python_power.py:422-424,431-433`), log once. If `dc_fallback: true`, publish the DC solution instead
  (`VM = 1`, angles from `dcpf`, `Q = 0`) and still raise `bus-alert`.
- Writes: `active`/`slack` and every numeric field map to the case row as in §3.4; they are applied atomically per
  WRITE batch at the next step, `Ybus` is rebuilt from scratch (cheap at this size), and the solve runs in that step.
  PyPower solves synchronously inside `write()` before replying (`python_power.py:335-342`); we reply `ACK` immediately
  and solve within one step (≤ `dt`), which no RTU can observe (they never READ, they subscribe).
- Islands (Decision 9): PyPower only removes `BUS_TYPE 4` buses, so opening a breaker that islands a load bus leaves a
  singular `Ybus` → exception → `bus-alert` with stale values. `islands: deenergize` runs a BFS over in-service
  branches from the reference buses and publishes `voltage = 0`, `angle = 0`, zero flows for unreachable buses, solving
  only the energised component(s). This is a deliberate deviation, off in pypower-compat mode.

### 4.4 Case file parsers

- PYPOWER `.py` (route b must read `/etc/sceptre/case300.py`, `A:templates/provider_config.mako:26-27`): the files are
  `ppc["bus"] = array([[...], ...])` blocks of numeric literals with `#` comments — `T:soap/injects/case300.py` has four
  `array([` blocks (`baseMVA`, `bus`, `gen`, `branch`, `gencost`) and the only alphabetic tokens inside them are column
  headers in comments. Parser: strip `#…` to end of line, locate `ppc["<key>"] =`, parse a nested bracket list of
  Python numeric literals (int, float, exponent, sign). Anything else (expressions, `numpy` calls other than `array`)
  is a load error with the offending line. `gencost` is ignored.
- MATPOWER `.m`: `mpc.bus = [ ... ];` with rows split by `;`/newline and `%` comments — same tokenizer, different
  delimiters. Nice-to-have for v1 (lets people use any public MATPOWER case without conversion); **not** required by
  any route.
- Inline YAML (§3.1) for small cases written by hand; column semantics follow MATPOWER's `caseformat`
  (bus 13 cols, gen 21, branch 13).

---

## 5. phenix / sceptre integration routes

### (a) Drop-in for `simulinksolver` — works today, keeps working

- The sceptre app's Simulink branch injects the solver binary to `/etc/sceptre/simulinksolver` and
  `publishPoints.txt`, then runs `bennu-simulink-provider` + `./simulinksolver -tf inf` (`A:simulators.py:134-150`,
  `A:templates/sceptre_start.mako:9-16`; this repo's scenario, `topologies/waterway-arm64/waterway-scenario.yaml:12-18`,
  via `gen_scenario.py:12-14`). No app change.
- **Native model files already ship through this route**: a topology-level injection puts `model.yaml` in `/etc/sceptre`
  next to the binary. This repo's generator already does per-host injections (`topologies/waterway-arm64/gen_topology.py:13-21`,
  e.g. `opc_gateway.json → /etc/sceptre/opc_gateway.json` at `:43`, rendered as `injections: [{src, dst}]` in
  `waterway-topology.yaml:69-71`); the `waterway-provider` host (`waterway-topology.yaml:8`) has none today, so route (a)
  for a native model is one tuple added to its `vm(...)` call, and the adapter loads `./model.yaml`. So
  the pump-station example runs under `simulator: Simulink` with zero upstream changes; its PYPOWER-vocabulary tags
  are published by the stock `bennu-simulink-provider` like any other point.
- Changes needed: none in sceptre; in this repo `README.md:21-22` (build + copy) stays, `Makefile` gains the Docker
  test target (§6).
- Limits: all points are published as `DOUBLE` by the shm contract unless we emit `BOOLEAN` (`R:CONTRACT.md:51-52`); the
  provider's `read` returns `ACK=<value>`; publish rate is the provider's `--publish-rate` (default 0.1 s,
  `B:…/bennu-simulink-provider/main.cpp:362`).

### (b) Drop-in for `pybennu-power-solver` — `simulator: PyPower` scenarios run unchanged

- Launch contract (`A:templates/sceptre_start.mako:22-31`): `ps cax | grep pybennu` then `pybennu-power-solver restart
  -c /etc/sceptre/config.ini -e pybennu -d` or `… start …`. CLI (`PB:providers/power/power_daemon.py:473-511`):
  positional `start|stop|restart|status`, `-c/--config-file` (default `/etc/sceptre/config.ini`), `-d/--daemonize`,
  `-e/--env` (pidfile `/var/run/bennu-<env>.pid`, logs `/var/log/bennu-<env>.{out,err}`, `:34-40`), `-v/--debug`.
  `restart` without a live pidfile prints "cannot restart" and does nothing (`:533-538`), `stop` kills by pidfile.
  Our binary must implement all four verbs and real daemonisation (`fork`+`setsid`, pidfile, stdio to the log files);
  `ps cax` shows the 15-char comm name, so install it **as** `pybennu-power-solver` (comm `pybennu-power-s` matches
  `grep pybennu`).
- `config.ini` (`A:templates/provider_config.mako:2-4,8-11,26-27`): section `[power-solver-service]`, keys
  `solver-type = PyPower`, `debug`, `server-endpoint`, `publish-endpoint` (arrives as `udp://*;239.0.0.1:40000`;
  pybennu strips `*;` for the RADIO connect, `power_daemon.py:114`), `case-file = /etc/sceptre/<case>.py`.
  The app injects the case under its basename (`A:simulators.py:174-193`). We parse the same INI (own 30-line parser,
  no crate), ignore unknown keys, and refuse `solver-type` ≠ `PyPower`/`Prosim` with the same exit code 1 style.
- Fidelity list (all from `PB:…/python_power.py`): tag vocabulary and order §3.4 with `bus-alert.active` first
  (`:41-42`); publish every 1 s (`:352-361`) with ±1 % multiplicative noise on analogs and ±0.1 absolute on zeros
  (`:363-369`) applied to bus fields except `base_kv/active/slack`, load and shunt fields except `bus/active`, gen
  fields except the limits and `active`; **branch fields are published without noise** (`_pack_data` has no branch
  loop, `:380-405`); `read` →
  `ACK=<tag>:<value>` (`:290`); write batch validated before applied (`:330-333`), `ERR=Invalid value for tag` for a
  boolean on a non-boolean field (`:322-326`); booleans printed `true/false`, floats like Python `repr` (we append `.0`
  to integral values so logs look the same; RTUs `stod` either); solve at init and after each write
  (`:252-257,340`), never periodically; `ENFORCE_Q_LIMS` off (`:417-418`), `PF_TOL 1e-8`, `PF_MAX_IT 10`.
- Deployment on the arm64 bennu image: the overlay `images/overlays/bennu-arm64` replaces pip's console script
  `/usr/local/bin/pybennu-power-solver` with a symlink to `ferrofire` (PATH-independent; Decision 12). This removes the
  provider's dependency on Python `PYPOWER==5.1.19`/scipy wheels (`PB:pyproject.toml:35`; plan risk 4 on missing
  aarch64 wheels, `docs/plan.md:386`).
- Why second: it needs the native protocol (this branch never launches `bennu-simulink-provider`), and it is the
  route that makes every existing `simulator: PyPower` scenario (e.g. `T:soap`) run natively on the arm64 range.

### (c) New sceptre simulator type (upstream PR to `sceptre-phenix-apps`)

Exact edits, all in `A:`:
- `metadata.py:39-55` `Simulator` enum: add `PROSIM = "Prosim"` (the value becomes `solver-type`, `:42-43`).
- `simulators.py:49-55` `REQUIRED_METADATA[Simulator.PROSIM] = ("model",)`; new `ferrofire_injections` (config.ini →
  `/etc/sceptre/config.ini`, `metadata.model` → `/etc/sceptre/model.yaml`) and `ferrofire_kwargs` → `{"model_file":
  "/etc/sceptre/model.yaml"}`; register in `INJECTIONS` (`:322-329`); `prestart.py:168-190` picks the kwargs up.
- `templates/provider_config.mako`: `% elif solver == 'Prosim': model-file = ${model_file}`.
- `templates/sceptre_start.mako:22`: add `'ferrofire'` to the pybennu branch (binary installed as above) **or** a
  dedicated branch `ferrofire run /etc/sceptre/model.yaml --config /etc/sceptre/config.ini > /etc/sceptre/log/provider.log 2>&1 &`.
  The dedicated branch is cleaner and avoids the `ps cax | grep pybennu` dance.
- `validation.py:175-180` uses `REQUIRED_METADATA` automatically; `tests/test_sceptre_golden.py` goldens need
  regenerating. The phenix grapheditor UI enum (`~/git/sceptre-phenix/src/go/web/public/grapheditor/utils/schemas/schema.json:686`)
  lists simulators for the editor only; add `Prosim` in a separate PR, it does not gate scenario creation (**UNVERIFIED**
  that no server-side schema also enumerates simulators; a grep of `.go/.json/.yaml` found only the two grapheditor files).
- Why last: it changes nothing a user cannot already do with (a); its value is discoverability and dropping the
  `simulator: Simulink` misnomer. Ship after (a)+(b) prove the tags and protocol, so the PR carries evidence.

Recommended order: **engine + model file through (a) → native protocol → (b) → (c)**.

Optional later: HELICS federate frontend (pybennu has a `Helics` solver, `power_daemon.py:369-395`; bennu has
`bennu-simulink-provider-helics`). Out of scope here.

---

## 6. Testing / verification

Toolchain constraint: there is **no `cargo` on the Mac**; the VM has rustup (`R:build-linux.sh:10-12`) and is off-limits
while the other workflow runs. Unit tests therefore run in Docker Desktop (available, independent of Lima): image
`ferrofire-test:22.04` = `ubuntu:22.04` + rustup minimal + `gcc libzmq3-dev pkg-config` (new `Makefile` target `test`,
replacing the bare `cargo test` in `R:Makefile:2-3`). Integration tests run in the Lima VM when it is free.

### 6.1 Unit (container)
- Expression parser: precedence, `?:`, functions, back-quoted tags, error positions.
- Model load: waterway + pump-station parse; dependency cycle rejected; unknown identifier named with its tag.
- Group hash: Rust `libstdcxx_hash("udp://239.0.0.1:40000") == 0x54386972605942ba`, group `54386972605942b`;
  oracle = the Python port (40 lines, committed under `tests/`) which matched `g++ 11.4` byte-for-byte on
  2026-11-08; verify command `docker run --rm -v $PWD/tests:/w:ro burger-bennu-build:22.04 bash -c 'g++ -std=c++17 -o /tmp/h /w/hash.cpp && /tmp/h'`.
- Datagram framing: `[len][group][body\0]`; chunking reproduces the `chunk_message` cases (`PB:distributed/utils.py:4-21`:
  empty parts skipped, a single over-long part returned alone).
- REP round trip: a `zmq` REQ client in the test sends `QUERY=\0`, `READ=lock.height\0`,
  `WRITE=lowervalve.open:1.000000,uppergate.open:true\0`, checks `ACK=…\0`/`ERR=…\0` and that an unknown tag in a
  batch fails the batch.
- Case parsers: `case300.py` (copied into `target/` at test time from `T:soap/injects/`, not committed) parses to
  300/69/411 rows; a MATPOWER `.m` fixture of our own 3-bus case.

### 6.2 Golden power-flow comparisons (container + `uv`, no cases vendored)
- `tests/golden/gen_pypower.py` runs under `uv run --with PYPOWER==5.1.19 --with numpy --with scipy python -I …`
  (`uv` 0.13.7 is on the Mac; PYPOWER 5.1.19 with numpy ≥ 2 is **UNVERIFIED**, pin `numpy<2` if it fails) and writes
  `target/golden/<case>.json` with `VM, VA, PG, QG, PF, QF, PT, QT, success` for `case9, case14, case30, case57,
  case118, case300` (PYPOWER's own `pypower/case*.py`, imported from the installed package at test time).
- Rust test loads each JSON, runs our solver on the same case (parsed from the installed package's `.py` file) and
  asserts `|ΔVM| < 1e-6`, `|ΔVA| < 1e-4°`, `|ΔP|,|ΔQ| < 1e-4 MW/Mvar`, same `success` (tune at implementation; a
  different LU and iteration count legitimately move the last digits). Tag-naming test: hand-derived
  expected tag list for `case9` (3 gens, loads at buses 5/7/9, 9 branches) compared to ours.
- Write semantics: `bus-5.active=false` → bus removed, re-solve differs from golden by design; `branch-1_4-5.active=false`
  compared against a golden generated with that row's `BR_STATUS=0`.

### 6.3 Waterway regression
- Port `R:src/physics.rs:159-176` (`full_transit_with_rtu_logic`) to drive the model-based engine with the same RTU
  logic transcription (`physics.rs:140-152`); assert the boat reaches 300 m and returns, the lock fills to 15 m and
  drains to within 0.2 m of 5 m — identical thresholds. Also `closed_gates_block_boat_and_valve_moves_level`,
  `boat_reverses_at_ends` (`physics.rs:179-199`). A trace-equality test compares 600 s of snapshots between the old
  `physics::step` and the model engine (max abs diff 1e-9) until `physics.rs` is deleted.

### 6.4 Property tests
- Mass balance: for random pump/valve input sequences, `area·Δlevel = ∫(q_in − q_out)dt` to 1e-9 unless a bound was
  hit, in which case the clipped volume is accounted; seeded LCG, no `proptest` dependency unless it earns its keep.
- Barriers: the boat never crosses a closed gate; sensors are mutually exclusive and exactly one is active.
- Power: when `success`, `‖mis‖∞ < 1e-8` recomputed independently from the published `VM/VA`; `Σ Pg − Σ Pd − losses = 0`
  to 1e-6 p.u.; DC vs AC angles within 2° on lightly loaded random 5-bus cases.

### 6.5 Protocol conformance against stock bennu (Lima VM, when free)
- `ipc-test.sh` (`R:ipc-test.sh`) stays green for the shm adapter (15 points, `lock.height` moves with the valves).
- Native mode in `bennu:arm64`: start `ferrofire run models/waterway.yaml`; `bennu-probe --e tcp://127.0.0.1:5555 --c query`
  lists 15 tags; `--c read --t lock.height`, `--c write --t uppervalve.open --v 1` then read again (the current
  `ipc-test.sh:12-18` sequence); `pybennu-test-subscriber` (`PB:executables/pybennu_test_subscriber.py:19-21`, DISH on
  `udp://239.0.0.1:40000`) logs our datagrams — proves group + framing; a `bennu-field-device` with the `rtu-1`
  `config.xml` generated by `scada/gen_configs.py` shows `lowergate.open` flipping via Modbus (the README §4 check).
- PyPower drop-in: `pybennu-power-solver start -c config.ini -e pybennu -d` with `solver-type = PyPower`,
  `case-file = /etc/sceptre/case300.py`; `bennu-probe … --c query | wc -l` equals the Python provider's count on the
  same case (run both, once, record the number); `read --t bus-242.voltage` prints `ACK=bus-242.voltage:<v>`; `restart`
  and `status` work against the pidfile.

---

## 7. Phased plan

Sizes are focused-work days. "verify" commands run in the Docker Desktop test container unless marked VM.

| # | Phase | Deliverables | Verify | Size |
|---|---|---|---|---|
| 0 | Engine core + waterway as a model | `lib`: YAML schema, expr parser, `states/bodies/outputs`, `models/waterway.yaml` embedded; shm frontend loads `--model`/`./model.yaml`/embedded; `physics.rs` deleted after trace-equality | `make test` (6.1 expr/model, 6.3, 6.4 mass/barriers); `make linux` (VM) then `ipc-test.sh` (VM) unchanged output | 1.5 |
| 1 | Power flow | case parsers (.py, inline; .m optional), ext2int/bustypes/makeYbus/makeSbus/dSbus_dV/newtonpf/pfsoln/makeBdc/dcpf, PYPOWER tag vocabulary, `power.drive`, islands option; `models/pump-station.yaml` | `make golden` (6.2) + `make test`; `ferrofire check models/pump-station.yaml --write 'branch-1_2-3.active=false@30'` shows voltage 0 at bus 3 and tank draining | 2 |
| 2 | Native bennu protocol + CLI | REP via `zmq` crate, UDP RADIO framing, group hash, chunking, `ferrofire run`, NOTICE file | 6.1 hash/framing/REP; `make linux` (VM) → 6.5 native checks in `bennu:arm64` (VM) | 1 |
| 3 | `pybennu-power-solver` drop-in | INI parser, daemon verbs/pidfile/logs, noise, 1 s publish, `ACK=<tag>:<value>`, image overlay symlink | 6.5 PyPower checks (VM); a soap-derived arm64 scenario boots with `simulator: PyPower` and `bennu-probe` on an RTU reads `bus-242.voltage` (VM) | 1 |
| 4 | Range integration of a coupled model | pump-station scenario in this repo (RTU devices `pump`/`valve`/`bus`/`branch`), FUXA view, historian series | end-to-end as README §4 with `branch-1_2-3.active` written from the HMI (VM) | 1 |
| 5 | Upstream | PR to `sceptre-phenix-apps` per §5(c) with the §6.5 evidence; grapheditor enum PR | upstream CI (`tests/test_sceptre_golden.py` regenerated) | 0.5 + review |

Total ≈ 7 days of work. Phases 0–1 need no VM time at all.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| REP interop subtleties (reconnects, NUL handling) | low with libzmq linked | `zmq` crate = libzmq itself; 6.1 REQ round trip + 6.5 against stock `bennu-probe`/field device |
| Group hash mismatch on some build | very low | vector verified against jammy `g++ 11.4` libstdc++; bennu on this range is built with that toolchain (`images/docker/bennu-arm64.Dockerfile`, `images/scripts/bennu-arm64.sh:3,18`) |
| libzmq soname/ABI on the target image | low | image has apt `libzmq5-dev` plus a `/usr/local` drafts build (`images/scripts/bennu-arm64.sh:3,18`); verify `ldconfig -p | grep libzmq` — **UNVERIFIED** which one `ld.so` resolves first; pin with `RPATH`/`LD_LIBRARY_PATH` if needed |
| `.py` case files with non-literal content | low | parser fails loudly with the line; `.m`/inline as escape hatches; soap's `case300.py` verified literal-only |
| Numerical divergence from PYPOWER (Q split at multi-gen buses, slack P) | medium | goldens on 6 cases incl. case300; tolerance 1e-6 p.u.; `pfsoln` ported literally |
| Daemonisation edge cases (`restart` with stale pidfile) | medium | 6.5 verbs test; mirror `power_daemon.py:521-545` behaviour exactly |
| Model-format creep | medium | three primitives only; new component types need a third copy of an expression block (ponytail rule in §3.1) |
| Multicast egress interface on multi-NIC guests | low | honour `iface;` in the endpoint; log the chosen interface at start |
| YAML crate churn | low | `serde-saphyr` (Decision 7); the schema is small enough to switch crates in an afternoon |

### Licensing (the "check the licence" part)

- **PYPOWER** is 3-clause BSD, "Copyright (c) 1996-2015, Power System Engineering Research Center (PSERC)"
  (https://github.com/rwl/PYPOWER/blob/master/LICENSE). Porting its algorithms into MIT code is allowed; the BSD notice
  must be retained. We ship `NOTICE` (PSERC copyright + the three BSD conditions + "portions ported from PYPOWER") and a
  header comment in `power/*.rs` naming the ported function. The repo stays MIT (`LICENSE`).
- **MATPOWER** code is BSD-3 but its LICENSE states "The MATPOWER case files distributed with MATPOWER are not covered
  by the BSD license" (https://github.com/MATPOWER/matpower/blob/master/LICENSE); PYPOWER's copies carry a PSERC BSD
  header anyway (`pypower/case9.py`: "Based on data from Joe H. Chow's book, p. 70"). We do not resolve that conflict:
  **no third-party case files are vendored**. Goldens are generated at test time from the installed PYPOWER package
  (§6.2); the shipped example case is our own 3-bus network; docs point users at MATPOWER/PYPOWER case files and the
  public IEEE test-case archive (University of Washington) with their own provenance.
- **bennu and pybennu are GPL-3.0-or-later** (`B:LICENSE`, `PB:pyproject.toml:8`). Nothing is ported from them. Wire
  formats, tag names, config keys and CLI flags are interface facts and are matched from observation (cited above);
  `std::hash` is libstdc++ behaviour (GPL-3 with the GCC Runtime Library Exception), reimplemented from the published
  algorithm description, not copied.
- Crates excluded on licence: `evalexpr` is AGPL-3.0-only since 12.0.0 (2024-10-17; last MIT release 11.3.1 —
  crates.io version list). `rhai` 1.27.0 (MIT OR Apache-2.0, released 2026-10-21) and `zeromq` 0.7.0 (MIT) are fine;
  `fasteval` 0.2.4 (MIT) has had no release since 2020-01-25; `libzmq` (libzmq-rs) 0.2.5 since 2020-05-09.

---

## 8. Decisions for Ryan (recommendation first)

1. **Crate/binary name.** `ferrofire` (process simulator; binary `ferrofire`, repo dir `provider/ferrofire/`, later its own
   repo). Alternatives: keep `waterway-sim` (too narrow once power lands), `rangesim`, `physim`.
2. **Publish route.** Raw UDP datagrams in RADIO/DISH framing from `std::net::UdpSocket` (zero dependencies, format
   verified from libzmq `udp_engine.cpp`, group vector verified) — vs linking a drafts-enabled libzmq (the `zmq` crate
   exposes no RADIO/DISH: `SocketType` has 12 variants, no `join`/`set_group`, rust-zmq `src/lib.rs`; the pure-Rust
   `zeromq` crate has no UDP/RADIO either). Recommended: raw UDP.
3. **REP route.** `zmq` crate 0.10 linking the system libzmq via pkg-config (`zmq-sys` declares `system-deps libzmq >= 4.1`
   and a `zeromq-src` build-dep with no feature gate; which one its `build.rs` prefers is **UNVERIFIED** — install
   `libzmq3-dev pkg-config cmake g++` in the build/test container so either path works) — exact libzmq interop, no
   protocol code.
   Alternatives: pure-Rust `zeromq` 0.7 (MIT, active, REP over tcp, but pulls tokio and is async-only) or a hand-rolled
   ZMTP 3 REP (~250 lines, enables a fully static native binary later). Recommended: `zmq` crate now, hand-rolled
   ZMTP only if a static binary becomes a requirement.
4. **Expression language.** Own ~250-line parser with the §3.1 grammar (MIT-clean, no deps, allocation-free eval) —
   vs `rhai` (full scripting engine, heavy compile, more than the models need) vs `evalexpr` (AGPL, excluded).
   Recommended: own parser; `rhai` is the upgrade path if models need loops/functions.
5. **Linear algebra.** Dense LU + dense complex Ybus (own code + `num-complex`), ceiling ≈ 2000 buses — vs `faer`
   sparse `Lu` from day one. Recommended: dense; `faer` behind a feature flag when someone brings a >1000-bus case.
6. **Power scope in v1.** AC NR with PV/PQ/slack, taps/shifts, shunts, in/out-of-service toggles, DC fallback;
   **no** `ENFORCE_Q_LIMS` (PyPower runs without it), no OPF, no `.mat`. Recommended as stated; Q-limits as a follow-up
   bead.
7. **YAML crate.** `serde-saphyr` 2.1.1 (MIT OR Apache-2.0, released 2026-11-05) — `serde_yaml` is
   `0.9.34+deprecated` (2024-03-25), `serde_yml` declares itself unmaintained, `serde_yaml_ng` 0.10.0 last released
   2024-05-26 (all crates.io). Recommended: `serde-saphyr`; the schema is small, switching is cheap.
8. **PyPower load/shunt write quirk.** pybennu never writes `load-*`/`shunt-*` edits back into the case
   (`python_power.py:198-250`), so `load-1_bus-N.active=false` changes the published tag but not the solve.
   Bug-compatible vs sensible (loads/shunts do affect the solve). Recommended: sensible, documented as a deviation
   (no scenario can depend on the quirk except by accident).
9. **Islands.** PyPower-faithful (`islands: fail` → singular → `bus-alert`, stale values) vs `deenergize` (zero
   voltage on islands without a reference gen). Recommended: `deenergize` default for native models, `fail` default
   in pypower-compat mode.
10. **Waterway becomes a model file.** Yes: `models/waterway.yaml` embedded as the default, `physics.rs` deleted
    once the trace-equality test passes (§6.3). Alternative: keep `physics.rs` as a built-in. Recommended: model file.
11. **Integration order.** (a) engine through the existing Simulink branch → native protocol → (b) PyPower drop-in →
    (c) upstream simulator type. Alternative: (c) first for cleanliness. Recommended as stated (phases 0–1 need no
    upstream and no VM time).
12. **Binary install for (b).** Replace pip's `/usr/local/bin/pybennu-power-solver` console script with a symlink to
    `ferrofire` in the bennu-arm64 overlay — vs a `/usr/local/sbin` shadow (depends on the PATH the phenix startup script
    runs with under `cc exec`, **UNVERIFIED**) vs patching `sceptre_start.mako` now. Recommended: replace the script
    (PATH-independent, zero upstream change; `ps cax | grep pybennu` still matches because the comm name comes from
    the symlink name).
13. **Ground-truth page.** `docs/plan.md:296-297` deferred a small HTTP ground-truth view (the dropped `simulinkgt`).
    Recommended: separate bead after Phase 2, served by the native binary on `:8080` with the snapshot as JSON.

## 9. Decisions taken (2026-11-08)
- Name: **ferrofire** (renamed from rustbelt, which collides with the RustBelt Rust-soundness research project, the crates.io `rustbelt` crate and a Rust Seatbelt port). FIRE = **F**ield-to-**I**nfrastructure **R**untime **E**ngine. Tagline: *The fire phēnix rises from.* Free on crates.io and GitHub as of 2026-11-08. The repo directory is ~/git/ferrofire.
- Waterway becomes a model file; `physics.rs` is deleted only after trace-equality and the full-transit test pass.
- All other section 8 recommendations accepted as written.
- Start after the range repo publish + PR (ww-585.33).

## 10. Migration roadmap: off the older sceptre runtime stack (agreed 2026-11-08)

Principle: replace components where there is real pain, one at a time, keeping every
wire format and config contract (tags, register maps, bennu config XML, ZeroMQ REP +
RADIO/DISH framing at the edges) so each piece can go upstream on its own and stock
components keep interoperating. bennu/pybennu are GPL-3: rewrites are clean-room from
protocols and observed behaviour, never translations of bennu code, so they can stay MIT.

| Step | Component | Today | Move | Why |
|---|---|---|---|---|
| 1 | Providers (Simulink, PYPOWER) | C++ + MATLAB / Python | ferrofire (sections 1-9) | x86-only binaries, licences, SciPy on arm64 |
| 2 | Field device (`bennu-field-deviced`) | C++ | Rust drop-in: same config XML, same ZeroMQ subscription to the provider, Modbus/DNP3/IEC 104 servers on tokio | vendored x86 libs, broken upstream tree, arm64 build pain; hostile-input parsers want memory safety |
| 3 | brash, probe, test endpoints | C++ / Python | folded into the Rust binaries | little pain, consolidation |
| 4 | phenix apps run as Python subprocesses, orchestration, SCORCH components | Python | Go where it hurts | phenix and minimega are Go: shared types, clients, maintainers |
| 5 | Field-device swarm (research) | none | BEAM/Elixir spike: thousands of supervised emulated RTUs/IEDs | utility-scale attack surface without thousands of VMs; compare against the Rust field device |

Transport: stay on ZeroMQ wire compatibility (REQ/REP plus the ferrofire datagram v1 multicast
bytes, section 11). NNG was evaluated and dropped on 2026-11-09.

Language rule: Rust for code that runs inside range VMs (simulators, field devices,
protocol parsers: determinism, memory safety, small static binaries, no GC pauses in
control loops); Go for the orchestration layer next to phenix/minimega; BEAM only for
the swarm research spike, not as a base layer.

## 11. Transport decision: ZeroMQ REQ/REP plus ferrofire datagram v1 (2026-11-09; supersedes the 2026-11-08 "ZeroMQ and NNG, selectable")
- **NNG was evaluated and dropped (2026-11-09).** The earlier text here chose both transports selectable; the measurements (ferrofire `docs/bench/transport-comparison.md`, kept as historical) did not justify a second stack. There is no `--transport` flag, no `nng` cargo feature and no `bennu-ferrofire-nng-arm64` image.
- Requests `QUERY=`, `READ=tag`, `WRITE=tag:value` are libzmq REQ/REP (stable API), answered `ACK=`/`ERR=`; the provider answers every request exactly once.
- State publishing is UDP multicast and the primary provider-to-RTU path. ferrofire owns the wire, **ferrofire datagram v1**: libzmq RADIO bytes (`[u8 group_len][group][body]`, group = libstdc++ hash of the endpoint), documented and sequenced (`_ff.seq`, `_ff.cyc`, `_ff.t` pseudo-tags). Specification: ferrofire `docs/datagram-v1.md`; Wireshark dissector: ferrofire `tools/wireshark/ferrofire_datagram.lua`. Stock bennu DISH subscribers keep working because the bytes do not change.
- Per-RTU endpoints: `publish_slices:` in the model or `--publish-tags ENDPOINT=...` publish tag slices to separate groups.
- No multicast: `ferrofire pull-bridge` (batched `READ`, zmq REQ/REP) next to each RTU republishes locally.
- Robustness: a lost datagram heals within one publish period (periodic full state); REQ/REP clients use lazy pirate so a lost reply cannot wedge them; see "Failure behaviour" in `docs/datagram-v1.md`.
- Image: `bennu-ferrofire-arm64`. The Simulink shm adapter is unaffected.
