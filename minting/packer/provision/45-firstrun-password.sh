#!/usr/bin/env bash
# Force a GUI password-set on first login (users are GUI-only; chage/console flows
# don't apply under lightdm autologin). Installs the dialog, the one-time root helper,
# and a single-command NOPASSWD sudoers entry that the helper revokes after use.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_HOME=/home/commec-user

apt-get install -y --no-install-recommends yad zenity libnotify-bin

install -m 0755 /tmp/firstboot/commec-set-initial-password /usr/local/sbin/commec-set-initial-password
install -m 0755 /tmp/firstboot/commec-firstrun-password.sh  /usr/local/bin/commec-firstrun-password.sh
install -m 0755 /tmp/firstboot/commec-setup-wait.sh         /usr/local/bin/commec-setup-wait.sh

# One-time privilege: commec-user may run ONLY this helper without a password, so the
# very first password can be set. The helper deletes this file once done.
# NB: the filename MUST sort AFTER /etc/sudoers.d/commec-user (the blanket
# "commec-user ALL=(ALL) ALL" that first-boot installs). sudo applies the LAST matching
# rule, so an earlier-sorting NOPASSWD exception is overridden by that blanket rule and
# `sudo -n` would demand a password we cannot have yet. Hence the zzz- prefix. Do not rename.
cat >/etc/sudoers.d/zzz-commec-firstrun <<'EOF'
commec-user ALL=(root) NOPASSWD: /usr/local/sbin/commec-set-initial-password
EOF
chmod 0440 /etc/sudoers.d/zzz-commec-firstrun
visudo -cf /etc/sudoers.d/zzz-commec-firstrun

# Autostart the dialog (after wallpaper setup, before conky).
install -d "$USER_HOME/.config/autostart"
cat >"$USER_HOME/.config/autostart/01-commec-firstrun-password.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec First-Run Password
Exec=/usr/local/bin/commec-firstrun-password.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
# Fullscreen "setting up databases - do not power off" gate (after the password dialog),
# closes itself when first-boot finishes the decompress.
cat >"$USER_HOME/.config/autostart/02-commec-setup-wait.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec Setup Wait
Exec=/usr/local/bin/commec-setup-wait.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown -R commec-user:commec-user "$USER_HOME/.config"

# Ensure it runs on the deployed box.
rm -f /var/lib/commec/password.done
echo "45-firstrun-password done"
