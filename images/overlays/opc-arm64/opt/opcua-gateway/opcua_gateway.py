#!/usr/bin/env python3
"""OPC UA gateway for the waterway range (replaces Kepware TopServer).

Polls each RTU over Modbus/TCP (default) or DNP3 and serves the values as OPC UA nodes
`ns=2;s=<rtu>.<device>.<field>` (Double, engineering units). Writing a node
that has a write point forwards the value to the RTU (gate/valve commands).

Config: /etc/sceptre/opc_gateway.json, rendered by scada/gen_configs.py:
  {"opc_endpoint": "opc.tcp://0.0.0.0:4840", "poll_interval": 1.0, "scale": [0, 1000],
   "rtus": [{"name": "rtu-1", "host": "10.1.1.101", "port": 502, "unit": 1,
             "points": [{"node": "rtu-1.lock.height",
                         "read":  {"type": "input-register",   "address": 30001},
                         "write": {"type": "holding-register", "address": 40000} | null}]}]}
DNP3 rtu ("protocol": "dnp3"): {"name": "rtu-1", "host": "10.1.1.101", "port": 20000, "master": 1, "outstation": 10,
   "points": [{"node": ..., "read": {"type": "analog-input", "address": 2},    # DNP3 point index
                            "write": {"type": "analog-output", "address": 3}}]}
  Each cycle is one integrity poll (g30 analog inputs, already engineering units: no scaling); writes are g41v3
  (float32) direct operates, the only variation ferrofire's outstation applies. One persistent connection per RTU.
Modbus register <-> engineering units: bennu scales to 16 bit linearly over `scale` (an rtu entry may carry its own `scale`: the infrastructure's register range, e.g. power-transmission [-600, 1800])
(Server.cpp: raw = 65535*(v-min)/(max-min)), identical to the Kepware tag scaling.

Run:   opcua_gateway.py --config FILE      Self-test: python3 -I opcua_gateway.py --self-test
Needs: asyncua==2.1.0 pymodbus==3.16.2 dnp3py==0.6.0
"""
import argparse
import asyncio
import json
import logging
import struct
import sys

from asyncua import Server, ua
from dnp3.master import Master, MasterConfig, MasterTcpRunner
from dnp3.application.fragment import ObjectBlock
from dnp3.application.qualifiers import ObjectHeader
from dnp3.master.commands import ControlOperation, DirectOperateTask
from dnp3.master.handler import DefaultSOEHandler
from pymodbus.client import AsyncModbusTcpClient

log = logging.getLogger("opcua_gateway")
NS_URI = "urn:waterway:opc"
FULL = 65535.0


def to_eng(raw, lo, hi):
    return round(lo + raw / FULL * (hi - lo), 3)


def to_raw(v, lo, hi):
    return max(0, min(65535, round((v - lo) / (hi - lo) * FULL)))


class FloatOperate(DirectOperateTask):
    """DIRECT_OPERATE with g41v3 (float32). dnp3py's CommandBuilder hardcodes g41v1 (int32 truncation), and ferrofire's
    outstation answers success to g41v1/v2/v4 but applies only g41v3 (ferrofire field-device spec Q6).
    ponytail: 1-byte point index (<= 255), one point per request; widen if a device ever needs more."""

    def _build_analog_block(self, operations):
        data = b"".join(bytes([1, op.index]) + struct.pack("<fB", op.analog_value, 0) for op in operations[:1])
        return ObjectBlock(header=ObjectHeader(group=41, variation=3, qualifier=0x17), data=data)


def float_operate(index, value):
    return FloatOperate(operations=[ControlOperation(index=index, analog_value=float(value), is_analog=True)])


def runs(addrs):
    """Sorted addresses -> [(start, count)] of contiguous runs (bennu rejects unmapped gaps)."""
    out = []
    for a in sorted(set(addrs)):
        if out and a == out[-1][0] + out[-1][1]:
            out[-1][1] += 1
        else:
            out.append([a, 1])
    return out


