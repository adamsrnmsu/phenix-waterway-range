"""Regenerate range evidence screenshots (run inside the Playwright container via capture.sh).

Env: PARSEUS_URL KIBANA_URL PHENIX_URL ONLY (comma list of a,b,c,d). Outputs to /out.
"""
import json, os, socket, sys, traceback, urllib.request
from playwright.sync_api import sync_playwright, expect

P = os.environ.get("PARSEUS_URL", "http://localhost:8080")
K = os.environ.get("KIBANA_URL", "http://localhost:5601")
X = os.environ.get("PHENIX_URL", "http://localhost:3000")
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
OUT = "/out"
VP = {"width": 1600, "height": 900}
PAIR = "10.1.2.50 → 10.1.1.101"  # scada -> rtu-1
PREFIX = "c10_1_2_50-10_1_1_101--"
# ponytail: parseus Django ALLOWED_HOSTS rejects host.docker.internal, so URLs use "localhost"
# and chromium maps it to the docker host gateway. Remap other names if you point URLs elsewhere.


def regs(page, names):
    for n in names:
        box = page.locator(f"[id='{PREFIX}{n}']")
        expect(box, f"register {n} missing").to_have_count(1)
        box.check()


def load_parseus(page):
    errors = []
    page.on("response", lambda r: errors.append(f"{r.status} {r.url}") if r.status >= 400 else None)
    page.goto(f"{P}/registers/")
    page.get_by_role("button", name="Load Data").click()
    page.locator("#conversation-list").get_by_role("button", name=PAIR).click()
    expect(page.locator(f"[id='{PREFIX}dnp3_analog_input_1']")).to_be_visible(timeout=60000)
    return errors


def no_toast(page):
    expect(page.locator("#toasts .toast.text-bg-danger, #toasts .toast.bg-danger, #toasts .alert-danger")).to_have_count(0)
    txt = page.locator("#toasts").inner_text().lower()
    assert "error" not in txt and "fail" not in txt, f"error toast: {txt!r}"


def flow_a(b):
    ctx = b.new_context(viewport=VP, record_video_dir=f"{OUT}/.video", record_video_size=VP)
    page = ctx.new_page(); errors = load_parseus(page)
    page.screenshot(path=f"{OUT}/.pre.png")  # keeps the video from starting on a blank page
    regs(page, ["dnp3_analog_input_1", "dnp3_analog_input_10", "modbus_IR_30001"])
    page.get_by_label("Normalize").check()
    expect(page.locator("#register-graph svg path").first).to_be_visible(timeout=30000)
    page.wait_for_timeout(2500)
    no_toast(page)
    page.locator("#registers-container").scroll_into_view_if_needed()
    page.screenshot(path=f"{OUT}/registers-chart.png")
    vid = page.video; ctx.close(); os.replace(vid.path(), f"{OUT}/registers-chart.webm")
    os.remove(f"{OUT}/.pre.png")
    assert not [e for e in errors if "/registers/" in e], errors


def flow_b(b):
    ctx = b.new_context(viewport=VP); page = ctx.new_page()
    state = []
    page.on("response", lambda r: state.append((r.status, r.url)) if "/registers/state/state/" in r.url else None)
    load_parseus(page)
    regs(page, ["dnp3_analog_input_0", "dnp3_analog_input_1", "dnp3_analog_input_2", "dnp3_analog_input_10", "dnp3_analog_input_11"])
    page.get_by_role("tab", name="State").click()
    expect(page.locator("#state-graph svg, #state-graph canvas").first).to_be_visible(timeout=60000)
    expect(page.locator("#state-graph-loading-wheel")).to_have_class(__import__("re").compile("d-none"), timeout=60000)
    page.wait_for_timeout(2000)
    assert state, "no /registers/state/state/ request seen"
    bad = [s for s in state if s[0] >= 400]
    assert not bad, f"state endpoint failed (needs sandialabs/parseus#6): {bad}"
    no_toast(page)
    page.locator("#state-container").scroll_into_view_if_needed()
    page.screenshot(path=f"{OUT}/state-tab.png")
    ctx.close()


def kibana_api(method, path, body=None):
    req = urllib.request.Request(K.replace("localhost", "host.docker.internal") + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"kbn-xsrf": "x", "content-type": "application/json"})
    return json.load(urllib.request.urlopen(req))


