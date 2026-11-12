#!/usr/bin/env python3
"""Emit topologies/control-bench-arm64/control-bench-topology.yaml: the live-range subset of the ferrofire control-latency bench (ferrofire ww-1df.23.5).
One flat ICS VLAN (no router), a provider VM that also runs the SCADA driver (one clock for every timestamp) and up to 5 RTU VMs; all boot the
bennu-ferrofire-arm64 image (stock pybennu + bennu-field-deviced AND ferrofire, so one boot serves the ferrofire and the stock stack).
Boot stagger (ww-344.6/ww-344.9): provider, rtu-1, rtu-2 boot with the experiment; rtu-3..5 are do_not_boot and the bench starts them with `phenix vm restart` once the first batch has cc clients.
No scenario: nothing autostarts, the bench (ferrofire bench/range/run_range.py) drives the VMs through minimega cc.
  gen_topology.py [--rtus 5] [--image bennu-ferrofire-arm64.qc2]      Self-check: gen_topology.py --self-test   (needs pyyaml)"""
import argparse, sys, yaml

ADV = "-bios /usr/share/AAVMF/AAVMF_CODE.fd"

def nic(addr):
    return {"name": "IF0", "address": addr, "mask": 24, "proto": "static", "type": "ethernet", "vlan": "ICS"}

def vm(host, desc, image, addr, mem, vcpus, dnb=False):
    return {"general": {"hostname": host, "description": desc, **({"do_not_boot": True} if dnb else {})},
            "hardware": {"cpu": "host", "memory": mem, "vcpus": vcpus, "os_type": "linux",
                         "drives": [{"image": image, "interface": "virtio", "inject_partition": 2}]},
            "advanced": {"machine": "virt", "vga": "virtio", "qemu-append": ADV},
            "overrides": {"bus=usb-bus.0": "bus=xhci.0"},  # no usb-bus on machine virt (as waterway-arm64)
            "network": {"interfaces": [nic(addr)]}, "type": "VirtualMachine"}

def topology(rtus, image):
    nodes = [vm("provider", "provider + SCADA driver of the control bench", image, "10.1.1.10", 3072, 4)]
    nodes += [vm(f"rtu-{n}", "RTU of the control bench", image, f"10.1.1.{100 + n}", 1024, 2, dnb=n > 2) for n in range(1, rtus + 1)]
    return {"apiVersion": "phenix.sandia.gov/v1", "kind": "Topology", "metadata": {"name": "control-bench-arm64"}, "spec": {"nodes": nodes}}

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--rtus", type=int, default=5)
    a.add_argument("--image", default="bennu-ferrofire-arm64.qc2")
    a.add_argument("--self-test", action="store_true")
    a = a.parse_args()
    doc = topology(a.rtus, a.image)
    if a.self_test:
        n = doc["spec"]["nodes"]
        assert len(n) == a.rtus + 1 and len({x["general"]["hostname"] for x in n}) == len(n)
        ips = [i["address"] for x in n for i in x["network"]["interfaces"]]
        assert len(ips) == len(set(ips))
        print("gen_topology self-test ok")
    else:
        print(yaml.safe_dump(doc, sort_keys=False), end="")
