# runs in the Lima VM: every 5 s record docker stats of the capture stack and ES doc counts / newest @timestamp per dataset.
import json, subprocess, sys, time, urllib.request
dur = float(sys.argv[1]); out = open(sys.argv[2], "w", buffering=1); ES = "http://localhost:9205"
def es(path, body=None):
    r = urllib.request.Request(ES + path, data=json.dumps(body).encode() if body else None, headers={"content-type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=10))
t0 = time.time()
while time.time() - t0 < dur:
    now = time.time(); rec = {"t": now}
    try:
        st = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{json .}}", "pz-zeek", "pz-ing", "pz-es"], capture_output=True, text=True, timeout=20).stdout
        rec["docker"] = [json.loads(l) for l in st.splitlines() if l.strip()]
    except Exception as e: rec["docker_err"] = str(e)
    try:
        a = es("/arkime_sessions3-parseus-zeek-*/_search", {"size": 0, "track_total_hits": True, "aggs": {"d": {"terms": {"field": "event.dataset"}, "aggs": {"mx": {"max": {"field": "@timestamp"}}}}}})
        rec["es_total"] = a["hits"]["total"]["value"]; rec["es"] = {b["key"]: {"n": b["doc_count"], "max_ts": b["mx"]["value"]} for b in a["aggregations"]["d"]["buckets"]}
    except Exception as e: rec["es_err"] = str(e)
    out.write(json.dumps(rec) + "\n"); time.sleep(max(0, 5 - (time.time() - now)))
