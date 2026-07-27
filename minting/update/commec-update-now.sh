#!/usr/bin/env bash
# On-demand update, launched from the "Update Commec" desktop icon. Runs the check
# and ALWAYS shows a result: offline notice / "up to date" / one install prompt covering BOTH
# what is pending - the commec package and the screening databases.
#
# Order matters on install: commec first, then databases. A database revision can require a
# newer commec (commec/database_compatibility.yaml), so the database check is re-run against the
# freshly installed environment before the databases are touched.
#
# This is the only update UI - the background poller (commec-update-poll.sh) is headless and
# just refreshes the status file for the conky overlay.
set -u

CONF=/etc/commec-box/update.conf
PY=/opt/miniconda/bin/python
REL=/etc/commec-box/release.json
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/commec-update.json"
# Where this dialog's own stderr goes. Silently swallowing it would leave a wrong dialog with
# no way to find out why.
UILOG="$RUNTIME/commec-update-ui.log"
SCREEN_GUARD=/usr/local/lib/commec-box/commec-screen-state
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

info_dialog() {  # $1 = text, $2 = timeout seconds
  ( yad --title="Commec" --info --on-top --sticky --skip-taskbar --center --no-wrap \
        --width=420 --timeout="$2" --button="OK:0" --text="$1" >/dev/null 2>&1 ) &
  raise_above "Commec"
}

error_dialog() {  # $1 = text
  ( yad --title="Commec" --error --on-top --sticky --skip-taskbar --center --no-wrap \
        --width=460 --button="OK:0" --text="$1" >/dev/null 2>&1 ) &
  raise_above "Commec"
}

screen_update_allowed() {
  local state rc
  state=$("$SCREEN_GUARD" 2>>"$UILOG")
  rc=$?
  case "$rc" in
    0) return 0 ;;
    4) info_dialog "A screening run is in progress.\n\nFinish it before updating Commec." 30 ;;
    *) error_dialog "Could not determine whether a screening run is in progress.\n\nRefusing to update Commec." ;;
  esac
  printf 'screen guard refused update: state=%s rc=%s\n' "${state:-unknown}" "$rc" >>"$UILOG"
  return 1
}

check_with_progress() {  # $1 = progress text; prints the check's status token
  local text="$1" progress_pid st
  yad --title="Checking for Commec updates" --progress --pulsate --no-buttons \
      --on-top --sticky --skip-taskbar --center --width=460 --timeout=180 \
      --progress-text="Working..." --text="$text" >/dev/null 2>>"$UILOG" &
  progress_pid=$!
  raise_above "Checking for Commec updates"

  st=$(/usr/local/bin/commec-update-check | tail -1)

  if kill -0 "$progress_pid" 2>>"$UILOG"; then
    kill "$progress_pid" 2>>"$UILOG"
  fi
  wait "$progress_pid" || true
  printf '%s\n' "$st"
}

# Human-readable summary of everything pending, built from the state the check just wrote.
summary_text() {
  "$PY" - "$STATE" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as fh:
        state = json.load(fh)
except Exception:
    print("An update is available.")
    raise SystemExit(0)


def gb(n):
    return n / (1024.0 ** 3)


rows = []
commec = state.get("commec") or {}
if commec.get("update"):
    rows.append(("commec", str(commec.get("installed")), str(commec.get("latest")), ""))

pending = {n: v for n, v in (state.get("databases") or {}).items()
           if v.get("status") in ("update", "missing", "revert")}
for name, info in sorted(pending.items()):
    size = info.get("bytes")
    rows.append((name,
                 info.get("have") or "not installed",
                 str(info.get("latest")),
                 f"({gb(size):.1f} GB)" if size else ""))

# Pad into columns: the dialog renders this block in a monospace <tt> span, so a ragged list
# reads as noise when several things are pending at once.
w_name = max((len(r[0]) for r in rows), default=0)
w_have = max((len(r[1]) for r in rows), default=0)
w_want = max((len(r[2]) for r in rows), default=0)
lines = [f"{n:<{w_name}}  {h:>{w_have}} -> {w:<{w_want}}  {s}".rstrip()
         for n, h, w, s in rows]

text = "The following updates are available:\n\n<tt>" + "\n".join(lines) + "</tt>"

download = state.get("db_download_bytes") or 0
required = state.get("db_required_bytes") or 0
if download:
    text += (f"\n\nDownload about {gb(download):.1f} GB; "
             f"needs about {gb(required):.0f} GB free while installing.")

blocked = [n for n, v in (state.get("databases") or {}).items()
           if v.get("status") == "blocked"]
if blocked:
    text += ("\n\nNote: " + ", ".join(sorted(blocked)) +
             " needs a newer commec before it can be updated.")

text += ("\n\nInstall now? Each part is prepared alongside the current installation and swapped in "
         "only after it checks out.")
print(text)
PYEOF
}

state_field() {  # $1 = python expression over `d`
  "$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));print($1)" "$STATE" 2>>"$UILOG"
}

