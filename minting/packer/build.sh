#!/usr/bin/env bash
# Orchestrate the master-image build:
#   1. fetch + verify pinned base image and Miniconda installer
#   2. build the DB disk (ext4 raw holding the two .zst archives) -> attached to the VM
#   3. generate a build-only SSH key + render the cloud-init seed
#   4. packer init + build (under the kvm group) -> $OUTPUT_DIR/commec-box.qcow2
#
# Uses /dev/kvm directly (kvm group membership OR an ACL grant); builds the DB disk
# with mkfs.ext4 -d, so no root/sudo is required on the host.
set -euo pipefail

# sbin tools (mkfs.ext4, blkid, ...) aren't on a non-root PATH by default.
export PATH="/usr/sbin:/sbin:$PATH"

# Re-exec within the kvm group so qemu can use /dev/kvm (use an absolute path - sg
# starts a fresh shell that may not share this cwd).
SELF=$(readlink -f "$0")
if ! id -nG | grep -qw kvm && ! { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
  exec sg kvm -c "exec '$SELF' $*"
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # minting/packer
MINTING=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MINTING/.." && pwd)
PINS="$MINTING/pins.json"

# Locations. The DB disk image and qcow2 output MUST live on a sparse-capable, fast
# fs (nvme/ext4), NOT on the COMMEC external: it's exfat, which has no sparse files, so
# truncate+mkfs would physically write the whole image over USB (very slow). COMMEC is
# only the source of the .zst tarballs.
WORK="${WORK:-$HOME/commec-build}"            # on nvme (ext4)
DOWNLOADS="${DOWNLOADS:-$MINTING/downloads}"
STAGING="${STAGING:-/mnt/commec/dbs-staging}" # source tarballs (COMMEC/exfat)
DB_DISK="${DB_DISK:-$WORK/db-staging.img}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORK/output}"
SECRETS="$HERE/.secrets"
SEED="$HERE/cloud-init/_build"

mkdir -p "$WORK" "$DOWNLOADS" "$SECRETS" "$SEED"

pin() { python3 -c "import json;print(json.load(open('$PINS'))$1)"; }

fetch_verify() { # url  outpath  algo  expected_hash
  local url="$1" out="$2" algo="$3" want="$4" got
  if [ -f "$out" ]; then
    got=$("${algo}sum" "$out" | awk '{print $1}')
    [ "$got" = "$want" ] && { echo "ok (cached): $(basename "$out")"; return; }
    echo "cached $(basename "$out") hash mismatch; refetching"
  fi
  echo "fetching $(basename "$out")"
  curl -fSL --retry 3 -o "$out" "$url"
  got=$("${algo}sum" "$out" | awk '{print $1}')
  [ "$got" = "$want" ] || { echo "HASH MISMATCH for $out: got $got want $want" >&2; exit 1; }
  echo "verified: $(basename "$out")"
}

echo "== 1. pinned inputs =="
DEB_FILE=$(pin "['debian_cloud_image']['file']")
fetch_verify "$(pin "['debian_cloud_image']['url']")" "$DOWNLOADS/$DEB_FILE" sha512 "$(pin "['debian_cloud_image']['sha512']")"
MC_FILE=$(pin "['miniconda']['file']")
fetch_verify "$(pin "['miniconda']['url']")" "$DOWNLOADS/$MC_FILE" sha256 "$(pin "['miniconda']['sha256']")"

# DB source: by default STAGING is a local dir of *.zst (a mount, or pre-staged). For CI
# / the future Cloudflare R2 bucket, set DB_BASE_URL to fetch the pinned main-DB tarballs
# into a local staging dir instead of relying on a mount.
if [ -n "${DB_BASE_URL:-}" ]; then
  STAGING="${DB_STAGING_LOCAL:-$WORK/dbs-staging}"; mkdir -p "$STAGING"
  for k in nr_blast core_nt_blast; do
    f=$(pin "['commec_main_dbs']['$k']['archive']")
    fetch_verify "${DB_BASE_URL%/}/$f" "$STAGING/$f" sha256 "$(pin "['commec_main_dbs']['$k']['sha256']")"
  done
  ( cd "$STAGING" && sha256sum ./*.zst | sed 's#\./##' > SHA256SUMS )
fi

echo "== 2. DB disk =="
if [ -f "$DB_DISK" ] && [ "$(blkid -s LABEL -o value "$DB_DISK" 2>/dev/null)" = "COMMEC_DBSRC" ]; then
  echo "reusing existing $DB_DISK"
else
  echo "building $DB_DISK from $STAGING/*.zst (no-sudo: mkfs.ext4 -d)"
  rm -f "$DB_DISK"
  truncate -s 12G "$DB_DISK"   # holds the ~7 GB compressed bundled DB (was 90G for the old nr+nt)
  # Embed the .zst tarballs at mkfs time (-d <dir>), avoiding a root-only loop mount.
  # STAGING holds exactly the .zst (+ SHA256SUMS); all get copied into the fs image.
  mkfs.ext4 -q -F -L COMMEC_DBSRC -d "$STAGING" "$DB_DISK"
fi

echo "== 3. ssh key + cloud-init seed =="
if [ ! -f "$SECRETS/build_key" ]; then
  ssh-keygen -t ed25519 -N '' -C commec-build -f "$SECRETS/build_key"
fi
PUBKEY=$(cat "$SECRETS/build_key.pub")
sed "s|@@SSH_PUBKEY@@|$PUBKEY|" "$HERE/cloud-init/user-data.tmpl" > "$SEED/user-data"
cp "$HERE/cloud-init/meta-data" "$SEED/meta-data"

# OVMF needs a writable VARS file (the system copy is read-only).
EFI_VARS="$SECRETS/OVMF_VARS_4M.fd"
cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$EFI_VARS"

# cloud-init NoCloud seed ISO (attached as a CD via qemuargs; Packer's cd_files can't
# be used here because our qemuargs takes over -drive).
SEED_ISO="$SECRETS/seed.iso"
cloud-localds "$SEED_ISO" "$SEED/user-data" "$SEED/meta-data"

echo "== 4. packer build =="
rm -rf "$OUTPUT_DIR"
cd "$HERE"
~/.local/bin/packer init .
~/.local/bin/packer build \
  -var "base_image=$DOWNLOADS/$DEB_FILE" \
  -var "miniconda_installer=$DOWNLOADS/$MC_FILE" \
  -var "db_disk=$DB_DISK" \
  -var "db_sha256sums=$STAGING/SHA256SUMS" \
  -var "wallpaper_dir=$REPO/bg/wallpaper" \
  -var "ssh_private_key_file=$SECRETS/build_key" \
  -var "efi_vars=$EFI_VARS" \
  -var "seed_iso=$SEED_ISO" \
  -var "commec_version=$(pin "['commec']['version']")" \
  -var "biorisk_url=$(pin "['commec_small_dbs']['url']")" \
  -var "output_dir=$OUTPUT_DIR" \
  -var "cpus=${CPUS:-4}" \
  commec-box.pkr.hcl

echo "== done: $OUTPUT_DIR/commec-box.qcow2 =="
