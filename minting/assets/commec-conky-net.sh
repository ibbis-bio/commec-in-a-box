#!/usr/bin/env bash
# Per-interface IPv4 with friendly labels, for the conky overlay's Network section.
# Installed to /usr/local/bin/commec-conky-net by 40-desktop.sh.
for i in $(ls /sys/class/net); do
  [ "$i" = lo ] && continue
  if [ -d "/sys/class/net/$i/wireless" ]; then
    label="Wireless"
  else
    case "$i" in
      tailscale*)          label="VPN";;
      docker*|br-*|virbr*) label="Bridge";;
      veth*)               label="Virtual";;
      en*|eth*)            label="Wired";;
      *)                   label="Other";;
    esac
  fi
  ip=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd, -)
  printf "%-11s %-9s %s\n" "$i" "$label" "${ip:-not connected}"
done
