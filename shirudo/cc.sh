#!/usr/bin/env bash
# usage: shirudo/cc.sh <vm> <script> [file...]   (run on the Mac)
# Runs a shell script on a shirudo-arm64 VM through minimega's cc (miniccc), waits for it and prints its stdout.
# Extra files are sent first and land in /tmp/miniccc/files/shirudo-cc/<call>/ on the VM; the script runs from there.
# Each call gets its own directory: miniccc does not resend a file the VM already holds under the same path.
# Timeout: CC_TIMEOUT seconds (default 900).
set -euo pipefail
vm=${1:?vm} script=${2:?script}; shift 2
X=shirudo-arm64
L() { limactl shell phenix sudo "$@"; }
mm() { L docker exec minimega mm "$@" 2>/dev/null | grep -v 'got command' || true; }
uuid=$(mm namespace "$X" .columns name,uuid vm info | awk -F'|' -v v="$vm" '$2 ~ "^ *"v" *$" {gsub(/ /,"",$3); print $3}')
[ -n "$uuid" ] || { echo "no vm $vm in $X" >&2; exit 1; }
tag=$(basename "$script" .sh)-$$-$RANDOM
dir=shirudo-cc/$tag
L mkdir -p "/phenix/images/$dir"
{ cat "$script"; echo; echo "echo CC-DONE-$tag"; } | L tee "/phenix/images/$dir/$tag.sh" >/dev/null
for f in "$@"; do L tee "/phenix/images/$dir/$(basename "$f")" < "$f" >/dev/null; done
mm namespace "$X" clear cc filter >/dev/null
mm namespace "$X" cc filter uuid="$uuid" >/dev/null
for f in "$@" "$tag.sh"; do mm namespace "$X" cc send "file:$dir/$(basename "$f")" >/dev/null; done
mm namespace "$X" cc exec sh -c "cd /tmp/miniccc/files/$dir && sh ./$tag.sh" >/dev/null
id=$(mm namespace "$X" cc commands | awk -F'|' -v t="$tag.sh" 'index($0, "./"t) {gsub(/ /,"",$2); i=$2} END {print i}')
[ -n "$id" ] || { echo "cc command for $tag not found" >&2; exit 1; }
for _ in $(seq $(( ${CC_TIMEOUT:-900} / 2 ))); do
  out=$(mm namespace "$X" cc response "$id" raw)
  grep -q "CC-DONE-$tag" <<<"$out" && { sed -e "/CC-DONE-$tag/d" -e "1s/^lima-phenix: //" <<<"$out"; exit 0; }
  sleep 2
done
echo "timeout waiting for $tag on $vm" >&2; exit 1
