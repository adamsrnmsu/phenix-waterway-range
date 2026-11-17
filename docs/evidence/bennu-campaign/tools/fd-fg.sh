# rtu-1: run the same field device in the foreground form (bennu-field-device --f) so its stderr is captured
pkill -f "bennu-field-device" ; rm -f /var/run/default-bennu-field-deviced.pid
(cd /etc/sceptre && exec setsid bennu-field-device --f /etc/sceptre/config.xml) > /tmp/fd-fg.log 2>&1 < /dev/null &
sleep 4; ps -eo pid,etimes,args | grep "bennu-field-device" | grep -v grep; ss -ltn | grep :502
