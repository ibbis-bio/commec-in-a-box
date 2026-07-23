#!/usr/bin/env bash
# Connectivity + commec update state for the conky overlay. Reads the status token that the
# headless poller (commec-update-poll.sh) keeps fresh at $XDG_RUNTIME_DIR/commec-update.status;
# does NO network itself (so it can't stall the overlay). "can hit conda?" is answered via the
# poller's `offline` token. Emits ${color ...} tokens, so the conky line must use ${execpi}
# (NOT ${execi}). Installed to /usr/local/bin/commec-conky-update by 40-desktop.sh.
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # conky's env may lack XDG_RUNTIME_DIR
st=$(cat "$RT/commec-update.status" 2>/dev/null)
case "$st" in
  offline)     printf '${color red}Offline${color}\n' ;;
  available:*) printf '${color orange}Update %s available${color}\n' "${st#available:}" ;;
  up-to-date)  printf '${color green}Up to date${color}\n' ;;
  *)           printf 'checking...\n' ;;   # status file not written yet (pre first poll)
esac
