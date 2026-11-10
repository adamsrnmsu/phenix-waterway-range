## What

- `make ignition` builds `ignition.qc2` (Ubuntu noble): the official Ignition 8.1.55 gateway tree under `/usr/local/bin/ignition`, an `ignition.service` unit, a `gwcmd` wrapper, and miniccc injected.
- `scripts/ignition.sh` is the chroot step. The tree is staged on the host by the Makefile from the official `inductiveautomation/ignition:$(IGNITION_VERSION)` image (amd64) into `overlays/ignition/opt/ignition-tree.tar` (gitignored). It is one tar because vmdb2's copy-dir hangs on the tree's `logs/wrapper.log -> /dev/stdout` symlink.
- With `IGNITION_ACCEPT_EULA=1` the image commissions itself headlessly: a systemd drop-in sets `ACCEPT_IGNITION_EULA=Y`, admin credentials and the three ports, and a pre-start step stages `/phenix/ignition.gwbk` (`gwcmd.sh -s <gwbk> -m -y`, then the Upgrader) before the first start. This is the method of the official image's `docker-entrypoint.sh`.

## Why

`sceptre-phenix-topologies/soap/topology.yaml` boots a node from `ignition.qc2` and runs `gwcmd --restore /phenix/ignition.gwbk -y; gwcmd -r`, but this repo has no recipe that produces that image. A fresh 8.1 gateway starts uncommissioned (`StatusPing` reports `COMMISSIONING`) and silently ignores `gwcmd --restore`, so a plain install does not work with the SOAP commands. The `gwcmd` wrapper waits for `RUNNING` so SOAP's unchanged command line works.

## Licensing / EULA

Nothing is redistributed: the tree comes from Inductive Automation's own image at build time. No licence key is installed, so the gateway runs in trial mode (2 h, reset from the gateway web UI). Accepting the EULA is the builder's decision, so it is an explicit opt-in (`IGNITION_ACCEPT_EULA=1`). Without it the image builds but stays uncommissioned and the Makefile prints a note. I deliberately did not add `ignition` to the `image-build` CI matrix for that reason; maintainers can decide.

## How tested (honest status)

- arm64: end to end. The same script and drop-in, built as a noble minbase arm64 image (`images/recipes/ignition-arm64.env` in the downstream range repo), booted with the SOAP topology's unchanged commands and `soap-hil_20240612.gwbk`: `gwcmd` log "Gateway backup restored / Gateway is now running", `StatusPing` RUNNING, `data/projects` contains `soap_hil`, 0 pending `__restore` files, about 16 min boot to restored. Notes: <https://github.com/adamsrnmsu/phenix-waterway-range/blob/main/images/recipes/README.md> (ignition section) and `images/scripts/ignition.sh` there.
- amd64: the image builds (qemu-user chroot on an arm64 host, same script) but its TCG boot and restore test is PENDING (about 40 min in it starved the host and was paused). Not yet confirmed on amd64.
- This patch: applies cleanly to `origin/main` (`git am`), `sh -n` and `shellcheck -s sh` clean, `make -n ignition` expands correctly. `make ignition` itself was NOT run against this repo's CI-style toolchain (it needs docker plus the phenix container); the downstream build used a Lima driver script instead of the Makefile target.
- Not verified: the `-P` package list under this repo's default phenix variant (downstream used debootstrap `minbase`), and the Makefile's host `docker create/cp` staging when `WORKDIR` is a container path.

## Risks / open questions

- Hard-coded default login `admin` / `password` (override with `GATEWAY_ADMIN_PASSWORD` in the drop-in); fine for a throwaway range, not for anything else.
- Heap is fixed at 512 MB initial / 2 GB max for the SOAP topology's 8 GiB VM.
- The `.run` installer route (x86_64 only, current 8.3.x) was not used: the `.gwbk` is an 8.1 backup, and IA publishes aarch64 Linux only in the Docker image.
- Staging needs docker on the machine running `make`.
