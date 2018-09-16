#!/bin/sh
set -eux

if [ "$(id -u)" != "0" ]; then
	echo "Re-executing as root"
	exec su root -c "/bin/sh $0"
fi

# This may be run in build instance or actual instance, don't care. It's only here to allow Internet access
# from jails later. Starting pf first so we don't lose the SSH connection later in the setup.

main_network_interface=unknown
for nic in vtnet0 xn0 em0; do
	if ifconfig "${nic}" >/dev/null 2>&1; then
		main_network_interface="${nic}"
		break
	fi
done

cat >/etc/pf.conf <<-EOF
	ext_if = "${main_network_interface}"

	# Common recommended pf rules
	set skip on lo0
	block drop in
	pass out on \$ext_if

	# Don't lock ourselves out from SSH
	pass in on \$ext_if proto tcp to \$ext_if port 22

	# Allow web access
	pass in on \$ext_if proto tcp to \$ext_if port 80
EOF

sysrc pf_enable=YES
service pf start
