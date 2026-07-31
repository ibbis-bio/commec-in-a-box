#!/usr/bin/env bash
# Build an unreleased commec conda package from the exact source commit in pins.json. The package
# is indexed both in a host-side test channel and in packer/devchannel for the appliance mint.
# Set SERVE=1 to serve the host-side channel for update-flow tests.
#
# Usage:  ./commec-devbuild.sh
#         ./commec-devbuild.sh 2.1.0.dev1
#         SERVE=1 PORT=8000 ./commec-devbuild.sh 2.1.0.dev1
#
# This script only modifies a throwaway clone and local channels. It never pushes, tags, uploads,
# or dispatches an upstream release.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PINS="$HERE/pins.json"
pin() { python3 -c "import json;print(json.load(open('$PINS'))$1)"; }

DEVVER="${1:-$(pin "['commec']['candidate']['version']")}"
case "$DEVVER" in *[!A-Za-z0-9.+_-]*) echo "bad version string: $DEVVER"; exit 2 ;; esac
BRANCH="${BRANCH:-$(pin "['commec']['gui_shim']['branch']")}"
COMMIT="${COMMIT:-$(pin "['commec']['gui_shim']['commit']")}"
PORT="${PORT:-8000}"
WORK="${WORK:-$HOME/commec-devbuild}"
REPO="$WORK/common-mechanism"
CH="$WORK/channel"
STAGE_MINT="${STAGE_MINT:-1}"
SERVE="${SERVE:-0}"

# Locate conda (needs conda + conda-build on the mint host)
CONDA="${CONDA:-}"
if [ -z "$CONDA" ] && command -v conda >/dev/null; then
  CONDA=$(command -v conda)
fi
for p in "$HOME/miniconda3/bin/conda" "$HOME/miniconda/bin/conda" /opt/miniconda/bin/conda /opt/conda/bin/conda; do
  [ -z "$CONDA" ] && [ -x "$p" ] && CONDA="$p"
done
[ -n "$CONDA" ] && [ -x "$CONDA" ] || { echo "ERROR: no conda found. Install miniconda + conda-build on the mint host."; exit 1; }
echo "using conda: $CONDA"
mkdir -p "$WORK"

echo "== fetch pinned source =="
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch origin "$BRANCH"
else
  git clone --no-checkout https://github.com/ibbis-bio/common-mechanism "$REPO"
  git -C "$REPO" fetch origin "$BRANCH"
fi
git -C "$REPO" merge-base --is-ancestor "$COMMIT" "origin/$BRANCH" || {
  echo "ERROR: pinned commit $COMMIT is not reachable from origin/$BRANCH" >&2
  exit 1
}
git -C "$REPO" reset --hard
git -C "$REPO" clean -fdx
git -C "$REPO" checkout --detach "$COMMIT"
SHA=$(git -C "$REPO" rev-parse HEAD)
echo "source @ $SHA"

echo "== set LOCAL dev version $DEVVER (throwaway edit, not committed) =="
sed -i "s/{% set version = \".*\" %}/{% set version = \"$DEVVER\" %}/" "$REPO/conda-recipe/meta.yaml"
grep -q "{% set version = \"$DEVVER\" %}" "$REPO/conda-recipe/meta.yaml" || \
  { echo "ERROR: could not set the version in conda-recipe/meta.yaml"; exit 1; }
# pyproject quotes the version with EITHER quote style; match both. This is not cosmetic: the
# package's own metadata comes from here, so a missed substitution builds a conda package
# labelled <devver> whose `commec --version` (and release.json, and the GUI) still report the
# source version - which then disagrees with what the updater compares against.
sed -i -E "s/^version = ['\"][^'\"]*['\"]/version = \"$DEVVER\"/" "$REPO/pyproject.toml"
grep -q "^version = \"$DEVVER\"$" "$REPO/pyproject.toml" || \
  { echo "ERROR: could not set the version in pyproject.toml"; exit 1; }
# Build from the LOCAL checkout, not a release tarball. The recipe's source is a versioned GitHub
# release URL (v{{version}}.tar.gz) with a pinned sha256, so a dev version has no matching release
# and conda-build errors ("Empty sha256"). Point source at the parent dir (the checked-out gui).
sed -i -e '/^  url: /d' -e 's|^  sha256:.*|  path: ..|' "$REPO/conda-recipe/meta.yaml"
for dep in flask openpyxl psutil werkzeug xlrd; do
  grep -q "^    - ${dep}$" "$REPO/conda-recipe/meta.yaml" || {
    echo "ERROR: pinned conda recipe is missing runtime dependency: $dep" >&2
    exit 1
  }
done

echo "== conda build (no upload) into local channel $CH =="
"$CONDA" run -n base conda-build --version >/dev/null || "$CONDA" install -y -n base conda-build
"$CONDA" build --no-anaconda-upload -c conda-forge -c bioconda --output-folder "$CH" "$REPO/conda-recipe"
"$CONDA" index "$CH"

mapfile -t PACKAGES < <(find "$CH/noarch" -maxdepth 1 -type f -name "commec-${DEVVER}-*.conda" -print)
[ "${#PACKAGES[@]}" -eq 1 ] || {
  echo "ERROR: expected exactly one commec $DEVVER package, found ${#PACKAGES[@]}" >&2
  printf '  %s\n' "${PACKAGES[@]}" >&2
  exit 1
}
PACKAGE="${PACKAGES[0]}"
PACKAGE_SHA=$(sha256sum "$PACKAGE" | awk '{print $1}')
echo "package: $(basename "$PACKAGE")"
echo "sha256: $PACKAGE_SHA"

if [ "$STAGE_MINT" = "1" ]; then
  mkdir -p "$HERE/packer/devchannel/noarch"
  find "$HERE/packer/devchannel/noarch" -maxdepth 1 -type f -name 'commec-*.conda' -delete
  cp -f "$PACKAGE" "$HERE/packer/devchannel/noarch/"
  "$CONDA" index "$HERE/packer/devchannel"
  echo "mint channel: $HERE/packer/devchannel"
elif [ "$STAGE_MINT" != "0" ]; then
  echo "ERROR: STAGE_MINT must be 0 or 1" >&2
  exit 2
fi

[ "$SERVE" = "0" ] && exit 0
[ "$SERVE" = "1" ] || { echo "ERROR: SERVE must be 0 or 1" >&2; exit 2; }

IP=$(hostname -I | awk '{print $1}')
if command -v tailscale >/dev/null; then
  TS_IP=$(tailscale ip -4) && IP=$(printf '%s\n' "$TS_IP" | head -1)
fi
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
