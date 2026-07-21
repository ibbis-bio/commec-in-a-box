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

# The appliance config patch is a shared tool (mint + runtime updates both apply it); install it
# now so this script and commec-update-apply call the same code. /tmp/update is staged by packer
# before any shell provisioner runs.
install -m 0755 /tmp/update/commec-patch-config /usr/local/sbin/commec-patch-config

cat > /tmp/run-commec-setup.sh <<'INNER'
set -euo pipefail
cd "$HOME"
source /opt/miniconda/etc/profile.d/conda.sh
conda activate commec-env
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

# Patch the installed package config (base_paths.default, bundled-DB paths, blast_mt_mode=0) via
# the shared tool, so the mint env and any future updated env are configured identically.
/usr/local/sbin/commec-patch-config /opt/miniconda/envs/commec-env "$DBDIR"

chown -R commec-user:commec-user /home/commec-user/commec-dbs
echo "30-commec-setup done"
