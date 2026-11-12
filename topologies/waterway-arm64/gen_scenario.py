import os, yaml, sys
# --linux-fuxa: also emit the SCADA-side hosts with `stack: linux_fuxa`, so the sceptre app writes their configs
# (opc_gateway.json, fuxa_project.json, telegraf.conf, ...) itself. Default output is unchanged.
LINUX_FUXA = "--linux-fuxa" in sys.argv
# --mqtt is accepted so one flag set drives both generators; the broker is a plain topology node (no sceptre
# host entry, nothing to configure), so the scenario output is identical with or without it.
# --dnp3: rtu-1/rtu-2 also serve DNP3 (a `dnp3:` list equal to their `modbus:` list); ferrofire's field device answers both.
DNP3 = "--dnp3" in sys.argv
TOPOS = os.environ.get("SCEPTRE_PHENIX_TOPOLOGIES", os.path.expanduser("~/git/sceptre-phenix-topologies"))
up = yaml.safe_load(open(os.path.join(TOPOS, "waterway/waterway-scenario.yaml")))
A = "/phenix/topologies/waterway-arm64"
# The app's linux_fuxa defaults are generic ("sceptre"); the range keeps its own names and the animated lock view.
WATERWAY = {
    "scada-server": {"fuxa_name": "waterway"},
    "historian": {"influx_bucket": "waterway", "influx_token": "waterway-historian-token",
                  "influx_password": "waterway-admin-pass", "measurement": "waterway"},
}
hosts = []
for h in up["spec"]["apps"][0]["hosts"]:
    n, m = h["hostname"], dict(h["metadata"])
    scada = m["type"] not in ("provider", "fd-server")
    if scada and not LINUX_FUXA:
        continue  # SCADA-side hosts: no sceptre type, configs come from topology injections
    m.pop("labels", None)
    if scada:  # Windows project/automation files do not apply to the Linux stack
        m = {k: v for k, v in m.items() if k not in ("project", "automation")}
        hosts.append({"hostname": n, "metadata": {**m, "stack": "linux_fuxa", **WATERWAY.get(m["type"], {})}})
        continue
    if m["type"] == "provider":
        n = "waterway-provider"
        m = {"type": "provider", "simulator": "Simulink", "publish_endpoint": m["publish_endpoint"],
             "publish_points": f"{A}/injects/publishPoints.txt", "solver": f"{A}/injects/simulinksolver"}
    else:
        m["provider"] = "waterway-provider"
        if n == "rtu-1":  # LAST device so existing register addresses do not shift (ww-585.37)
            m["modbus"] = m["modbus"] + [{"name": "boat", "type": "boat"}]
        if DNP3:
            m["dnp3"] = [dict(d) for d in m["modbus"]]  # copies: no YAML aliases
    hosts.append({"hostname": n, "metadata": m})
if LINUX_FUXA:  # the topology has an engineer workstation the upstream scenario lacks
    hosts.append({"hostname": "engineer-workstation",
                  "metadata": {"type": "engineer-workstation", "stack": "linux_fuxa"}})
doc = {"apiVersion": "phenix.sandia.gov/v2", "kind": "Scenario",
       "metadata": {"name": "waterway-arm64", "annotations": {"topology": "waterway-arm64"}},
       "spec": {"apps": [{"name": "sceptre", "assetDir": A, "hosts": hosts}]}}
yaml.safe_dump(doc, sys.stdout, sort_keys=False, width=10000)
