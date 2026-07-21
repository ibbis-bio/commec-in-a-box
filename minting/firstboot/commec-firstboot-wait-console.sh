#!/usr/bin/env bash
# Full-screen console notice on tty1 while first-boot unpacks the databases, so the operator
# sees a branded "setting up" screen with progress instead of a bare login prompt (the desktop
# is not up this early). Exits when the first-boot guard appears; getty/desktop then take over.
set -u
GUARD=/var/lib/commec/firstboot.done
DBROOT=/home/commec-user/commec-dbs
TOTAL_GB=31           # approx fully-unpacked DB size (best_match ~30 GiB + the small DBs), for a rough progress estimate
BAR_W=34
O=$'\033[38;5;202m'; B=$'\033[48;5;17m'; R=$'\033[0m'   # IBBIS orange fg, deep-blue bg, reset
spin='-\|/'; i=0; start=$(date +%s); used_gb=0

# Kernel console spam (e.g. "pcieport spurious native interrupt!") writes straight to the
# console and would shred this screen. Quiet the console log level while we own tty1, and
# restore it (plus the cursor) on exit.
OLD_PRINTK=$(cut -f1 /proc/sys/kernel/printk 2>/dev/null)
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true
trap 'printf "\033[?25h"; [ -n "${OLD_PRINTK:-}" ] && echo "$OLD_PRINTK" > /proc/sys/kernel/printk 2>/dev/null || true' EXIT

# The default Lat15 console font lacks half-blocks (renders them as '#'); load the bundled CP437
# font that has the full block set so the COMMEC/IBBIS art + logo render correctly.
setfont /usr/local/share/commec/console8x16.psf.gz 2>/dev/null || setfont default8x16 2>/dev/null || true
printf '\033[?25l\033[2J\033[H'   # hide cursor, clear, home
cat <<BANNER
 ██████╗ ██████╗ ███╗   ███╗███╗   ███╗███████╗ ██████╗ ${O}         ▄▄               ${R}
██╔════╝██╔═══██╗████╗ ████║████╗ ████║██╔════╝██╔════╝ ${O}       ▄███▌              ${R}
██║     ██║   ██║██╔████╔██║██╔████╔██║█████╗  ██║      ${O}      ▐█████              ${R}
██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██╔══╝  ██║      ${O}     ▐██████▌             ${R}
╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║███████╗╚██████╗ ${O}     ███████▌             ${R}
 ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝╚══════╝ ╚═════╝ ${O}    ▐███████▌             ${R}
${B}█ █████▄ █████▄ █ ▄█▀█▄                                 ${O}     ███████   ▄█▄      ${R}
${B}█ █    █ █    █ █ █   ▀          DATABASE               ${O}      █████▌  ▄███▄▄     ${R}  
${B}█ █████▄ █████▄ █ ▀███▄            SETUP                ${O}      ▐█████▄██▀    ▀▄    ${R}   
${B}█ █    █ █    █ █ ▄   █              UTILITY            ${O}      ▐████████       ▌  ${R}
${B}█ █████▀ █████▀ █ ▀█▄█▀                                 ${O}      ████████▀         ${R}
                                                        ${O}   ▄▄██████▀▀             ${R}
                                                        ${O} ▀▀                       ${R}
BANNER
cat <<'MSG'

   Unpacking databases - please wait...

MSG
while [ ! -e "$GUARD" ]; do
  if [ $(( i % 5 )) -eq 0 ]; then
    used_gb=$(du -sb "$DBROOT" 2>/dev/null | awk '{printf "%d",$1/1073741824}'); [ -z "$used_gb" ] && used_gb=0
  fi
  pct=$(( used_gb * 100 / TOTAL_GB )); [ "$pct" -gt 100 ] && pct=100
  el=$(( ( $(date +%s) - start ) / 60 ))
  c=${spin:$(( i % 4 )):1}; i=$(( i + 1 ))
  filled=$(( pct * BAR_W / 100 )); bar=''
  for ((k=0; k<filled; k++)); do bar+='#'; done
  for ((k=filled; k<BAR_W; k++)); do bar+='.'; done
  printf '\r\033[K   [%s] %3d%%    ~%d / %d GB    up %dm   %s' "$bar" "$pct" "$used_gb" "$TOTAL_GB" "$el" "$c"
  sleep 2
done
printf '\r\033[K\033[?25h\n\n   Setup complete - starting the desktop...\n'
sleep 2
