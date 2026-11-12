#!/usr/bin/env python3
"""Render the SCADA-side role configs for the waterway range from the sceptre app's register map.

Single source of truth for addresses. Inputs:
  reg_addrs.json  - what `phenix-app-sceptre pre-start` writes to <baseDir>/elk/reg_addrs.json
                    (prestart.py elk_files: {ip, register_type, address, name, field} per modbus register).
                    Produce it with --from-dry-run (runs the app's own --dry-run, no phenix needed).
  topology yaml   - node hostnames + interface addresses.
Outputs (default topologies/waterway-arm64/injects/):
  opc_gateway.json      -> /etc/sceptre/opc_gateway.json      (scada/opcua_gateway.py config)
  fuxa_project.json     -> /etc/sceptre/fuxa_project.json     (scada/fuxa_project.json.j2)
  telegraf.conf         -> /etc/telegraf/telegraf.conf        (scada/telegraf.conf.j2)
  influx-setup.sh       -> /etc/phenix/startup/influx-setup.sh
  hmi_url               -> /etc/sceptre/hmi_url               one line: http://<scada-ip>:1881/
  rtus.txt              -> /etc/sceptre/rtus.txt              one "<hostname> <ip>" per line, sorted

OPC node id for every register point: ns=2;s=<rtu>.<device>.<field>. A (device, field) with both an
input-register and a holding-register (gate/valve `open`) is ONE node: read from the input register,
writes go to the holding register.

Usage:
  gen_configs.py [--reg-addrs F] [--topology F] [--out DIR]
  gen_configs.py --from-dry-run PATH/TO/phenix-app-sceptre --scenario F --topology F   (refresh reg_addrs.json)
  python3 -I gen_configs.py --self-test            (needs pyyaml jinja2)
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import tomllib
import xml.etree.ElementTree as ET

import jinja2
import yaml

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # python -I drops the script dir
import lock_view  # noqa: E402
REPO = HERE.parent
RANGE_DIR = REPO / "topologies" / "waterway-arm64"
UPSTREAM = pathlib.Path.home() / "git" / "sceptre-phenix-topologies" / "waterway"
OVERLAY_GW = REPO / "images/overlays/opc-arm64/opt/opcua-gateway/opcua_gateway.py"

# infrastructures.yaml `waterway: range: [0, 1000]`; bennu scales registers to 16 bit over it
SCALE = [0, 1000]
INFLUX = dict(influx_url="http://127.0.0.1:8086", influx_org="sceptre", influx_bucket="waterway",
              influx_token="waterway-historian-token")  # same values as influx-setup.sh
TYPES = {"input-register", "holding-register"}
DNP3_TYPES = {"analog-input", "analog-output"}
DNP3 = {"protocol": "dnp3", "port": 20000, "master": 1, "outstation": 10}  # ferrofire outstation answers master 1 only


def load_nodes(topology):
    spec = yaml.safe_load(open(topology))["spec"]
    return (spec.get("nodes") or spec["topology"]["nodes"])


def ifaces(node):
    return [i for i in node["network"]["interfaces"] if i.get("address")]


def data_ip(nodes, host):
    """First non-MGMT interface address of a host."""
    for n in nodes:
        if n["general"]["hostname"] == host:
            for i in ifaces(n):
                if i.get("vlan", "").lower() != "mgmt":
                    return i["address"]
    raise KeyError(f"no data-plane address for {host}")


def build(regs, nodes, dnp3=False):
    """-> (rtus, points); rtus = gateway-config rtu list, points = flat [(rtu, device, field)].
    dnp3: regs are analog-input/analog-output rows (dnp3_rows) and the gateway talks DNP3 instead of Modbus."""
    types = DNP3_TYPES if dnp3 else TYPES
    out_type = "analog-output" if dnp3 else "holding-register"
    ip2host = {i["address"]: n["general"]["hostname"] for n in nodes for i in ifaces(n)}
    rtus = {}
    for r in regs:
        if r["register_type"] not in types:
            raise NotImplementedError(f"{r['register_type']}: waterway only has {sorted(types)}")
        host = ip2host[r["ip"]]
        rtu = rtus.setdefault(host, {"name": host, "host": r["ip"], **(DNP3 if dnp3 else {"port": 502, "unit": 1}), "pts": {}})
        pt = rtu["pts"].setdefault((r["name"], r["field"]), {})
        pt["write" if r["register_type"] == out_type else "read"] = {
            "type": r["register_type"], "address": r["address"]}
    out, flat = [], []
    for host in sorted(rtus):
        rtu = rtus[host]
        points = []
        for (dev, field), pt in sorted(rtu.pop("pts").items()):
            pt.setdefault("read", pt.get("write"))  # holding-only point is read back from the holding register
            points.append({"node": f"{host}.{dev}.{field}", "read": pt["read"], "write": pt.get("write")})
            flat.append((host, dev, field))
        out.append({**rtu, "points": points})
    return out, flat


def render(regs, nodes, tpl_dir=HERE, dnp3=False):
    opc_ip = data_ip(nodes, "opc")
    gw = {"opc_endpoint": "opc.tcp://0.0.0.0:4840", "poll_interval": 1.0, "scale": SCALE}
    rtus, flat = build(regs, nodes, dnp3)
    gw["rtus"] = rtus
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(tpl_dir), keep_trailing_newline=True)
    endpoint = f"opc.tcp://{opc_ip}:4840"
    ftags = [{"rtu": r, "point": f"{d}.{f}"} for r, d, f in flat]
    fuxa = env.get_template("fuxa_project.json.j2").render(
        opc_endpoint=endpoint, tags=ftags,
        view=lock_view.build({f"{t['rtu']}.{t['point']}": f"t{i}" for i, t in enumerate(ftags, 1)}))
    json.loads(fuxa)  # fail here, not at FUXA import
    tele = env.get_template("telegraf.conf.j2").render(
        opc_endpoint=endpoint, nodes=[{"rtu": r, "device": d, "field": f, "ns": 2, "id": f"{r}.{d}.{f}"} for r, d, f in flat],
        **INFLUX)
    return {
        "opc_gateway.json": json.dumps(gw, indent=2) + "\n",
        "fuxa_project.json": fuxa,
        "telegraf.conf": tele,
        "hmi_url": f"http://{data_ip(nodes, 'scada-server')}:1881/\n",
        "rtus.txt": "".join(f"{r['name']} {r['host']}\n" for r in rtus),
    }


def write(out_dir, files):
    out_dir = pathlib.Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (out_dir / name).write_text(text)
    shutil.copy(HERE / "influx-setup.sh", out_dir / "influx-setup.sh")


def dnp3_rows(config_xml):
    """One RTU config.xml -> reg_addrs-style rows for its <dnp3-server> points. The app's reg_addrs.json is
    Modbus-only, so read the DNP3 index/type from the config itself: tag -> <input>/<output> id -> point name."""
    fd = ET.parse(config_xml).getroot().find("field-device")
    ids = {}  # io id -> "device.field"
    for sec in ("input", "output"):
        for a in fd.iterfind(f"{sec}/analog"):
            ids[a.findtext("id")] = a.findtext("name")
    ext = {t.findtext("name"): t.findtext("io") for t in fd.iterfind("tags/external-tag")}
    srv = fd.find("comms/dnp3-server")
    if srv is None:
        return []
    ip = srv.findtext("endpoint").split("//")[1].split(":")[0]
    rows = []
    for el in srv:
        if el.tag in DNP3_TYPES:
            name, field = ids[ext[el.findtext("tag")]].split(".", 1)
            rows.append({"ip": ip, "register_type": el.tag, "address": int(el.findtext("address")),
                         "name": name, "field": field})
    return rows


def from_dry_run(app, scenario, topology, dest):
    """Run the sceptre app's pre-start --dry-run on topology+scenario; copy elk/reg_addrs.json to dest
    and write the DNP3 map (dnp3_rows of every RTU config.xml) next to it as reg_addrs_dnp3.json."""
    exp = {"metadata": {"annotations": {"topology": "waterway", "scenario": "waterway"}},
           "spec": {"experimentName": "waterway", "scenario": yaml.safe_load(open(scenario))["spec"],
                    "topology": yaml.safe_load(open(topology))["spec"]}}
    with tempfile.TemporaryDirectory() as td:
        exp["spec"]["baseDir"] = td
        subprocess.run([app, "pre-start", "--dry-run"], input=json.dumps(exp), text=True, check=True,
                       capture_output=True, env={"PHENIX_LOG_FILE": "", "PATH": "/usr/bin:/bin"})
        shutil.copy(pathlib.Path(td) / "elk" / "reg_addrs.json", dest)
        rows = [r for x in sorted(pathlib.Path(td, "sceptre").glob("*/config.xml")) for r in dnp3_rows(x)]
        pathlib.Path(dest).with_name("reg_addrs_dnp3.json").write_text(json.dumps(rows))


# ---------------------------------------------------------------- self-test
def _fixture_nodes():
    def n(host, *ifs):
        return {"general": {"hostname": host},
                "network": {"interfaces": [{"address": a, "vlan": v} for a, v in ifs]}}
    return [n("opc", ("10.1.2.50", "SCADA"), ("172.16.2.50", "MGMT")),
            n("scada-server", ("10.1.2.71", "SCADA"), ("172.16.2.71", "MGMT")),
            n("rtu-1", ("172.16.1.101", "MGMT"), ("10.1.1.101", "ICS")),
            n("rtu-2", ("10.1.1.102", "ICS"), ("172.16.1.102", "MGMT"))]


def self_test():
    regs = json.load(open(HERE / "testdata" / "reg_addrs.json"))  # real dry-run output for the upstream waterway
    files = render(regs, _fixture_nodes())
    gw = json.loads(files["opc_gateway.json"])
    fuxa = json.loads(files["fuxa_project.json"])
    tele = tomllib.loads(files["telegraf.conf"])["inputs"]["opcua"][0]
    opc_nodes = {p["node"] for r in gw["rtus"] for p in r["points"]}
    tele_ids = {n["identifier"] for n in tele["nodes"]}
    fuxa_addr = {t["address"] for t in fuxa["devices"]["d_opc"]["tags"].values()}
    ip2rtu = {r["host"]: r["name"] for r in gw["rtus"]}
    assert set(ip2rtu) == {"10.1.1.101", "10.1.1.102"} and len(regs) == 20
    for r in regs:  # every RTU register point is readable/writable through all three consumers
        node = f"{ip2rtu[r['ip']]}.{r['name']}.{r['field']}"
        assert node in opc_nodes and node in tele_ids and f"ns=2;s={node}" in fuxa_addr, node
        pt = next(p for g in gw["rtus"] for p in g["points"] if p["node"] == node)
        key = "write" if r["register_type"] == "holding-register" else "read"
        assert pt[key] == {"type": r["register_type"], "address": r["address"]}, (node, pt)
    assert opc_nodes == tele_ids == {a[len("ns=2;s="):] for a in fuxa_addr} and len(opc_nodes) == 16
    g = next(p for g in gw["rtus"] for p in g["points"] if p["node"] == "rtu-1.lowergate.open")
    assert g["read"]["address"] == 30002 and g["write"]["address"] == 40000
    assert next(p for g in gw["rtus"] for p in g["points"] if p["node"] == "rtu-1.lowerwater.height")["write"] is None
    assert tele["endpoint"] == "opc.tcp://10.1.2.50:4840" == fuxa["devices"]["d_opc"]["property"]["address"]
    assert files["hmi_url"] == "http://10.1.2.71:1881/\n"
    assert files["rtus.txt"] == "rtu-1 10.1.1.101\nrtu-2 10.1.1.102\n"
    out = tomllib.loads(files["telegraf.conf"])["outputs"]["influxdb_v2"][0]
    sh = (HERE / "influx-setup.sh").read_text()
    for k in ("org", "bucket", "token"):  # historian setup script and telegraf output agree
        assert f"INFLUX_{k.upper()}={INFLUX['influx_' + k] if k != 'token' else out['token']}" in sh, k
    assert out["bucket"] == "waterway"
    if OVERLAY_GW.exists():  # image overlay carries a copy of the gateway; keep it in sync
        assert OVERLAY_GW.read_bytes() == (HERE / "opcua_gateway.py").read_bytes(), \
            f"stale overlay: cp {HERE / 'opcua_gateway.py'} {OVERLAY_GW}"
    with tempfile.TemporaryDirectory() as td:
        write(td, files)
        assert sorted(p.name for p in pathlib.Path(td).iterdir()) == sorted(
            [*files, "influx-setup.sh"])
    if (UPSTREAM / "waterway-topology.yaml").exists():  # upstream topology gives the same addresses
        up = render(regs, load_nodes(UPSTREAM / "waterway-topology.yaml"))
        assert up == files, "upstream topology renders differently from fixture"
    # DNP3: same 16 nodes, DNP3 transport, indexes counted across the device list in order (read + write for gate/valve)
    d = json.loads(render(json.load(open(HERE / "testdata" / "reg_addrs_dnp3.json")), _fixture_nodes(), dnp3=True)["opc_gateway.json"])
    assert {p["node"] for r in d["rtus"] for p in r["points"]} == opc_nodes
    assert all(r["protocol"] == "dnp3" and r["port"] == 20000 and r["outstation"] == 10 for r in d["rtus"])
    g = next(p for r in d["rtus"] for p in r["points"] if p["node"] == "rtu-1.lowergate.open")
    assert g["read"] == {"type": "analog-input", "address": 2} and g["write"] == {"type": "analog-output", "address": 3}, g
    print("gen_configs self-test ok: 20 registers -> 16 nodes, all in opc/fuxa/telegraf (Modbus and DNP3)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    topo = RANGE_DIR / "waterway-topology.yaml"
    topo = topo if topo.exists() else UPSTREAM / "waterway-topology.yaml"
    ap.add_argument("--reg-addrs", default=str(RANGE_DIR / "reg_addrs.json"))
    ap.add_argument("--topology", default=str(topo))
    ap.add_argument("--scenario", default=str(UPSTREAM / "waterway-scenario.yaml"))
    ap.add_argument("--out", default=str(RANGE_DIR / "injects"))
    ap.add_argument("--from-dry-run", metavar="PHENIX_APP_SCEPTRE")
    ap.add_argument("--dnp3", action="store_true", help="gateway polls the RTUs over DNP3 (reg_addrs_dnp3.json)")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.from_dry_run:
        pathlib.Path(a.reg_addrs).parent.mkdir(parents=True, exist_ok=True)
        from_dry_run(a.from_dry_run, a.scenario, a.topology, a.reg_addrs)
        print(f"wrote {a.reg_addrs}")
    src = pathlib.Path(a.reg_addrs).with_name("reg_addrs_dnp3.json") if a.dnp3 else a.reg_addrs
    files = render(json.load(open(src)), load_nodes(a.topology), dnp3=a.dnp3)
    write(a.out, files)
    print(f"wrote {', '.join(files)}, influx-setup.sh to {a.out}")


if __name__ == "__main__":
    sys.exit(main())
