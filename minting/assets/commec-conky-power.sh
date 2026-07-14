#!/usr/bin/env bash
# APU/CPU power draw (Watts) for the conky overlay. Scans /sys/class/hwmon for a power sensor
# (the ThinkCentre APUs expose it as 'amdgpu' power1_input); value is microwatts, /1e6 -> W.
# Prefers power1_average (smoothed) then power1_input, and matches by presence not a fixed hwmon
# number. Emits ${color ...} tokens, so the conky line must use ${execpi} (NOT ${execi}).
# Thresholds are env-overridable. Installed to /usr/local/bin/commec-conky-power by 40-desktop.sh.
RST='${color}'
uw=""
for h in /sys/class/hwmon/hwmon*; do
  for f in "$h/power1_average" "$h/power1_input"; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) continue;; esac
    [ "$v" -gt 0 ] && { uw="$v"; break 2; }
  done
done
[ -z "$uw" ] && { printf '%sn/a%s\n' "$RST" "$RST"; exit 0; }
w=$(( uw / 1000000 ))
if   [ "$w" -ge "${PWR_CRIT:-55}" ]; then c='${color red}'
elif [ "$w" -ge "${PWR_WARN:-40}" ]; then c='${color orange}'
else c="$RST"; fi
printf '%s%d W%s\n' "$c" "$w" "$RST"
