#!/bin/bash
# Chroot build step: terminals to the RTUs. One xfce4-terminal per line of /etc/sceptre/rtus.txt.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get install -y xfce4-terminal telnet openssh-client sshpass
install -d /etc/sceptre /etc/xdg/autostart
# cloud-init / wait-online block graphical.target ~5 min waiting for a DHCP datasource
touch /etc/cloud/cloud-init.disabled
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
cat > /usr/local/bin/engineer-terminals <<'BIN'
#!/bin/bash
# Waits for the injected RTU list, then opens an SSH session per RTU as the sceptre
# user, whose login shell is bennu-brash (upstream sceptre-phenix-images bennu.sh).
# Default creds sceptre/sceptre are upstream's; override with /etc/sceptre/rtu_password.
until [ -s /etc/sceptre/rtus.txt ]; do sleep 1; done
pw=sceptre
[ -s /etc/sceptre/rtu_password ] && pw=$(cat /etc/sceptre/rtu_password)
while read -r rtu ip _; do
  case "$rtu" in ''|\#*) continue ;; esac
  xfce4-terminal --title "$rtu" -e "sh -c 'while :; do sshpass -p \"$pw\" ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null sceptre@${ip:-$rtu}; sleep 3; done'" &
done < /etc/sceptre/rtus.txt
wait
BIN
chmod +x /usr/local/bin/engineer-terminals
cat > /etc/xdg/autostart/engineer-terminals.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=RTU terminals
Exec=/usr/local/bin/engineer-terminals
DESK
