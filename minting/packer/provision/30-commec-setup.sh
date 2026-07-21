#!/usr/bin/env bash
# Populate ~commec-user/commec-dbs with the SMALL screening DBs for commec 1.1.0 (biorisk,
# low_concern, control_lists), pulled from commec's R2 bucket, then patch the installed config.
# The large best_match BLAST DBs ride the DB disk compressed and expand at firstboot
# (commec-firstboot.sh) into best_match/ - they are NOT handled here.
#
# DB source: <base>/<name>/<rev>/<name>.tar.zst, revisions resolved live from <base>/latest.json
# (COMMEC_DB_CHANNEL = stable -> 'latest', experimental -> 'experimental'). We trust upstream's
# versioning - no local hash pin; each DB's revision is recorded in <name>/manifest.json so
# commec's screen JSON and its DB-revision check can read it. Extraction mirrors `commec setup`:
# `tar --zstd -xf <name>.tar.zst -C <dbdir>/<name>/` (tar members are relative to <name>/, landing
# e.g. biorisk/biorisk.hmm - exactly the shipped screen-default-config.yaml paths).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

DB_BASE_URL="https://databases.commec.io"
DB_CHANNEL="${COMMEC_DB_CHANNEL:-stable}"
DBDIR=/home/commec-user/commec-dbs

# tools for the fetch/extract (base image may lack them; idempotent).
apt-get install -y --no-install-recommends curl zstd python3

# The appliance config patch is a shared tool (mint + runtime updates both apply it); install it
# now so this script and commec-update-apply call the same code. /tmp/update is staged before any
# shell provisioner runs.
install -m 0755 /tmp/update/commec-patch-config /usr/local/sbin/commec-patch-config

install -d "$DBDIR"

# Resolve the current revision map for the selected channel.
LATEST_JSON=$(curl -fSL --retry 3 "${DB_BASE_URL%/}/latest.json")
r2_rev() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d[{'stable':'latest','experimental':'experimental'}[sys.argv[3]]][sys.argv[2]])" "$LATEST_JSON" "$1" "$DB_CHANNEL"; }

# biorisk / low_concern / control_lists: download, extract into <dbdir>/<name>/, stamp manifest.
for name in biorisk low_concern control_lists; do
  rev=$(r2_rev "$name")
  echo "== $name revision $rev =="
  curl -fSL --retry 3 -o "/tmp/$name.tar.zst" "${DB_BASE_URL%/}/$name/$rev/$name.tar.zst"
  install -d "$DBDIR/$name"
  tar --zstd -xf "/tmp/$name.tar.zst" -C "$DBDIR/$name"
  rm -f "/tmp/$name.tar.zst"
  printf '{\n  "component": "%s",\n  "revision": "%s"\n}\n' "$name" "$rev" > "$DBDIR/$name/manifest.json"
  test -n "$(ls -A "$DBDIR/$name")"
done

chown -R commec-user:commec-user "$DBDIR"

# --- patch the installed package config (base_paths.default + blast_mt_mode=0) ---
/usr/local/sbin/commec-patch-config /opt/miniconda/envs/commec-env "$DBDIR"

echo "30-commec-setup done"
