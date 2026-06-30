#!/usr/bin/env bash
# Fetch ONLY the small DBs (biorisk + low_concern + taxonomy) by driving `commec setup`
# from commec-user's home, so its default dir resolves to ~/commec-dbs. We decline the
# two big BLAST downloads (staged separately) and pin biorisk via an explicit URL.
#
# Note: `commec setup` writes base_paths.default to a RELATIVE path that does not resolve
# (upstream quirk), so we patch the installed package config ourselves afterwards.
set -euxo pipefail
: "${BIORISK_URL:?BIORISK_URL not set}"

DBDIR=/home/commec-user/commec-dbs

cat > /tmp/run-commec-setup.sh <<'INNER'
set -euo pipefail
cd "$HOME"
source /opt/miniconda/etc/profile.d/conda.sh
conda activate commec
# commec setup needs wget + update_blastdb.pl on PATH (the latter ships with blast in the env).
command -v wget >/dev/null
command -v update_blastdb.pl >/dev/null
# Use HTTPS for taxdump (the setup default is NCBI FTP, which is flaky/deprecated).
TAXURL="https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz"
# Answer sequence for the interactive setup state machine:
#   dir=<Enter>(default ~/commec-dbs), biorisk=y, biorisk-url=<pinned>, blastnr=n,
#   blastnt=n, taxonomy=y, tax-url=<TAXURL> then <Enter> (get_taxonomy_url loops once
#   after a non-empty URL, so an empty line triggers the validity check), confirm=<Enter>
printf '%s\n' '' 'y' "$BIORISK_URL" 'n' 'n' 'y' "$TAXURL" '' '' | commec setup
# sanity: the small DBs landed
test -d "$HOME/commec-dbs/biorisk"
test -d "$HOME/commec-dbs/low_concern"
test -d "$HOME/commec-dbs/taxonomy"
INNER

sudo -u commec-user env "BIORISK_URL=$BIORISK_URL" HOME=/home/commec-user bash /tmp/run-commec-setup.sh
rm -f /tmp/run-commec-setup.sh

# Patch the installed package default config: set base_paths.default to the absolute
# DB dir (with trailing slash, since paths are "{default}nr_blast/nr" etc.).
/opt/miniconda/envs/commec/bin/python - "$DBDIR" <<'PY'
import sys, pathlib, importlib.resources, yaml
dbdir = sys.argv[1].rstrip("/") + "/"
p = pathlib.Path(str(importlib.resources.files("commec").joinpath("screen-default-config.yaml")))
cfg = yaml.safe_load(p.read_text())
cfg.setdefault("base_paths", {})["default"] = dbdir
p.write_text(yaml.safe_dump(cfg, sort_keys=False))
print("patched base_paths.default ->", dbdir, "in", p)
PY

chown -R commec-user:commec-user /home/commec-user/commec-dbs
echo "30-commec-setup done"
