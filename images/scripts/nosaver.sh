#!/bin/bash
# Chroot build step (GUI nodes): the range display must never blank or lock (ww-585.29).
# xfce4-screensaver / xscreensaver / xfce4-power-manager each blank after ~10-30 min idle and defeat the
# Xorg noblank conf, so hide their autostarts, make the binaries unrunnable, and run `xset s off -dpms` at login.
set -eu
for f in xfce4-screensaver xscreensaver xfce4-power-manager gnome-screensaver light-locker; do
  d=/etc/xdg/autostart/$f.desktop
  if [ -f "$d" ]; then
    sed -i '/^Hidden=/d' "$d"; echo 'Hidden=true' >> "$d"
  fi
  for b in /usr/bin/$f /usr/libexec/$f /usr/lib/aarch64-linux-gnu/xfce4/$f; do
    if [ -f "$b" ]; then chmod -x "$b"; fi
  done
done
install -d /etc/xdg/autostart
cat > /etc/xdg/autostart/nosaver.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Disable X screensaver/DPMS
Exec=sh -c 'xset s off s noblank -dpms; while sleep 300; do xset s off s noblank -dpms; done'
DESK
