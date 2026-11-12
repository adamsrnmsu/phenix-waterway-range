#!/bin/bash
# Chroot build step: Firefox (Mozilla apt repo; Ubuntu's firefox is a snap) + kiosk autostart.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get install -y wget gnupg ca-certificates
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg > /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
apt-get update
apt-get install -y --allow-downgrades firefox
install -d /etc/sceptre /etc/xdg/autostart /etc/firefox/policies
touch /etc/cloud/cloud-init.disabled
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
# skip first-run/welcome pages so the kiosk lands on the URL
cat > /etc/firefox/policies/policies.json <<'POL'
{"policies":{"OverrideFirstRunPage":"","OverridePostUpdatePage":"","DontCheckDefaultBrowser":true,"DisableTelemetry":true,"DisableFirefoxStudies":true,"NoDefaultBookmarks":true,"DisableProfileImport":true,"Preferences":{"browser.aboutwelcome.enabled":false,"datareporting.policy.dataSubmissionPolicyBypassNotification":true}}}
POL
cat > /etc/xdg/autostart/hmi-kiosk.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=HMI kiosk
Exec=sh -c 'until [ -s /etc/sceptre/hmi_url ]; do sleep 1; done; u=$(cat /etc/sceptre/hmi_url); until curl -fs -m 3 -o /dev/null "$u"; do sleep 2; done; exec firefox --kiosk "$u"'
DESK
