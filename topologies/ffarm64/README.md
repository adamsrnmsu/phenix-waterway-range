# ffarm64

The smallest arm64 range that boots ferrofire field devices from the topology and scenario alone, with no manual
steps (ww-7mw.2). It uses the Ferrofire simulator type (sceptre-phenix-apps #217) and ferrofire RTU images chosen by
`firmware: ferrofire` metadata (#218).

| node | role | addresses |
|---|---|---|
| ff-provider | `simulator: Ferrofire`; the app injects `injects/model.yaml` | MGMT 172.16.1.2 |
| rtu-1 | fd-server, Modbus: pump, valve, storagetank | ICS 10.1.1.101, MGMT 172.16.1.101 |
| rtu-2 | fd-server, DNP3: bus-1, generator-1_bus-1 | ICS 10.1.1.102, MGMT 172.16.1.102 |
| probe | bennu-ferrofire image on ICS, only for reading the RTUs | ICS 10.1.1.20 |

`gen.py` writes `ffarm64-topology.yaml` and `ffarm64-scenario.yaml` (needs pyyaml); the asset dir is
`/phenix/topologies/ffarm64`. Images: `ferrofire-rtu-arm64.qc2`, `bennu-ferrofire-arm64.qc2`.

Verified 2026-11-26 with sceptre-phenix-apps main `1b2845e`:
- All four VMs registered with cc about 75 s after `exp start`.
- The provider ran `ferrofire run ... --publish udp://*;239.0.0.1:40000`.
- Modbus input registers on rtu-1 tracked the model; tank volume rose in step with the provider.
- DNP3 analog inputs on rtu-2 matched the provider's `bus-1.voltage` and `generator-1_bus-1.mw` exactly.
- Tear it down with `scripts/exp-down.sh ffarm64`.
