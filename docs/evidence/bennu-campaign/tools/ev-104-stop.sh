for P in 25405 25407 25408; do echo "=== /tmp/ev-104-$P.log"; cat /tmp/ev-104-$P.log; done
echo "switch-to count on 25405: $(grep -c 'switch to' /tmp/ev-104-25405.log)"
pkill -f 'bennu-field-device --f /tmp/ev-104'; sleep 1; ps -eo pid,args | grep -c '[e]v-104'; ss -ltn | grep -E ':502|:254'
