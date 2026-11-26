#!/usr/bin/env bash
# Test: fetch-build.sh --check-only refuses a shirudo checkout whose HEAD is not shirudo/PIN.
# Runs on the Mac. Uses a throwaway git worktree of ~/git/shirudo; never moves that checkout.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=${SHIRUDO_SRC:-$HOME/git/shirudo}
pin=$(cat "$here/PIN")
tmp=$(mktemp -d)
trap 'git -C "$src" worktree remove --force "$tmp/old" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

git -C "$src" worktree add -q --detach "$tmp/old" "$pin~1"
old=$(git -C "$tmp/old" rev-parse HEAD)

set +e
out=$(SHIRUDO_SRC="$tmp/old" "$here/fetch-build.sh" --check-only 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "drifted checkout: want exit 1, got $rc: $out"
grep -q "$pin" <<<"$out" || fail "drift message does not name the pin: $out"
grep -q "$old" <<<"$out" || fail "drift message does not name the checkout HEAD: $out"

git -C "$tmp/old" checkout -q --detach "$pin"
set +e
out=$(SHIRUDO_SRC="$tmp/old" "$here/fetch-build.sh" --check-only 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "pinned checkout: want exit 0, got $rc: $out"

# at the pin but with an uncommitted change: stage.sh would ship the edit under the pin's name
echo "# local edit" >> "$tmp/old/testing/vm/run.sh"
set +e
out=$(SHIRUDO_SRC="$tmp/old" "$here/fetch-build.sh" --check-only 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "dirty checkout: want exit 1, got $rc: $out"
grep -q 'uncommitted' <<<"$out" || fail "dirty message does not say why: $out"
echo "PASS fetch-build-pin"
