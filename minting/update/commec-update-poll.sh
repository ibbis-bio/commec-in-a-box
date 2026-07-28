#!/usr/bin/env bash
# Headless update-status poller (autostarted in the commec-user session). Periodically runs
# commec-update-check so $XDG_RUNTIME_DIR/commec-update.status stays fresh for the conky overlay
# (commec-conky-update reads it). NO dialogs - all update UI lives in the desktop icon
# (commec-update-now.sh). Poll timing comes from update.conf.
set -u

CONF=/etc/commec-box/update.conf
FIRSTBOOT_GUARD=/var/lib/commec/firstboot.done
poll_interval=1800
startup_delay=20
[ -r "$CONF" ] && . "$CONF"

sleep "$startup_delay"
while [ ! -e "$FIRSTBOOT_GUARD" ]; do
  sleep 3
done
while :; do
  /usr/local/bin/commec-update-check >/dev/null 2>&1
  sleep "$poll_interval"
done
