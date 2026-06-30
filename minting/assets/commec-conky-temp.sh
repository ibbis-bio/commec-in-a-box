#!/usr/bin/env bash
# CPU / GPU / disk temperatures (color-coded) for the conky overlay. Robust across
# AMD + Intel. Emits ${color ...} tokens, so the conky line must use ${execpi} (which
# parses the output), NOT ${execi}. Thresholds are env-overridable.
# Installed to /usr/local/bin/commec-conky-temp by 40-desktop.sh.
RST='${color}'
val() { sensors 2>/dev/null | grep -iE "^($1):" | grep -oE '[0-9]+\.[0-9]+' | head -1; }
col() { local t=${1%.*}
  [ -z "$1" ] && { printf '%s' "$RST"; return; }
  if   [ "$t" -ge "$3" ]; then printf '${color red}'
  elif [ "$t" -ge "$2" ]; then printf '${color orange}'
  else printf '%s' "$RST"; fi; }
seg() { # label  sensor-pattern  warn  crit
  local v; v=$(val "$2"); [ -z "$v" ] && return
  printf '%s %s%s°C%s' "$1" "$(col "$v" "$3" "$4")" "$v" "$RST"; }

out="$(seg CPU 'Tctl|Tdie|Package id 0|Core 0' "${CPU_WARN:-80}" "${CPU_CRIT:-90}")"
g=$(seg GPU 'edge|junction' "${GPU_WARN:-80}" "${GPU_CRIT:-90}"); [ -n "$g" ] && out="$out   $g"
d=$(seg Disk 'Composite|Sensor 1' "${DISK_WARN:-65}" "${DISK_CRIT:-80}"); [ -n "$d" ] && out="$out   $d"
printf '%s\n' "$out"
