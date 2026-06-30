#!/usr/bin/env bash
# Phase 4a: save the master image into a Clonezilla image (partclone) in a repo disk.
# Result: <CZ_REPO_IMG>:/partimag/<IMAGE_NAME>/  (ready to bake onto a deployment USB).
#
# Usage:  MASTER_IMAGE=/path/to/commec-box.qcow2 ./save.sh
# Extra env: CZ_COMPRESS (clonezilla -z option, default z0 = none; DBs are already zstd).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CZ_COMPRESS="${CZ_COMPRESS:-z0}"
[ -f "$MASTER_IMAGE" ] || die "MASTER_IMAGE not found: $MASTER_IMAGE"
ensure_clonezilla_iso
ensure_clonezilla_kernel

# Fresh ext4 repo disk to receive the image.
log "preparing repo disk $CZ_REPO_IMG"
sudo modprobe nbd max_part=8
sudo qemu-nbd -d /dev/nbd0 2>/dev/null || true
rm -f "$CZ_REPO_IMG"
qemu-img create -f qcow2 "$CZ_REPO_IMG" 120G >/dev/null
sudo qemu-nbd --connect=/dev/nbd0 "$CZ_REPO_IMG"; sleep 1
sudo sgdisk -n 1:0:0 -t 1:8300 /dev/nbd0
sudo partprobe /dev/nbd0; sleep 1
sudo mkfs.ext4 -q -L clz-repo /dev/nbd0p1
sudo qemu-nbd -d /dev/nbd0

# Read-only-ish source overlay so the master is never modified.
SRC_OVERLAY="$WORK_DIR/save-src.qcow2"
rm -f "$SRC_OVERLAY"
qemu-img create -f qcow2 -F qcow2 -b "$MASTER_IMAGE" "$SRC_OVERLAY" >/dev/null

log "saving '$IMAGE_NAME' (compress=$CZ_COMPRESS) ..."
run_clonezilla \
  "ocs-sr -q2 -j2 -$CZ_COMPRESS -i 4096 -sfsck -senc -nogui -batch -p poweroff savedisk $IMAGE_NAME vda" \
  "dev:///dev/vdb1" \
  -drive "file=$SRC_OVERLAY,if=virtio,format=qcow2" \
  -drive "file=$CZ_REPO_IMG,if=virtio,format=qcow2"

rm -f "$SRC_OVERLAY"
log "done. Clonezilla image is in $CZ_REPO_IMG at /partimag/$IMAGE_NAME"
