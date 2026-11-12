#!/usr/bin/env python3
"""pump-station-arm64 (ww-1df.10): ferrofire pump-station + feeder model on the range, route (a) of docs/provider-spec.md section 5:
`simulator: Simulink` provider running ferrofire as simulinksolver with model.yaml injected next to it (stock bennu provider publishes).
  rtu-1  batch-process      pump, valve, storagetank          (ICS 10.1.1.101)
  rtu-2  power-transmission bus-1, bus-3, branch-1_2-3, load-1_bus-3, generator-1_bus-1   (ICS 10.1.1.102)
  opc, historian, scada-server (FUXA) on SCADA; router joins ICS and SCADA.  Writes: pump.control, valve.open, branch-1_2-3.active.
usage: gen.py   -> pump-station-topology.yaml, pump-station-scenario.yaml (needs pyyaml)"""
import yaml
ADV = "-bios /usr/share/AAVMF/AAVMF_CODE.fd"
A = "/phenix/topologies/pump-station-arm64"
I = A + "/injects/"
def inj(src, dst, perms="0644"):
    return {"src": I + src, "dst": dst, "description": src, "permissions": perms}
def nic(name, addr, mask, vlan, gw=None):
    d = {"name": name, "address": addr, "mask": mask, "proto": "static", "type": "ethernet", "vlan": vlan}
    if gw:
        d["gateway"] = gw
    return d
def vm(host, desc, image, ifs, mem=1024, vcpus=2, injections=None, os="linux", kind="VirtualMachine"):
    n = {"general": {"hostname": host, "description": desc},
         "hardware": {"cpu": "host", "memory": mem, "vcpus": vcpus, "os_type": os,
                      "drives": [{"image": image, "interface": "virtio", "inject_partition": 2}]},
         "advanced": {"machine": "virt", "vga": "virtio", "qemu-append": ADV},
         "overrides": {"bus=usb-bus.0": "bus=xhci.0"}, "network": {"interfaces": ifs}, "type": kind}
    if injections:
        n["injections"] = [inj(*i) for i in injections]
    return n
def scada(host, desc, image, ip, **kw):
    return vm(host, desc, image, [nic("IF0", f"10.1.2.{ip}", 24, "SCADA", "10.1.2.1"), nic("mgmt", f"172.16.2.{ip}", 16, "MGMT")], **kw)
def rtu(host, n):
    return vm(host, "SCEPTRE RTU", "bennu-arm64.qc2", [nic("IF0", f"10.1.1.{100 + n}", 24, "ICS", "10.1.1.1"),
                                                      nic("mgmt", f"172.16.1.{100 + n}", 16, "MGMT")])
nodes = [
    vm("pump-provider", "Simulink provider: ferrofire solver + pump-station model", "bennu-arm64.qc2",
       [nic("mgmt", "172.16.1.2", 16, "MGMT", "172.16.1.1")], mem=2048,
       injections=[("model.yaml", "/etc/sceptre/model.yaml")]),
    scada("opc", "OPC UA gateway", "opc-arm64.qc2", 50,
          injections=[("opc_gateway.json", "/etc/sceptre/opc_gateway.json"),
                      ("opcua_gateway.py", "/opt/opcua-gateway/opcua_gateway.py")]),   # coil + per-RTU scale (newer than the image)
    scada("historian", "InfluxDB + telegraf", "historian-arm64.qc2", 60, mem=2048,
          injections=[("telegraf.conf", "/etc/telegraf/telegraf.conf"), ("influx-setup.sh", "/etc/phenix/startup/influx-setup.sh")]),
    scada("scada-server", "FUXA", "scada-arm64.qc2", 71, mem=2048, injections=[("fuxa_project.json", "/etc/sceptre/fuxa_project.json")]),
    rtu("rtu-1", 1), rtu("rtu-2", 2),
    vm("router", "Router", "minirouter-arm64.qc2", [nic("IF0", "10.1.2.1", 24, "SCADA"), nic("IF1", "10.1.1.1", 24, "ICS"),
                                                   nic("mgmt", "172.16.1.1", 16, "MGMT")], os="minirouter", kind="Router"),
]
topo = {"apiVersion": "phenix.sandia.gov/v1", "kind": "Topology", "metadata": {"name": "pump-station-arm64"}, "spec": {"nodes": nodes}}
def dev(*pairs):
    return [{"name": n, "type": t} for n, t in pairs]
hosts = [
    {"hostname": "pump-provider", "metadata": {"type": "provider", "simulator": "Simulink", "publish_endpoint": "udp://*;239.0.0.1:40000",
                                               "publish_points": I + "publishPoints.txt", "solver": I + "simulinksolver"}},
    {"hostname": "rtu-1", "metadata": {"type": "fd-server", "provider": "pump-provider", "infrastructure": "batch-process",
                                       "modbus": dev(("pump", "pump"), ("valve", "valve"), ("storagetank", "storagetank"))}},
    {"hostname": "rtu-2", "metadata": {"type": "fd-server", "provider": "pump-provider", "infrastructure": "power-transmission",
                                       "modbus": dev(("bus-1", "bus"), ("bus-3", "bus"), ("branch-1_2-3", "branch"),
                                                     ("load-1_bus-3", "load"), ("generator-1_bus-1", "generator"))}},
]
scen = {"apiVersion": "phenix.sandia.gov/v2", "kind": "Scenario",
        "metadata": {"name": "pump-station-arm64", "annotations": {"topology": "pump-station-arm64"}},
        "spec": {"apps": [{"name": "sceptre", "assetDir": A, "hosts": hosts}]}}
if __name__ == "__main__":
    for n, d in (("topology", topo), ("scenario", scen)):
        yaml.safe_dump(d, open(f"pump-station-{n}.yaml", "w"), sort_keys=False, width=10000)
    print("wrote pump-station-topology.yaml pump-station-scenario.yaml")
