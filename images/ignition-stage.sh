#!/bin/bash
# usage: images/ignition-stage.sh <amd64|arm64> [tag]   (Mac; drives the Lima VM "phenix")
# Extracts the official Ignition tree from inductiveautomation/ignition:<tag> (IA's per-arch image) into
# /phenix/images/overlays-src/ignition-<arch>/usr/local/bin/ignition, the overlay for the ignition-<arch> recipe.
# IA publishes aarch64 Linux only in this Docker image; the same route is used for amd64 so both arches are the same build.
set -euo pipefail
ARCH=${1:?amd64|arm64}; TAG=${2:-8.1.55}
VM() { limactl shell phenix -- "$@"; }
VM sudo docker pull -q --platform linux/$ARCH inductiveautomation/ignition:$TAG
VM sudo docker rm -f ignx-$ARCH >/dev/null 2>&1 || true
VM sudo docker create --platform linux/$ARCH --name ignx-$ARCH inductiveautomation/ignition:$TAG >/dev/null
# shipped as one tar: vmdb2's copy-dir hangs on the tree's symlinks (logs/wrapper.log -> /dev/stdout); scripts/ignition.sh unpacks it
OV=/phenix/images/overlays-src/ignition-$ARCH
VM sudo rm -rf "$OV"; VM sudo mkdir -p "$OV/opt" /phenix/images/ign-tree-$ARCH
VM sudo docker cp ignx-$ARCH:/usr/local/bin/ignition /phenix/images/ign-tree-$ARCH/
VM sudo docker rm ignx-$ARCH >/dev/null
VM sudo tar -C /phenix/images/ign-tree-$ARCH -cf "$OV/opt/ignition-tree.tar" ignition
VM sudo rm -rf /phenix/images/ign-tree-$ARCH
# opt-in: the operator accepts the Inductive Automation EULA for headless commissioning (see scripts/ignition.sh)
[[ ${IGNITION_ACCEPT_EULA:-0} = 1 ]] && VM sudo touch "$OV/opt/ignition-eula-accepted"
VM sudo ls -lh "$OV/opt/ignition-tree.tar"
