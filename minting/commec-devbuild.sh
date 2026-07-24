#!/usr/bin/env bash
# Build a DEV commec conda package from the gui branch into a LOCAL channel and serve it over
# HTTP on the tailnet, so a commec-in-a-box *devel* box can exercise the update flow end-to-end.
#
# It feeds two consumers: (1) the mint - copy the built .conda into packer/devchannel/, which
# 20-commec.sh installs from file:///tmp/devchannel (COMMEC_SOURCE=gui); this is the only way the
# appliance gets an unreleased commec 1.1.0.dev*. (2) the update-flow dry run - the served :8000
# channel is what a devel box's updater points at to test an A/B update.
#
# RELEASE-SAFE: everything is local. It never pushes, never tags, never dispatches CI, and never
# uploads to bioconda/anaconda. The only things that cut a real release are (a) publishing a
# GitHub Release or (b) manually running the "Automate Release" workflow_dispatch - neither
# happens here. The version bump is a local edit to a throwaway clone, not committed.
#
# Usage:  ./commec-devbuild.sh <devversion>        e.g. 1.1.0.dev2  (must sort ABOVE the box's version)
#         BRANCH=gui PORT=8000 ./commec-devbuild.sh 1.1.0.dev2
# Re-run with a higher devN to make the box's updater prompt again.
set -euo pipefail

DEVVER="${1:?usage: commec-devbuild.sh <devversion, e.g. 1.1.0.dev2>}"
case "$DEVVER" in *[!A-Za-z0-9.+_-]*) echo "bad version string: $DEVVER"; exit 2 ;; esac
BRANCH="${BRANCH:-gui}"
PORT="${PORT:-8000}"
WORK="${WORK:-$HOME/commec-devbuild}"
REPO="$WORK/common-mechanism"
CH="$WORK/channel"

# Locate conda (needs conda + conda-build on the mint host)
CONDA="${CONDA:-}"
[ -z "$CONDA" ] && CONDA=$(command -v conda 2>/dev/null || true)
for p in "$HOME/miniconda3/bin/conda" "$HOME/miniconda/bin/conda" /opt/miniconda/bin/conda /opt/conda/bin/conda; do
  [ -z "$CONDA" ] && [ -x "$p" ] && CONDA="$p"
done
[ -n "$CONDA" ] && [ -x "$CONDA" ] || { echo "ERROR: no conda found. Install miniconda + conda-build on the mint host."; exit 1; }
echo "using conda: $CONDA"
mkdir -p "$WORK"

echo "== fetch gui branch =="
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch origin "$BRANCH"
else
  git clone -b "$BRANCH" https://github.com/ibbis-bio/common-mechanism "$REPO"
fi
git -C "$REPO" checkout "$BRANCH"
git -C "$REPO" reset --hard "origin/$BRANCH"
SHA=$(git -C "$REPO" rev-parse --short HEAD)
echo "gui @ $SHA"

echo "== set LOCAL dev version $DEVVER (throwaway edit, not committed) =="
sed -i "s/{% set version = \".*\" %}/{% set version = \"$DEVVER\" %}/" "$REPO/conda-recipe/meta.yaml"
[ -f "$REPO/pyproject.toml" ] && sed -i -E "s/^version = \".*\"/version = \"$DEVVER\"/" "$REPO/pyproject.toml" || true
# Build from the LOCAL checkout, not a release tarball. The recipe's source is a versioned GitHub
# release URL (v{{version}}.tar.gz) with a pinned sha256, so a dev version has no matching release
# and conda-build errors ("Empty sha256"). Point source at the parent dir (the checked-out gui).
sed -i -e '/^  url: /d' -e 's|^  sha256:.*|  path: ..|' "$REPO/conda-recipe/meta.yaml"
# The commec-gui server (commec/gui/server.py) needs flask + werkzeug + psutil, but the recipe's
# run: deps omit them, so an updated env (conda create commec=<ver>) would break the kiosk. Add them
# so the package carries its server deps. NB: fold this into the gui branch's conda-recipe/meta.yaml.
grep -q '^    - flask$' "$REPO/conda-recipe/meta.yaml" || \
  sed -i '/^    - pyyaml$/a\    - flask\n    - werkzeug\n    - psutil' "$REPO/conda-recipe/meta.yaml"

echo "== conda build (no upload) into local channel $CH =="
command -v conda-build >/dev/null 2>&1 || "$CONDA" run -n base conda-build --version >/dev/null 2>&1 || "$CONDA" install -y -n base conda-build
"$CONDA" build --no-anaconda-upload -c conda-forge -c bioconda --output-folder "$CH" "$REPO/conda-recipe"
"$CONDA" index "$CH"

IP=$(tailscale ip -4 2>/dev/null | head -1 || hostname -I | awk '{print $1}')
echo
echo "=================================================================="
echo " commec $DEVVER built. Serving channel at http://$IP:$PORT/"
echo
echo " On the devel box, set /etc/commec-box/update.conf:"
echo "   channel=devel"
echo "   conda_channels=http://$IP:$PORT,conda-forge,bioconda"
echo "   probe_url=http://$IP:$PORT/noarch/repodata.json"
echo
echo " Then the updater will prompt for $DEVVER. Bump devN + re-run to re-trigger."
echo " Ctrl-C to stop serving."
echo "=================================================================="
cd "$CH" && exec python3 -m http.server "$PORT" --bind 0.0.0.0
