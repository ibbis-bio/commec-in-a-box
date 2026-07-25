#!/usr/bin/env bash
# Install + configure the commec-gui kiosk (implements gui/deploy-notes.md).
#
# Topology for this appliance: the server binds 0.0.0.0:443 over HTTPS (per-device mkcert cert),
# so the walk-up operator gets a clean https://localhost AND LAN clients can reach it - behind the
# GUI password (non-localhost only) and a host firewall. A local browser auto-opens for the walk-up,
# gated on first-boot + password completion so it never races those screens.
#
# NOTE: several pieces here can only be fully verified on a booted image (mkcert<->Firefox NSS
# trust timing, the systemd service env, the firewall). Marked inline.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

KUSER=commec-user
KHOME=/home/$KUSER
GUI=/opt/commec-gui
DBDIR=$KHOME/commec-dbs
CONDA=/opt/miniconda

# --- packages: per-device TLS (mkcert) + Firefox NSS trust store + browser + firewall + udisks ---
# mkcert missing is a loud failure by design (deploy-notes): no silent self-signed warning-cert.
# NB: Debian 13 (trixie) renamed the polkit daemon package policykit-1 -> polkitd.
apt-get install -y --no-install-recommends \
  mkcert libnss3-tools firefox-esr nftables polkitd udisks2 curl xdg-utils

# --- install the gui tree ---
install -d "$GUI"
cp -a /tmp/guisrc/. "$GUI"/
rm -f "$GUI/.gitkeep" "$GUI/.gitignore"
# flask/werkzeug/pyyaml ride in with the commec package (recipe run: deps), so nothing to pip here.

# --- .env (sourced by kiosk.sh/lan.sh) ---
cat > "$GUI/.env" <<EOF
# commec-gui config (image-provisioned). See gui/deploy-notes.md.
COMMEC_CONDA_ENV="/opt/commec/current-env"   # the A/B symlink, so updates take effect
COMMEC_DB_DIR="$DBDIR"
COMMEC_GUI_PORT="443"
COMMEC_GUI_PASSWORD_FILE="$KHOME/.config/commec-gui/password.hash"
# HTTPS via mkcert (--tls-auto). Set COMMEC_TLS=0 for plain HTTP.
EOF

# --- presets.yaml (mt_mode is NOT set here: 30-commec-setup.sh bakes blast_mt_mode=0 into the
# commec config so it applies to every run - CLI and GUI - not just these presets) ---
cat > "$GUI/presets.yaml" <<'EOF'
presets:
  - id: biorisk
    label: Biorisk only (fast)
    recommended: false
    config:
      skip_taxonomy_search: true
      skip_nt_search: true
  - id: full
    label: Full screen
    recommended: true
    config:
      skip_taxonomy_search: false
      skip_nt_search: false
EOF

chown -R "$KUSER:$KUSER" "$GUI"

# --- let the unprivileged GUI user bind 443 (dedicated appliance; simpler than CAP/systemd) ---
echo 'net.ipv4.ip_unprivileged_port_start=443' > /etc/sysctl.d/60-commec-gui.conf

# --- udisks USB auto-mount authorization for the GUI (plugdev), per deploy-notes ---
usermod -aG plugdev "$KUSER" || true
install -d /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-commec-usb.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.udisks2.filesystem-mount") == 0 &&
      subject.isInGroup("plugdev")) { return polkit.Result.YES; }
});
EOF

# --- inbound firewall: allow localhost / private LAN / tailscale to 443, drop the public net ---
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet commec {
  chain input {
    type filter hook input priority 0; policy accept;
    ct state established,related accept
    iif "lo" accept
    iifname "tailscale0" tcp dport 443 accept
    tcp dport 443 ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } accept
    tcp dport 443 drop
  }
}
EOF
systemctl enable nftables.service

