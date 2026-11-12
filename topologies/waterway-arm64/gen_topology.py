#!/usr/bin/env python3
"""Emit topologies/waterway-arm64/waterway-topology.yaml (upstream node list, arm64 Linux guests).
Self-check: python3 -I gen_topology.py --self-test   (needs pyyaml)"""
import sys, yaml

ADV = "-bios /usr/share/AAVMF/AAVMF_CODE.fd"
GUI = ADV + " -device virtio-gpu-pci -device usb-kbd,bus=xhci.0"  # no GPU/keyboard on virt otherwise
I = "/phenix/topologies/waterway-arm64/injects/"

def inj(src, dst, perms="0644"):
    return {"src": I + src, "dst": dst, "description": src, "permissions": perms}

# --linux-fuxa: the sceptre app injects the SCADA configs itself, so drop the static ones (keep 10-noblank.conf)
LINUX_FUXA = "--linux-fuxa" in sys.argv
# --mqtt: add an mqtt-broker node (Mosquitto, ICS VLAN 10.1.1.60) for field-device MQTT; default output unchanged
MQTT = "--mqtt" in sys.argv

# --dnp3: rtu-1/rtu-2 run ferrofire's field device (Modbus 502 + DNP3 20000) behind a bennu-field-deviced shim
DNP3 = "--dnp3" in sys.argv

def vm(host, desc, image, ifs, mem=1024, vcpus=2, gui=False, injections=None, os="linux", kind="VirtualMachine"):
    n = {"general": {"hostname": host, "description": desc},
         "hardware": {"cpu": "host", "memory": mem, "vcpus": vcpus, "os_type": os,
                      "drives": [{"image": image, "interface": "virtio", "inject_partition": 2}]},
         "advanced": {"machine": "virt", "vga": "virtio", "qemu-append": GUI if gui else ADV},
         "overrides": {"bus=usb-bus.0": "bus=xhci.0"},
         "network": {"interfaces": ifs}, "type": kind}
    if LINUX_FUXA and injections:
        injections = [i for i in injections if i[0] in ("10-noblank.conf", "ferrofire", "ferrofire-fd-shim.sh")]
    if injections:
        n["injections"] = [inj(*i) for i in injections]
    return n

def nic(name, addr, mask, vlan, gw=None, proto="static"):
    d = {"name": name, "address": addr, "mask": mask, "proto": proto, "type": "ethernet", "vlan": vlan}
    if gw:
        d["gateway"] = gw
    return d

def scada_host(host, desc, image, ip, **kw):
    return vm(host, desc, image, [nic("IF0", f"10.1.2.{ip}", 24, "SCADA", "10.1.2.1"),
                                  nic("mgmt", f"172.16.2.{ip}", 16, "MGMT")], **kw)

def rtu(host, n):
    # shim goes to /usr/local/bin: /usr/bin/bennu-field-deviced is a symlink to it (bennu-arm64.sh), and injecting
    # onto a real file avoids guessing how phenix treats a symlink dst
    extra = [("ferrofire", "/usr/local/bin/ferrofire", "0755"),
           ("ferrofire-fd-shim.sh", "/usr/local/bin/bennu-field-deviced", "0755")] if DNP3 else None
    return vm(host, "SCEPTRE RTU", "bennu-arm64.qc2",
              [nic("IF0", f"10.1.1.{100+n}", 24, "ICS", "10.1.1.1"), nic("mgmt", f"172.16.1.{100+n}", 16, "MGMT")],
              injections=extra)

NOBLANK = ("10-noblank.conf", "/etc/X11/xorg.conf.d/10-noblank.conf")  # virtio-gpu scanout goes dead after DPMS standby
nodes = [
    vm("waterway-provider", "SCEPTRE Simulink provider (Rust simulinksolver)", "bennu-arm64.qc2",
       [nic("mgmt", "172.16.1.2", 16, "MGMT", "172.16.1.1")], mem=2048),
    scada_host("opc", "OPC UA gateway", "opc-arm64.qc2", 50,
               injections=[("opc_gateway.json", "/etc/sceptre/opc_gateway.json")]),
    scada_host("historian", "InfluxDB + telegraf", "historian-arm64.qc2", 60, mem=2048,
               injections=[("telegraf.conf", "/etc/telegraf/telegraf.conf"),
                           ("influx-setup.sh", "/etc/phenix/startup/influx-setup.sh")]),
    scada_host("hmi", "Firefox kiosk on FUXA", "hmi-arm64.qc2", 70, mem=2048, gui=True,
               injections=[("hmi_url", "/etc/sceptre/hmi_url"), NOBLANK]),
    scada_host("scada-server", "FUXA", "scada-arm64.qc2", 71, mem=2048,
               injections=[("fuxa_project.json", "/etc/sceptre/fuxa_project.json")]),
    scada_host("engineer-workstation", "xfce + brash terminals", "engineer-arm64.qc2", 72, mem=2048, gui=True,
               injections=[("rtus.txt", "/etc/sceptre/rtus.txt"), NOBLANK]),
    rtu("rtu-1", 1), rtu("rtu-2", 2),
    vm("router", "Router", "minirouter-arm64.qc2",
       [nic("IF0", "10.1.2.1", 24, "SCADA"), nic("IF1", "10.1.1.1", 24, "ICS"), nic("mgmt", "172.16.1.1", 16, "MGMT")],
       os="minirouter", kind="Router"),
]
if MQTT:
    nodes.append(vm("mqtt-broker", "Mosquitto MQTT broker", "mqtt-arm64.qc2",
                    [nic("IF0", "10.1.1.60", 24, "ICS", "10.1.1.1"), nic("mgmt", "172.16.1.60", 16, "MGMT")],
                    mem=512, vcpus=1))
doc = {"apiVersion": "phenix.sandia.gov/v1", "kind": "Topology", "metadata": {"name": "waterway-arm64"},
       "spec": {"nodes": nodes}}

if __name__ == "__main__":
    if "--self-test" in sys.argv:
        k = 10 if MQTT else 9
        assert len(nodes) == k and len({n["general"]["hostname"] for n in nodes}) == k
        ips = [i["address"] for n in nodes for i in n["network"]["interfaces"]]
        assert len(ips) == len(set(ips)), "duplicate address"
        assert all(n["hardware"]["os_type"] != "windows" for n in nodes)
        print("gen_topology self-test ok")
    else:
        print(yaml.safe_dump(doc, sort_keys=False), end="")
