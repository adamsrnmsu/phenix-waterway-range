#!/bin/sh
# Chroot build step: Eclipse Mosquitto broker (Ubuntu distro package, unmodified; EPL-2.0 / EDL-1.0).
# POSIX sh only (vmdb2 runs scripts under `sh -ec`). Packages come from the recipe's PACKAGES.
#
# LAB DEFAULT: with no injected files the broker is ANONYMOUS and open on 1883 (and 8883 TLS when certs are injected).
# Lock down by injecting (phenix injections / cc send), then `systemctl restart mosquitto`:
#   /etc/mosquitto/passwd   mosquitto_passwd file   -> password_file, allow_anonymous false
#   /etc/mosquitto/acl      ACL file (optional)      -> acl_file
#   /etc/mosquitto/certs/{ca.crt,server.crt,server.key} -> TLS listener on 8883
# The listener config is regenerated at every start from what is present (ferrofire-mqtt-conf).
# Logging: syslog -> journald, capped by journald.conf.d (cannot fill the disk). No persistence.
set -eu

install -d /etc/mosquitto/conf.d /etc/mosquitto/certs /etc/systemd/journald.conf.d \
  /etc/systemd/system/mosquitto.service.d /etc/systemd/system/multi-user.target.wants

# replace the distro main conf: it logs to an uncapped file and enables persistence
cat > /etc/mosquitto/mosquitto.conf <<'EOF'
# managed by images/scripts/mqtt.sh; site config lives in conf.d/
pid_file /run/mosquitto/mosquitto.pid
persistence false
log_dest syslog
log_type error
log_type warning
log_type notice
include_dir /etc/mosquitto/conf.d
EOF

cat > /etc/systemd/journald.conf.d/ferrofire.conf <<'EOF'
[Journal]
SystemMaxUse=32M
RuntimeMaxUse=32M
EOF

cat > /usr/local/sbin/ferrofire-mqtt-conf <<'EOF'
#!/bin/sh
# regenerate /etc/mosquitto/conf.d/ferrofire.conf from the injected files; runs as root before mosquitto
D=/etc/mosquitto
OUT=$D/conf.d/ferrofire.conf
{
  echo "# generated at boot by ferrofire-mqtt-conf; edit/inject files, do not edit this"
  if [ -s $D/passwd ]; then
    chgrp mosquitto $D/passwd; chmod 0640 $D/passwd
    echo "allow_anonymous false"; echo "password_file $D/passwd"
  else
    echo "# LAB DEFAULT: no $D/passwd injected, anonymous access allowed"
    echo "allow_anonymous true"
  fi
  if [ -s $D/acl ]; then
    chgrp mosquitto $D/acl; chmod 0640 $D/acl; echo "acl_file $D/acl"
  fi
  echo "listener 1883"
  if [ -s $D/certs/ca.crt ] && [ -s $D/certs/server.crt ] && [ -s $D/certs/server.key ]; then
    chgrp mosquitto $D/certs/*; chmod 0640 $D/certs/*
    echo "listener 8883"
    echo "cafile $D/certs/ca.crt"; echo "certfile $D/certs/server.crt"; echo "keyfile $D/certs/server.key"
  fi
} > $OUT.tmp && mv $OUT.tmp $OUT
EOF
chmod 0755 /usr/local/sbin/ferrofire-mqtt-conf

cat > /etc/systemd/system/mosquitto.service.d/ferrofire.conf <<'EOF'
[Service]
ExecStartPre=+/usr/local/sbin/ferrofire-mqtt-conf
EOF

ln -sf /lib/systemd/system/mosquitto.service /etc/systemd/system/multi-user.target.wants/mosquitto.service
/usr/local/sbin/ferrofire-mqtt-conf   # sanity: also leaves a default conf in the image
