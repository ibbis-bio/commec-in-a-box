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

# --- 3. decompress staged DBs into ~commec-user/commec-dbs ---
echo "[3/3] unpacking databases (this takes a while)"
declare -A MAP=( ["nr.tar-001.zst"]="nr_blast" ["core_nt.tar-002.zst"]="nt_blast" )
for f in "${!MAP[@]}"; do
  sub="${MAP[$f]}"
  src="$STAGING/$f"
  if [ ! -f "$src" ]; then echo "  MISSING $src - skipping"; continue; fi
  echo "  $f -> $DBROOT/$sub"
  # Idempotent/resumable: a tarball is only removed AFTER a successful extract, so if we
  # reach here the dir may hold a partial extract from an interrupted run - wipe it first.
  rm -rf "$DBROOT/$sub"; mkdir -p "$DBROOT/$sub"
  if tar -I 'zstd -d --long=31' -xf "$src" -C "$DBROOT/$sub"; then
    rm -f "$src"
  else
    echo "ERROR: failed to unpack $f"; exit 1
  fi
done
chown -R commec-user:commec-user "$DBROOT"
rmdir "$STAGING" 2>/dev/null || true

touch "$GUARD"
systemctl disable commec-firstboot.service || true
echo "=== commec-firstboot complete $(date -u +%FT%TZ) ==="
