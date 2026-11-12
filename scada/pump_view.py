"""Pump-station + feeder process view for FUXA (ww-1df.10). build(tag_ids) -> {"items", "svg"}, same contract as lock_view.build.
tag_ids maps "<rtu>.<device>.<field>" -> FUXA tag id. Reuses lock_view.View (FUXA item types: gauge_progress tank, shapes with
colour ranges for pump / valve / feeder breaker, value table). Elements whose tag is missing are skipped."""
import lock_view as lv

TANK = "rtu-1.storagetank.tank_level"
PUMP, VALVE = "rtu-1.pump.active", "rtu-1.valve.open"
BRK, BUS3 = "rtu-2.branch-1_2-3.active", "rtu-2.bus-3.voltage"
TABLE = [TANK, "rtu-1.pump.flow", "rtu-1.storagetank.flow_out", PUMP, "rtu-1.pump.control", VALVE,
         BRK, "rtu-2.bus-1.voltage", BUS3, "rtu-2.load-1_bus-3.mw", "rtu-2.branch-1_2-3.source_mw", "rtu-2.branch-1_2-3.current"]
OK, BAD, GREY = lv.OPEN_C, lv.SHUT_C, "#cfd8dc"


def two_colour(v, iid, markup, var, on_c=OK, off_c=BAD):
    rng = [{"type": "range", "min": -lv.BIG, "max": 0.4999, "color": off_c, "stroke": "#222"},
           {"type": "range", "min": 0.5, "max": lv.BIG, "color": on_c, "stroke": "#222"}]
    v.shape(iid, markup, var=var, ranges=rng, attrs=f"fill='{off_c}' stroke='#222'")


def build(tag_ids):
    v = lv.View(tag_ids)
    s = v.static
    s("<rect x='0' y='0' width='1280' height='720' fill='#f4f6f8'/>")
    s(v.text(40, 40, "Pump station on the feeder - live process view", 26, "#16324f", "start", "bold"))
    s(v.text(40, 62, "bus 1 (slack) -- branch 1_2 -- bus 2 -- branch 2_3 (breaker) -- bus 3 -- pump motor", 13, "#5a6b7b"))
    # feeder one-line diagram (y=150)
    y = 150
    s("<line x1='60' y1='150' x2='620' y2='150' stroke='#3d4348' stroke-width='4'/>")
    for x, name in ((60, "BUS 1"), (260, "BUS 2"), (620, "BUS 3")):
        s(f"<rect x='{x - 6}' y='{y - 26}' width='12' height='52' fill='#16324f'/>" + v.text(x, y - 34, name, 13, "#16324f", "middle", "bold"))
    if BRK in tag_ids:   # feeder breaker between bus 2 and bus 3 = branch-1_2-3.active
        two_colour(v, "BRK", f"<rect x='424' y='{y - 14}' width='28' height='28'/>", BRK)
        s(v.text(438, y + 34, "BREAKER 2-3", 12, "#16324f", "middle", "bold"))
        s(v.text(438, y + 50, "green = closed, red = open", 11, "#5a6b7b", "middle"))
    s(f"<line x1='620' y1='{y + 26}' x2='620' y2='230' stroke='#3d4348' stroke-width='3'/>")
    # pump + valve + tank
    px, py = 620, 262
    if PUMP in tag_ids:
        two_colour(v, "PUMP", f"<circle cx='{px}' cy='{py}' r='30'/>", PUMP)
        s(v.text(px, py + 5, "PUMP", 13, "#fff", "middle", "bold"))
    s(f"<line x1='{px - 30}' y1='{py}' x2='440' y2='{py}' stroke='#3d4348' stroke-width='8'/>")
    tx, ty, tw, th = 200, 220, 240, 300
    if TANK in tag_ids:
        iid = "GXP_tank"
        v.items[iid] = {"id": iid, "type": "svg-ext-gauge_progress", "name": TANK, "label": "HtmlProgress",
                        "property": {"events": [], "alarmId": "", "alarmSrc": "", "alarm": "", "alarmColor": "",
                                     "ranges": [{"type": "minmax", "min": 0, "max": "10", "style": [True, True], "color": lv.WATER}],
                                     "variable": TANK, "variableId": tag_ids[TANK], "variableSrc": lv.SRC}}
        s(f"<g id='{iid}' type='svg-ext-gauge_progress' font-family='sans-serif' font-size='14' stroke='null'>"
          f"<rect id='A-{iid}' fill='#e9f1f8' x='{tx}' y='{ty}' width='{tw}' height='{th}' stroke='#222'/>"
          f"<rect id='B-{iid}' fill='{lv.WATER}' x='{tx}' y='{ty + th / 2}' width='{tw}' height='{th / 2}' stroke='null'/>"
          f"<foreignObject id='H-{iid}' font-size='14' x='{tx}' y='{ty}' width='{tw}' height='{th}'/></g>")
        s(v.text(tx + tw / 2, ty - 8, "STORAGE TANK (level 0-10 m)", 13, "#16324f", "middle", "bold"))
    if VALVE in tag_ids:   # orifice valve at the bottom of the tank
        vx, vy = tx + tw / 2, ty + th + 34
        two_colour(v, "VALVE", f"<polygon points='{vx - 14},{vy - 14} {vx + 14},{vy + 14} {vx + 14},{vy - 14} {vx - 14},{vy + 14}'/>", VALVE)
        s(f"<line x1='{vx}' y1='{ty + th}' x2='{vx}' y2='{vy - 14}' stroke='#3d4348' stroke-width='8'/>")
        s(v.text(vx + 24, vy + 5, "OUTLET VALVE", 12, "#16324f"))
    # table
    tx0, ty0 = 780, 100
    s(f"<rect x='{tx0 - 12}' y='{ty0 - 24}' width='490' height='{34 + 20 * len(TABLE)}' rx='6' fill='#fff' stroke='#c6d0da'/>")
    s(v.text(tx0, ty0 - 6, "Telemetry", 15, "#16324f", "start", "bold"))
    row = 0
    for n in TABLE:
        if n not in tag_ids:
            continue
        yy, iid = ty0 + 20 + row * 20, f"VAL_{n}"
        v.items[iid] = {"id": iid, "type": "svg-ext-value", "name": n, "label": "Value",
                        "property": {"events": [], "variable": n, "variableId": tag_ids[n], "variableSrc": lv.SRC, "alarmId": "",
                                     "alarmSrc": "", "alarm": "", "alarmColor": "",
                                     "ranges": [{"type": "unit", "min": 0, "max": 1000000, "text": ""}]}}
        s(v.text(tx0, yy, n, 13, "#3f4a55"))
        s(f"<g id='{iid}' type='svg-ext-value' text-anchor='end' font-family='sans-serif' font-size='13' fill='none' stroke-width='0'>"
          f"<text id='VALT_{n}' x='{tx0 + 450}' y='{yy}' text-anchor='end' font-family='sans-serif' font-size='13' fill='#000' "
          f"stroke-width='0'>##.##</text></g>")
        row += 1
    return {"items": v.items, "svg": "<svg xmlns='http://www.w3.org/2000/svg' width='1280' height='720'>" + "".join(v.svg) + "</svg>"}
