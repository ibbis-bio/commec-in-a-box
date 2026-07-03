#!/usr/bin/env bash
# Finalize the master image: tighten sudo, remove the build-only SSH key, disable
# cloud-init, and reset clone-unique identity (machine-id + SSH host keys). Runs last;
# the active Packer SSH session stays alive so shutdown still works.
set -euxo pipefail

# NOTE: sudo is NOT tightened here. commec-user must keep its build-time NOPASSWD so
# Packer's shutdown_command ('sudo shutdown') works. The deployed box is hardened to
# password-required sudo by the first-boot service (commec-firstboot.sh), which removes
# the cloud-init NOPASSWD grant on the target.

# Remove the build SSH key so the deployed box doesn't trust it.
truncate -s 0 /home/commec-user/.ssh/authorized_keys 2>/dev/null || true

# Disable cloud-init on the deployed box.
touch /etc/cloud/cloud-init.disabled
cloud-init clean --logs 2>/dev/null || true

# Clone hygiene: unique machine-id + SSH host keys are (re)generated on the target.
# (firstboot runs `ssh-keygen -A`; machine-id regenerates on boot when empty.)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

# Trim package caches.
apt-get clean
rm -rf /var/lib/apt/lists/*

# Bake the essential static device nodes into the image. The genericcloud base ships an EMPTY
# /dev and relies on devtmpfs at boot, leaving the image one lost mountpoint away from an
# unbootable "Attempted to kill init" panic (the initramfs init-handoff opens /root/dev/console).
# A bind-mount of / exposes the underlying on-disk /dev (the live /dev here is devtmpfs), so
# these nodes land in the image itself.
mount --bind / /mnt
mkdir -p /mnt/dev
[ -e /mnt/dev/console ] || mknod -m 600 /mnt/dev/console c 5 1
[ -e /mnt/dev/null ]    || mknod -m 666 /mnt/dev/null    c 1 3
umount /mnt

sync
echo "99-cleanup done"
