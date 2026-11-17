# rtu-2: same config, but the holding register for var_rtu-2_O40000 moved to address 30000 (same number as input
# register 30000, separate Modbus table) with range 0..1. Run the field device in the foreground form with it.
set -e
python3 - <<'PY'
import re
s = open("/etc/sceptre/config.xml").read()
s = s.replace("<holding-register>\n                    <address>40000</address>\n                    <max-value>1000</max-value>",
              "<holding-register>\n                    <address>30000</address>\n                    <max-value>1</max-value>", 1)
open("/tmp/collide.xml", "w").write(s)
PY
diff /etc/sceptre/config.xml /tmp/collide.xml || true
grep -B1 -A1 -E "rtu-2_I30000|rtu-2_O40000" /etc/sceptre/config.xml | grep -E "<id>|<name>"
/usr/bin/bennu-field-deviced --c stop --env default --file /etc/sceptre/config.xml || true; pkill -f bennu-field-device || true; sleep 1
(cd /etc/sceptre && exec setsid bennu-field-device --f /tmp/collide.xml) > /tmp/collide.log 2>&1 < /dev/null &
sleep 4; ss -ltn | grep :502
