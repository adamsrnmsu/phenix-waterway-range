## What

Two commits, two standalone topology directories. Both are static YAML plus injects: no generator scripts and no dependency on the `waterway/` or `mitm/` checkouts at run time.

- `waterway-arm64/`: the `waterway` lock model for arm64 hosts. Same nodes, addressing and physics. The Windows roles (OPC TOP Server, mySCADA, Wonderware, Win7 HMI and engineer workstation) are replaced by a Python OPC UA gateway, FUXA, InfluxDB + Telegraf and xfce desktops. README explains the arm64 node block (`virt` machine, `cpu: host`, AAVMF UEFI, `inject_partition: 2`, usb bus override, virtio-gpu for GUI nodes), the images needed and the Linux-for-Windows mapping.
- `mitm-arm64/`: the arm64 counterpart of `mitm/`, with the `scorch` ettercap + tcpdump components wired into the scenario and an optional Kali Purple + Malcolm `blue` node.

## Relationship to #31 (`mitm/`)

Both are meant to be published. #31 stays the x86/Windows original; `mitm-arm64` keeps its node set, names, addressing and attack (ARP poisoning of rtu-1 <-> router) and only swaps the guests. The links from `mitm-arm64/README.md` to `../mitm` resolve once #31 merges. Nothing in this PR touches `mitm/`.

## Why

There is no way to run these models on Apple Silicon / arm64 KVM hosts today: the images are x86 and several roles need licensed Windows software. This gives an all-Linux, freely buildable variant.

## How tested

On the downstream range (https://github.com/adamsrnmsu/phenix-waterway-range: Lima VM, nested KVM, minimega + phenix containers), using these exact topologies (the files here are the generated YAML, copied unchanged apart from two comment lines in `injects/telegraf.conf` and `injects/influx-setup.sh` that named a generator script):
- `waterway-arm64`: 9 arm64 clients up; full lock cycle observed on rtu-1, agreed by the OPC gateway, FUXA HMI rendering and rows in InfluxDB; stop/start repeatable. Evidence: `docs/shots/waterway/*.png`, `docs/shots/live-hmi.png`, bead ww-585.13 notes.
- `mitm-arm64`: ARP poisoning observed in the neighbour tables of rtu-1 and router (kali's MAC), Modbus 502 captured on kali, tables self-healed after `mitm-stop`: `docs/mitm-evidence.md`, `docs/mitm-capture.pcap`. Blue node: Zeek/Suricata/Arkime saw the traffic and raised the ARP notice: `docs/blue-evidence.md`, `docs/shots/malcolm-live-*.png`.
- In this branch: applies to `origin/main` with `git am`; `prek run` (yamllint, shellcheck, check-yaml/json, codespell) passes on the changed files.

Not tested: against a phenix build other than the downstream one (the `advanced`, `overrides` and `inject_partition` node fields exist in upstream phenix `node.go`, but I have not run these on upstream main), and not on a bare-metal arm64 Linux host (only Apple Silicon via Lima).

## Risks / things to decide

- The aarch64 `simulinksolver` binary is deliberately NOT included (opaque binary); the READMEs say how to build it from ferrofire. Say if you prefer it committed like the x86 one in `waterway/injects/`.
- The arm64 images have no recipes in `sceptre-phenix-images` yet (a separate PR there adds only `ignition`). The READMEs point at the downstream recipes.
- minimega's `kvm` launch needs an aarch64 wrapper (see the minimega issue), otherwise `-vga` is silently dropped on `virt`.
- Lab-default credentials (Influx admin password/token, Malcolm login) are in injects/images; documented in the READMEs.
- Each commit is a self-contained topology, so they can be split into two PRs if preferred.
