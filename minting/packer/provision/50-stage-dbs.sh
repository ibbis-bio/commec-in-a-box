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

# Record best_match's revision in release.json alongside the databases 47-update-system.sh
# already stamped. It has to happen here, not there: best_match is staged compressed and does not
# reach the database directory until first boot, so at 47's point in the order there is nothing to
# read. The block is what commec-db-apply moves to "databases_previous" on the first update, i.e.
# what --rollback would restore - and best_match is the one database nobody wants to re-fetch
# blind.
REL=/etc/commec-box/release.json
/opt/miniconda/bin/python - "$REL" "$DST/best_match.manifest.json" <<'PY'
import json, sys

rel_path, manifest_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as fh:
    revision = json.load(fh)["revision"]
with open(rel_path) as fh:
    release = json.load(fh)

release.setdefault("databases", {})["best_match"] = revision
with open(rel_path, "w") as fh:
    json.dump(release, fh, indent=2)
    fh.write("\n")
print("release.json databases:", json.dumps(release["databases"]))
PY

echo "50-stage-dbs done"
