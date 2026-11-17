# Baseline: sceptre-bennu upstream main cd3bb5b (2026-11-16)

Measured with the host idle.

Docker harness (ubuntu:22.04, amd64 under emulation), `docker/test/run.sh build ctest throughput`:
- ctest: 33/33 pass
- throughput (50 tags, 100 ms cycle, 60 s): 466.50 tag writes/s, 9.33 requests/s, 0.107 s per cycle

Range (bennucamp = topologies/mitm-arm64, arm64 KVM in Lima). Native arm64 build of cd3bb5b deployed to simulink-provider, rtu-1 and rtu-2 (md5 bennu-field-device bda89fd1..., bennu-simulink-provider 103ed452...):
- Modbus from kali, 2000 reads each, one TCP connection:
  - rtu-1 FC04 30000: 2000 ok, p50 1.48 ms, p99 14.77 ms
  - rtu-1 FC03 40000: 2000 ok, p50 1.31 ms, p99 7.90 ms
  - rtu-2 FC04 30000: 2000 ok, p50 1.02 ms, p99 3.75 ms
  - rtu-2 FC03 40000: 2000 ok, p50 0.94 ms, p99 1.89 ms
- Provider from rtu-1, 200 bennu-probe QUERYs (one process each): 0 failed, 56 ms mean
- fds: provider 14, rtu field device 23
Raw output: range-baseline.txt (the first PROBE line used a wrong flag and is superseded by the last block).
