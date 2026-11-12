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
assert xs == sorted(xs) and xs[0] == 326 and xs[-1] == 574 - 64, (xs[0], xs[-1])  # clamped clear of both gate leaves
gate = items["GATE_lower"]["property"]["actions"]
assert {a["type"] for a in gate} == {"move"} and {a["options"]["toY"] for a in gate} == {lock_view.YB, lock_view.TOP - 10}
# boat on the water, never over a gate, one body at a time -- around and exactly on the gates (ww-cq0)
LV = {"lower": "rtu-1.lowerwater.height", "chamber": "rtu-1.lock.height", "upper": "rtu-2.upperwater.height"}


def hit(acts, var, val, kind):
    h = [a for a in acts if a["variableId"] == var and a["type"] == kind and a["range"]["min"] <= val <= a["range"]["max"]]
    return h[-1] if h else None


loc_id = ids["rtu-1.boat.location"]
for loc in (0, 99.9, 100, 100.001, 102.998, 114, 150, 199.9, 200, 200.001, 250, 300):
    for lev in ((4.99, 5.447, 15), (5, 10.3, 15), (5, 14.9, 15), (5.2, 7.7, 14.6)):
        levels, shown = dict(zip(LV, lev)), []
        for n in LV:
            acts = items[f"BOATX_{n}"]["property"]["actions"]
            vis = n == "lower"
            for kind in ("show", "hide"):
                if hit(acts, loc_id, loc, kind):
                    vis = kind == "show"
            if vis:
                x = hit(acts, loc_id, loc, "move")["options"]["toX"]
                top = hit(items[f"BOATY_{n}"]["property"]["actions"], ids[LV[n]], levels[n], "move")["options"]["toY"]
                shown.append((n, x, top + 34))
        assert len(shown) == 1, (loc, shown)
        n, x, bottom = shown[0]
        surface = lock_view.YB - lock_view.PXL * levels[n]
        assert surface <= bottom <= surface + lock_view.PXL * lock_view.LVL_STEP + 12, (loc, n, bottom, surface)
        assert all(x + lock_view.BW <= g0 or x >= g1 for g0, g1 in ((316, 326), (574, 584))), (loc, n, x)
# degrade gracefully when the boat tags are absent (older register map): no boat items, view still renders
p2, _ = render([x for x in POINTS if ".boat." not in x])
assert not any(k.startswith("BOAT") for k in p2["hmi"]["views"][0]["items"])
print("ok")
