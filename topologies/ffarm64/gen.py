#!/usr/bin/env python3
"""ffarm64 (ww-7mw.2): smallest range that boots ferrofire field devices from topology+scenario alone, no manual steps.
  ff-provider  simulator: Ferrofire (sceptre-phenix-apps #217), model injected by the app          (MGMT 172.16.1.2)
  rtu-1        fd-server, firmware: ferrofire (#218), modbus: pump, valve, storagetank              (ICS 10.1.1.101, MGMT 172.16.1.101)
  rtu-2        fd-server, firmware: ferrofire, dnp3: bus-1, generator-1_bus-1                      (ICS 10.1.1.102, MGMT 172.16.1.102)
  probe        bennu-ferrofire image on ICS; only used to speak Modbus/DNP3 to the RTUs for the check
usage: gen.py -> ffarm64-topology.yaml ffarm64-scenario.yaml (needs pyyaml)"""
import yaml
A = "/phenix/topologies/ffarm64"
ADV = "-bios /usr/share/AAVMF/AAVMF_CODE.fd"
def nic(name, addr, vlan):
    return {"name": name, "address": addr, "mask": 24 if vlan == "ICS" else 16, "proto": "static", "type": "ethernet", "vlan": vlan}
def vm(host, image, ifs, mem=1024, vcpus=2):
    return {"general": {"hostname": host}, "hardware": {"cpu": "host", "memory": mem, "vcpus": vcpus, "os_type": "linux",
            "drives": [{"image": image, "interface": "virtio", "inject_partition": 2}]},
            "advanced": {"machine": "virt", "vga": "virtio", "qemu-append": ADV},
            "overrides": {"bus=usb-bus.0": "bus=xhci.0"}, "network": {"interfaces": ifs}, "type": "VirtualMachine"}
RTU = "ferrofire-rtu-arm64.qc2"
nodes = [vm("ff-provider", "bennu-ferrofire-arm64.qc2", [nic("mgmt", "172.16.1.2", "MGMT")], mem=2048),
         vm("rtu-1", RTU, [nic("IF0", "10.1.1.101", "ICS"), nic("mgmt", "172.16.1.101", "MGMT")]),
         vm("rtu-2", RTU, [nic("IF0", "10.1.1.102", "ICS"), nic("mgmt", "172.16.1.102", "MGMT")]),
         vm("probe", "bennu-ferrofire-arm64.qc2", [nic("IF0", "10.1.1.20", "ICS")])]
def dev(*p):
    return [{"name": n, "type": t} for n, t in p]
hosts = [{"hostname": "ff-provider", "metadata": {"type": "provider", "simulator": "Ferrofire", "model": A + "/injects/model.yaml",
                                                    "publish_endpoint": "udp://*;239.0.0.1:40000"}},
         {"hostname": "rtu-1", "metadata": {"type": "fd-server", "provider": "ff-provider", "firmware": "ferrofire", "infrastructure": "batch-process",
                                            "modbus": dev(("pump", "pump"), ("valve", "valve"), ("storagetank", "storagetank"))}},
         {"hostname": "rtu-2", "metadata": {"type": "fd-server", "provider": "ff-provider", "firmware": "ferrofire", "infrastructure": "power-transmission",
                                            "dnp3": dev(("bus-1", "bus"), ("generator-1_bus-1", "generator"))}}]
topo = {"apiVersion": "phenix.sandia.gov/v1", "kind": "Topology", "metadata": {"name": "ffarm64"}, "spec": {"nodes": nodes}}
scen = {"apiVersion": "phenix.sandia.gov/v2", "kind": "Scenario", "metadata": {"name": "ffarm64", "annotations": {"topology": "ffarm64"}},
        "spec": {"apps": [{"name": "sceptre", "assetDir": A, "hosts": hosts}]}}
for n, d in (("topology", topo), ("scenario", scen)):
    yaml.safe_dump(d, open(f"ffarm64-{n}.yaml", "w"), sort_keys=False, width=10000)