class Gateway:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lo, self.hi = cfg.get("scale", [0, 1000])
        self.nodes = {}   # node id string -> asyncua Node
        self.cache = {}   # node id -> last value we set; a differing datachange is a client write
        self.points = {}  # node id -> (rtu dict, point dict)
        self.clients = {}
        self.dnp3 = {}    # rtu name -> (master, soe handler, runner, lock); one persistent connection per RTU

    async def start(self):
        s = self.server = Server()
        await s.init()
        s.set_endpoint(self.cfg.get("opc_endpoint", "opc.tcp://0.0.0.0:4840"))
        s.set_server_name("waterway OPC gateway")
        s.set_security_policy([ua.SecurityPolicyType.NoSecurity])
        idx = await s.register_namespace(NS_URI)
        assert idx == 2, f"expected namespace index 2, got {idx}"  # node ids are published as ns=2
        for rtu in self.cfg["rtus"]:
            for p in rtu["points"]:
                n = await s.nodes.objects.add_variable(
                    ua.NodeId(p["node"], idx), ua.QualifiedName(p["node"], idx), 0.0, ua.VariantType.Double)
                if p.get("write"):
                    await n.set_writable()
                self.nodes[p["node"]] = n
                self.points[p["node"]] = (rtu, p)
                self.cache[p["node"]] = 0.0
        await s.start()
        sub = await s.create_subscription(100, self)
        await sub.subscribe_data_change([self.nodes[k] for k, (_, p) in self.points.items() if p.get("write")])
        self.task = asyncio.create_task(self.poll_forever())

    async def stop(self):
        self.task.cancel()
        for c in self.clients.values():
            c.close()
        for _, _, runner, _ in self.dnp3.values():
            await runner.close()
        await self.server.stop()

    # asyncua subscription handler: forward client writes to the RTU holding register
    def datachange_notification(self, node, val, data):
        nid = node.nodeid.Identifier
        if val is not None and nid in self.cache and val != self.cache[nid]:  # val None = our own Bad-status write
            self.cache[nid] = val
            asyncio.create_task(self.write_through(nid, val))

    async def write_through(self, nid, val):
        rtu, p = self.points[nid]
        w = p["write"]
        try:
            if rtu.get("protocol") == "dnp3":
                await self.dnp3_write(rtu, w["address"], val)
            else:
                c = await self.client(rtu)
                if w["type"] == "coil":
                    r = await c.write_coil(w["address"], bool(val), device_id=rtu.get("unit", 1))
                    if r.isError():
                        raise IOError(str(r))
                    log.info("%s <- %s (coil %d)", nid, val, w["address"])
                    return
                r = await c.write_register(w["address"], to_raw(val, *rtu.get("scale", (self.lo, self.hi))), device_id=rtu.get("unit", 1))
                if r.isError():
                    raise IOError(str(r))
            log.info("%s <- %s (%s %d)", nid, val, w["type"], w["address"])
        except Exception as e:  # noqa: BLE001 - keep serving; the next poll shows the real state
            log.warning("write %s failed: %s", nid, e)

    async def client(self, rtu):
        c = self.clients.get(rtu["name"])
        if c is None:
            c = self.clients[rtu["name"]] = AsyncModbusTcpClient(rtu["host"], port=rtu.get("port", 502), timeout=3)
        if not c.connected:
            await c.connect()
        return c

    async def dnp3_session(self, rtu):
        """(master, handler, runner, lock) for this RTU, connected; a dropped link is reopened here."""
        s = self.dnp3.get(rtu["name"])
        if s is None:
            h = DefaultSOEHandler()
            m = Master(config=MasterConfig(address=rtu.get("master", 1), outstation_address=rtu.get("outstation", 10),
                                           enable_unsolicited_on_startup=False, startup_integrity_poll=False), handler=h)
            r = MasterTcpRunner(master=m, host=rtu["host"], port=rtu.get("port", 20000), response_timeout=3.0)
            s = self.dnp3[rtu["name"]] = (m, h, r, asyncio.Lock())
        if not s[2].is_open:
            await s[2].close()  # drop remnants of a dead connection before reopening
            await s[2].open()
        return s

    async def dnp3_read(self, rtu):
        m, h, r, lock = await self.dnp3_session(rtu)
        try:
            async with lock:
                res = await r.integrity_poll()
            if not res or any(x.function.name != "RESPONSE" for x in res):
                raise IOError(f"integrity poll: {res}")
        except BaseException:
            await r.close()  # next cycle reconnects
            raise
        return {("analog-input", i): v.value for i, v in h.analog_inputs.items()}

    async def dnp3_write(self, rtu, index, val):
        m, h, r, lock = await self.dnp3_session(rtu)
        async with lock:
            res = await r.request(m.build_direct_operate(float_operate(index, val)))
        if not res or res[0].function.name != "RESPONSE":
            raise IOError(f"direct operate: {res}")

    async def modbus_read(self, rtu):
        """-> {(type, address): engineering value}"""
        unit = rtu.get("unit", 1)
        regs = {}
        c = await self.client(rtu)
        want = {}
        for p in rtu["points"]:
            r = p["read"]
            want.setdefault(r["type"], []).append(r["address"])
        for typ, addrs in want.items():
            bits = typ in ("discrete-input", "coil")   # binary fields (pump.control, branch.active ...): 1.0 / 0.0, never scaled
            fn = {"input-register": c.read_input_registers, "holding-register": c.read_holding_registers,
                  "discrete-input": c.read_discrete_inputs, "coil": c.read_coils}[typ]
            for start, count in runs(addrs):
                r = await fn(start, count=count, device_id=unit)
                if r.isError():
                    raise IOError(str(r))
                if bits:
                    regs.update({(typ, start + i): float(b) for i, b in enumerate(r.bits[:count])})
                    continue
                regs.update({(typ, start + i): to_eng(v, *rtu.get("scale", (self.lo, self.hi))) for i, v in enumerate(r.registers)})
        return regs

    async def poll_rtu(self, rtu):
        regs = {}  # (type, address) -> engineering value
        try:
            regs = await (self.dnp3_read(rtu) if rtu.get("protocol") == "dnp3" else self.modbus_read(rtu))
            good = all((p["read"]["type"], p["read"]["address"]) in regs for p in rtu["points"])
            if not good:
                log.warning("poll %s: points missing from the response", rtu["name"])
        except Exception as e:  # noqa: BLE001
            log.warning("poll %s failed: %s", rtu["name"], e)
            good = False
        for p in rtu["points"]:
            nid = p["node"]
            if good:
                v = round(float(regs[(p["read"]["type"], p["read"]["address"])]), 3)
                self.cache[nid] = v  # set before write so our own datachange is not seen as a client write
                await self.nodes[nid].write_value(ua.DataValue(ua.Variant(v, ua.VariantType.Double)))
            else:  # keep last value, flag Bad so clients (Telegraf, FUXA) see the outage
                dv = ua.DataValue(ua.Variant(self.cache[nid], ua.VariantType.Double),
                                  StatusCode=ua.StatusCode(ua.StatusCodes.BadCommunicationError))
                await self.nodes[nid].write_value(dv)

    async def poll_forever(self):
        while True:
            for r in await asyncio.gather(*(self.poll_rtu(r) for r in self.cfg["rtus"]), return_exceptions=True):
                if isinstance(r, Exception):
                    log.exception("poll error", exc_info=r)
            await asyncio.sleep(self.cfg.get("poll_interval", 1.0))


