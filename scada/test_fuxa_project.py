"""Self-check: python3 -I scada/test_fuxa_project.py  (needs jinja2). Renders the template + lock_view and asserts shape."""
import json, pathlib, re, sys
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lock_view
from jinja2 import Environment

POINTS = ["rtu-1.lowerwater.height", "rtu-1.lock.height", "rtu-2.lock.height", "rtu-2.upperwater.height",
          "rtu-1.lowergate.open", "rtu-2.uppergate.open", "rtu-1.lowervalve.open", "rtu-2.uppervalve.open",
          "rtu-1.boat.location", "rtu-1.boat.direction"]


def render(points):
    tags = [{"rtu": p.split(".", 1)[0], "point": p.split(".", 1)[1]} for p in points]
    ids = {p: f"t{i}" for i, p in enumerate(points, 1)}
    out = Environment().from_string((HERE / "fuxa_project.json.j2").read_text()).render(
        opc_endpoint="opc.tcp://10.1.2.50:4840", tags=tags, view=lock_view.build(ids))
    return json.loads(out), ids


p, ids = render(POINTS)
d = p["devices"]["d_opc"]
assert d["type"] == "OPCUA" and d["property"]["address"] == "opc.tcp://10.1.2.50:4840"
assert d["tags"]["t1"]["address"] == "ns=2;s=rtu-1.lowerwater.height"
v = p["hmi"]["views"][0]
items, svg = v["items"], v["svgcontent"]
# every item id is an element id in the svg, and every tag/variable it references exists
for k, it in items.items():
    assert f"id='{k}'" in svg, k
    refs = [it["property"].get("variableId")] + [a["variableId"] for a in it["property"].get("actions", [])]
    for r in filter(None, refs):
        assert r in d["tags"], (k, r)
assert {"GXP_lower", "GXP_chamber", "GXP_upper", "GATE_lower", "GATE_upper", "VALVE_lower", "VALVE_upper",
        "BOATX_lower", "BOATX_chamber", "BOATX_upper", "BOATY_chamber"} <= set(items)
# boat: x steps follow boat.location (t9), y steps follow that body's level; chamber boat y follows rtu-1.lock.height (t2)
bx = items["BOATX_chamber"]["property"]["actions"]
assert {a["variableId"] for a in bx} == {ids["rtu-1.boat.location"]}
assert {a["variableId"] for a in items["BOATY_chamber"]["property"]["actions"]} == {ids["rtu-1.lock.height"]}
xs = [a["options"]["toX"] for a in bx if a["type"] == "move"]
assert xs == sorted(xs) and xs[0] == round(60 + 100 * 2.6 - 32) and xs[-1] == round(60 + 200 * 2.6 - 32), (xs[0], xs[-1])
gate = items["GATE_lower"]["property"]["actions"]
assert {a["type"] for a in gate} == {"move"} and {a["options"]["toY"] for a in gate} == {lock_view.YB, lock_view.TOP - 10}
# degrade gracefully when the boat tags are absent (older register map): no boat items, view still renders
p2, _ = render([x for x in POINTS if ".boat." not in x])
assert not any(k.startswith("BOAT") for k in p2["hmi"]["views"][0]["items"])
print("ok")
