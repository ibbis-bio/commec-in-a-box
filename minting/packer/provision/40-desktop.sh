#!/usr/bin/env bash
# XFCE desktop: lightdm auto-login for commec-user, wallpaper, conky overlay,
# and NO screen lock / NO display power-off (kiosk-ish appliance).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_HOME=/home/commec-user

# The target box (ThinkCentre M75q) has an AMD Radeon APU, and the Debian genericcloud base
# ships no GPU microcode. Without it amdgpu can't initialise the APU -> no DRM device -> Xorg
# finds no screens -> lightdm never starts a session and the box drops to a text login. Enable
# Debian's non-free-firmware component so the AMD (and Intel wifi) firmware is installable.
SRC=/etc/apt/sources.list.d/debian.sources
if [ -f "$SRC" ]; then
  grep -q non-free-firmware "$SRC" || sed -i '/^Components:/ s/$/ non-free-firmware/' "$SRC"
else
  grep -q non-free-firmware /etc/apt/sources.list || sed -i 's/\(^deb\b.*\bmain\b\)/\1 non-free-firmware/' /etc/apt/sources.list
fi

# Persistent journal so kernel/service logs survive a reboot - volatile logs cost us a
# painful blind debug of exactly this issue on a deployed box.
install -d -m 2755 /var/log/journal

apt-get update
apt-get install -y --no-install-recommends \
  xorg xfce4 xfce4-goodies lightdm \
  conky-all lm-sensors x11-xserver-utils xfconf dbus-x11 \
  gnome-disk-utility librsvg2-common mate-polkit-bin \
  network-manager-gnome \
  firmware-amd-graphics firmware-iwlwifi firmware-realtek firmware-mediatek \
  firmware-atheros firmware-brcm80211 firmware-misc-nonfree

# No auto-lock / no locker (xfce4-goodies may pull these in).
apt-get purge -y light-locker xfce4-screensaver 2>/dev/null || true

# Boot to the desktop.
systemctl set-default graphical.target

# lightdm: auto-login commec-user into XFCE.
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/10-commec-autologin.conf <<'EOF'
[Seat:*]
autologin-user=commec-user
autologin-user-timeout=0
autologin-session=xfce
EOF
# Debian requires the user be in the 'autologin' group to skip the password.
groupadd -f autologin
gpasswd -a commec-user autologin

# Wallpaper asset.
install -d /usr/share/backgrounds/commec
install -m 0644 /tmp/wallpaper/commec_wallpaper_A_3840x2160.png \
  /usr/share/backgrounds/commec/wallpaper.png

# Login-time desktop setup: wallpaper on every connected monitor + disable blanking,
# DPMS and power-manager display sleep. Done at login because monitor names aren't
# known offline.
install -d /usr/local/bin
cat >/usr/local/bin/commec-desktop-setup.sh <<'EOF'
#!/usr/bin/env bash
IMG=/usr/share/backgrounds/commec/wallpaper.png
# give xfdesktop/xfconf a moment to register the session
sleep 3
props=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/backdrop/screen0/monitor.*/workspace0/last-image' || true)
if [ -n "$props" ]; then
  while read -r p; do
    [ -n "$p" ] && xfconf-query -c xfce4-desktop -p "$p" -s "$IMG" 2>/dev/null || true
  done <<< "$props"
else
  for out in $(xrandr --listmonitors 2>/dev/null | awk 'NR>1{print $NF}'); do
    base="/backdrop/screen0/monitor${out}/workspace0"
    xfconf-query -c xfce4-desktop -p "$base/last-image" -n -t string -s "$IMG" 2>/dev/null || true
    xfconf-query -c xfce4-desktop -p "$base/image-style" -n -t int -s 5 2>/dev/null || true
  done
fi
# no blanking / no DPMS
xset s off -dpms s noblank 2>/dev/null || true
# xfce power manager: never sleep/blank the display on AC
for kv in dpms-enabled:bool:false blank-on-ac:int:0 dpms-on-ac-sleep:int:0 dpms-on-ac-off:int:0; do
  p=${kv%%:*}; rest=${kv#*:}; t=${rest%%:*}; v=${rest#*:}
  xfconf-query -c xfce4-power-manager -p "/xfce4-power-manager/$p" -n -t "$t" -s "$v" 2>/dev/null || true
done
# large desktop icons (default 48px -> 96px): make the "Open Commec Screening" relaunch
# icon a big, easy target for walk-up operators.
xfconf-query -c xfce4-desktop -p /desktop-icons/icon-size -n -t uint -s 96 2>/dev/null \
  || xfconf-query -c xfce4-desktop -p /desktop-icons/icon-size -s 96 2>/dev/null || true
EOF
chmod 0755 /usr/local/bin/commec-desktop-setup.sh

# MITOSIS delegates target selection, authorization, unmounting, and writing to GNOME Disks.
# It deliberately contains no raw-device handling of its own.
install -m 0755 /tmp/assets/commec-mitosis /usr/local/bin/commec-mitosis
install -d "$USER_HOME/Desktop"
install -m 0755 /tmp/assets/MITOSIS.desktop "$USER_HOME/Desktop/MITOSIS.desktop"
install -d /usr/share/commec/icons /usr/share/doc/commec-box
install -m 0644 /tmp/assets/icons/commec-screening.svg /usr/share/commec/icons/
install -m 0644 /tmp/assets/icons/commec-update.svg /usr/share/commec/icons/
install -m 0644 /tmp/assets/icons/mitosis.svg /usr/share/commec/icons/
install -m 0644 /tmp/assets/icons/LICENSE.tabler-icons /usr/share/doc/commec-box/

# conky: network-listing + temperature helpers + config.
install -m 0755 /tmp/assets/commec-conky-net.sh /usr/local/bin/commec-conky-net
install -m 0755 /tmp/assets/commec-conky-temp.sh /usr/local/bin/commec-conky-temp
install -m 0755 /tmp/assets/commec-conky-power.sh /usr/local/bin/commec-conky-power
install -m 0755 /tmp/assets/commec-conky-update.sh /usr/local/bin/commec-conky-update
install -d "$USER_HOME/.config/conky"
install -m 0644 /tmp/assets/conky.conf "$USER_HOME/.config/conky/conky.conf"

# Autostart entries (desktop-setup first, then conky).
install -d "$USER_HOME/.config/autostart"
cat >"$USER_HOME/.config/autostart/00-commec-desktop-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec Desktop Setup
Exec=/usr/local/bin/commec-desktop-setup.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
cat >"$USER_HOME/.config/autostart/10-conky.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Conky
Exec=conky -c /home/commec-user/.config/conky/conky.conf
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

chown -R commec-user:commec-user "$USER_HOME/.config" "$USER_HOME/Desktop"
echo "40-desktop done"
