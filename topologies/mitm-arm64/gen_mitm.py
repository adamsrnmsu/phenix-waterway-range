#!/usr/bin/env python3
"""Emit mitm-arm64 topology+scenario from the PR #31 mitm node list on our arm64 images:
derived from waterway-arm64 (Linux opc gateway, Rust simulinksolver) + a kali-arm64 attacker.
Usage: python3 -I gen_mitm.py [--no-blue]   (needs pyyaml; writes next to this file)
Default includes the `blue` Kali Purple + Malcolm node (capture NIC on the MIRROR vlan; see scripts/mirror.sh)."""
import copy, os, sys, yaml
H = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(H, "..", "waterway-arm64")
A = "/phenix/topologies/mitm-arm64"
topo = yaml.safe_load(open(f"{W}/waterway-topology.yaml"))
scen = yaml.safe_load(open(f"{W}/waterway-scenario.yaml"))
keep = {"waterway-provider": "simulink-provider", "opc": "opc", "rtu-1": "rtu-1", "rtu-2": "rtu-2", "router": "router"}
nodes = []
for n in topo["spec"]["nodes"]:
    h = n["general"]["hostname"]
    if h not in keep:
        continue
    n["general"]["hostname"] = keep[h]
    for i in n.get("injections", []):
        i["src"] = i["src"].replace("/waterway-arm64/", "/mitm-arm64/")
    nodes.append(n)
kali = copy.deepcopy(next(n for n in nodes if n["general"]["hostname"] == "rtu-1"))
kali["general"] = {"hostname": "kali", "description": "Kali attacker (ettercap MITM)"}
kali["hardware"].update(memory=4096, vcpus=2)
kali["hardware"]["drives"][0]["image"] = "kali-arm64.qc2"
kali["network"]["interfaces"][0]["address"] = "10.1.1.200"
kali["network"]["interfaces"][1]["address"] = "172.16.1.200"
nodes.append(kali)
if "--no-blue" not in sys.argv:
    blue = yaml.safe_load(open(f"{H}/../blue-test/blue-test.yaml"))["spec"]["nodes"][0]
    blue["general"]["description"] = "Blue team: Kali Purple + Malcolm (eth0 mgmt, eth1 capture NIC fed by OVS mirror)"
    blue["hardware"].update(memory=24576, vcpus=8)   # Malcolm needs >=20 GiB (16 GiB thrashed, ww-ebo.7); 24 GiB for Firefox headroom (ww-ebo.10)
    ifs = blue["network"]["interfaces"]
    ifs[0].update(address="172.16.1.250", vlan="MGMT")
    ifs[1].update(vlan="MIRROR")
    nodes.append(blue)
topo["metadata"]["name"] = "mitm-arm64"
topo["spec"]["nodes"] = nodes
scen["metadata"] = {"name": "mitm-arm64", "annotations": {"topology": "mitm-arm64"}}
app = scen["spec"]["apps"][0]
app["assetDir"] = A
for h in app["hosts"]:
    m = h["metadata"]
    if m["type"] == "provider":
        h["hostname"] = "simulink-provider"
        m["publish_points"] = f"{A}/injects/publishPoints.txt"
        m["solver"] = f"{A}/injects/simulinksolver"
    else:
        m["provider"] = "simulink-provider"
# SCORCH: the ettercap component poisons rtu-1 <-> router (the PR/burger pair); tcpdump captures on kali.
# Guest NICs are eth0 (ICS) / eth1 (mgmt) on Linux, not the topology name IF0. Two runs so the attack
# can be observed between start and stop (a single run would stop it straight away).
scen["spec"]["apps"].append({"name": "scorch", "metadata": {
    "components": [
        {"name": "ettercap", "type": "ettercap", "metadata": {"vms": [
            {"hostname": "kali", "iface": "eth0", "targets": "/10.1.1.101// /10.1.1.1//"}]}},
        {"name": "mitm-capture", "type": "tcpdump", "metadata": {"vms": [
            {"hostname": "kali", "iface": "eth0", "filter": "tcp port 502"}]}}],
    "runs": [{"name": "mitm-start", "start": ["mitm-capture", "ettercap"]},
             {"name": "mitm-stop", "stop": ["ettercap", "mitm-capture"]}]}})
yaml.safe_dump(topo, open(f"{H}/mitm-topology.yaml", "w"), sort_keys=False, width=10000)
yaml.safe_dump(scen, open(f"{H}/mitm-scenario.yaml", "w"), sort_keys=False, width=10000)
assert [n["general"]["hostname"] for n in nodes][:6] == ["simulink-provider", "opc", "rtu-1", "rtu-2", "router", "kali"]