async def serve(cfg):
    g = Gateway(cfg)
    await g.start()
    log.info("serving %d nodes on %s", len(g.nodes), cfg.get("opc_endpoint"))
    try:
        await asyncio.Event().wait()
    finally:
        await g.stop()


# ---------------------------------------------------------------- self-test
async def _self_test():
    from asyncua import Client
    from pymodbus.server import ModbusTcpServer
    from pymodbus.simulator import DataType, SimData, SimDevice

    # fake RTU: input regs at 30000.. (height 250, lock 500), holding at 40000.. (bennu keys by absolute address)
    dev = SimDevice(1, simdata=[
        SimData(30000, values=[to_raw(250.0, 0, 1000), to_raw(500.0, 0, 1000), 0, 0, 0, 0, 0, 0], datatype=DataType.REGISTERS),
        SimData(40000, values=[0] * 4, datatype=DataType.REGISTERS)])
    mb = ModbusTcpServer(dev, address=("127.0.0.1", 15020))
    mb_task = asyncio.create_task(mb.serve_forever())
    await asyncio.sleep(0.5)
    probe = AsyncModbusTcpClient("127.0.0.1", port=15020)
    await probe.connect()

    async def hr0():
        return (await probe.read_holding_registers(40000, count=1, device_id=1)).registers[0]

    cfg = {"opc_endpoint": "opc.tcp://127.0.0.1:14840", "poll_interval": 0.2, "scale": [0, 1000],
           "rtus": [{"name": "rtu-t", "host": "127.0.0.1", "port": 15020, "unit": 1, "points": [
               {"node": "rtu-t.lowerwater.height", "read": {"type": "input-register", "address": 30000}, "write": None},
               {"node": "rtu-t.lock.height", "read": {"type": "input-register", "address": 30001}, "write": None},
               {"node": "rtu-t.lowergate.open", "read": {"type": "input-register", "address": 30002},
                "write": {"type": "holding-register", "address": 40000}}]}]}
    g = Gateway(cfg)
    await g.start()
    try:
        async with Client("opc.tcp://127.0.0.1:14840") as c:
            ns = await c.get_namespace_index(NS_URI)
            assert ns == 2, ns
            n = c.get_node("ns=2;s=rtu-t.lowerwater.height")
            for _ in range(30):
                v = await n.read_value()
                if abs(v - 250.0) < 0.1:
                    break
                await asyncio.sleep(0.1)
            assert abs(v - 250.0) < 0.1, f"read-through failed: {v}"
            assert abs(await c.get_node("ns=2;s=rtu-t.lock.height").read_value() - 500.0) < 0.1
            # write-through: command the gate, expect the holding register to follow
            await c.get_node("ns=2;s=rtu-t.lowergate.open").write_value(ua.DataValue(ua.Variant(1000.0, ua.VariantType.Double)))
            for _ in range(30):
                if await hr0() == 65535:
                    break
                await asyncio.sleep(0.1)
            assert await hr0() == 65535, "write-through failed"
            # no echo: our own polling must not rewrite the holding register
            await probe.write_register(40000, 123, device_id=1)
            await asyncio.sleep(0.6)
            assert await hr0() == 123, "poll echoed into holding register"
            # outage -> Bad status
            probe.close()
            await mb.shutdown()
            mb_task.cancel()
            for _ in range(40):
                dv = await n.read_data_value(raise_on_bad_status=False)
                if not dv.StatusCode.is_good():
                    break
                await asyncio.sleep(0.2)
            assert not dv.StatusCode.is_good(), "RTU outage not flagged"
    finally:
        await g.stop()
    assert runs([30000, 30001, 30002, 30005, 30006]) == [[30000, 3], [30005, 2]]
    print("opcua_gateway self-test ok")


