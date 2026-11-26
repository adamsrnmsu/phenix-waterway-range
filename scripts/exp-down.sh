#!/usr/bin/env bash
# Stop (and delete) an experiment, then make sure minimega holds none of its VMs (ww-585.39).
# Usage (on the Mac): scripts/exp-down.sh [-k] <experiment>      -k: stop only, keep the experiment
# phenix marks an experiment stopped, and `exp delete` removes it, even when minimega's `clear namespace` failed
# ("scheduler still running for namespace" while a launch is in flight): the VMs keep running with no experiment
# left to find them. So the namespace is checked afterwards, retried, then killed by hand; exit 1 if VMs remain.
# PX / MM override the phenix and minimega commands (the self-check stubs them).
set -uo pipefail
PX=${PX:-limactl shell phenix sudo docker exec phenix phenix} MM=${MM:-limactl shell phenix sudo docker exec minimega mm}
tries=${TRIES:-30} keep=
[ "${1:-}" = -k ] && { keep=1; shift; }
exp=${1:?usage: exp-down.sh [-k] <experiment>}
warn() { echo "exp-down: WARNING: $*" >&2; }
# VM states in the namespace; empty when it is absent (naming a namespace creates it, so list first)
vms() { $MM .csv true .headers false .columns namespace namespace 2>&1 | grep -qx "[^,]*,$exp" || return 0
        $MM namespace "$exp" .csv true .headers false .columns state vm info 2>&1 | grep -v INFO; }
clear_ns() { local i; for ((i = 0; i < ${1:-$tries}; i++)); do
  [ $i -gt 0 ] && sleep "${SLEEP:-2}"
  $MM clear namespace "$exp" >/dev/null 2>&1 && [ -z "$(vms)" ] && return 0; done; return 1; }

$PX exp stop "$exp" || warn "phenix exp stop $exp failed; minimega is checked below"
[ -n "$keep" ] || $PX exp delete "$exp" || warn "phenix exp delete $exp failed"
left=$(vms)
if [ -z "$left" ]; then $MM clear namespace "$exp" >/dev/null 2>&1; exit 0; fi   # an empty leftover namespace
clear_ns && exit 0
warn "$(echo "$left" | wc -l | tr -d ' ') VM(s) of $exp survived phenix stop/delete in minimega; killing them by hand"
$MM namespace "$exp" vm kill all >/dev/null 2>&1; $MM namespace "$exp" vm flush >/dev/null 2>&1
clear_ns 1 && exit 0
warn "minimega still holds VMs of $exp; run: mm clear namespace $exp"; exit 1
