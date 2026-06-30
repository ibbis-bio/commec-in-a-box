#!/usr/bin/env bash
# XFCE desktop: lightdm auto-login for commec-user, wallpaper, conky overlay,
# and NO screen lock / NO display power-off (kiosk-ish appliance).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_HOME=/home/commec-user

apt-get update
apt-get install -y --no-install-recommends \
  xorg xfce4 xfce4-goodies lightdm \
  conky-all x11-xserver-utils xfconf dbus-x11 \
  network-manager-gnome

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
EOF
chmod 0755 /usr/local/bin/commec-desktop-setup.sh

# conky: network-listing + temperature helpers + config.
install -m 0755 /tmp/assets/commec-conky-net.sh /usr/local/bin/commec-conky-net
install -m 0755 /tmp/assets/commec-conky-temp.sh /usr/local/bin/commec-conky-temp
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

chown -R commec-user:commec-user "$USER_HOME/.config"
echo "40-desktop done"
