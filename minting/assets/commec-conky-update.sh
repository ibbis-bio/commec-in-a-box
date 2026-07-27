#!/usr/bin/env bash
# Connectivity + update state for the conky overlay, covering both axes (the commec package and
# the screening databases). Reads the status token that the headless poller
# (commec-update-poll.sh) keeps fresh at $XDG_RUNTIME_DIR/commec-update.status; does NO network
# itself (so it can't stall the overlay). "can we reach the update services?" is answered via the
# poller's `offline` token. The offline and up-to-date states add installed versions from
# release.json; this is local metadata maintained by the software and database apply helpers,
# not another network check. Emits ${color ...} tokens, so the conky line must use ${execpi}
# (NOT ${execi}).
# Installed to /usr/local/bin/commec-conky-update by 40-desktop.sh.
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # conky's env may lack XDG_RUNTIME_DIR
st=$(cat "$RT/commec-update.status" 2>/dev/null)
PY="${COMMEC_BASE_PYTHON:-/opt/miniconda/bin/python}"
REL="${COMMEC_BOX_RELEASE:-/etc/commec-box/release.json}"

release_summary() {
  [ -x "$PY" ] && [ -r "$REL" ] || return 0
  "$PY" - "$REL" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        release = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)

version = release.get("version")
if version:
    print(f"commec {version}")

databases = release.get("databases") or {}
pairs = [f"{name}={revision}" for name, revision in sorted(databases.items())]
for offset in range(0, len(pairs), 2):
    prefix = "DBs " if offset == 0 else "    "
    print(prefix + "  ".join(pairs[offset:offset + 2]))
PY
}

status_with_release() {  # <color> <label>
  summary=$(release_summary)
  if [ -n "$summary" ]; then
    printf '${color %s}%s${color}  %s\n' "$1" "$2" "$summary"
  else
    printf '${color %s}%s${color}\n' "$1" "$2"
  fi
}

case "$st" in
  offline)    status_with_release red "Offline" ;;
  up-to-date) status_with_release green "Up to date" ;;
  # A newer database exists but this commec is too old to accept it, and no commec update is
  # available yet either. Not green: the box IS behind, it just cannot act on it right now.
  blocked:*)  printf '${color orange}Databases need a newer commec${color}\n' ;;
  available:*)
    # "available:sw=<ver>" | "available:db=<n>" | "available:sw=<ver>,db=<n>"
    body=${st#available:}
    sw=""; db=""
    oldifs=$IFS; IFS=','
    for part in $body; do
      case "$part" in
        sw=*) sw=${part#sw=} ;;
        db=*) db=${part#db=} ;;
      esac
    done
    IFS=$oldifs
    if [ -n "$sw" ] && [ -n "$db" ]; then
      printf '${color yellow}%s + %s database(s) available${color}\n' "$sw" "$db"
    elif [ -n "$sw" ]; then
      printf '${color yellow}%s available${color}\n' "$sw"
    elif [ -n "$db" ]; then
      printf '${color yellow}%s database(s) available${color}\n' "$db"
    else
      printf '${color yellow}Available${color}\n'
    fi
    ;;
  *) printf 'checking...\n' ;;   # status file not written yet (pre first poll)
esac