VEGA = {
    "$schema": "https://vega.github.io/schema/vega-lite/v5.json",
    "title": "DNP3 points from rtu-1 (10.1.1.101): zeek.dnp3_points.value by index",
    "data": {
        "url": {
            "index": "arkime_sessions3-parseus-zeek-*",
            "body": {"size": 0,
                     "query": {"bool": {"filter": [
                         {"term": {"event.dataset": "dnp3_points"}}, {"term": {"destination.ip": "10.1.1.101"}},
                         {"terms": {"zeek.dnp3_points.index": [1, 10]}}, {"range": {"@timestamp": {"%timefilter%": True}}}]}},
                     "aggs": {"t": {"date_histogram": {"field": "@timestamp", "fixed_interval": "5s", "min_doc_count": 1},
                                    "aggs": {"i": {"terms": {"field": "zeek.dnp3_points.index"},
                                                   "aggs": {"v": {"avg": {"field": "zeek.dnp3_points.value"}}}}}}}},
        },
        "format": {"property": "aggregations.t.buckets"},
    },
    "transform": [{"flatten": ["i.buckets"], "as": ["b"]},
                  {"calculate": "'index ' + datum.b.key", "as": "index"}, {"calculate": "datum.b.v.value", "as": "value"}],
    "mark": {"type": "line", "point": True},
    "width": 950,
    "encoding": {"x": {"field": "key", "type": "temporal", "title": "time"},
                 "y": {"field": "value", "type": "quantitative", "title": "avg value"},
                 "row": {"field": "index", "type": "nominal", "title": None},
                 "color": {"field": "index", "type": "nominal", "legend": None}},
    "resolve": {"scale": {"y": "independent"}},
}


HIDE = '.kbnGlobalBannerList, .euiGlobalToastList {display:none !important}'


def flow_c(b):
    ctx = b.new_context(viewport=VP); page = ctx.new_page()
    kuery = "event.dataset:dnp3_points"
    page.goto(f"{K}/app/discover#/?_g=(time:(from:now-15m,to:now))&_a=(columns:!(destination.ip,zeek.dnp3_points.index,zeek.dnp3_points.value),"
              f"dataSource:(dataViewId:parseus-zeek,type:dataView),query:(language:kuery,query:'{kuery}'),sort:!(!('@timestamp',desc)))")
    expect(page.get_by_text("Documents (")).to_be_visible(timeout=60000)
    expect(page.get_by_text("zeek.dnp3_points.value").last).to_be_visible()
    # hide Kibana's telemetry banner / security toast by CSS (clicking them could open dialogs)
    page.add_style_tag(content=HIDE)
    page.wait_for_timeout(2000)
    page.screenshot(path=f"{OUT}/kibana-dnp3-points.png")
    # idempotent saved object with a fixed id (overwrite=true)
    vis = {"title": "DNP3 rtu-1 value (index 1 lock height, index 10 boat location)",
           "visState": json.dumps({"title": "DNP3 rtu-1 value", "type": "vega", "aggs": [], "params": {"spec": json.dumps(VEGA, indent=2)}}),
           "uiStateJSON": "{}", "description": "", "version": 1,
           "kibanaSavedObjectMeta": {"searchSourceJSON": "{}"}}
    kibana_api("POST", "/api/saved_objects/visualization/dnp3-rtu1-values?overwrite=true", {"attributes": vis})
    page.goto(f"{K}/app/visualize#/edit/dnp3-rtu1-values?_g=(time:(from:now-15m,to:now))")
    page.add_style_tag(content=HIDE)
    expect(page.locator(".vgaVis__view canvas, .vgaVis__view svg").first).to_be_visible(timeout=60000)
    expect(page.locator(".visError, .vgaVis__message--err")).to_have_count(0)
    page.wait_for_timeout(3000)
    page.screenshot(path=f"{OUT}/kibana-dnp3-chart.png")
    ctx.close()


def flow_d(b):
    ctx = b.new_context(viewport=VP); page = ctx.new_page()
    page.goto(f"{X}/experiments")
    if page.get_by_role("textbox", name="Password").count() or "login" in page.url.lower():
        print("SKIP d: phenix needs login"); return
    page.get_by_role("cell", name="waterway", exact=True).click()
    for vm in ["hmi", "scada"]:
        expect(page.get_by_text(vm).first).to_be_visible(timeout=30000)
    page.wait_for_timeout(2000)
    page.screenshot(path=f"{OUT}/phenix-waterway.png")
    ctx.close()


def main():
    ip = socket.gethostbyname("host.docker.internal")
    fails = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=[f"--host-resolver-rules=MAP localhost {ip}"])
        for key, fn in (("a", flow_a), ("b", flow_b), ("c", flow_c), ("d", flow_d)):
            if ONLY and key not in ONLY: continue
            try: fn(b); print("ok", key)
            except Exception:
                traceback.print_exc(); fails.append(key)
        b.close()
    sys.exit(f"FAILED flows: {fails}" if fails else 0)


main()
