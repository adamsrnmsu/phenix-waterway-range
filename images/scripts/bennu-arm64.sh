#!/bin/sh
# Chroot build step (phenix runs this under sh -ec: POSIX only): bennu on arm64 (jammy). Port of sceptre-phenix-images/scripts/bennu.sh:
# /usr/local (bennu, libzmq drafts, HELICS, pybennu + deps) arrives via overlay images/overlays/bennu-arm64
# (docker cp from bennu:arm64), so no GitHub .deb/wheel downloads and no LabJack.
set -ex
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
APT="apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime
M=http://ports.ubuntu.com/ubuntu-ports
. /etc/os-release
mv /etc/apt/sources.list /etc/apt/sources.list_backup || true
for p in "" -updates -security; do
  echo "deb [arch=arm64 trusted=yes] $M ${VERSION_CODENAME}$p main restricted universe multiverse" >> /etc/apt/sources.list
done
apt-get update
# runtime deps from the bennu Dockerfile final stage + upstream bennu.sh tools
$APT apt-utils ca-certificates libzmq5-dev collectd ftp pv python3 python3-pip python3-setuptools \
  python3-twisted python3-wheel socat tcpdump tmux telnet vsftpd wget git nano vim jq ntp libusb-1.0-0 \
  libsodium23 libfreetype6 liblapack3 libboost-system1.74.0 libboost-filesystem1.74.0 \
  libboost-thread1.74.0 libboost-serialization1.74.0 libboost-date-time1.74.0 \
  libboost-program-options1.74.0 libboost-iostreams1.74.0 libunwind8

echo /usr/local/lib > /etc/ld.so.conf.d/usr-local.conf
echo /usr/local/lib/aarch64-linux-gnu >> /etc/ld.so.conf.d/usr-local.conf
ldconfig

# upstream debs install to /usr/bin; the sceptre app's sceptre-start.sh copies /usr/bin/bennu-field-deviced
for f in /usr/local/bin/bennu-* /usr/local/bin/pybennu-*; do ln -sf "$f" /usr/bin/; done

brash=$(command -v bennu-brash) && chmod u+s "$brash"

sed -i 's/pam_service_name=vsftpd/pam_service_name=ftp/g' /etc/vsftpd.conf
echo "sceptre" >> /etc/vsftpd.allowed_users
cat <<EOT >> /etc/vsftpd.conf
write_enable=YES
file_open_mode=0777
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
userlist_deny=NO
userlist_enable=YES
userlist_file=/etc/vsftpd.allowed_users
EOT

echo "root:SiaSd3te" | chpasswd
adduser sceptre --UID 1001 --gecos "" --shell /usr/local/bin/bennu-brash --disabled-login || true
echo "sceptre:sceptre" | chpasswd
grep -q bennu-brash /etc/shells || echo /usr/local/bin/bennu-brash >> /etc/shells

systemctl disable systemd-timesyncd || true
systemctl enable ntp || true

cat << EOT >> /root/.bash_aliases
alias prun='pybennu-power-solver start'
alias pstart='pybennu-power-solver start -d'
alias pstop='pybennu-power-solver stop'
alias prestart='pybennu-power-solver restart -d'
alias plogs='tail -f /var/log/bennu-pybennu.*'
alias preset='pybennu-power-solver stop;rm -f /var/log/bennu-pybennu.*'
alias pconf='vim /etc/sceptre/config.ini'
alias pyconf='vim /etc/sceptre/*.yaml'
EOT

chown -R root:root /etc
apt-get -y clean || true
