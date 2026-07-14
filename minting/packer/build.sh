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

# Mirror the pinned commec GUI tree (the repo's gui/ dir) into packer/guisrc, which the packer
# file provisioner then bakes into the image. The gui branch AT THE PINNED COMMIT is the single
# source of truth; guisrc is a build artifact (gitignored), regenerated every build so a stale
# hand-edit can't silently drift from the branch. Bump commec.gui_shim.commit in pins.json to update.
# Uses SSH (git@github.com:...) -> relies on the caller's git/SSH auth; a CI runner needs a deploy key.
#
# THIS IS THE GUI SHIM. It exists only because gui/ isn't in a commec release yet. Removal, once
# gui merges to main and ships in the pinned commec version: delete this function + its call below,
# delete packer/guisrc/ and its file provisioner in commec-box.pkr.hcl, drop commec.gui_shim from
# pins.json, and have 48-commec-gui.sh copy gui/ out of the installed package instead of /tmp/guisrc.
fetch_gui() {
  local url branch commit cache dest
  url=$(pin "['commec']['repo']")
  branch=$(pin "['commec']['gui_shim']['branch']")
  commit=$(pin "['commec']['gui_shim']['commit']")
  cache="$WORK/commec-gui-src"
  dest="$HERE/guisrc"
  if [ ! -d "$cache/.git" ]; then
    echo "cloning $url"
    git clone --no-checkout "$url" "$cache"
  fi
  git -C "$cache" fetch --quiet origin "$branch"
  git -C "$cache" checkout --quiet --detach "$commit" 2>/dev/null \
    || { echo "ERROR: pinned commec_gui commit $commit not reachable on origin/$branch" >&2; exit 1; }
  mkdir -p "$dest"
  find "$cache/gui" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
  rsync -a --delete --exclude='.gitkeep' "$cache/gui/" "$dest/"
  echo "guisrc <- $(basename "$url") @ ${commit:0:8} ($(find "$dest" -type f ! -name .gitkeep | wc -l) files)"
}

# Plant a colophon (build-provenance note) into the image so a deployed box can answer "what
# exactly was I built from?" (reproducibility for testing / graphs). Captures the
# commec-in-a-box commit AND working-tree dirtiness -- critical because mints are sometimes
# built from an uncommitted tree (e.g. a pins.json bump made seconds before the build), so
# HEAD alone can be a lie. When dirty, the full `git diff HEAD` is saved too, so the exact
# built state is reconstructable. Output goes to packer/colophon/ (a gitignored build
# artifact); the packer file provisioner uploads it and 98-colophon.sh installs it to
# /etc/commec-colophon/ in the guest.
# DEB_FILE, MC_FILE, and the gui pins must already be resolved (call after fetch_gui).
write_colophon() {
  local dir="$HERE/colophon"
  mkdir -p "$dir"
  find "$dir" -mindepth 1 ! -name .gitkeep -delete 2>/dev/null || true
  cp "$PINS" "$dir/pins.json"

  local head subject describe dirty status
  head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
  subject=$(git -C "$REPO" log -1 --format=%s 2>/dev/null || echo unknown)
  describe=$(git -C "$REPO" describe --always --tags --dirty 2>/dev/null || echo unknown)
  status=$(git -C "$REPO" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then dirty=true; else dirty=false; fi
  if [ "$dirty" = true ]; then
    printf '%s\n' "$status" > "$dir/git-status.txt"
    git -C "$REPO" diff HEAD > "$dir/uncommitted.diff" 2>/dev/null || true
  fi

  local gui_repo gui_branch gui_commit built_at built_by
  gui_repo=$(pin "['commec']['repo']")
  gui_branch=$(pin "['commec']['gui_shim']['branch']")
  gui_commit=$(pin "['commec']['gui_shim']['commit']")
  built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  built_by="$(id -un)@$(hostname)"

  IAB_COMMIT="$head" IAB_SUBJECT="$subject" IAB_DESCRIBE="$describe" IAB_DIRTY="$dirty" \
  BUILT_AT="$built_at" BUILT_BY="$built_by" \
  GUI_REPO="$gui_repo" GUI_BRANCH="$gui_branch" GUI_COMMIT="$gui_commit" \
  V_COMMEC="$(pin "['commec']['version']")" \
  V_SOURCE="${COMMEC_SOURCE:-stable}" V_CHANNEL="${COMMEC_CHANNEL:-stable}" \
  V_GUI="${COMMEC_GUI_VERSION:-1.0.6.dev1}" V_UPDATE_URL="${COMMEC_UPDATE_URL:-http://10.0.2.2:8000}" \
  BASE_IMAGE="$DEB_FILE" MINICONDA="$MC_FILE" \
  python3 - "$dir/colophon.json" <<'PY'
import json, os, sys
m = {
    "schema": 1,
    "built_at_utc": os.environ["BUILT_AT"],
    "built_by": os.environ["BUILT_BY"],
    "commec_in_a_box": {
        "commit": os.environ["IAB_COMMIT"],
        "commit_subject": os.environ["IAB_SUBJECT"],
        "describe": os.environ["IAB_DESCRIBE"],
        "dirty": os.environ["IAB_DIRTY"] == "true",
    },
    "gui_shim": {
        "repo": os.environ["GUI_REPO"],
        "branch": os.environ["GUI_BRANCH"],
        "commit": os.environ["GUI_COMMIT"],
    },
    "build_vars": {
        "commec_version": os.environ["V_COMMEC"],
        "commec_source": os.environ["V_SOURCE"],
        "commec_channel": os.environ["V_CHANNEL"],
        "commec_gui_version": os.environ["V_GUI"],
        "commec_update_url": os.environ["V_UPDATE_URL"],
    },
    "inputs": {
        "base_image": os.environ["BASE_IMAGE"],
        "miniconda": os.environ["MINICONDA"],
    },
    "note": "commec.lock (exact package versions) sits alongside this colophon, added in-guest at build.",
}
with open(sys.argv[1], "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
  echo "colophon <- commec-in-a-box @ ${head:0:8}$([ "$dirty" = true ] && echo ' (DIRTY)'); gui @ ${gui_commit:0:8}"
}

echo "== 1. pinned inputs =="
DEB_FILE=$(pin "['debian_cloud_image']['file']")
fetch_verify "$(pin "['debian_cloud_image']['url']")" "$DOWNLOADS/$DEB_FILE" sha512 "$(pin "['debian_cloud_image']['sha512']")"
MC_FILE=$(pin "['miniconda']['file']")
fetch_verify "$(pin "['miniconda']['url']")" "$DOWNLOADS/$MC_FILE" sha256 "$(pin "['miniconda']['sha256']")"

# GUI tree from the pinned gui branch (populates packer/guisrc).
fetch_gui

# Build-provenance colophon (populates packer/colophon; installed to /etc/commec-colophon in the guest).
write_colophon

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
  -var "commec_source=${COMMEC_SOURCE:-stable}" \
  -var "commec_channel=${COMMEC_CHANNEL:-stable}" \
  -var "commec_gui_version=${COMMEC_GUI_VERSION:-1.0.6.dev1}" \
  -var "commec_update_url=${COMMEC_UPDATE_URL:-http://10.0.2.2:8000}" \
  -var "output_dir=$OUTPUT_DIR" \
  -var "cpus=${CPUS:-4}" \
  commec-box.pkr.hcl

echo "== done: $OUTPUT_DIR/commec-box.qcow2 =="
