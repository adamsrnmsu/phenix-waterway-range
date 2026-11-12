# usage: analyze.py <work dir> <reg_addrs_dnp3.json> ; writes stats.json + charts
import json, sys, glob, bisect, statistics as S, collections, os
W, RA = sys.argv[1], sys.argv[2]
def jl(path):
    out = []
    base = path[:-len("*.log")]   # exact log name plus rotated copies (name.YYYY-...log), never name_other.log
    for f in sorted(glob.glob(base + ".log") + glob.glob(base + ".2*.log")):
        for l in open(f):
            l = l.strip()
            if l.startswith("{"): out.append(json.loads(l))
    return out
def pct(v, p): v = sorted(v); return v[min(len(v)-1, int(round(p/100*(len(v)-1))))] if v else None
cap = json.load(open(f"{W}/pcap_info.json")); t0, t1 = cap["first"], cap["last"]
_co = json.load(open(f"{W}/clock_offsets.json")) if os.path.exists(f"{W}/clock_offsets.json") else {"rtu-1_host_minus_guest_s": 0.0, "opc_host_minus_guest_s": 0.0}
OFF_GT, OFF_MB = _co["rtu-1_host_minus_guest_s"], _co["opc_host_minus_guest_s"]   # guest clocks are behind the host: add to put samples on host time
def _rng(path):
    ts = [float(l.split(",")[0]) for l in open(path) if l[:1].isdigit()]; return min(ts), max(ts)
_g, _m = [x + OFF_GT for x in _rng(f"{W}/gt.csv")], [x + OFF_MB for x in _rng(f"{W}/mb.csv")]
t0, t1 = max(t0, _g[0], _m[0]) + 1.0, min(t1, _g[1], _m[1]) - 1.0   # analysis window = pcap window clipped to where ground-truth samplers were running
cap["analysis_window_note"] = "pcap clipped to the interval covered by both the provider sampler and the Modbus poller"
inwin = lambda r: t0 <= r["ts"] <= t1
live = {k: [r for r in jl(f"{W}/live-logs/{k}*.log") if inwin(r)] for k in ("dnp3", "dnp3_points", "modbus", "modbus_detailed")}
rep = {k: jl(f"{W}/pcap-logs/{k}*.log") for k in live}
amap = {(r["ip"], r["address"]): f'{r["name"]}.{r["field"]}' for r in json.load(open(RA))}
mmap = {(r['ip'], r['address']): f"{r['name']}.{r['field']}" for r in json.load(open(os.path.join(os.path.dirname(RA), 'reg_addrs.json'))) if r['register_type'] == 'input-register'}
# ---- ground truth
gt = collections.defaultdict(list)
for l in open(f"{W}/gt.csv"):
    p = l.strip().split(",")
    if len(p) == 3:
        try: gt[p[1]].append((float(p[0]) + OFF_GT, float(p[2])))
        except ValueError: pass
for v in gt.values(): v.sort()
gts = {t: [x[0] for x in v] for t, v in gt.items()}
def agree(tag, ts, val, lag=0.0, win=0.6, tol=1e-3):
    xs = gts.get(tag); 
    if not xs: return None
    i = bisect.bisect_left(xs, ts - lag); best = None
    # nearest sample
    c = [j for j in (i-1, i) if 0 <= j < len(xs)]
    j = min(c, key=lambda j: abs(xs[j] - (ts - lag))); near = gt[tag][j]
    lo, hi = bisect.bisect_left(xs, ts - lag - win), bisect.bisect_right(xs, ts - lag + win)
    inwindow = any(abs(gt[tag][k][1] - val) <= tol for k in range(lo, hi))
    return abs(near[1] - val), inwindow, abs(xs[j] - (ts - lag))
dn = [r for r in live["dnp3_points"] if r["function_code"] == "RESPONSE"]
rows = []
for r in dn:
    tag = amap.get((r["id.resp_h"], r["index"]))
    if tag: rows.append((r["ts"], r["id.resp_h"], tag, r["value"]))
def score(lag):
    d = [agree(t, ts, v, lag) for ts, ip, t, v in rows]; d = [x for x in d if x]
    return d
