# rtu: simulate a crash (SIGKILL the field device, as the type-mismatch abort did), then try the normal start
date -u +%FT%TZ; cat /etc/bennu-bundle
p=$(pgrep -f "bennu-field-deviced --c" | head -1); echo "field device pid $p, pidfile $(cat /var/run/default-bennu-field-deviced.pid)"
kill -9 $p; sleep 1; ss -ltn | grep -q :502 && echo "502 still open" || echo "502 closed (device gone)"; echo "pidfile still holds $(cat /var/run/default-bennu-field-deviced.pid)"
echo "--- bennu-field-deviced --c start"; /usr/bin/bennu-field-deviced --c start --env default --file /etc/sceptre/config.xml; echo "rc=$?"
sleep 3; ps -eo pid,args | grep "bennu-field-deviced --c" | grep -v grep; ss -ltn | grep :502 || echo "nothing on 502"
