#!/usr/bin/env bash
# First-login GUI gate: while first-boot is still unpacking the databases, cover the
# desktop with a fullscreen "DO NOT power off" screen so the operator doesn't touch the
# machine (run commec before the DBs exist, reboot mid-decompress, etc.). Closes itself
# once /var/lib/commec/firstboot.done appears. No-op on every later login.
set -uo pipefail

GUARD=/var/lib/commec/firstboot.done
PWGUARD=/var/lib/commec/password.done

[ -e "$GUARD" ] && exit 0          # setup already finished; never show again

# Let the first-run password dialog take the foreground first.
for _ in $(seq 1 600); do
  [ -e "$GUARD" ] && exit 0
  [ -e "$PWGUARD" ] && break
  sleep 1
done
[ -e "$GUARD" ] && exit 0

start=$(date +%s)
# Pulsing progress (indeterminate so it never looks frozen); stdin closes when the guard
# appears -> --auto-close dismisses it.
(
  while [ ! -e "$GUARD" ]; do
    mins=$(( ( $(date +%s) - start ) / 60 ))
    echo "# Setting up databases - please DO NOT power off the machine.   (elapsed: ${mins} min)"
    sleep 5
  done
  echo "100"
) | yad --progress --pulsate --auto-close --no-buttons --no-escape \
        --fullscreen --on-top --sticky --skip-taskbar --undecorated \
        --image=dialog-information \
        --title="Commec first-time setup" \
        --text="<big><b>Setting up Commec - first-time only</b></big>\n\nUnpacking the screening databases. This can take a while.\n\n<b>Please DO NOT power off or restart the machine.</b>\nThe desktop will be ready when this screen closes." \
        2>/dev/null || true

notify-send -u normal "Commec" "Setup complete - the machine is ready to use." 2>/dev/null || true
