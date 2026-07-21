#!/usr/bin/env bash
# Copy the compressed best_match BLAST DB archive (+ its manifest) from the attached read-only
# DB disk (/dev/vdb, ext4, label COMMEC_DBSRC) into the image. It is NOT decompressed here -
# first boot (commec-firstboot.sh) expands it into ~commec-user/commec-dbs/best_match. Verify
# sha256 of the archive after copy.
set -euxo pipefail

SRC=/mnt/dbsrc
DST=/opt/commec/staging
mkdir -p "$SRC" "$DST"

DEV=$(blkid -L COMMEC_DBSRC 2>/dev/null || true)
[ -n "$DEV" ] || DEV=/dev/vdb
mount -o ro,noload "$DEV" "$SRC"

cp -v "$SRC"/*.zst "$DST"/
cp -v "$SRC"/best_match.manifest.json "$DST"/
umount "$SRC"

# Integrity check the archive(s) against the uploaded SHA256SUMS (basenames match).
cd "$DST"
sha256sum -c /tmp/db.SHA256SUMS

echo "50-stage-dbs done"