# time-offset search on the DNP3 stream (guest clock + provider->RTU->poll latency)
lags = {l/10: sum(x[0] for x in score(l/10)) / max(1, len(score(l/10))) for l in range(-30, 31, 2)}
best_lag = min(lags, key=lags.get)
def summarize(d):
    ad = [x[0] for x in d]
    return {"n": len(d), "exact_match_nearest": round(sum(a < 1e-3 for a in ad)/len(d), 4), "match_within_0.6s_window": round(sum(x[1] for x in d)/len(d), 4),
            "max_abs_diff": max(ad), "mean_abs_diff": round(S.mean(ad), 5), "median_nearest_sample_gap_s": round(S.median(x[2] for x in d), 3)}
per_tag = {}
for tag in sorted({r[2] for r in rows}):
    d = [agree(t, ts, v, best_lag) for ts, ip, t, v in rows if t == tag]; d = [x for x in d if x]
    if d: per_tag[tag] = summarize(d)
# ---- Modbus: Zeek response_values vs client-side poller truth and vs provider
mb = collections.defaultdict(list)
for l in open(f"{W}/mb.csv"):
    p = l.strip().split(",")
    if len(p) == 4: mb[(p[1], int(p[2]))].append((float(p[0]) + OFF_MB, int(p[3])))
mbs = {k: [x[0] for x in v] for k, v in mb.items()}
mrows = []; mm_match = mm_n = 0; mm_prov = []; _pairs = []
_off = []
for r in live["modbus_detailed"]:
    if r.get("is_orig") or "response_values" not in r or r["func"] != "READ_INPUT_REGISTERS" or r["address"] != 30000 or r["id.resp_h"] != "10.1.1.101": continue
    xs = mbs.get(("10.1.1.101", 30000)); i = bisect.bisect_left(xs, r["ts"]); c = [j for j in (i-1, i) if 0 <= j < len(xs)]; j = min(c, key=lambda j: abs(xs[j]-r["ts"])); _off.append(xs[j] - r["ts"])
mb_clock_offset = S.median(_off) if _off else 0.0
for r in live["modbus_detailed"]:
    if r.get("is_orig") or "response_values" not in r or r["func"] != "READ_INPUT_REGISTERS": continue
    for k, v in enumerate(r["response_values"]):
        a = r["address"] + k; ip = r["id.resp_h"]; tag = mmap.get((ip, a))
        mrows.append((r["ts"], ip, a, tag, v))
        xs = mbs.get((ip, a))
        if xs:
            tt = r["ts"] + mb_clock_offset; i = bisect.bisect_left(xs, tt); c = [j for j in (i-1, i) if 0 <= j < len(xs)]; j = min(c, key=lambda j: abs(xs[j]-tt))
            _pairs.append((ip, a, j, r["ts"], v))
        if tag: mm_prov.append((r["ts"], tag, v / 65.535))
# the poller's clock offset is only known modulo its 1.01 s period, so pick the poll-index shift whose values agree best (the values choose the alignment)
_best = None
for k in range(-4, 5):
    m = n = 0
    for ip, a, j, ts, v in _pairs:
        jj = j + k
        if 0 <= jj < len(mb[(ip, a)]): n += 1; m += mb[(ip, a)][jj][1] == v
    if n and (_best is None or m/n > _best[1]): _best = (k, m/n, m, n)
mm_n, mm_match, mm_shift = _best[3], _best[2], _best[0]
def lagsearch(rs, tol, fixed=None):
    res = {}
    for l in ([fixed*10] if fixed is not None else range(-30, 31, 2)):
        d = [agree(t, ts, v, l/10, 0.6, tol) for ts, t, v in rs]; d = [x for x in d if x]; res[l/10] = (S.mean(x[0] for x in d), d)
    bl = min(res, key=lambda k: res[k][0]); d = res[bl][1]; ad = [x[0] for x in d]
    return {"lag_s": bl, "n": len(d), "mean_abs_diff": round(S.mean(ad), 4), "median_abs_diff": round(S.median(ad), 4), "max_abs_diff": round(max(ad), 4), "exact_nearest": round(sum(a <= tol for a in ad)/len(ad), 4), "match_in_0.6s_window": round(sum(x[1] for x in d)/len(d), 4), "tol": tol, "mean_abs_diff_by_lag": {k: round(v[0], 4) for k, v in res.items()}}
