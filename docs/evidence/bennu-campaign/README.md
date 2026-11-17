# sceptre-bennu bug campaign (2026-11-16): evidence

Each finding was hunted on upstream main cd3bb5b by one agent and reproduced independently by a second. Every finding below then has:

- a regression test that fails on cd3bb5b and passes with the fix;
- the full upstream suite run on the fix branch, plus the throughput benchmark;
- before/after runs on a live arm64 phenix range wherever the range can exercise the code path. Where it cannot, the finding is marked "container only".

| PR branch | finding | evidence |
|---|---|---|
| fix-modbus-request-validation | truncated FC15/FC16 answered with success, heap bytes written | [modbus/](modbus/README.md) |
| | holding/input registers at one address share one scaling range | [modbus/](modbus/README.md) |
| fix-datapath-value-validation | a wrong-typed provider value kills the field device | [datapath/](datapath/README.md) |
| | provider WRITE ACKs malformed batches; duplicate tag keeps the first value | [datapath/](datapath/README.md) |
| | CommandInterface aborts on a non-numeric WRITE (container only) | [datapath/](datapath/README.md) |
| | CommandInterface/Provider read requests up to a NUL (container only) | [datapath/](datapath/README.md) |
| | stale pidfile after a crash blocks `--c start` | [datapath/](datapath/README.md) |
| fix-dnp3-104-commands | DNP3 AO Int16/Int32/Double64 acked SUCCESS, never applied | [dnp3-104/](dnp3-104/README.md) |
| | IEC-104 IOA 65536+N executes as IOA N | [dnp3-104/](dnp3-104/README.md) |
| | IEC-104 client ignores periodic binary ASDUs | [dnp3-104/](dnp3-104/README.md) |

## Setup

- **Container:** the upstream harness `docker/test/run.sh` (ubuntu:22.04; amd64, emulated on an arm64 Mac). Baseline at cd3bb5b: ctest 33/33, throughput 466.50 tag writes/s and 0.107 s per cycle ([baseline/](baseline/README.md)).
- **Range:** an isolated phenix experiment from `topologies/mitm-arm64` (arm64 KVM in Lima):
  - stock bennu-simulink-provider at 172.16.1.2;
  - two stock bennu-field-deviced Modbus RTUs at 10.1.1.101 and 10.1.1.102;
  - kali at 10.1.1.200 as the client or attacker.
- **Builds on the range:** before and after are both native arm64 builds of the same tree (`tools/build-arm64.sh`), installed the same way (`tools/mkdeploy.sh`). Each capture records which build was installed (`/etc/bennu-bundle` plus md5s).
- **Range latency** with each build deployed: [bench/](bench/README.md).
- **Tools:** in [tools/](tools/). `mb.py` is a raw Modbus client, `zreq.py` a raw ZMTP REQ client, `forge_pub.py` a provider-publish forger, and `ccrun.sh` runs a script in a guest via minimega cc.

Not in these PRs: a few further bennu-brash and pybennu findings are tracked separately.

Note: the branch commits were later amended only to set the executable bit on the new test scripts, which CI's prek requires. The SHAs in the READMEs are the current ones. Bundle labels in the raw files (`bennu-modbus-c956e80`, `bennu-datapath-3d437f0`, `bennu-dnp3-104-cc56e96`) keep the SHAs from before that amend; the source is identical.
