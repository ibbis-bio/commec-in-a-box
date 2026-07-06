#!/usr/bin/env bash
# Install the first-boot service (uploaded to /tmp/firstboot) and enable it.
set -euxo pipefail

install -m 0755 /tmp/firstboot/commec-firstboot.sh /usr/local/sbin/commec-firstboot.sh
install -m 0644 /tmp/firstboot/commec-firstboot.service /etc/systemd/system/commec-firstboot.service

# Console progress notice: replaces the bare tty1 login prompt with a "do not power off"
# screen + spinner/progress while the DBs unpack (the desktop is not up this early).
install -m 0755 /tmp/firstboot/commec-firstboot-wait-console.sh /usr/local/sbin/commec-firstboot-wait-console.sh
install -m 0644 /tmp/firstboot/commec-firstboot-console.service /etc/systemd/system/commec-firstboot-console.service

# Console font with the full block/half-block set the banner art needs. The default Lat15
# console font has only the full block, so half-blocks (the IBBIS mark + logo) render as '#';
# this CP437 8x16 font has them all. The wait-console script setfonts it before drawing.
install -d /usr/local/share/commec
install -m 0644 /tmp/assets/commec-console8x16.psf.gz /usr/local/share/commec/console8x16.psf.gz

mkdir -p /var/lib/commec
rm -f /var/lib/commec/firstboot.done    # ensure it runs on the deployed box

systemctl enable commec-firstboot.service
systemctl enable commec-firstboot-console.service
echo "90-firstboot-install done"