modbus_vs_prov = lagsearch(mm_prov, 0.05); modbus_vs_prov["scale"] = "register = value * 65.535 (0..1000 -> 0..65535); tolerance 0.05 unit = 3 register LSB"
mp_tag = {}
for tag in sorted({x[1] for x in mm_prov}): mp_tag[tag] = lagsearch([x for x in mm_prov if x[1] == tag], 0.05, modbus_vs_prov["lag_s"]); mp_tag[tag].pop("mean_abs_diff_by_lag")
wire = [(r[0], amap.get((r[1], r[2])), r[3]) for r in json.load(open(f"{W}/tshark_dnp3.json"))]
wire = [w for w in wire if w[1] and t0 <= w[0] <= t1]
wire_vs = lagsearch(wire, 1e-3); wt = {}
for tag in sorted({x[1] for x in wire}): wt[tag] = lagsearch([x for x in wire if x[1] == tag], 1e-3, wire_vs["lag_s"]); wt[tag].pop("mean_abs_diff_by_lag")
# ---- rates / intervals
dur = t1 - t0
def intervals(rs):
    by = collections.defaultdict(list)
    for r in rs:
        if r.get("fc_request") == "READ" or r.get("func") == "READ_INPUT_REGISTERS": by[r["id.resp_h"]].append(r["ts"])
    return by
di = intervals(live["dnp3"]); polls = {}
for ip, ts in di.items():
    ts.sort(); d = [b-a for a, b in zip(ts, ts[1:])]
    polls[ip] = {"n_polls": len(ts), "median_interval_s": round(S.median(d), 4), "p95_interval_s": round(pct(d, 95), 4), "p99_interval_s": round(pct(d, 99), 4), "max_interval_s": round(max(d), 4)}
ppp = collections.Counter(r["uid"] + str(round(r["ts"], 3)) for r in dn)
st = [json.loads(l) for l in open(f"{W}/st.jsonl")]
st = [s for s in st if t0 <= s["t"] <= t1 + 5 and "es" in s]
lag = []
for s in st:
    for ds in ("dnp3_points", "dnp3"):
        if ds in s["es"]: lag.append(s["t"] - s["es"][ds]["max_ts"]/1000)
def num(x, unit): return float(x.replace(unit, "").replace("%", ""))
def mib(x):
    v = x.split(" / ")[0]; return float(v[:-3])*(1024 if v.endswith("GiB") else 1)
dk = collections.defaultdict(lambda: {"cpu": [], "mem": []})
for s in st:
    for c in s.get("docker", []): dk[c["Name"]]["cpu"].append(num(c["CPUPerc"], "")); dk[c["Name"]]["mem"].append(mib(c["MemUsage"]))
dstat = {n: {"cpu_pct_mean": round(S.mean(v["cpu"]), 2), "cpu_pct_max": max(v["cpu"]), "mem_mib_mean": round(S.mean(v["mem"]), 1), "mem_mib_max": max(v["mem"])} for n, v in dk.items()}
# live-vs-pcap
key = lambda r, f: tuple((k, tuple(r.get(k)) if isinstance(r.get(k), list) else r.get(k)) for k in f)
f_pts = ("ts", "id.orig_h", "id.resp_h", "function_code", "group", "variation", "index", "value")
f_d = ("ts", "id.orig_h", "id.resp_h", "fc_request", "fc_reply", "iin")
f_md = ("ts", "id.orig_h", "id.resp_h", "is_orig", "func", "address", "quantity", "response_values")
def cmp(name, f):
    a = collections.Counter(key(r, f) for r in live[name]); b = collections.Counter(key(r, f) for r in rep[name] if inwin(r))
    return {"live": sum(a.values()), "pcap": sum(b.values()), "identical_records": sum((a & b).values()), "live_only": sum((a - b).values()), "pcap_only": sum((b - a).values())}