async def _self_test_dnp3():
    """Fake DNP3 RTU (dnp3py outstation, address 10, master 1): AI 0..2, direct operate on AO 3 lands in AI 2 (gate)."""
    from asyncua import Client
    from dnp3.outstation import CommandResult, DefaultCommandHandler, Outstation, OutstationConfig, OutstationTcpRunner

    class Handler(DefaultCommandHandler):
        def direct_operate_analog_output(self, index, value):
            if index != 3:
                return CommandResult.not_supported()
            db.update_analog_input(2, value)  # the RTU applies the command; the gate reading follows
            return CommandResult.success()

    blk = float_operate(3, 1.5).build_request(seq=0).objects[0]  # the wire format ferrofire applies: g41v3, index 3, 1.5f
    assert (blk.header.group, blk.header.variation) == (41, 3) and blk.data == bytes([1, 3]) + struct.pack("<fB", 1.5, 0)
    out = Outstation(config=OutstationConfig(address=10, master_address=1, time_sync_required=False), handler=Handler())
    db = out.database
    for i, v in enumerate([250.0, 500.0, 0.0]):
        db.add_analog_input(i, value=v)
    srv = OutstationTcpRunner(outstation=out, host="127.0.0.1", port=15030)
    srv_task = asyncio.create_task(srv.run())
    await asyncio.sleep(0.5)
    cfg = {"opc_endpoint": "opc.tcp://127.0.0.1:14841", "poll_interval": 0.2,
           "rtus": [{"name": "rtu-d", "host": "127.0.0.1", "protocol": "dnp3", "port": 15030, "master": 1, "outstation": 10,
                     "points": [
                         {"node": "rtu-d.lowerwater.height", "read": {"type": "analog-input", "address": 0}, "write": None},
                         {"node": "rtu-d.lock.height", "read": {"type": "analog-input", "address": 1}, "write": None},
                         {"node": "rtu-d.lowergate.open", "read": {"type": "analog-input", "address": 2},
                          "write": {"type": "analog-output", "address": 3}}]}]}
    g = Gateway(cfg)
    await g.start()
    try:
        async with Client("opc.tcp://127.0.0.1:14841") as c:
            async def until(node, want):
                for _ in range(40):
                    v = await c.get_node(node).read_value()
                    if abs(v - want) < 0.01:
                        return
                    await asyncio.sleep(0.1)
                raise AssertionError(f"{node}: wanted {want}, got {v}")
            await until("ns=2;s=rtu-d.lowerwater.height", 250.0)   # engineering units pass through unscaled
            await until("ns=2;s=rtu-d.lock.height", 500.0)
            await c.get_node("ns=2;s=rtu-d.lowergate.open").write_value(ua.DataValue(ua.Variant(1.0, ua.VariantType.Double)))
            for _ in range(40):                                    # g41v3 direct operate reached the RTU
                if abs(db.get_analog_input(2).value - 1.0) < 1e-6:
                    break
                await asyncio.sleep(0.1)
            assert abs(db.get_analog_input(2).value - 1.0) < 1e-6, "RTU did not receive the command"
            await asyncio.sleep(0.6)                               # and the following polls read it back, no echo
            await until("ns=2;s=rtu-d.lowergate.open", 1.0)
            await srv.stop()                                       # outage -> Bad status
            srv_task.cancel()
            for _ in range(60):
                dv = await c.get_node("ns=2;s=rtu-d.lock.height").read_data_value(raise_on_bad_status=False)
                if not dv.StatusCode.is_good():
                    break
                await asyncio.sleep(0.2)
            assert not dv.StatusCode.is_good(), "DNP3 RTU outage not flagged"
    finally:
        await g.stop()
    print("opcua_gateway dnp3 self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default="/etc/sceptre/opc_gateway.json")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if a.self_test:
        asyncio.run(_self_test())
        asyncio.run(_self_test_dnp3())
    else:
        with open(a.config) as f:
            asyncio.run(serve(json.load(f)))


if __name__ == "__main__":
    sys.exit(main())
