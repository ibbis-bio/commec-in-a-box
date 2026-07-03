#!/usr/bin/env bash
# Phase 4b: bake Clonezilla Live + the saved image + an unattended-restore boot entry
# into a SINGLE bootable disk image = the deployment stick. dd it to a USB at least as
# large as STICK_SIZE (a nominal 128 GB stick is ~125.8 GB actual, so STICK_SIZE must
# stay well under that).
#
# Layout: GPT, one FAT32 ESP partition holding the Clonezilla live files, the image in
# /home/partimag/<IMAGE_NAME>, and a custom restore script. UEFI boots /EFI/boot/bootx64.efi
# -> grub -> our default menuentry runs the restore script. (Target box boots UEFI.)
#
# Usage:  ./build-stick.sh        (CZ_REPO_IMG must contain /partimag/<IMAGE_NAME>)
# Env: STICK_IMG (default $WORK_DIR/commec-deploy-stick.img), STICK_SIZE (default 90G),
#      BOOT_TIMEOUT secs (default 10).
#
# STATUS: authored from the proven save/restore params but NOT yet test-booted end to end.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STICK_IMG="${STICK_IMG:-$WORK_DIR/commec-deploy-stick.img}"
# Size the disk image just above the baked payload (~85G: the partclone image + Clonezilla
# Live) so it fits generic "128 GB" media (~125.8 GB actual) with margin. A 128G image is
# 137 GB and will NOT fit such sticks. Bump this if the databases grow past the headroom.
STICK_SIZE="${STICK_SIZE:-90G}"
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
# Custom restore: Clonezilla Live's root is the squashfs overlay, so this script and the
# image actually live on the boot medium (mounted at /run/live/medium). Locate that medium
# and bind its /home/partimag onto /home/partimag, where ocs-sr looks for the image; then
# restore onto the first NON-removable disk (the box's internal drive, never the USB).
sudo tee "$MNT_STICK/commec-restore" >/dev/null <<RESTORE
#!/bin/bash
# Do the medium-locate + repo bind quietly (to a log), then show a clear "installing, do not
# power off" banner and run ocs-sr with its partclone progress VISIBLE on the console. The
# restore takes ~15-30 min; a frozen screen otherwise looks hung and invites a power-pull
# mid-write (which corrupts the disk).
{
  MED=""
  for d in /run/live/medium /lib/live/mount/medium; do
    [ -e "\$d/home/partimag/$IMAGE_NAME" ] && MED="\$d" && break
  done
  mkdir -p /home/partimag
  mount --bind "\$MED/home/partimag" /home/partimag
  dest=\$(lsblk -dno NAME,RM,TYPE | awk '\$2==0 && \$3=="disk"{print \$1; exit}')
  echo "MED=\$MED dest=\$dest"
} >/tmp/commec-restore.log 2>&1
clear 2>/dev/null || true
# Branded COMMEC banner (matches the first-boot screen). Colors resolve at restore time.
O=\$(printf '\033[38;5;202m'); B=\$(printf '\033[48;5;17m'); R=\$(printf '\033[0m')
cat <<BANNER

 ██████╗ ██████╗ ███╗   ███╗███╗   ███╗███████╗ ██████╗ \$O         ▄▄               \$R
██╔════╝██╔═══██╗████╗ ████║████╗ ████║██╔════╝██╔════╝ \$O       ▄███▌              \$R
██║     ██║   ██║██╔████╔██║██╔████╔██║█████╗  ██║      \$O      ▐█████              \$R
██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██╔══╝  ██║      \$O     ▐██████▌             \$R
╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║███████╗╚██████╗ \$O     ███████▌             \$R
 ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝╚══════╝ ╚═════╝ \$O    ▐███████▌             \$R
\$B█ █████▄ █████▄ █ ▄█▀█▄                                 \$O     ███████   ▄█▄      \$R
\$B█ █    █ █    █ █ █   ▀            BOX                  \$O      █████▌  ▄███▄▄     \$R
\$B█ █████▄ █████▄ █ ▀███▄            SETUP                \$O      ▐█████▄██▀    ▀▄    \$R
\$B█ █    █ █    █ █ ▄   █              UTILITY            \$O      ▐████████       ▌  \$R
\$B█ █████▀ █████▀ █ ▀█▄█▀                                 \$O      ████████▀         \$R
                                                        \$O   ▄▄██████▀▀             \$R
                                                        \$O ▀▀                       \$R

     Installing onto this computer.

     Restoring the appliance system and databases to the internal disk.
     This one-time step takes about 15 to 30 minutes.

     >>>   Do NOT power off.   <<<

