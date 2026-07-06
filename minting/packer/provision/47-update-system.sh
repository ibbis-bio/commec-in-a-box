#!/usr/bin/env bash
# Install the commec update notifier + A/B env-flip machinery. Additive: leaves 20-commec.sh's
# `commec-env` as-is and layers a stable `current-env` symlink that the shell activates, so an
# update can flip commec versions without rewriting dotfiles. Set COMMEC_CHANNEL=devel to build
# a devel image whose updater is pre-flipped to the devel channel.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends yad wmctrl curl libnotify-bin

# --- A/B: stable symlink -> the live env; repoint the shell activation at it ---------------
install -d /opt/commec
ln -sfn /opt/miniconda/envs/commec-env /opt/commec/current-env
for home in /home/commec-user /root; do
  [ -f "$home/.bashrc" ] && sed -i 's#conda activate commec-env#conda activate /opt/commec/current-env#' "$home/.bashrc" || true
done

# --- scripts ------------------------------------------------------------------------------
install -m 0755 /tmp/update/commec-update-check    /usr/local/bin/commec-update-check
install -m 0755 /tmp/update/commec-update-popup.sh /usr/local/bin/commec-update-popup.sh
install -m 0755 /tmp/update/commec-update-apply    /usr/local/sbin/commec-update-apply

# --- config -------------------------------------------------------------------------------
install -d /etc/commec-box
install -m 0644 /tmp/update/update.conf /etc/commec-box/update.conf
if [ "${COMMEC_CHANNEL:-stable}" = "devel" ]; then
  sed -i 's/^channel=stable/channel=devel/' /etc/commec-box/update.conf
fi

# release.json from the currently-installed commec
CONDA=/opt/miniconda/bin/conda; PY=/opt/miniconda/bin/python
VER=$("$CONDA" list -p /opt/commec/current-env '^commec$' --json 2>/dev/null | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(d[0]["version"] if d else "unknown")')
cat >/etc/commec-box/release.json <<JSON
{ "version": "$VER", "channel": "${COMMEC_CHANNEL:-stable}", "built": "$(date -u +%FT%TZ)" }
JSON
chmod 0644 /etc/commec-box/release.json

# --- NOPASSWD for the apply helper --------------------------------------------------------
# MUST sort AFTER /etc/sudoers.d/commec-user (first-boot's blanket 'commec-user ALL=(ALL) ALL')
# so its NOPASSWD wins sudo's last-match. Same reason as zzz-commec-firstrun; do not rename.
cat >/etc/sudoers.d/zzz-commec-update <<'EOF'
commec-user ALL=(root) NOPASSWD: /usr/local/sbin/commec-update-apply
EOF
chmod 0440 /etc/sudoers.d/zzz-commec-update
visudo -cf /etc/sudoers.d/zzz-commec-update

# --- autostart the notifier (after 01-password and 10-conky) ------------------------------
install -d /home/commec-user/.config/autostart
cat >/home/commec-user/.config/autostart/30-commec-update.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec Update Notifier
Exec=/usr/local/bin/commec-update-popup.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown -R commec-user:commec-user /home/commec-user/.config

echo "47-update-system done"
