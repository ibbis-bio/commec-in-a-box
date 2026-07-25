#!/usr/bin/env bash
# Flash a deployment-stick image to a physical disk, verify the copied bytes, and
# relocate the backup GPT to the physical end of media that is larger than the image.
#
# Usage: ./flash-stick.sh /dev/sdX
# Env:
#   STICK_IMG             raw image to flash (default: $WORK_DIR/commec-deploy-stick.img)
#   COMMEC_FLASH_CONFIRM  exact resolved device path for non-interactive use
#   COMMEC_FLASH_ALLOW_FIXED=1  permit a non-USB, non-removable target (VM/test use)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STICK_IMG="${STICK_IMG:-$WORK_DIR/commec-deploy-stick.img}"
[ $# -eq 1 ] || die "usage: $0 /dev/sdX"
[ -f "$STICK_IMG" ] || die "STICK_IMG not found: $STICK_IMG"

for cmd in awk blkid blockdev dd findmnt fsck.vfat head lsblk partprobe readlink \
  sgdisk sha256sum stat sudo udevadm; do
  command -v "$cmd" >/dev/null || die "required command not found: $cmd"
done

TARGET=$(readlink -f -- "$1")
[ -b "$TARGET" ] || die "target is not a block device: $TARGET"
[ "$(lsblk -dnro TYPE "$TARGET")" = disk ] || die "target must be a whole disk: $TARGET"

ROOT_SOURCE=$(findmnt -no SOURCE /)
mapfile -t ROOT_DISKS < <(
  lsblk -srnpo PATH,TYPE "$ROOT_SOURCE" | awk '$2 == "disk" { print $1 }'
)
[ "${#ROOT_DISKS[@]}" -gt 0 ] || die "could not resolve the disk containing / ($ROOT_SOURCE)"
for ROOT_DISK in "${ROOT_DISKS[@]}"; do
  [ "$TARGET" != "$ROOT_DISK" ] || die "refusing to overwrite a disk containing /: $TARGET"
done

TARGET_TRAN=$(lsblk -dnro TRAN "$TARGET")
TARGET_RM=$(lsblk -dnro RM "$TARGET")
if [ "$TARGET_TRAN" != usb ] && [ "$TARGET_RM" != 1 ] &&
   [ "${COMMEC_FLASH_ALLOW_FIXED:-0}" != 1 ]; then
  die "target is not USB/removable: $TARGET (set COMMEC_FLASH_ALLOW_FIXED=1 only for VM/test use)"
fi

if lsblk -nrpo MOUNTPOINTS "$TARGET" | awk 'NF { found=1 } END { exit !found }'; then
  die "target or one of its partitions is mounted: $TARGET"
fi

IMAGE_BYTES=$(stat -c %s "$STICK_IMG")
TARGET_BYTES=$(sudo blockdev --getsize64 "$TARGET")
[ "$(sudo blockdev --getro "$TARGET")" -eq 0 ] || die "target is read-only: $TARGET"
[ "$TARGET_BYTES" -ge "$IMAGE_BYTES" ] ||
  die "target is too small: $TARGET_BYTES bytes available, $IMAGE_BYTES required"

IMAGE_GPT=$(sgdisk -v "$STICK_IMG")
printf '%s\n' "$IMAGE_GPT"
case "$IMAGE_GPT" in
  *"No problems found."*) ;;
  *) die "source image GPT validation failed: $STICK_IMG" ;;
esac

log "DESTRUCTIVE target:"
lsblk -dn -o PATH,SIZE,MODEL,SERIAL,TRAN "$TARGET"
log "image: $STICK_IMG ($IMAGE_BYTES bytes)"

CONFIRM=${COMMEC_FLASH_CONFIRM:-}
if [ -z "$CONFIRM" ]; then
  [ -t 0 ] || die "no terminal for confirmation; set COMMEC_FLASH_CONFIRM=$TARGET"
  printf 'Type the exact target path (%s) to erase it: ' "$TARGET" >&2
  IFS= read -r CONFIRM
fi
[ "$CONFIRM" = "$TARGET" ] || die "confirmation did not match $TARGET"

log "writing image to $TARGET"
sudo dd if="$STICK_IMG" of="$TARGET" bs=4M status=progress oflag=direct conv=fsync

log "verifying the copied $IMAGE_BYTES-byte image range"
SOURCE_HASH=$(sha256sum "$STICK_IMG" | awk '{ print $1 }')
TARGET_HASH=$(sudo head -c "$IMAGE_BYTES" "$TARGET" | sha256sum | awk '{ print $1 }')
[ "$TARGET_HASH" = "$SOURCE_HASH" ] ||
  die "readback hash mismatch: source=$SOURCE_HASH target=$TARGET_HASH"
log "readback sha256: $TARGET_HASH"

# A whole-disk image carries its backup GPT at the image boundary. If the physical
# device is larger, GPT requires that backup at the physical end of the device.
log "relocating the backup GPT to the physical end of $TARGET"
sudo sgdisk -e "$TARGET"
sudo partprobe "$TARGET"
sudo udevadm settle

FINAL_GPT=$(sudo sgdisk -v "$TARGET")
printf '%s\n' "$FINAL_GPT"
case "$FINAL_GPT" in
  *"No problems found."*) ;;
  *) die "final GPT validation failed: $TARGET" ;;
esac

PART1=$(lsblk -nrpo PATH,PARTN "$TARGET" | awk '$2 == "1" { print $1; exit }')
[ -b "$PART1" ] || die "partition 1 did not appear on $TARGET"
if findmnt -rn -S "$PART1" >/dev/null; then
  die "partition was mounted before filesystem validation: $PART1"
fi
[ "$(sudo blkid -s TYPE -o value "$PART1")" = vfat ] ||
  die "partition 1 is not FAT: $PART1"
sudo fsck.vfat -n "$PART1"
sudo blockdev --flushbufs "$TARGET"

log "deployment stick ready: $TARGET"
