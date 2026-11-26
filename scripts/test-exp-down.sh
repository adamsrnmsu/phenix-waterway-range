#!/bin/bash
# self-check: stub phenix and minimega on a state dir; run: bash scripts/test-exp-down.sh
d=$(mktemp -d); trap 'rm -r "$d"' EXIT
w=$(dirname "$0")/exp-down.sh
cat > $d/mm <<'S'
#!/bin/bash
# $d/vms = VMs in the namespace; $d/fails = clear namespace failures left; $d/kill_works
a="$*"
case $a in
  *"columns namespace namespace") echo "host,minimega"; echo "host,e1";;
  *"columns state vm info") cat $D/vms;;
  "clear namespace e1") n=$(<$D/fails); echo $((n-1)) > $D/fails
     [ "$n" -gt 0 ] && { echo "Error: scheduler still running for namespace"; exit 1; }; : > $D/vms;;
  *"vm kill all") [ -f $D/kill_works ] && echo 0 > $D/fails;;
esac
S
printf '#!/bin/sh\necho "px $*" >> $D/log\n[ -z "$PXFAIL" ]\n' > $d/px; chmod +x $d/mm $d/px
t() { # want-rc fails kill_works(1/0) vms
  printf 'RUNNING\nBUILDING\n' | awk -v n="$4" 'NR<=n' > $d/vms; echo "$2" > $d/fails; rm -f $d/log $d/kill_works
  [ "$3" = 1 ] && : > $d/kill_works
  D=$d TRIES=3 SLEEP=0 PX=$d/px MM=$d/mm bash $w ${5:-} e1 2>/dev/null; rc=$?
  [ $rc = "$1" ] || { echo "FAIL: rc $rc want $1 ($*)"; exit 1; }
  [ "$1" = 1 ] || [ ! -s $d/vms ] || { echo "FAIL: VMs left ($*)"; exit 1; }
}
t 0 0 1 0                       # nothing left: stop+delete only
grep -q "px exp delete e1" $d/log || { echo "FAIL: no delete"; exit 1; }
t 0 2 1 2                       # scheduler finishes while we retry the clear
t 0 99 1 2                      # clear never works, vm kill + flush does
t 1 99 0 2                      # nothing works: exit 1
t 0 0 1 0 -k; ! grep -q "exp delete" $d/log || { echo "FAIL: -k deleted"; exit 1; }
PXFAIL=1 t 0 0 1 0              # a failing phenix stop does not abort the check
echo exp-down OK