release_version() {
  "$PY" -c 'import json;print(json.load(open("'"$REL"'")).get("version",""))' 2>>"$UILOG"
}

# --- install steps ---------------------------------------------------------------------------

install_software() {  # $1 = version; returns the helper's exit status
  local ver="$1" rc
  ( sudo -n /usr/local/sbin/commec-update-apply "$ver" ) 2>&1 | \
    yad --title="Installing commec $ver" --progress --pulsate --auto-close --auto-kill \
        --on-top --sticky --center --width=460 --no-buttons \
        --progress-text="Working..." \
        --text="Installing commec $ver - please wait..." >/dev/null 2>&1 &
  raise_above "Installing commec"
  wait
  # The dialog consumed the pipe, so ask release.json what actually landed.
  [ "$(release_version)" = "$ver" ]
  rc=$?
  return $rc
}

install_databases() {  # returns the helper's exit status
  local rc errfile rcfile
  # Two files, deliberately: the helper's exit status is written with > (truncating), so it
  # must not share a file with the ERROR lines the translator appends.
  errfile=$(mktemp); rcfile=$(mktemp)
  # commec-db-apply speaks a small line protocol (PROGRESS/STEP/ERROR); translate it into
  # yad's (a bare number sets the bar, "#text" sets the label) so the operator sees real
  # download progress rather than a pulsating bar that says nothing.
  ( sudo -n /usr/local/sbin/commec-db-apply; echo "$?" >"$rcfile" ) 2>>"$UILOG" | \
    while IFS= read -r line; do
      case "$line" in
        PROGRESS\ *) set -- $line; printf '%s\n' "$2"; printf '#Downloading %s (%s%%)\n' "${3:-database}" "$2" ;;
        STEP\ *)     printf '#%s\n' "${line#STEP }" ;;
        ERROR\ *)    printf '%s\n' "${line#ERROR }" >>"$errfile" ;;
      esac
    done | \
    yad --title="Updating databases" --progress --auto-close --auto-kill \
        --on-top --sticky --center --width=520 --no-buttons \
        --text="Updating screening databases - please wait..." >/dev/null 2>&1 &
  raise_above "Updating databases"
  wait
  rc=$(tail -1 "$rcfile")
  DB_ERROR=$(tail -1 "$errfile")
  rm -f "$errfile" "$rcfile"
  return "${rc:-1}"
}

prompt_and_install() {
  yad --title="Commec updates available" --question --on-top --sticky --skip-taskbar --center \
      --no-wrap --width=520 --image=software-update-available \
      --text="$(summary_text)" \
      --button="Later:1" --button="Install now:0" >/dev/null 2>&1
  [ $? = 0 ] || return 0

  # The prompt can remain open indefinitely. Re-check immediately before any apply helper so a
  # screening run started after the channel check is still protected.
  screen_update_allowed || return 0

  local failures="" sw_ver
  sw_ver=$(state_field 'd["commec"]["latest"] if d.get("commec",{}).get("update") else ""')

  if [ -n "$sw_ver" ]; then
    if install_software "$sw_ver"; then
      # A newer commec can lift the compatibility ceiling on database revisions, so re-check
      # against the environment that is now live before deciding what to download.
      check_with_progress "Checking database compatibility with commec $sw_ver..." >/dev/null
    else
      failures="commec $sw_ver did not install. See /var/log/commec-update.log."
    fi
  fi

  if [ "$(state_field 'd.get("db_update_count",0)')" != "0" ]; then
    if ! install_databases; then
      failures="${failures:+$failures\n}Database update failed: ${DB_ERROR:-see /var/log/commec-update.log}"
    fi
  fi

  check_with_progress "Refreshing update status..." >/dev/null
  if [ -n "$failures" ]; then
    error_dialog "$failures"
  else
    info_dialog "Update complete.\n\ncommec: <b>$(release_version)</b>\nNew terminals use it immediately." 20
  fi
}

# Refuse immediately while screening rather than making the operator wait for the network and
# conda checks. The available case checks again after that slow work, and prompt_and_install
# checks once more after confirmation, closing the intervening race windows.
screen_update_allowed || exit 0

st=$(check_with_progress "Checking software and database updates...")
case "$st" in
  offline)     info_dialog "Offline - can't check for commec updates right now." 25 ;;
  available:*) if screen_update_allowed; then prompt_and_install; fi ;;
  blocked:*)
    # Newer databases exist but this commec is too old for them, and no commec update is on
    # offer yet. There is nothing to install, so say what the situation is instead of claiming
    # everything is current.
    blocked_names=$(state_field '", ".join(sorted(n for n,v in d.get("databases",{}).items() if v.get("status")=="blocked"))')
    info_dialog "Newer screening databases are available (<b>${blocked_names}</b>), but they need a newer version of commec than this machine has.\n\nNo commec update is available yet - check again later." 30 ;;
  *)           info_dialog "commec and its databases are up to date." 15 ;;
esac
