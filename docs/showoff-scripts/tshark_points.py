# independent decode of the DNP3 static g30v6 (64-bit double) points with tshark -> [[ts, rtu_ip, index, value], ...]
# Each response = g32v6 change events (0..n doubles) followed by the static g30v6 objects for the non-int points;
# g30v1 ints are indexes 3 and 5 (setpoint outputs), so statics are indexes 0,1,2,4,6.. (see reg_addrs_dnp3.json).
import json, subprocess, sys
pcap, out = sys.argv[1], sys.argv[2]
STATIC = {"10.1.1.101": [0, 1, 2, 4, 6, 7, 8, 9, 10, 11], "10.1.1.102": [0, 1, 2, 4, 6, 7, 8, 9]}
txt = subprocess.run(["tshark", "-r", pcap, "-Y", "dnp3.al.func == 129 && ip.src >= 10.1.1.0 && ip.src < 10.1.1.255", "-T", "fields", "-e", "frame.time_epoch", "-e", "ip.src", "-e", "dnp3.al.ana.double"], capture_output=True, text=True, check=True).stdout
rows = []; n = 0
for l in txt.splitlines():
    p = l.split("\t")
    if len(p) < 3 or not p[2]: continue
    vals = [float(x) for x in p[2].split(",")]; idx = STATIC[p[1]]; n += 1
    if len(vals) < len(idx): continue
    for i, v in zip(idx, vals[-len(idx):]): rows.append([float(p[0]), p[1], i, v])
json.dump(rows, open(out, "w")); print(n, "responses,", len(rows), "points")
