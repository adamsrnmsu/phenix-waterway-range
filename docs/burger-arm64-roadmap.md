# Roadmap: everything-burger on the arm64 range

Status 2026-11-08: burger has 49 items; 3 declare `waterway-arm64` (`field-device`,
`simulink-provider`, `modbus-polled`), `preflight --route waterway-arm64` passes, and
no full `burger run arm64` has been attempted. Goal: a measured pass/fail matrix for
every item on this range, then close the gaps in order of cost.

## Gap classes

| Class | Items | Blocker |
|---|---|---|
| A. Route lists only | disruption, erspan, hoststats, mm, pipe, qos, tcpdump, pcap, vmstats, cc-empty-output, cc-output-parsing, fifo, es-stub, field-device-bench, snort, ssh, ssh-password, helics, mgmt_tap, mirror, trafficgen, caldera, ettercap, mitm-capture, opcexport-live | `routes:` omits waterway-arm64 / a mitm-arm64 route; arch-agnostic otherwise (unverified until run) |
| B. burger injects amd64 artifacts | bennu PR testing (deb build), attacker/monitor/traffic/caldera nodes (`kali.qc2`, `ubuntu.qc2`, `bennu.qc2`, `caldera.qc2`), art (goart), iperf / iperf-322 | upstream images and binaries are amd64; bennu's tree vendors x86 libs and cpack hardcodes amd64 |
| C. Mis-modelled requirement | modbus-polled | `requires: {windows: true}` really means "an OPC/SCADA host polls the RTUs"; the Linux OPC gateway does that here |
| D. Windows guests | cc-windows-exit-code, cc-windows-failure | no Windows image on arm64 |
| E. Power / soap | power-solver, pybennu-provider, siren, providerdata, collector, publish-fragments, elastic-empty | no arm64 soap topology; PYPOWER provider path |
| F. Native deps missing on aarch64 | opendss-batched-write | dss-python has no aarch64 wheel |
| G. Hardware | rtds | needs RTDS hardware in the loop; out of scope locally |

## Phases

1. **Route-level image map + arm64 bennu builds (burger repo).** Routes gain an
   `image_map` (e.g. `kali.qc2 -> kali-arm64.qc2`, `ubuntu.qc2 -> ubuntu-arm64.qc2`,
   `bennu.qc2 -> bennu-arm64.qc2`, `caldera.qc2 -> caldera-arm64.qc2`) applied to
   injected nodes; `bennu.py` builds PR debs with this repo's
   `images/docker/bennu-arm64.Dockerfile` approach (git archive, arm64 libzmq, rebuilt
   swig endpoint, cpack arch from dpkg) when the route is arm64. Add a `mitm-arm64`
   route. Verify: `burger check` renders arm64 images only; a bennu PR deb builds and
   installs on bennu-arm64.
2. **Measured matrix (class A).** Add the arm64 routes to every class A item, run
   `burger run arm64` (and the mitm board on mitm-arm64), record pass / fail / reason
   per item in `docs/burger-arm64-matrix.md`; fix cheap failures, file beads for the
   rest.
3. **Requirement fix (class C).** Replace `windows: true` on modbus-polled with a role
   requirement (e.g. `pollers: opc`) satisfied by either the Windows OPC or the Linux
   gateway. Upstream-friendly (no behaviour change on the real rig).
4. **arm64 tool artifacts (class B rest).** goart and iperf static builds for arm64
   (Go cross-compile; iperf static build in an arm64 container); trafficgen image
   mapping.
5. **Windows on arm64 (class D).** `win11-arm64` recipe from the Windows 11 Enterprise
   Evaluation Arm64 ISO (free, 90-day, testing use; rebuild resets the clock):
   unattended install (borrow dockur/windows-arm's answer-file approach), virtio-win
   Arm64 drivers, `miniccc.exe` cross-compiled for windows/arm64, phenix startup
   injection on the arm64 layout. Verify: the two cc-windows items pass. The real rig
   keeps its licensed x86 Windows images; this image is for local testing only.
6. **Power / soap (class E).** After ferrofire phase 3 (pybennu-power-solver drop-in):
   a soap-arm64 topology and route; run the soap boards.
7. **OpenDSS (class F).** Spike: build dss-python / DSS C-API from source on aarch64;
   if it builds, ship it in the bennu-arm64 overlay; else mark unsupported.
8. **Unsupported locally (class G).** rtds stays real-rig only; burger reports it as
   skipped with a reason rather than failing.
