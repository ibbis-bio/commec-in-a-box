#!/usr/bin/env bash
# Desktop update notifier (autostarted in the commec-user session). Periodically checks for a
# newer commec and pops a dialog OVER fullscreen apps. Offline notice is one-and-done per boot;
# an available update prompts (Install / Later) and, on Install, runs the NOPASSWD apply helper.
set -u

CONF=/etc/commec-box/update.conf
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATUS="$RT/commec-update.status"
OFFLINE_FLAG="$RT/commec-update.offline-shown"
PROMPTED_FLAG="$RT/commec-update.prompted"
poll_interval=1800
startup_delay=20
[ -r "$CONF" ] && . "$CONF"

# Force a just-mapped dialog above fullscreen windows (yad --on-top sets _NET_WM_STATE_ABOVE;
# this reinforces it for WMs that let fullscreen win).
raise_above() {  # $1 = window title substring
  local w
  for _ in 1 2 3 4 5 6; do
    w=$(wmctrl -l 2>/dev/null | grep -F "$1" | awk '{print $1; exit}')
    if [ -n "$w" ]; then wmctrl -i -r "$w" -b add,above 2>/dev/null; return; fi
    sleep 0.5
  done
}

notify_offline() {
  [ -e "$OFFLINE_FLAG" ] && return            # one-and-done per boot (flag on tmpfs, clears on reboot)
  : > "$OFFLINE_FLAG"
  ( yad --title="Commec" --info --on-top --sticky --skip-taskbar --center --no-wrap \
        --width=380 --timeout=25 --button="OK:0" \
        --text="Offline - can't check for commec updates right now." >/dev/null 2>&1 ) &
  raise_above "Commec"
}

prompt_update() {  # $1 = version
  local ver="$1" ans newver
  [ "$(cat "$PROMPTED_FLAG" 2>/dev/null)" = "$ver" ] && return   # already offered this version this boot
  printf '%s' "$ver" > "$PROMPTED_FLAG"
  (
    yad --title="Commec update available" --question --on-top --sticky --skip-taskbar --center \
        --no-wrap --width=460 --image=software-update-available \
        --text="A new commec version is available: <b>$ver</b>\n\nInstall it now? The new version is prepared alongside the current one and switched in only after it checks out." \
        --button="Later:1" --button="Install now:0" >/dev/null 2>&1
    ans=$?
    [ "$ans" = 0 ] || exit 0
    ( sudo -n /usr/local/sbin/commec-update-apply "$ver" ) 2>&1 | \
      yad --title="Installing commec $ver" --progress --pulsate --auto-close --auto-kill \
          --on-top --sticky --center --width=460 --no-buttons \
          --text="Installing commec $ver - please wait..." >/dev/null 2>&1 &
    raise_above "Installing commec"
    wait
    newver=$(python3 -c 'import json;print(json.load(open("/etc/commec-box/release.json")).get("version",""))' 2>/dev/null)
    if [ "$newver" = "$ver" ]; then
      yad --title="Commec" --info --on-top --sticky --center --timeout=15 --button="OK:0" \
          --text="Updated to commec <b>$ver</b>. New terminals use it immediately." >/dev/null 2>&1 &
      raise_above "Commec"
    else
      yad --title="Commec" --error --on-top --sticky --center --button="OK:0" \
          --text="Update to $ver did not complete. See /var/log/commec-update.log." >/dev/null 2>&1 &
      raise_above "Commec"
    fi
  ) &
  raise_above "Commec update"
}

sleep "$startup_delay"
while :; do
  st=$(/usr/local/bin/commec-update-check 2>/dev/null | tail -1)
  case "$st" in
    offline)     notify_offline ;;
    available:*) prompt_update "${st#available:}" ;;
    *)           : ;;   # up-to-date / unknown
  esac
  sleep "$poll_interval"
done
