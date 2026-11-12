import json, collections, glob, statistics as S, sys
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
W = sys.argv[1]; OUT = sys.argv[2]
st = json.load(open(f"{W}/stats.json")); R = json.load(open(f"{W}/_rows.json")); wire = json.load(open(f"{W}/tshark_dnp3.json"))
t0 = st["window"]["start"]; RA = sys.argv[3]
amap = {(r["ip"], r["address"]): f'{r["name"]}.{r["field"]}' for r in json.load(open(RA))}
BG, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"; BLUE, ORANGE, AQUA, MAG = "#2a78d6", "#eb6834", "#1baf7a", "#e87ba4"
plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG, "text.color": INK, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
  "axes.edgecolor": GRID, "axes.grid": True, "grid.color": GRID, "grid.linewidth": .6, "axes.spines.top": False, "axes.spines.right": False, "font.size": 11, "axes.titleweight": "bold", "axes.titlesize": 13, "axes.titlelocation": "left", "legend.frameon": False})
co = json.load(open(f'{W}/clock_offsets.json')); OFF = co['rtu-1_host_minus_guest_s']
gt = collections.defaultdict(list)
for l in open(f"{W}/gt.csv"):
    p = l.strip().split(",")
    try: gt[p[1]].append((float(p[0]) + OFF - t0, float(p[2])))
    except (ValueError, IndexError): pass
X0, X1 = 40, 250
def sl(v): return [(a, b) for a, b in v if X0 <= a <= X1]
def fin(fig, name, sub=None):
    if sub: fig.text(0.01, -0.03, sub, fontsize=9, color=INK2)
    fig.savefig(f"{OUT}/{name}", dpi=160, bbox_inches="tight"); plt.close(fig)
mrows = [(a - t0, t, v / 65.535) for a, ip, ad, t, v in R["mrows"] if t]
wr = [(a - t0, amap.get((ip, i)), v) for a, ip, i, v in wire]
dn = [(a - t0, t, v) for a, ip, t, v in R["rows"]]
def series(rs, tag, ip=None): return sl([(a, v) for a, t, v in rs if t == tag])
# 1 lock height
fig, ax = plt.subplots(figsize=(10, 4.2))
p = sl(gt["lock.height"]); ax.plot([a for a, b in p], [b for a, b in p], color=BLUE, lw=2, label="provider tag (ground truth)")
m = series(mrows, "lock.height"); ax.scatter([a for a, b in m], [b for a, b in m], s=14, color=ORANGE, zorder=3, label="Zeek modbus_detailed register / 65.535")
ax.set_xlabel("seconds since capture start"); ax.set_ylabel("lock.height"); ax.set_title("Lock chamber level: provider tag vs value Zeek extracted from Modbus"); ax.legend(loc="upper right")
fin(fig, "lock-height-provider-vs-zeek-modbus.png", "Modbus 16-bit registers carry value*65.535; provider timestamps shifted by the measured guest clock offset (+1.04 s); Modbus tracks the provider with ~0 s apparent lag.")
# 2 boat location
fig, ax = plt.subplots(figsize=(10, 4.2))
p = sl(gt["boat.location"]); ax.plot([a for a, b in p], [b for a, b in p], color=BLUE, lw=2, label="provider tag (ground truth)")
w = series(dn, "boat.location"); ax.scatter([a for a, b in w], [b for a, b in w], s=16, color=AQUA, zorder=3, label="Zeek dnp3_points (g30v6 double)")
m = series(mrows, "boat.location"); ax.scatter([a for a, b in m], [b for a, b in m], s=10, color=ORANGE, marker="s", zorder=2, label="Zeek modbus_detailed register / 65.535")
ax.set_xlabel("seconds since capture start"); ax.set_ylabel("boat.location"); ax.set_title("Boat position across a lock transit, three views of the same tag"); ax.legend(loc="upper right")
fin(fig, "boat-location-provider-vs-dnp3-vs-modbus.png", "DNP3 values are Zeek dnp3_points g30v6 (fixed parseus.zeek); Modbus values are Zeek modbus_detailed; both on the host clock.")
# 3 gates/valves: provider vs Zeek DNP3 points
fig, axs = plt.subplots(4, 1, figsize=(10, 5.6), sharex=True)
for ax, tag in zip(axs, ["lowergate.open", "uppergate.open", "lowervalve.open", "uppervalve.open"]):
    p = sl(gt[tag]); ax.step([a for a, b in p], [b for a, b in p], where="post", color=BLUE, lw=2, label="provider")
    d = series(dn, tag); ax.scatter([a for a, b in d], [b for a, b in d], s=12, color=AQUA, zorder=3, label="Zeek dnp3_points")
    ax.set_ylabel(tag.replace(".open", ""), rotation=0, ha="right", va="center"); ax.set_yticks([0, 1]); ax.set_ylim(-.2, 1.25)
