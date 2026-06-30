#!/usr/bin/env bash
# First-login GUI: force the user to set their account password before using the box.
# Loops until a valid password is set (the dialog cannot be escaped out of), then the
# root helper records the guard so this never runs again.
set -uo pipefail

GUARD=/var/lib/commec/password.done
[ -e "$GUARD" ] && exit 0

err() { zenity --error --no-wrap --title="Commec" --text="$1" 2>/dev/null || true; }

# Give the desktop a moment to settle.
sleep 4

while [ ! -e "$GUARD" ]; do
  if command -v yad >/dev/null 2>&1; then
    out=$(yad --title="Welcome to Commec" --form \
              --text="Set a password for this machine.\nYou'll use it for admin tasks and remote access." \
              --field="New password:H" --field="Confirm password:H" \
              --button="Set password:0" --no-escape --on-top --sticky \
              --skip-taskbar --center --width=420 2>/dev/null) || { sleep 1; continue; }
    p1=$(printf '%s' "$out" | awk -F'|' '{print $1}')
    p2=$(printf '%s' "$out" | awk -F'|' '{print $2}')
  else
    p1=$(zenity --password --title="Set a password for this machine" 2>/dev/null) || { sleep 1; continue; }
    p2=$(zenity --password --title="Confirm password" 2>/dev/null) || { sleep 1; continue; }
  fi

  if [ -z "${p1:-}" ];            then err "Password cannot be empty.";        continue; fi
  if [ "${#p1}" -lt 8 ];         then err "Use at least 8 characters.";       continue; fi
  if [ "$p1" != "${p2:-}" ];     then err "Passwords did not match.";         continue; fi

  if printf '%s\n' "$p1" | sudo -n /usr/local/sbin/commec-set-initial-password; then
    zenity --info --no-wrap --title="Commec" \
      --text="Password set. Use it for admin tasks and remote access." 2>/dev/null || true
  else
    err "Could not set the password. Please try again."
  fi
done
