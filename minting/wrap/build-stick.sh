#!/usr/bin/env bash
# Phase 4b: bake Clonezilla Live + the saved image + an unattended-restore boot entry
# into a SINGLE bootable disk image = the deployment stick. dd it to a >=128 GB USB.
#
# Layout: GPT, one FAT32 ESP partition holding the Clonezilla live files, the image in
# /home/partimag/<IMAGE_NAME>, and a custom restore script. UEFI boots /EFI/boot/bootx64.efi
# -> grub -> our default menuentry runs the restore script. (Target box boots UEFI.)
#
# Usage:  ./build-stick.sh        (CZ_REPO_IMG must contain /partimag/<IMAGE_NAME>)
# Env: STICK_IMG (default $WORK_DIR/commec-deploy-stick.img), STICK_SIZE (default 128G),
#      BOOT_TIMEOUT secs (default 10).
#
# STATUS: authored from the proven save/restore params but NOT yet test-booted end to end.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STICK_IMG="${STICK_IMG:-$WORK_DIR/commec-deploy-stick.img}"
STICK_SIZE="${STICK_SIZE:-128G}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-10}"
[ -f "$CZ_REPO_IMG" ] || die "CZ_REPO_IMG not found (run save.sh first): $CZ_REPO_IMG"
ensure_clonezilla_iso

NBD_STICK=/dev/nbd0
NBD_REPO=/dev/nbd1
MNT_STICK="$WORK_DIR/mnt-stick"
MNT_REPO="$WORK_DIR/mnt-repo"
MNT_ISO="$WORK_DIR/mnt-iso"
cleanup() {
  sudo umount "$MNT_STICK" "$MNT_REPO" "$MNT_ISO" 2>/dev/null || true
  sudo qemu-nbd -d "$NBD_STICK" 2>/dev/null || true
  sudo qemu-nbd -d "$NBD_REPO" 2>/dev/null || true
}
trap cleanup EXIT
sudo modprobe nbd max_part=8
mkdir -p "$MNT_STICK" "$MNT_REPO" "$MNT_ISO"

log "creating stick image $STICK_IMG ($STICK_SIZE), GPT + FAT32 ESP"
rm -f "$STICK_IMG"
qemu-img create -f raw "$STICK_IMG" "$STICK_SIZE" >/dev/null
sudo qemu-nbd -d "$NBD_STICK" 2>/dev/null || true
sudo qemu-nbd --connect="$NBD_STICK" -f raw "$STICK_IMG"; sleep 1
sudo sgdisk -n 1:0:0 -t 1:EF00 -c 1:"COMMEC-DEPLOY" "$NBD_STICK"
sudo partprobe "$NBD_STICK"; sleep 1
sudo mkfs.vfat -F 32 -n COMMECDPLY "${NBD_STICK}p1"
sudo mount "${NBD_STICK}p1" "$MNT_STICK"

log "copying Clonezilla Live files from the ISO"
sudo mount -o loop,ro "$CZ_ISO" "$MNT_ISO"
sudo cp -a "$MNT_ISO"/. "$MNT_STICK"/
sudo umount "$MNT_ISO"

log "copying the saved image into /home/partimag/$IMAGE_NAME (this is the big copy)"
sudo qemu-nbd --read-only --connect="$NBD_REPO" "$CZ_REPO_IMG"; sleep 1
sudo mount -o ro "${NBD_REPO}p1" "$MNT_REPO"
sudo mkdir -p "$MNT_STICK/home/partimag"
sudo cp -a "$MNT_REPO/$IMAGE_NAME" "$MNT_STICK/home/partimag/"
sudo umount "$MNT_REPO"; sudo qemu-nbd -d "$NBD_REPO"

log "installing custom restore script + default boot entry"
# Custom restore: pick the first NON-removable disk (the box's internal drive, never the
# USB) and restore onto it. Works in the VM test (target is the only disk) and on metal.
sudo tee "$MNT_STICK/commec-restore" >/dev/null <<RESTORE
#!/bin/bash
set -e
dest=\$(lsblk -dno NAME,RM,TYPE | awk '\$2==0 && \$3=="disk"{print \$1; exit}')
echo "Commec: restoring $IMAGE_NAME onto /dev/\$dest ..."
exec ocs-sr -g auto -e2 -j2 -icds -scr -sfsck -batch -nogui -p poweroff restoredisk $IMAGE_NAME "\$dest"
RESTORE
sudo chmod +x "$MNT_STICK/commec-restore"

# Prepend a default auto-restore menuentry to Clonezilla's grub.cfg (UEFI path).
GRUBCFG="$MNT_STICK/boot/grub/grub.cfg"
[ -f "$GRUBCFG" ] || die "grub.cfg not found at $GRUBCFG (clonezilla layout changed?)"
sudo cp "$GRUBCFG" "$GRUBCFG.orig"
{
  echo "set default=0"
  echo "set timeout=$BOOT_TIMEOUT"
  echo 'menuentry "Commec: RESTORE appliance to internal disk (AUTO)" {'
  echo '  search --set -f /live/vmlinuz'
  echo '  linux /live/vmlinuz boot=live union=overlay username=user config components quiet noswap edd=on enforcing=0 locales=en_US.UTF-8 keyboard-layouts=NONE net.ifnames=0 nosplash ocs_live_batch=yes ocs_live_run="/commec-restore"'
  echo '  initrd /live/initrd.img'
  echo '}'
  sudo cat "$GRUBCFG.orig"
} | sudo tee "$GRUBCFG" >/dev/null

sudo sync
log "deployment stick image ready: $STICK_IMG"
log "  dd to a >=128 GB USB:  sudo dd if=$STICK_IMG of=/dev/sdX bs=4M status=progress oflag=direct"
log "  or test in a VM:        see wrap/README.md"
