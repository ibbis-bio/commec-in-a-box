#!/usr/bin/env bash
# Commec appliance first-boot setup. Runs once (guarded), as root, via systemd.
#   1. force operator password change + lock root   (fast)
#   2. grow root partition/fs to fill the real disk  (fast)
#   3. stream-decompress the staged BLAST DBs        (slow: ~tens of minutes)
# Does NOT block the display manager - the desktop is up while DBs unpack.
set -uo pipefail

GUARD=/var/lib/commec/firstboot.done
LOG=/var/log/commec-firstboot.log
DBROOT=/home/commec-user/commec-dbs
STAGING=/opt/commec/staging
exec > >(tee -a "$LOG") 2>&1

echo "=== commec-firstboot $(date -u +%FT%TZ) ==="
if [ -e "$GUARD" ]; then echo "guard present; nothing to do"; exit 0; fi
mkdir -p "$(dirname "$GUARD")"

cat <<'BANNER'
########################################################################
#  COMMEC FIRST-TIME SETUP IN PROGRESS - DO NOT POWER OFF              #
#  Unpacking the screening databases. This can take a while.           #
#  The machine will be ready when the desktop setup screen clears.     #
########################################################################
BANNER

# --- 0. regenerate clone-unique SSH host keys (removed from the master) ---
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  echo "[0] regenerating SSH host keys"
  ssh-keygen -A || echo "WARN: ssh-keygen -A failed"
  systemctl restart ssh 2>/dev/null || true
fi

# --- 1. accounts (fast, do first so security is set even if unpack is slow) ---
# Operator password is set via the GUI first-run dialog (users are GUI-only), not here.
echo "[1/3] securing accounts + sudo"
passwd -l root || echo "WARN: root lock failed"
# Harden sudo on the deployed box: drop the build-time NOPASSWD grant, require a
# password (kept NOPASSWD during the build so Packer could shut the VM down). The
# one-time password-setup helper has its own narrow NOPASSWD rule (sudoers.d/commec-firstrun).
rm -f /etc/sudoers.d/90-cloud-init-users
printf 'commec-user ALL=(ALL) ALL\n' > /etc/sudoers.d/commec-user
chmod 0440 /etc/sudoers.d/commec-user

# --- 2. grow root to fill the disk (must precede decompression) ---
echo "[2/3] growing root filesystem"
ROOT_SRC=$(findmnt -no SOURCE /)
PART=$(basename "$ROOT_SRC")
DISK=/dev/$(lsblk -no PKNAME "$ROOT_SRC")
PARTNUM=$(cat "/sys/class/block/$PART/partition")
echo "  root=$ROOT_SRC disk=$DISK part=$PARTNUM"
growpart "$DISK" "$PARTNUM" || echo "  growpart: nothing to do"
resize2fs "$ROOT_SRC" || echo "WARN: resize2fs failed"

# --- 2b. pre-flight: the grown fs must fit the DB decompression ---
# The best_match BLAST DBs decompress to ~36 GiB, and the compressed tarball (~6.5 GiB) is
# still present during extraction, so the target fs needs ~40 GiB free. Fail LOUDLY on a
# too-small disk here instead of cascading into a mid-extract ENOSPC - which leaves a
# corrupt DB, blocks the password helper (its write also hits ENOSPC), and surfaces to
# the operator only as a baffling "Could not set the password". Update NEED_GB if the
# staged DB set changes.
NEED_GB=40
AVAIL_GB=$(df -PBG /home/commec-user | awk 'NR==2{gsub(/G/,"",$4); print $4+0}')
echo "[2b] disk check: need ${NEED_GB} GiB free for databases, have ${AVAIL_GB:-0} GiB"
if [ "${AVAIL_GB:-0}" -lt "$NEED_GB" ]; then
  cat <<EOF >&2
########################################################################
#  FATAL: this disk is too small for the screening databases.          #
#  Need ~${NEED_GB} GiB free, have ${AVAIL_GB:-0} GiB.
#  Re-deploy onto an internal disk of at least 64 GB.                   #
########################################################################
EOF
  exit 1
fi

# --- 3. decompress the staged best_match DBs into ~commec-user/commec-dbs/best_match ---
echo "[3/3] unpacking databases (this takes a while)"
# best_match is the large BLAST DB set; it rides the image compressed (build.sh stages
# best_match.tar.zst from R2) and expands here to keep the flashed stick small. The small DBs
# (biorisk/low_concern/control_lists) were already baked at mint by 30-commec-setup.sh; they are
# sibling dirs under $DBROOT and untouched. Extraction mirrors `commec setup`
# (`tar --zstd -xf ... -C $DBROOT/best_match`): the tar members are relative to best_match/, so
# they land as best_match/{protein/prot, nucleotide/nucl} - the shipped config paths. We wipe
# best_match/ first for a clean re-run, then drop the staged manifest so commec's screen JSON and
# DB-revision check see the revision. Removing the tarball only after a successful extract keeps
# it resumable across an interrupted run.
BUNDLE="$STAGING/best_match.tar.zst"
BMDIR="$DBROOT/best_match"
if [ -f "$BUNDLE" ]; then
  echo "  best_match.tar.zst -> $BMDIR/{protein,nucleotide}"
  rm -rf "$BMDIR"
  mkdir -p "$BMDIR"
  if tar --zstd -xf "$BUNDLE" -C "$BMDIR"; then
    install -m 0644 "$STAGING/best_match.manifest.json" "$BMDIR/manifest.json"
    rm -f "$BUNDLE"
  else
    echo "ERROR: failed to unpack best_match.tar.zst"; exit 1
  fi
else
  # Fail LOUD instead of silently booting a half-provisioned (small-DBs-only) box: a missing
  # bundle means the image/flash is incomplete. Exit before the guard is set so first-boot
  # re-runs (and the GUI never comes up) rather than presenting a quietly degraded appliance.
  cat <<EOF >&2
########################################################################
#  FATAL: the best_match database bundle is missing from this image.   #
#  Expected: $BUNDLE
#  This deployment is incomplete - re-flash from a known-good stick.    #
########################################################################
EOF
  exit 1
fi
chown -R commec-user:commec-user "$DBROOT"
rmdir "$STAGING" 2>/dev/null || true

touch "$GUARD"

# Start the GUI server now. Its unit has ConditionPathExists=firstboot.done, which was FALSE
# when systemd evaluated it at boot (this guard is written only here, post-decompress) - and
# systemd does NOT re-check a failed condition, so the service was skipped and would never come
# up on this first boot. Kick it now that the DBs are ready; the kiosk launcher is curl-waiting
# for it. No-op on non-kiosk images (unit absent). On later boots the guard already exists, so
# the unit starts normally at boot and this is a harmless restart.
systemctl start commec-gui.service 2>/dev/null || true

systemctl disable commec-firstboot.service || true
echo "=== commec-firstboot complete $(date -u +%FT%TZ) ==="