BANNER
sleep 4
# Restore, then GUARANTEE /dev exists on the restored root before power-off. The appliance
# base (Debian genericcloud) ships an EMPTY /dev and relies on devtmpfs mounting at boot; if
# any imaging step loses the /dev mountpoint, the initramfs init-handoff opens
# \$rootmnt/dev/console, the open fails, and PID1 exits -> "Attempted to kill init" panic.
# -p true = no-op postaction (do NOT auto-poweroff) so the guard below runs.
# NO -g flag: skip the grub reinstall entirely. ocs-sr only runs ocs-install-grub when -g is
# passed (ocs-functions: `if [ "$install_grub" = "on" ]`), so omitting -g means no grub step at
# all. partclone restores the ESP (nvme..p15) byte-for-byte with packer's bootloader incl. the
# universal /EFI/BOOT/BOOTX64.EFI removable path, so a reinstall is redundant (and Clonezilla's
# -g auto reinstall fails anyway: "cannot find EFI directory", it never mounts the ESP at
# /boot/efi). NB: -g has no "skip" value - passing one makes ocs-install-grub terminate the run.
ocs-sr -e2 -j2 -icds -scr -sfsck -batch -nogui -p true restoredisk $IMAGE_NAME "\$dest"
partprobe "/dev/\$dest" 2>/dev/null || true; sleep 1
rp=\$(lsblk -lno NAME,FSTYPE "/dev/\$dest" | awk '\$2=="ext4"{print \$1; exit}')
if [ -n "\$rp" ]; then
  mkdir -p /mnt/commec-root && mount "/dev/\$rp" /mnt/commec-root
  mkdir -p /mnt/commec-root/dev
  [ -e /mnt/commec-root/dev/console ] || mknod -m 600 /mnt/commec-root/dev/console c 5 1
  [ -e /mnt/commec-root/dev/null ]    || mknod -m 666 /mnt/commec-root/dev/null    c 1 3
  # Fix sudoers last-match ordering so the first-run password helper's NOPASSWD rule wins over
  # first-boot's blanket 'commec-user ALL=(ALL) ALL'. Images predating the pipeline fix ship the
  # rule as 'commec-firstrun' (sorts BEFORE commec-user -> overridden -> operator locked out of
  # admin, "unable to set password"). Rename it to sort last + repoint the helper's self-cleanup.
  # No-op on already-fixed images (they ship zzz-commec-firstrun and the helper already targets it).
  sdd=/mnt/commec-root/etc/sudoers.d
  if [ -f "\$sdd/commec-firstrun" ] && [ ! -e "\$sdd/zzz-commec-firstrun" ]; then
    mv "\$sdd/commec-firstrun" "\$sdd/zzz-commec-firstrun"
    sed -i 's#sudoers.d/commec-firstrun#sudoers.d/zzz-commec-firstrun#' /mnt/commec-root/usr/local/sbin/commec-set-initial-password 2>/dev/null || true
  fi
  sync; umount /mnt/commec-root
fi
poweroff -f
RESTORE
sudo chmod +x "$MNT_STICK/commec-restore"

# Prepend a default auto-restore menuentry to Clonezilla's grub.cfg (UEFI path).
GRUBCFG="$MNT_STICK/boot/grub/grub.cfg"
[ -f "$GRUBCFG" ] || die "grub.cfg not found at $GRUBCFG (clonezilla layout changed?)"
sudo cp "$GRUBCFG" "$GRUBCFG.orig"
{
  echo "set default=0"
  echo "set timeout=$BOOT_TIMEOUT"
  # ocs_prerun copies commec-restore off the (non-executable, FAT) medium into /tmp and
  # makes it runnable, since ocs_live_run needs an executable path in the live filesystem
  # (a bare /commec-restore does not exist there). console=tty0 last = screen is primary;
  # ttyS0 kept for serial/VM debugging.
  echo 'menuentry "Commec: RESTORE appliance to internal disk (AUTO)" {'
  echo '  search --set -f /live/vmlinuz'
  echo '  linux /live/vmlinuz boot=live union=overlay username=user config components quiet noswap edd=on enforcing=0 locales=en_US.UTF-8 keyboard-layouts=NONE net.ifnames=0 nosplash console=ttyS0,115200 console=tty0 ocs_live_batch=yes ocs_prerun="cp /run/live/medium/commec-restore /tmp/commec-restore 2>/dev/null || cp /lib/live/mount/medium/commec-restore /tmp/commec-restore" ocs_prerun1="chmod +x /tmp/commec-restore" ocs_live_run="/tmp/commec-restore"'
  echo '  initrd /live/initrd.img'
  echo '}'
  sudo cat "$GRUBCFG.orig"
} | sudo tee "$GRUBCFG" >/dev/null

sudo sync
log "deployment stick image ready: $STICK_IMG"
log "  dd to a nominal 128 GB (or larger) USB:  sudo dd if=$STICK_IMG of=/dev/sdX bs=4M status=progress oflag=direct"
log "  or test in a VM:        see wrap/README.md"
