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

# Networking portability: the build VM NIC (ens3) differs from the target's (eno1),
# and the cloud image's per-interface config won't carry over. Hand networking to
# NetworkManager (DHCP on whatever NIC the target has). ENABLE ONLY - do not restart
# now, or we'd drop Packer's SSH; this takes effect on the target's first boot.
# wpasupplicant is a *Recommends* of network-manager, so --no-install-recommends drops it -
# and without it NM cannot operate ANY WiFi radio (the device shows "unavailable"). Add it
# explicitly so WiFi works on the metal box.
apt-get install -y --no-install-recommends network-manager wpasupplicant rfkill iw
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
