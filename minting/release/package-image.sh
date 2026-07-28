#!/usr/bin/env bash
# Compress a deployment image and split it into GitHub-compatible release assets.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MINTING=$(cd "$HERE/.." && pwd)
PINS="$MINTING/pins.json"
pin() { python3 -c "import json;print(json.load(open('$PINS'))$1)"; }

VERSION=$(pin "['commec_in_a_box']['version']")
IMAGE="${1:-$MINTING/_work/commec-deploy-stick.img}"
OUT_DIR="${OUT_DIR:-$MINTING/_release/$VERSION}"
PART_SIZE="${PART_SIZE:-1900M}"
ZSTD_LEVEL="${ZSTD_LEVEL:-9}"
BASE="commec-in-a-box-${VERSION}-deployment.img.zst"

[ -f "$IMAGE" ] || { echo "ERROR: deployment image not found: $IMAGE" >&2; exit 1; }
command -v zstd >/dev/null || { echo "ERROR: zstd is required" >&2; exit 1; }
command -v split >/dev/null || { echo "ERROR: GNU split is required" >&2; exit 1; }
case "$VERSION" in *[!A-Za-z0-9._-]*) echo "ERROR: unsafe appliance version: $VERSION" >&2; exit 2 ;; esac
case "$PART_SIZE" in *[!A-Za-z0-9]*) echo "ERROR: unsafe part size: $PART_SIZE" >&2; exit 2 ;; esac
case "$ZSTD_LEVEL" in *[!0-9]*) echo "ERROR: ZSTD_LEVEL must be an integer" >&2; exit 2 ;; esac

mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -type f \
  \( -name "$BASE.part-*" -o -name SHA256SUMS -o -name SHA256SUMS.parts \
     -o -name reassemble-image.sh \) -delete

echo "compressing and splitting $IMAGE"
zstd -T0 -"$ZSTD_LEVEL" -c -- "$IMAGE" |
  split -b "$PART_SIZE" -d -a 3 - "$OUT_DIR/$BASE.part-"

(
  cd "$OUT_DIR"
  sha256sum "$BASE".part-* > SHA256SUMS.parts
  cat "$BASE".part-* | sha256sum | awk -v name="$BASE" '{print $1 "  " name}' > SHA256SUMS
)

while read -r size name; do
  [ "$size" -lt 2147483648 ] || {
    echo "ERROR: release part is not under GitHub's 2 GiB limit: $name ($size bytes)" >&2
    exit 1
  }
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "$BASE.part-*" -printf '%s %f\n' | sort -k2)

install -m 0755 "$HERE/reassemble-image.sh" "$OUT_DIR/reassemble-image.sh"

echo "release assets:"
find "$OUT_DIR" -maxdepth 1 -type f -printf '  %f  %s bytes\n' | sort