vs = {"dnp3_points": cmp("dnp3_points", f_pts), "dnp3": cmp("dnp3", f_d), "modbus_detailed": cmp("modbus_detailed", f_md)}
fcs = collections.Counter((r.get("fc_request"), r.get("fc_reply")) for r in live["dnp3"])
grp = collections.Counter((r["group"], r["variation"], r["function_code"]) for r in live["dnp3_points"])
mfc = collections.Counter(r["func"] for r in live["modbus"])
def interp_err(rs, lag, scale=1.0):
    out = {}
    for tag in ("boat.location", "lock.height"):
        e = []
        for ts, ip_or_tag, *rest in rs:
            pass
    return out
def interp(tag, t):
    xs = gts[tag]; i = bisect.bisect_left(xs, t)
    if i == 0 or i >= len(xs): return None
    (x0, y0), (x1, y1) = gt[tag][i-1], gt[tag][i]
    return y0 if x1 == x0 else y0 + (y1 - y0) * (t - x0) / (x1 - x0)
ie = {}
for name, rs, lg in (("dnp3_zeek", [(a, t, v) for a, ip, t, v in rows], best_lag), ("modbus_zeek", mm_prov, modbus_vs_prov["lag_s"])):
    for tag in ("boat.location", "lock.height"):
        e = []
        for ts, t, v in rs:
            if t != tag: continue
            y = interp(tag, ts - lg)
            if y is not None: e.append(abs(y - v))
        ie[f"{name}:{tag}"] = {"n": len(e), "median_abs_err": round(S.median(e), 4), "p95_abs_err": round(pct(e, 95), 4), "max_abs_err": round(max(e), 4)}
stats = {"window": {"start": t0, "end": t1, "duration_s": round(dur, 1)}, "pcap": cap, "clock_offsets": _co, "continuous_tags_vs_linearly_interpolated_provider": ie,
 "dnp3": {"transactions": len(live["dnp3"]), "tx_per_s": round(len(live["dnp3"])/dur, 3), "fc_pairs": {f"{a}->{b}": n for (a, b), n in fcs.items()}, "points_rows": len(live["dnp3_points"]), "points_per_s": round(len(live["dnp3_points"])/dur, 3), "points_per_response_median": S.median(ppp.values()), "groups_variations_fc": {f"g{g}v{v} {f}": n for (g, v, f), n in grp.items()}, "poll_intervals_by_rtu": polls},
 "modbus": {"zeek_modbus_log_rows": len(live["modbus"]), "rows_per_s": round(len(live["modbus"])/dur, 3), "detailed_rows": len(live["modbus_detailed"]), "functions": dict(mfc), "register_values_extracted": len(mrows), "exception_rows": sum(1 for r in live["modbus"] if "EXCEPTION" in r["func"])},
 "ground_truth_dnp3": {"time_offset_search_s": {"best_lag_s": best_lag, "mean_abs_diff_by_lag": lags}, "all_points": summarize([x for x in score(best_lag)]), "all_points_no_lag": summarize(score(0.0)), "per_tag": per_tag},
 "ground_truth_modbus": {"zeek_vs_client_poller": {"n": mm_n, "exact_match_rate": round(mm_match/max(1, mm_n), 4), "opc_clock_minus_host_s_mod_period": round(mb_clock_offset, 4), "poll_index_shift_chosen": mm_shift, "note": "client poller timestamps are guest-clock and known only modulo its ~1 s period; the poll-index shift with the best value agreement is used (values pair 1:1 by order)"}, "zeek_vs_provider": modbus_vs_prov, "per_tag": mp_tag},
 "ground_truth_dnp3_wire_tshark_g30v6": {"overall": wire_vs, "per_tag": wt, "note": "independent tshark decode of the double-precision static points stock Zeek does not extract"},
 "ingest": {"freshness_lag_s": {"median": round(S.median(lag), 2), "p95": round(pct(lag, 95), 2), "max": round(max(lag), 2), "note": "wall clock at ES query minus newest @timestamp (packet time) in index; includes Zeek log flush + ingestor 2 s poll"}, "docker": dstat},
 "live_vs_pcap": vs}
json.dump(stats, open(f"{W}/stats.json", "w"), indent=1)
json.dump({"rows": rows, "mrows": mrows}, open(f"{W}/_rows.json", "w"))
print("done")
