#!/usr/bin/env bash
# Base system: full hardware kernel for bare metal, UEFI grub, core tools,
# unattended security upgrades, console on the physical display.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update

# Generic kernel (the cloud base may ship the stripped 'cloud' kernel which lacks
# drivers the ThinkCentre needs - amdgpu, its NIC, etc.) + UEFI bootloader.
apt-get install -y --no-install-recommends \
  linux-image-amd64 \
  grub-efi-amd64 \
  zstd \
  cloud-guest-utils \
  gdisk parted \
  ca-certificates curl wget unzip rsync \
  unattended-upgrades

# Drop the cloud-optimised kernel now that the generic one is installed.
apt-get purge -y linux-image-cloud-amd64 || true
apt-get autoremove -y --purge || true

# Console: the cloud image defaults to serial-only; add the physical console so
# the operator sees boot on the monitor. Keep ttyS0 too for headless debugging.
if [ -f /etc/default/grub ]; then
  sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"/' /etc/default/grub
  # don't hide boot behind a splash
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
fi
update-grub

# Keep ttyS0 kernel output for headless VM diagnostics, but do not spawn an interactive login
# prompt there. Some bare-metal systems expose a non-functional legacy UART: opening /dev/ttyS0
# succeeds, then agetty's terminal setup fails and systemd restarts it indefinitely.
systemctl mask serial-getty@ttyS0.service

# Networking portability: the build VM NIC (ens3) differs from the target's (eno1),
# and the cloud image's per-interface config won't carry over. Hand networking to
# NetworkManager (DHCP on whatever NIC the target has). ENABLE ONLY - do not restart
# now, or we'd drop Packer's SSH; this takes effect on the target's first boot.
# wpasupplicant is a *Recommends* of network-manager, so --no-install-recommends drops it -
# and without it NM cannot operate ANY WiFi radio (the device shows "unavailable"). Add it
# explicitly so WiFi works on the metal box.
apt-get install -y --no-install-recommends network-manager wpasupplicant rfkill iw

# --- locales: worldwide deployment -> ship ALL precompiled locales so any operator region or
# forwarded SSH LC_* resolves with no "setlocale: cannot change locale" warning, and the box
# needs no per-locale regeneration. locales-all is the full archive (~200MB); locales provides
# update-locale for the default. ---
apt-get install -y --no-install-recommends locales locales-all
update-locale LANG=en_US.UTF-8

# --- CPU governor + power-safety CLOCK CAP (boot-time oneshot; no cpupower package) ---
# GOVERNOR: dedicated mains box -> 'performance' (max clocks, no ramp latency). amd-pstate-epp active
# mode exposes only performance/powersave; 'performance' pins max EPP. Override: CPU_GOVERNOR=powersave.
#
# *****************************************************************************************************
# *** CLOCK CAP (CPU_MAXFREQ_KHZ) - HARDWARE-DEPENDENT POWER-STABILITY MITIGATION - READ BEFORE SHIP ***
# *****************************************************************************************************
# The target ThinkCentre M75q Gen2 (Ryzen 5 PRO 5650GE) on its STOCK 65W slim-tip brick is
# power-marginal: under sustained all-core load the SoC draws ~58W (~89% of the 65W brick's rating),
# and in testing BOTH units hard-power-off intermittently (abrupt, NO thermal/MCE/shutdown log; temps
# stay ~76C safe -> it's a POWER brownout, not heat). Capping the max CPU frequency lowers peak draw
# back under the brick's ceiling and prevented the crashes in testing.
#   Default 3000000 kHz (3.0 GHz) -> ~2.64 GHz effective all-core -> ~0.72x throughput
#   (~85k -> ~61k seq/day; still ~12x over the 5k/day target, so this spends headroom we don't need).
#
#   >>> THIS CAP IS SPECIFIC TO THIS CPU + THIS 65W BRICK. Different hardware needs a different (or no) cap. <<<
#   Disable entirely (full boost):   build with CPU_MAXFREQ_KHZ=0   (or ='')
#   Change the ceiling:              build with CPU_MAXFREQ_KHZ=3500000  (higher = more throughput,
#                                    LESS power margin -> RE-TEST stability under sustained load if you raise it)
#   Preferred hardware fix:          fit a 90W brick, then disable the cap (CPU_MAXFREQ_KHZ=0). The cap is
#                                    the no-hardware-change option; the 90W brick is the supply-side option.
# See aws/box/power-failure-log.md for the full investigation + data.
# *****************************************************************************************************
GOV="${CPU_GOVERNOR:-performance}"
MAXFREQ="${CPU_MAXFREQ_KHZ-3000000}"   # ${var-default}: UNSET -> 3.0GHz cap; set to 0 or '' -> disabled
cat > /usr/local/sbin/commec-cpu-tune <<EOF
#!/bin/sh
# Baked at mint time by 00-base.sh. Pin governor + optional max-freq cap on every CPU.
GOV=${GOV}
MAXFREQ=${MAXFREQ}
EOF
cat >> /usr/local/sbin/commec-cpu-tune <<'EOF'
for c in /sys/devices/system/cpu/cpu*/cpufreq; do
  [ -w "$c/scaling_governor" ] && echo "$GOV" > "$c/scaling_governor"
  [ -n "$MAXFREQ" ] && [ "$MAXFREQ" != "0" ] && [ -w "$c/scaling_max_freq" ] && echo "$MAXFREQ" > "$c/scaling_max_freq"
done
EOF
chmod +x /usr/local/sbin/commec-cpu-tune
cat > /etc/systemd/system/commec-cpu-tune.service <<EOF
[Unit]
Description=Pin CPU governor ${GOV} + max-freq cap ${MAXFREQ:-none}kHz (screening appliance power safety)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/commec-cpu-tune

[Install]
WantedBy=multi-user.target
EOF
systemctl enable commec-cpu-tune.service

# --- Never suspend: a screening run is a long headless CPU job with no keyboard/mouse/GUI activity,
# and logind/desktop idle detection is session-based (NOT load-based), so the box would otherwise
# idle-suspend MID-SCREEN (observed during stress testing: box dropped off the network under full
# load). Mask every sleep target so nothing - logind, the XFCE power manager, or a stray
# `systemctl suspend` - can put a screening box to sleep. ---
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-commec-no-idle.conf <<'EOF'
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
EOF
mkdir -p /etc/NetworkManager/conf.d
printf '[main]\nplugins=keyfile\n' >/etc/NetworkManager/conf.d/10-plugins.conf
# Remove cloud per-iface configs and stop cloud-init from rewriting netcfg next boot.
rm -f /etc/network/interfaces.d/* 2>/dev/null || true
mkdir -p /etc/cloud/cloud.cfg.d
printf 'network: {config: disabled}\n' >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
systemctl enable NetworkManager
systemctl disable systemd-networkd 2>/dev/null || true

# Security-only unattended upgrades.
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades || true

echo "00-base done"