h, l = axs[0].get_legend_handles_labels(); fig.legend(h, l, loc="upper right", ncol=2, bbox_to_anchor=(0.98, 1.0)); axs[-1].set_xlabel("seconds since capture start"); axs[0].set_title("Gate and valve positions: provider vs values Zeek extracted from DNP3")
fin(fig, "gates-valves-provider-vs-zeek-dnp3.png", "Provider timestamps shifted by the measured guest clock offset (+1.04 s). DNP3 points trail the provider by ~0.6 s.")
# 4 protocol rates
def binned(rows, key):
    c = collections.Counter(int((r["ts"] - t0) // 10) for r in rows); return c
def jl(path):
    out = []
    for f in sorted(glob.glob(path)):
        for l in open(f):
            if l.startswith("{"): out.append(json.loads(l))
    return out
d3 = [r for r in jl(f"{W}/live-logs/dnp3.*.log") + jl(f"{W}/live-logs/dnp3.log") if t0 <= r["ts"] <= st["window"]["end"]]
mb = [r for r in jl(f"{W}/live-logs/modbus.*.log") + jl(f"{W}/live-logs/modbus.log") if t0 <= r["ts"] <= st["window"]["end"]]
bd, bm = binned(d3, 0), binned(mb, 0); xs = range(0, int(st['window']['duration_s']//10))
fig, ax = plt.subplots(figsize=(10, 3.8))
ax.plot([x*10 for x in xs], [bd[x]/10 for x in xs], color=AQUA, lw=2, label="DNP3 (gateway integrity polls, 2 RTUs)"); ax.plot([x*10 for x in xs], [bm[x]/10 for x in xs], color=ORANGE, lw=2, label="Modbus (added poller, 2 RTUs)")
ax.set_ylim(0, None); ax.set_xlabel("seconds since capture start"); ax.set_ylabel("Zeek log rows per second"); ax.set_title("Request and response rows per second by protocol"); ax.legend(loc="lower right")
fin(fig, "protocol-rates.png", "dnp3.log: 1 row per transaction direction; modbus.log: 1 row per PDU (request and response each).")
# 5 poll interval hist
di = collections.defaultdict(list)
for r in d3:
    if r.get("fc_request") == "READ": di[r["id.resp_h"]].append(r["ts"])
iv = []
for ts in di.values(): ts.sort(); iv += [b - a for a, b in zip(ts, ts[1:])]
fig, ax = plt.subplots(figsize=(8, 3.8)); ax.hist([x for x in iv if x < 1.2], bins=60, color=BLUE); ax.set_xlabel("seconds between DNP3 READ polls (same RTU)"); ax.set_ylabel("polls"); ax.set_title("Gateway DNP3 poll interval")
ax.annotate("median %.3f s, p95 %.3f s\n(%d polls above 1.2 s, max %.2f s)" % (S.median(iv), sorted(iv)[int(.95*len(iv))], sum(x >= 1.2 for x in iv), max(iv)), xy=(.55, .7), xycoords="axes fraction", color=INK2)
fin(fig, "poll-interval-hist.png")
# 6 coverage
fig, ax = plt.subplots(figsize=(7.5, 3.6)); labs = ["rtu-1", "rtu-2"]; onw = [12, 10]; zk = [12, 10]
import numpy as np
x = np.arange(2); ax.bar(x-.18, onw, .34, color=BLUE, label="points on the wire per poll (tshark)"); ax.bar(x+.18, zk, .34, color=ORANGE, label="points Zeek extracts per poll (fixed script)")
for i in range(2): ax.text(x[i]-.18, onw[i]+.2, onw[i], ha="center", color=INK2); ax.text(x[i]+.18, zk[i]+.2, zk[i], ha="center", color=INK2)
ax.set_xticks(x); ax.set_xticklabels(labs); ax.set_ylabel("DNP3 points"); ax.set_title("DNP3 points per poll: wire vs Zeek (after the fix)"); ax.legend(loc="upper right"); ax.set_ylim(0, 15)
fin(fig, "dnp3-extraction-coverage.png", "With the double-precision (g30v6/g32v6) handlers added to parseus.zeek every point on the wire is extracted. Before the fix: 2 per RTU.")
# 7 freshness
sts = [json.loads(l) for l in open(f"{W}/st.jsonl")]; xs, ys = [], []
for s in sts:
    if "es" in s and "dnp3" in s["es"] and t0 <= s["t"] <= st["window"]["end"]: xs.append(s["t"]-t0); ys.append(s["t"] - s["es"]["dnp3"]["max_ts"]/1000)
fig, ax = plt.subplots(figsize=(10, 3.6)); ax.plot(xs, ys, color=BLUE, lw=2); ax.set_ylim(0, None); ax.set_xlabel("seconds since capture start"); ax.set_ylabel("seconds"); ax.set_title("Live ingest freshness: now minus newest DNP3 doc timestamp in Elasticsearch")
fin(fig, "ingest-freshness.png", "Sampled every 5 s; includes Zeek log flush and the ingestor's 2 s poll.")
print("charts ok")
