#!/usr/bin/env bash
# Reassemble and verify a commec-in-a-box deployment archive from GitHub release parts.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

[ -f SHA256SUMS.parts ] || { echo "ERROR: SHA256SUMS.parts is missing" >&2; exit 1; }
[ -f SHA256SUMS ] || { echo "ERROR: SHA256SUMS is missing" >&2; exit 1; }

ARCHIVE=$(awk 'NR == 1 {print $2}' SHA256SUMS)
EXPECTED=$(awk 'NR == 1 {print $1}' SHA256SUMS)
[ -n "$ARCHIVE" ] && [ -n "$EXPECTED" ] || { echo "ERROR: invalid SHA256SUMS" >&2; exit 1; }
case "$ARCHIVE" in */*|"") echo "ERROR: unsafe archive name in SHA256SUMS: $ARCHIVE" >&2; exit 1 ;; esac
[ ! -e "$ARCHIVE" ] || { echo "ERROR: refusing to overwrite existing $ARCHIVE" >&2; exit 1; }

sha256sum -c SHA256SUMS.parts

PARTS=("$ARCHIVE".part-*)
[ -e "${PARTS[0]}" ] || { echo "ERROR: no release parts found for $ARCHIVE" >&2; exit 1; }
TMP="$ARCHIVE.partial"
trap 'rm -f "$TMP"' EXIT

cat "${PARTS[@]}" > "$TMP"
GOT=$(sha256sum "$TMP" | awk '{print $1}')
[ "$GOT" = "$EXPECTED" ] || {
  echo "ERROR: reconstructed archive hash mismatch: got $GOT want $EXPECTED" >&2
  exit 1
}
mv "$TMP" "$ARCHIVE"
trap - EXIT

echo "verified: $HERE/$ARCHIVE"
