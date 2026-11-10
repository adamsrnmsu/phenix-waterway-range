import os, yaml, sys
TOPOS = os.environ.get("SCEPTRE_PHENIX_TOPOLOGIES", os.path.expanduser("~/git/sceptre-phenix-topologies"))
up = yaml.safe_load(open(os.path.join(TOPOS, "waterway/waterway-scenario.yaml")))
A = "/phenix/topologies/waterway-arm64"
hosts = []
for h in up["spec"]["apps"][0]["hosts"]:
    n, m = h["hostname"], dict(h["metadata"])
    if m["type"] not in ("provider", "fd-server"):
        continue  # SCADA-side hosts: no sceptre type, configs come from topology injections
    m.pop("labels", None)
    if m["type"] == "provider":
        n = "waterway-provider"
        m = {"type": "provider", "simulator": "Simulink", "publish_endpoint": m["publish_endpoint"],
             "publish_points": f"{A}/injects/publishPoints.txt", "solver": f"{A}/injects/simulinksolver"}
    else:
        m["provider"] = "waterway-provider"
        if n == "rtu-1":  # LAST device so existing register addresses do not shift (ww-585.37)
            m["modbus"] = m["modbus"] + [{"name": "boat", "type": "boat"}]
    hosts.append({"hostname": n, "metadata": m})
doc = {"apiVersion": "phenix.sandia.gov/v2", "kind": "Scenario",
       "metadata": {"name": "waterway-arm64", "annotations": {"topology": "waterway-arm64"}},
       "spec": {"apps": [{"name": "sceptre", "assetDir": A, "hosts": hosts}]}}
yaml.safe_dump(doc, sys.stdout, sort_keys=False, width=10000)
