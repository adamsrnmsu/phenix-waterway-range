hostname; date -u +%FT%TZ
ps -eo pid,etimes,rss,args | grep -E "bennu|simulinksolver|ferrofire" | grep -v grep
for p in $(pgrep -f "bennu-(field-device|simulink-provider)"); do echo "pid $p fds=$(ls /proc/$p/fd | wc -l)"; done
cat /etc/bennu-bundle 2>/dev/null; md5sum /usr/local/bin/bennu-field-device /usr/local/bin/bennu-simulink-provider $(readlink -f /usr/local/lib/libbennu-modbus-tcp.so /usr/local/lib/libbennu-field-device-base.so /usr/local/lib/libbennu-distributed.so 2>/dev/null) 2>/dev/null
ss -ltnup 2>/dev/null | grep -E ":502|:5555|:20000|:40000" 
