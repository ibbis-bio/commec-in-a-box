#!/usr/bin/env bash
# Install the commec update system (headless status poller + desktop-icon action) + A/B env-flip
# machinery. Additive: leaves 20-commec.sh's
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
# check: writes the status token + state json for BOTH axes (commec package and databases).
# poll: headless loop that keeps them fresh for the conky overlay (no dialogs). now: the
# desktop-icon action (check + all dialogs + install). apply: root A/B env-flip helper.
# db-apply: root database updater. db-status: the machine-readable database check the other two
# call; screen-state: the shared running-screen safety probe. These live in a lib dir rather
# than on PATH.
# (commec-patch-config is installed earlier by 30-commec-setup.sh, which both this apply helper
# and the mint step call.)
install -m 0755 /tmp/update/commec-update-check    /usr/local/bin/commec-update-check
install -m 0755 /tmp/update/commec-update-poll.sh  /usr/local/bin/commec-update-poll.sh
install -m 0755 /tmp/update/commec-update-now.sh   /usr/local/bin/commec-update-now.sh
install -m 0755 /tmp/update/commec-update-apply    /usr/local/sbin/commec-update-apply
install -m 0755 /tmp/update/commec-db-apply        /usr/local/sbin/commec-db-apply
install -d /usr/local/lib/commec-box
install -m 0644 /tmp/update/commec-db-status.py    /usr/local/lib/commec-box/commec-db-status.py
install -m 0755 /tmp/update/commec-screen-state    /usr/local/lib/commec-box/commec-screen-state

# --- config -------------------------------------------------------------------------------
install -d /etc/commec-box
install -m 0644 /tmp/update/update.conf /etc/commec-box/update.conf
if [ "${COMMEC_CHANNEL:-stable}" = "devel" ]; then
  # TEMPORARY: point the updater at the rose-served dev channel. Default is the QEMU user-net
  # gateway (= the rose host) for the Phase-3 VM test; override with COMMEC_UPDATE_URL for a real box.
  url="${COMMEC_UPDATE_URL:-http://10.0.2.2:8000}"
  sed -i "s|^channel=stable|channel=devel|" /etc/commec-box/update.conf
  sed -i "s|^commec_primary_channel=.*|commec_primary_channel=${url}|" /etc/commec-box/update.conf
  sed -i "s|^conda_channels=.*|conda_channels=${url},ibbis,conda-forge,bioconda|" /etc/commec-box/update.conf
  sed -i "s|^probe_url=.*|probe_url=${url}/noarch/repodata.json|" /etc/commec-box/update.conf
fi

# --- NetworkManager dispatcher: refresh the update status the moment connectivity comes up, so a
# post-boot wifi connect reflects in conky immediately instead of waiting for the periodic poll.
# NM requires dispatcher scripts to be root-owned and non-world-writable (0755). ---
install -m 0755 /tmp/update/commec-update-nm-dispatcher /etc/NetworkManager/dispatcher.d/90-commec-update

# release.json from the currently-installed commec, plus the database revisions baked at mint.
# The database block is not cosmetic: commec-db-apply moves it to "databases_previous" on each
# update, which is what --rollback restores from. Without it seeded here the FIRST database
# update on a box would have no rollback target.
CONDA=/opt/miniconda/bin/conda; PY=/opt/miniconda/bin/python
VER=$("$CONDA" list -p /opt/commec/current-env '^commec$' --json 2>/dev/null | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(d[0]["version"] if d else "unknown")')
DBDIR="${COMMEC_DB_DIR:-/home/commec-user/commec-dbs}"
"$PY" - /etc/commec-box/release.json "$VER" "${COMMEC_CHANNEL:-stable}" "$DBDIR" <<'PY'
import json, os, sys, time

rel_path, version, channel, db_dir = sys.argv[1:5]
databases = {}
for name in sorted(os.listdir(db_dir)) if os.path.isdir(db_dir) else []:
    manifest = os.path.join(db_dir, name, "manifest.json")
    if os.path.isfile(manifest):
        with open(manifest) as fh:
            databases[name] = json.load(fh)["revision"]

with open(rel_path, "w") as fh:
    json.dump({
        "version": version,
        "channel": channel,
        "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "databases": databases,
    }, fh, indent=2)
    fh.write("\n")
print("release.json:", version, channel, databases)
PY
chmod 0644 /etc/commec-box/release.json

# --- NOPASSWD for the apply helper --------------------------------------------------------
# MUST sort AFTER /etc/sudoers.d/commec-user (first-boot's blanket 'commec-user ALL=(ALL) ALL')
# so its NOPASSWD wins sudo's last-match. Same reason as zzz-commec-firstrun; do not rename.
cat >/etc/sudoers.d/zzz-commec-update <<'EOF'
commec-user ALL=(root) NOPASSWD: /usr/local/sbin/commec-update-apply
commec-user ALL=(root) NOPASSWD: /usr/local/sbin/commec-db-apply
EOF
chmod 0440 /etc/sudoers.d/zzz-commec-update
visudo -cf /etc/sudoers.d/zzz-commec-update

# --- autostart the headless status poller (after 01-password and 10-conky) ----------------
# No dialogs - it only refreshes the status file the conky overlay reads. All update UI is the
# desktop icon below.
install -d /home/commec-user/.config/autostart
cat >/home/commec-user/.config/autostart/30-commec-update.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec Update Status Poller
Exec=/usr/local/bin/commec-update-poll.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# --- desktop icon: operator-initiated check + install -------------------------------------
# Modeled on the "Open Commec Screening" icon (48-commec-gui.sh): a ~/Desktop/*.desktop made
# trusted by chmod 0755 so xfdesktop launches it without the "untrusted launcher" prompt. Renders
# at the global 96px desktop-icon size. Reaches root only via the existing zzz-commec-update rule.
install -d /home/commec-user/Desktop
cat >/home/commec-user/Desktop/commec-check-updates.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Update Commec
Comment=Check online for a newer commec and install it
Exec=/usr/local/bin/commec-update-now.sh
Icon=/usr/share/commec/icons/commec-update.svg
Terminal=false
Categories=Application;
EOF
chmod 0755 /home/commec-user/Desktop/commec-check-updates.desktop

chown -R commec-user:commec-user /home/commec-user/.config /home/commec-user/Desktop

echo "47-update-system done"
