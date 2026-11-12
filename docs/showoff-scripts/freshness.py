# Lima: every 0.25 s ask live ES for the newest dnp3_points @timestamp; record query time minus that packet time
import json, time, urllib.request, sys
out = []; t_end = time.time() + float(sys.argv[1]); body = json.dumps({"size": 1, "sort": [{"@timestamp": "desc"}], "query": {"term": {"event.dataset": "dnp3_points"}}, "_source": ["@timestamp"]}).encode()
last = None
while time.time() < t_end:
    t = time.time(); r = json.load(urllib.request.urlopen(urllib.request.Request("http://localhost:9205/arkime_sessions3-parseus-zeek-*/_search", data=body, headers={"content-type": "application/json"}), timeout=5))
    ts = r["hits"]["hits"][0]["sort"][0] / 1000
    out.append((t, t - ts, ts != last)); last = ts; time.sleep(0.25)
lags = [x[1] for x in out]; first_seen = []
# arrival delay: for each newly seen packet timestamp, how old it was the first time we saw it in ES
for t, l, new in out:
    if new: first_seen.append(l)
first_seen.sort(); n = len(first_seen); pct = lambda p: first_seen[min(n-1, int(p/100*(n-1)))]
print(json.dumps({"n_new_batches": n, "arrival_delay_s_median": round(pct(50), 3), "p95": round(pct(95), 3), "max": round(first_seen[-1], 3), "note": "age (query time minus packet timestamp) of each DNP3 poll batch the first time ES returned it; sampled every 0.25 s so resolution is 0.25 s"}))
