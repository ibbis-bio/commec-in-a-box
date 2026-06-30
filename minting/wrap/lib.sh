#!/usr/bin/env bash
# Shared config + helpers for the Clonezilla wrapping scripts.
# Everything is parameterized via env vars (defaults below) so these run identically
# on a workstation and a CI runner. No hardcoded user/host paths.
#
# Config (override via env):
#   MINTING_DIR     repo 'minting' dir (auto-detected from this script's location)
#   WORK_DIR        scratch/working dir for build artifacts            [<repo>/minting/_work]
#   DOWNLOADS_DIR   where pinned downloads live                        [$MINTING_DIR/downloads]
#   MASTER_IMAGE    input master qcow2 to wrap (the built appliance)   [$WORK_DIR/commec-box.qcow2]
#   IMAGE_NAME      Clonezilla image name                              [commec-v1]
#   CZ_REPO_IMG     qcow2 holding the Clonezilla image repository      [$WORK_DIR/clz-repo.qcow2]
#   CZ_ISO          Clonezilla Live ISO path (fetched+verified if absent, from pins.json)
#   QEMU_ACCEL      kvm | tcg (tcg only for KVM-less CI; very slow)    [kvm]
#   QEMU_CPU        qemu -cpu                                          [host]
#   QEMU_MEM_MB     guest RAM (MB)                                     [4096]
#   QEMU_SMP        guest vCPUs                                        [4]
#   QEMU_EXTRA      extra raw qemu args (e.g. serial/qmp for debug)    [empty]
set -euo pipefail

MINTING_DIR="${MINTING_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${WORK_DIR:-$MINTING_DIR/_work}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$MINTING_DIR/downloads}"
MASTER_IMAGE="${MASTER_IMAGE:-$WORK_DIR/commec-box.qcow2}"
IMAGE_NAME="${IMAGE_NAME:-commec-v1}"
CZ_REPO_IMG="${CZ_REPO_IMG:-$WORK_DIR/clz-repo.qcow2}"
PINS="${PINS:-$MINTING_DIR/pins.json}"
QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
QEMU_CPU="${QEMU_CPU:-host}"
QEMU_MEM_MB="${QEMU_MEM_MB:-4096}"
QEMU_SMP="${QEMU_SMP:-4}"
read -r -a QEMU_EXTRA <<< "${QEMU_EXTRA:-}"

mkdir -p "$WORK_DIR" "$DOWNLOADS_DIR"

pin() { python3 -c "import json,sys;print(json.load(open('$PINS'))$1)"; }

log() { printf '[wrap] %s\n' "$*" >&2; }
die() { printf '[wrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Fetch + verify the Clonezilla ISO from pins.json (SourceForge needs a *.dl mirror).
ensure_clonezilla_iso() {
  CZ_ISO="${CZ_ISO:-$DOWNLOADS_DIR/$(pin "['clonezilla']['file']")}"
  local want; want="$(pin "['clonezilla']['sha256']")"
  if [ -f "$CZ_ISO" ] && [ "$(sha256sum "$CZ_ISO" | awk '{print $1}')" = "$want" ]; then
    log "clonezilla ISO ok (cached)"
  else
    log "fetching clonezilla ISO"
    curl -fSL --retry 3 -A "Mozilla/5.0" -o "$CZ_ISO" "$(pin "['clonezilla']['url']")"
    [ "$(sha256sum "$CZ_ISO" | awk '{print $1}')" = "$want" ] || die "clonezilla ISO sha256 mismatch"
  fi
  export CZ_ISO
}

# Extract kernel+initrd from the ISO so we can inject the unattended kernel cmdline.
ensure_clonezilla_kernel() {
  CZ_KERNEL="$WORK_DIR/clz-vmlinuz"; CZ_INITRD="$WORK_DIR/clz-initrd.img"
  if [ ! -f "$CZ_KERNEL" ] || [ ! -f "$CZ_INITRD" ]; then
    log "extracting clonezilla kernel/initrd"
    xorriso -osirrox on -indev "$CZ_ISO" \
      -extract /live/vmlinuz "$CZ_KERNEL" -extract /live/initrd.img "$CZ_INITRD" 2>/dev/null
  fi
  export CZ_KERNEL CZ_INITRD
}

# Run Clonezilla Live unattended in qemu (foreground; returns when the guest powers off).
#   run_clonezilla <ocs-sr command> <ocs_repository> <qemu -drive args...>
# Notes:
#   - locales/keyboard MUST be non-empty or Clonezilla stops on the language menu.
#   - ocs_live_run autostart runs on tty1, not serial; monitor via disk growth/QMP.
run_clonezilla() {
  local ocs="$1" repo="$2"; shift 2
  local append="boot=live union=overlay username=user config components noswap edd=on enforcing=0"
  append+=" locales=en_US.UTF-8 keyboard-layouts=NONE net.ifnames=0 nosplash"
  append+=" ocs_live_batch=yes ocs_repository=$repo ocs_live_extra_param= ocs_live_run=\"$ocs\""
  qemu-system-x86_64 \
    -machine "q35,accel=$QEMU_ACCEL" -cpu "$QEMU_CPU" -m "$QEMU_MEM_MB" -smp "$QEMU_SMP" \
    -kernel "$CZ_KERNEL" -initrd "$CZ_INITRD" -append "$append" \
    "$@" \
    -cdrom "$CZ_ISO" -display none -no-reboot "${QEMU_EXTRA[@]}"
}
