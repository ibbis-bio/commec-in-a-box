#!/usr/bin/env bash
# Create the pinned commec conda env, emit an explicit lockfile, and make it the
# default environment for commec-user's interactive shells.
set -euxo pipefail

CONDA=/opt/miniconda/bin/conda
COMMEC_VERSION="${COMMEC_VERSION:-1.0.5}"

# Create env with commec pinned, using ONLY conda-forge + bioconda. Newer conda gates
# the Anaconda default channels (pkgs/main, pkgs/r) behind a Terms-of-Service accept;
# we don't use them, so drop 'defaults' and --override-channels. Accept ToS too as
# belt-and-suspenders (harmless, local-only).
$CONDA config --system --set channel_priority strict
$CONDA config --system --remove channels defaults 2>/dev/null || true
$CONDA tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
$CONDA tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
$CONDA create -y -n commec --override-channels -c conda-forge -c bioconda "commec=${COMMEC_VERSION}"

# Explicit lockfile (exact package URLs) for reproducibility; pulled back by Packer
# to be committed alongside pins.json.
mkdir -p /opt/commec
$CONDA list -n commec --explicit > /opt/commec/commec.lock

# Sanity: commec resolves and reports its version.
/opt/miniconda/envs/commec/bin/commec --version || true

# Auto-activate the env for commec-user (and root, for firstboot convenience).
ACTIVATE='
# commec env
if [ -f /opt/miniconda/etc/profile.d/conda.sh ]; then
  . /opt/miniconda/etc/profile.d/conda.sh
  conda activate commec
fi'
for home in /home/commec-user /root; do
  if [ -d "$home" ]; then
    printf '%s\n' "$ACTIVATE" >> "$home/.bashrc"
  fi
done
chown commec-user:commec-user /home/commec-user/.bashrc || true

echo "20-commec done"