# --- GUI server: systemd service (lan.sh -> 0.0.0.0:443 HTTPS), gated on first boot + password ---
# PATH includes miniconda so lan.sh's `conda info --base` resolves under the minimal service env.
# ExecStartPre runs mkcert -install (idempotent) so the per-device CA is trusted before --tls-auto
# issues the cert. (Firefox NSS trust also needs the user's profile to exist - see the launcher.)
# Do not use ConditionPathExists for these guards: systemd does not re-attempt a skipped unit when
# a condition file later appears. A blocking pre-start keeps this unit pending until first boot
# finished and the operator password (and its GUI hash) were recorded. If either setup phase
# crashes, the LAN GUI never starts unauthenticated.
cat > /etc/systemd/system/commec-gui.service <<EOF
[Unit]
Description=commec-gui server (kiosk + LAN, HTTPS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$KUSER
WorkingDirectory=$GUI
Environment=PATH=$CONDA/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$KHOME
TimeoutStartSec=0
ExecStartPre=/bin/bash -c 'until [ -e /var/lib/commec/firstboot.done ] && [ -e /var/lib/commec/password.done ]; do sleep 2; done'
ExecStartPre=-/bin/bash -c 'mkcert -install || true'
ExecStart=/bin/bash $GUI/lan.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable commec-gui.service

# --- Firefox enterprise policy: strip the first-run noise for a clean kiosk ---
# Suppresses the "Firefox Privacy Notice" / first-run tab, the post-update "what's new" tab,
# the telemetry prompt, and the default-browser nag - so the kiosk opens straight to the GUI.
install -d /etc/firefox-esr/policies
cat > /etc/firefox-esr/policies/policies.json <<'EOF'
{
  "policies": {
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "DisableProfileImport": true,
    "DisableFeedbackCommands": true
  }
}
EOF

# --- walk-up browser: guarded launcher + autostart (runs in the commec-user graphical session) ---
cat > /usr/local/bin/commec-kiosk-launch.sh <<'EOF'
#!/usr/bin/env bash
# Open the local kiosk browser, but only AFTER first-boot setup + password are done (so it never
# covers the setup-wait / password dialogs) and the server is answering. It opens windowed; the
# operator chooses fullscreen via the in-page header button (no auto-fullscreen).
set -u
URL="https://localhost:443/"
PROFILE="commec-kiosk"
PROFILE_DIR="$HOME/.mozilla/firefox/$PROFILE"

while [ ! -e /var/lib/commec/firstboot.done ] || [ ! -e /var/lib/commec/password.done ]; do sleep 3; done

# Use a DEDICATED, pre-created Firefox profile. Letting Firefox auto-create its default profile
# at launch races with first-run init (and with mkcert touching ~/.mozilla/firefox), which can
# leave a half-initialized profile dir and the fatal "Your Firefox profile cannot be loaded"
# dialog. -CreateProfile is deterministic and registers the profile in profiles.ini.
if [ ! -d "$PROFILE_DIR" ]; then
  firefox-esr -CreateProfile "$PROFILE $PROFILE_DIR" >/dev/null 2>&1 || true
fi
# Kiosk hygiene: suppress Firefox's first-run / data-collection ("Privacy Notice") tabs so the
# operator lands straight on the GUI. Profile-scoped prefs are more reliable than enterprise
# policy for these onboarding tabs (the policies.json OverrideFirstRunPage doesn't cover them).
if [ -d "$PROFILE_DIR" ]; then
  cat > "$PROFILE_DIR/user.js" <<'PREFS'
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
PREFS
fi
# Trust the per-device mkcert CA in THIS profile so the mkcert-issued server cert (gen-cert.sh,
# same CAROOT) validates with no browser warning. `mkcert -install` targets Firefox's *default*
# profile and needs an already-initialized cert db, so it misses our fresh dedicated profile;
# add the CA directly with certutil, which creates cert9.db in the profile if absent.
mkcert -install >/dev/null 2>&1 || true
CAROOT="$(mkcert -CAROOT 2>/dev/null)"
if [ -n "$CAROOT" ] && [ -f "$CAROOT/rootCA.pem" ] && [ -d "$PROFILE_DIR" ]; then
  certutil -A -n commec-mkcert -t C,, -i "$CAROOT/rootCA.pem" -d sql:"$PROFILE_DIR" >/dev/null 2>&1 || true
fi

for _ in $(seq 1 90); do curl -ksS -o /dev/null "$URL" && break; sleep 2; done
# Prefer the named profile (registered in profiles.ini, so mkcert trusted its cert db). If
# -CreateProfile didn't produce it, fall back to --profile <dir>, which self-creates a usable
# profile at launch - the kiosk still comes up (a cert warning is the worst case), never a
# dead "Profile Missing".
if [ -d "$PROFILE_DIR" ]; then
  exec firefox-esr --no-remote -P "$PROFILE" --new-window "$URL"
else
  exec firefox-esr --no-remote --profile "$PROFILE_DIR" --new-window "$URL"
fi
EOF
chmod 0755 /usr/local/bin/commec-kiosk-launch.sh

install -d "$KHOME/.config/autostart"
cat > "$KHOME/.config/autostart/40-commec-kiosk.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Commec Kiosk
Exec=/usr/local/bin/commec-kiosk-launch.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown -R "$KUSER:$KUSER" "$KHOME/.config"

# --- desktop "reopen the console" launcher (for when the operator closes the browser) ---
# A big, obvious desktop icon that relaunches the kiosk browser at the screening console.
# Reuses the standard kiosk launcher; the guard makes it a no-op if the browser is still up
# (so a stray double-click can't trip Firefox's --no-remote "already running" error).
cat > /usr/local/bin/commec-kiosk-open.sh <<'EOF'
#!/usr/bin/env bash
# Reopen the screening console. No-op if the kiosk browser is already running.
if pgrep -f 'firefox-esr.*commec-kiosk' >/dev/null 2>&1; then
  exit 0
fi
exec /usr/local/bin/commec-kiosk-launch.sh
EOF
chmod 0755 /usr/local/bin/commec-kiosk-open.sh

install -d "$KHOME/Desktop"
cat > "$KHOME/Desktop/commec-open-screening.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Open Commec Screening
Comment=Reopen the screening console if the window was closed
Exec=/usr/local/bin/commec-kiosk-open.sh
Icon=firefox-esr
Terminal=false
Categories=Application;
EOF
# Executable so xfdesktop launches it on double-click without the "untrusted launcher" prompt.
chmod 0755 "$KHOME/Desktop/commec-open-screening.desktop"
chown -R "$KUSER:$KUSER" "$KHOME/Desktop"

echo "48-commec-gui done"
