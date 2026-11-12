# added Modbus traffic: input-register polls of both RTUs every 1 s; logs "epoch,ip,addr,value" (client-side truth).
import asyncio, sys, time
from pymodbus.client import AsyncModbusTcpClient
dur = float(sys.argv[1]); out = open(sys.argv[2], "w", buffering=1)
async def main():
    cl = {ip: AsyncModbusTcpClient(ip, port=502) for ip in ("10.1.1.101", "10.1.1.102")}
    for c in cl.values(): await c.connect()
    n = {"10.1.1.101": 10, "10.1.1.102": 8}; t0 = time.time()
    while time.time() - t0 < dur:
        for ip, c in cl.items():
            ts = time.time(); r = await c.read_input_registers(30000, count=n[ip], device_id=1)
            if r.isError(): print("ERR", ip, r, flush=True)
            for i, v in enumerate(getattr(r, "registers", [])): out.write("%.4f,%s,%d,%d\n" % (ts, ip, 30000 + i, v))
        await asyncio.sleep(1.0)
asyncio.run(main())
