#!/usr/bin/env bash
# Connectivity + update state for the conky overlay, covering both axes (the commec package and
# the screening databases). Reads the status token that the headless poller
# (commec-update-poll.sh) keeps fresh at $XDG_RUNTIME_DIR/commec-update.status; does NO network
# itself (so it can't stall the overlay). "can we reach the update services?" is answered via the
# poller's `offline` token. Emits ${color ...} tokens, so the conky line must use ${execpi}
# (NOT ${execi}). Installed to /usr/local/bin/commec-conky-update by 40-desktop.sh.
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # conky's env may lack XDG_RUNTIME_DIR
st=$(cat "$RT/commec-update.status" 2>/dev/null)

case "$st" in
  offline)    printf '${color red}Offline${color}\n' ;;
  up-to-date) printf '${color green}Up to date${color}\n' ;;
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
      printf '${color orange}Update %s + %s database(s)${color}\n' "$sw" "$db"
    elif [ -n "$sw" ]; then
      printf '${color orange}Update %s available${color}\n' "$sw"
    elif [ -n "$db" ]; then
      printf '${color orange}%s database update(s)${color}\n' "$db"
    else
      printf '${color orange}Update available${color}\n'
    fi
    ;;
  *) printf 'checking...\n' ;;   # status file not written yet (pre first poll)
esac
