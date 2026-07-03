#!/usr/bin/env bash
# Phase 4c (VM test): restore the Clonezilla image onto a blank disk, to validate the
# restore path. Result: <WORK_DIR>/test-target.qcow2 with the image restored (the
# partition table is recreated from the image; first-boot then growparts to fill it).
#
# Usage:  ./test-restore.sh        (CZ_REPO_IMG must contain /partimag/<IMAGE_NAME>)
# Extra env: TARGET_SIZE (default 512G), TARGET_IMG (default $WORK_DIR/test-target.qcow2).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET_SIZE="${TARGET_SIZE:-512G}"
TARGET_IMG="${TARGET_IMG:-$WORK_DIR/test-target.qcow2}"
[ -f "$CZ_REPO_IMG" ] || die "CZ_REPO_IMG not found (run save.sh first): $CZ_REPO_IMG"
ensure_clonezilla_iso
ensure_clonezilla_kernel

log "creating blank target $TARGET_IMG ($TARGET_SIZE)"
rm -f "$TARGET_IMG"
qemu-img create -f qcow2 "$TARGET_IMG" "$TARGET_SIZE" >/dev/null

# Do NOT use -k: target is blank, so Clonezilla must create the partition table from the
# image. -icds skips the dest-size check (110G image onto a larger disk is intentional).
log "restoring '$IMAGE_NAME' onto blank target ..."
run_clonezilla \
  "ocs-sr -e2 -j2 -icds -scr -sfsck -batch -nogui -p poweroff restoredisk $IMAGE_NAME vda" \
  "dev:///dev/vdb1" \
  -drive "file=$TARGET_IMG,if=virtio,format=qcow2" \
  -drive "file=$CZ_REPO_IMG,if=virtio,format=qcow2"

log "done. Restored disk: $TARGET_IMG"
log "boot-test it (UEFI) with:  qemu-system-x86_64 -machine q35,accel=$QEMU_ACCEL -cpu $QEMU_CPU \\"
log "  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \\"
log "  -drive if=pflash,format=raw,file=<writable OVMF_VARS copy> \\"
log "  -drive file=$TARGET_IMG,if=virtio,format=qcow2 -serial stdio"
