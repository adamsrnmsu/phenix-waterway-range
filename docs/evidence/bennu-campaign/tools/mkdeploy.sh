#!/bin/bash
# mkdeploy.sh <bundle.tgz> : write deploy-<label>.sh that installs a bennu bundle (sent alongside via cc) and restarts bennu
D=$(cd "$(dirname "$0")" && pwd); T=$(basename "$1"); L=${T%.tgz}
cat > "$D/deploy-$L.sh" <<EOS
set -x
cd /tmp/miniccc/files && tar -C / -xzf \$(ls -t *$T | head -1) && ldconfig
[ -f /home/sceptre/bennu-field-deviced.firmware ] && cp /usr/local/bin/bennu-field-deviced /home/sceptre/bennu-field-deviced.firmware
for f in /usr/local/bin/bennu-*; do ln -sf "\$f" /usr/bin/; done
echo "$L" > /etc/bennu-bundle
if [ -f /etc/sceptre/watcher.ini ]; then pkill -f "bennu-field-deviced --c start"; sleep 2; /usr/bin/bennu-field-deviced --c restart --env default --file /etc/sceptre/config.xml; fi
if pgrep -f bennu-simulink-provider >/dev/null; then
  a=\$(tr '\0' ' ' < /proc/\$(pgrep -f bennu-simulink-provider | head -1)/cmdline); pkill -f bennu-simulink-provider; sleep 1
  # subshell+exec with its own redirects: a child holding miniccc's stdout pipe would block cc forever
  (cd /etc/sceptre && exec setsid nohup \$a) > /var/log/bennu-provider.log 2>&1 < /dev/null &
fi
sleep 3; ps -eo pid,etimes,args | grep -E "bennu|solver" | grep -v grep; md5sum /usr/local/bin/bennu-field-device /usr/local/bin/bennu-simulink-provider; cat /etc/bennu-bundle
EOS
echo "$D/deploy-$L.sh"
