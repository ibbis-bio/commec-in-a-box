#!/usr/bin/env bash
# Install the first-boot service (uploaded to /tmp/firstboot) and enable it.
set -euxo pipefail

install -m 0755 /tmp/firstboot/commec-firstboot.sh /usr/local/sbin/commec-firstboot.sh
install -m 0644 /tmp/firstboot/commec-firstboot.service /etc/systemd/system/commec-firstboot.service

# Console progress notice: replaces the bare tty1 login prompt with a "do not power off"
# screen + spinner/progress while the DBs unpack (the desktop is not up this early).
install -m 0755 /tmp/firstboot/commec-firstboot-wait-console.sh /usr/local/sbin/commec-firstboot-wait-console.sh
install -m 0644 /tmp/firstboot/commec-firstboot-console.service /etc/systemd/system/commec-firstboot-console.service

mkdir -p /var/lib/commec
rm -f /var/lib/commec/firstboot.done    # ensure it runs on the deployed box

systemctl enable commec-firstboot.service
systemctl enable commec-firstboot-console.service
echo "90-firstboot-install done"
