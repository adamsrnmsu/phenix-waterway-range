for P in 20997 20998; do echo "=== /tmp/ev-dnp3-$P.log"; cat /tmp/ev-dnp3-$P.log; done
pkill -f 'bennu-field-device --f /tmp/ev-dnp3'; sleep 1; ps -eo pid,args | grep -c '[e]v-dnp3'; ss -ltn | grep -E ':502|:2099'
