#!/usr/bin/env bash
# Install the first-boot service (uploaded to /tmp/firstboot) and enable it.
set -euxo pipefail

install -m 0755 /tmp/firstboot/commec-firstboot.sh /usr/local/sbin/commec-firstboot.sh
install -m 0644 /tmp/firstboot/commec-firstboot.service /etc/systemd/system/commec-firstboot.service

mkdir -p /var/lib/commec
rm -f /var/lib/commec/firstboot.done    # ensure it runs on the deployed box

systemctl enable commec-firstboot.service
echo "90-firstboot-install done"
