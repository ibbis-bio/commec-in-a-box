#!/usr/bin/env bash
# Install Miniconda system-wide at /opt/miniconda from the pinned installer
# (already uploaded + host-verified to /tmp/miniconda.sh).
set -euxo pipefail

bash /tmp/miniconda.sh -b -p /opt/miniconda
rm -f /tmp/miniconda.sh

# Keep conda from auto-updating itself (reproducibility).
/opt/miniconda/bin/conda config --system --set auto_update_conda false
/opt/miniconda/bin/conda config --system --set always_yes true

echo "10-miniconda done"
