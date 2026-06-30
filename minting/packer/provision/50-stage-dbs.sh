#!/usr/bin/env bash
# Copy the compressed BLAST DB archives from the attached read-only DB disk (/dev/vdb,
# ext4, label COMMEC_DBSRC) into the image. They are NOT decompressed here - first boot
# expands them into ~commec-user/commec-dbs. Verify sha256 after copy.
set -euxo pipefail

SRC=/mnt/dbsrc
DST=/opt/commec/staging
mkdir -p "$SRC" "$DST"

DEV=$(blkid -L COMMEC_DBSRC 2>/dev/null || true)
[ -n "$DEV" ] || DEV=/dev/vdb
mount -o ro,noload "$DEV" "$SRC"

cp -v "$SRC"/*.zst "$DST"/
umount "$SRC"

# Integrity check against the uploaded SHA256SUMS (basenames match).
cd "$DST"
sha256sum -c /tmp/db.SHA256SUMS

echo "50-stage-dbs done"
