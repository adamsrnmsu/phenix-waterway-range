# Range latency with each build deployed (2026-11-17, host idle)

Method:
- For each build, the same arm64 build is installed on simulink-provider, rtu-1 and rtu-2 (`../tools/mkdeploy.sh`), then the bench is run.
- kali makes 2000 Modbus reads per row on one TCP connection (`../tools/bench-kali.sh`).
- rtu-1 sends the provider 200 `bennu-probe --command query` requests, one process each (`../tools/bench-probe.sh`).
- Raw output is in `<build>.txt`, which also records each host's installed build, md5s and fd counts.

| build | rtu-1 FC04 p50 / p99 ms | rtu-1 FC03 | rtu-2 FC04 | rtu-2 FC03 | failures | provider QUERY mean | fds (provider / rtu-1 / rtu-2) |
|---|---|---|---|---|---|---|---|
| main cd3bb5b | 0.96 / 1.90 | 0.97 / 2.50 | 1.03 / 2.18 | 0.99 / 1.97 | 0 / 8000, 0 / 200 | 54 ms | 14 / 19 / 20 |
| fix-modbus-request-validation | 0.96 / 2.14 | 0.94 / 1.71 | 0.94 / 1.65 | 0.95 / 1.79 | 0 / 8000, 0 / 200 | 55 ms | 14 / 20 / 19 |
| fix-datapath-value-validation | 0.95 / 1.78 | 0.95 / 1.84 | 0.94 / 1.89 | 0.95 / 1.87 | 0 / 8000, 0 / 200 | 55 ms | 14 / 20 / 19 |
| fix-dnp3-104-commands | 0.96 / 1.82 | 0.95 / 1.92 | 0.96 / 2.42 | 0.97 / 1.89 | 0 / 8000, 0 / 200 | 55 ms | 14 / 19 / 19 |

No build differs from main beyond run-to-run noise. The provider QUERY time is dominated by starting a `bennu-probe` process for each request.

The first baseline (`../baseline/range-baseline.txt`, 2026-11-17 05:08Z) was taken while the arm64 range was still settling after boot. Its p99 values (up to 14.8 ms) are higher than the row for main above, which was taken on an idle host just before the other builds.
