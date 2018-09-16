#!/bin/sh
set -eux

if [ "$(id -u)" != "0" ]; then
	echo "Re-executing as root"
	exec su root -e -c "/bin/sh $0"
fi

test -s /home/packer/installerconfig

# Dist tarballs not included in standard FreeBSD AMI, so download them
mkdir -p /usr/freebsd-dist
# This fails if not using `ssh -t` i.e. terminal output (it's an ncurses UI)
#     env BSDINSTALL_DISTSITE='ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/11.2-RELEASE' \
#         DISTRIBUTIONS='base.txz kernel.txz lib32.txz' \
#         bsdinstall distfetch
# so we use the simplest workaround:
(
	cd /usr/freebsd-dist
	for t in base.txz kernel.txz lib32.txz; do
		fetch -o "$t" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/11.2-RELEASE/$t"
	done
)

bsdinstall script /home/packer/installerconfig


# Up to this point, this setup only creates a generic FreeBSD AMI on ZFS (however misses some typically required things
# like ec2-user in favor of simple password access). It's getting more specific here:

zpool import -N -R /mnt zroot # the one we just set up on second device
zfs mount zroot/ROOT/default # must be explicit because of noauto
zfs mount -a
sed -i '' 's|/dev/xbd1|/dev/ada0|g' /mnt/etc/fstab # fix wrong swap entry
test -s /home/packer/all.sh
cp /home/packer/all.sh /mnt/var/all.sh
chmod +x /mnt/var/all.sh

# Some stuff can't be done in chroot (like `zfs create`), so use two phases ^^
env AWSPHASE=0 /home/packer/all.sh
chroot /mnt /usr/bin/env AWSPHASE=1 /var/all.sh

rm /mnt/var/all.sh
zpool export zroot
