#!/bin/sh
set -eux

: "${AWSPHASE:=}"

# Currently hardcoded here, please decide which one you want
VARIANT=jailed-poudriere

echo "VARIANT=${AWSPHASE} AWSPHASE=${AWSPHASE}"

setup_basics() {
	# Set the time
	if [ -z "${AWSPHASE}" ]; then
		ntpdate -v -b de.pool.ntp.org
	fi

	env ASSUME_ALWAYS_YES=true pkg bootstrap -fy
	pkg install -y bash sudo
	echo 'fdescfs		/dev/fd		fdescfs	rw,late	0	0' >>/etc/fstab # for bash

	# Configure `sudo` to allow all users in wheel group without password
	echo '%wheel ALL=(ALL) NOPASSWD: ALL' >/usr/local/etc/sudoers.d/wheel
	chmod 0440 /usr/local/etc/sudoers.d/wheel

	# Create user "dev" with password "dev"
	pw groupadd dev
	pw useradd -n dev -g dev -G wheel -m -M 0755 -w yes -s /usr/local/bin/bash

	touch /root/.hushlogin
	touch /home/dev/.hushlogin
	sed -i '' '/\/usr\/bin\/fortune/d' /home/dev/.profile

	sysrc hostname=zfslockuptest
	hostname zfslockuptest
}

if [ "${VARIANT}" = "poudriere" ]; then

	if [ "${AWSPHASE}" = "0" ]; then
		exit 0
	fi

	setup_basics

	pkg install -y poudriere
	mkdir -p /pdr /var/cache/ccache /var/ports/distfiles
	ln -sfh /pdr /usr/local/poudriere

	cat >/usr/local/etc/poudriere.conf <<-EOF
		ZPOOL=zroot
		ZROOTFS=/poudriere
		FREEBSD_HOST=ftp://ftp.freebsd.org
		RESOLV_CONF=/etc/resolv.conf
		BASEFS=/pdr
		USE_PORTLINT=no
		USE_TMPFS=yes
		DISTFILES_CACHE=/var/ports/distfiles
		PKG_REPO_SIGNING_KEY=
		CCACHE_DIR=/var/cache/ccache
		PARALLEL_JOBS=3
		PREPARE_PARALLEL_JOBS=3
		NOLINUX=yes
	EOF

	cat >>/etc/make.conf <<-EOF
		WRKDIRPREFIX=/var/ports
		DISTDIR=/var/ports/distfiles
		PACKAGES=/var/ports/packages
		INDEXDIR=/var/ports
	EOF

	poudriere jail -c -j 112amd64 -v 11.2-RELEASE -a amd64

	poudriere ports -c -B branches/2018Q3 -m svn+https

	pkg install -y nginx

	cat >/usr/local/etc/nginx/nginx.conf <<-EOF
		worker_processes  1;

		events {
		    worker_connections  1024;
		}

		http {
		    include       mime.types;
		    default_type  application/octet-stream;
		    sendfile        on;
		    keepalive_timeout  65;
		    gzip on;
		    server {
		        listen       80;
		        server_name  localhost;
		        index        index.html;

		        location / {
		            root /usr/local/www/nginx;
		            index index.html index.htm;
		        }

		        location /buildbot/ {
		            proxy_pass http://10.0.0.2:8010/;
		        }
		        location /buildbot/sse/ {
		            # proxy buffering will prevent sse to work
		            proxy_buffering off;
		            proxy_pass http://10.0.0.2:8010/sse/;
		        }
		        # required for websocket
		        location /buildbot/ws {
		            proxy_http_version 1.1;
		            proxy_set_header Upgrade \$http_upgrade;
		            proxy_set_header Connection "upgrade";
		            proxy_pass http://10.0.0.2:8010/ws;
		            # raise the proxy timeout for the websocket
		            proxy_read_timeout 6000s;
		        }

		        location /pdr {
		            include mime.types;
		            types {
		                text/plain log;
		            }

		        alias /pdr/data/logs/bulk/;
		            index index.html index.htm;
		            autoindex on;
		        }
		        location /packages {
		            alias /pdr/data/packages/;
		            autoindex on;
		        }

		        error_page   500 502 503 504  /50x.html;
		        location = /50x.html {
		            root   /usr/local/www/nginx-dist;
		        }
		    }
		}
	EOF

	sysrc nginx_enable=YES
	if [ -z "${AWSPHASE}" ]; then
		service nginx start
	fi

elif [ "${VARIANT}" = "jailed-poudriere" ]; then

	if [ -z "${AWSPHASE}" ] || [ "${AWSPHASE}" = "0" ]; then
		zfs create zroot/usr/jails
		zfs create zroot/usr/jails/buildbot-master
		zfs create zroot/usr/jails/buildbot-worker0

		# Create jailed ZFS filesystem for poudriere in jail (poudriere itself will create child filesystems).
		# Before FreeBSD 12, mount path length is still restricted to 88 chars, so use a short name.
		zfs create zroot/pdr
		zfs create -o mountpoint=none -o jailed=on zroot/pdr/w0

		main_network_interface=unknown
		for nic in vtnet0 xn0 em0; do
			if ifconfig "${nic}" >/dev/null 2>&1; then
				main_network_interface="${nic}"
				break
			fi
		done

		cat >/etc/pf.conf <<-EOF
			ext_if = "${main_network_interface}"

			jail_if = "lo1" # the interface we chose for communication between jails

			# Allow jails to access Internet via NAT, but avoid NAT within same network so
			# jails can communicate with each other
			nat on \$ext_if inet from (\$jail_if:network) to ! (\$jail_if:network) -> \$ext_if:0
			# Only needed if you use a public IPv6 address:
			#nat on \$ext_if inet6 from (\$jail_if:network) to ! (\$jail_if:network) -> \$ext_if:0

			# No restrictions on jail network
			set skip on \$jail_if

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
		pfctl -vf /etc/pf.conf

		if [ -n "${AWSPHASE}" ]; then
			cp /etc/pf.conf /mnt/etc/pf.conf
			sysrc -f /mnt/etc/rc.conf pf_enable=YES

			exit 0
		fi
	fi

	setup_basics

	sysrc cloned_interfaces+=lo1
	service netif cloneup
	ifconfig lo1

	pkg install -y ca_root_nss
	fetch -o /tmp/base.txz "https://download.freebsd.org/ftp/releases/amd64/11.2-RELEASE/base.txz"

	cat >/etc/jail.buildbot-master.conf <<-EOF
		buildbot-master {
		    host.hostname = buildbot-master.localdomain;
		    ip4.addr = "lo1|10.0.0.2/24";
		    path = "/usr/jails/buildbot-master";
		    exec.start = "/bin/sh /etc/rc";
		    exec.stop = "/bin/sh /etc/rc.shutdown";
		    mount.devfs; # need /dev/*random for Python
		    persist;
		}
	EOF
	sysrc "jail_list+=buildbot-master"
	tar -x -f /tmp/base.txz -C /usr/jails/buildbot-master
	cp /etc/resolv.conf /usr/jails/buildbot-master/etc/resolv.conf

	cat >/etc/jail.buildbot-worker0.conf <<-EOF
		buildbot-worker0 {
		    host.hostname = buildbot-worker0.localdomain;
		    ip4.addr = lo1|10.0.0.3/24, lo0|127.0.0.140;
		    ip6.addr = lo0|::8c;
		    path = "/usr/jails/buildbot-worker0";
		    exec.start = "/bin/sh /etc/rc";
		    exec.stop = "/bin/sh /etc/rc.shutdown";
		    mount.devfs; # need /dev/*random for Python

		    # jailed poudriere requirements
		    exec.prestart = "/sbin/kldload nullfs";
		    allow.chflags;
		    allow.mount;
		    allow.mount.devfs;
		    allow.mount.nullfs;
		    allow.mount.procfs;
		    allow.mount.zfs;
		    allow.raw_sockets;
		    allow.socket_af;
		    allow.sysvipc;
		    children.max=16;
		    enforce_statfs=1;

		    persist;
		}
	EOF
	sysrc "jail_list+=buildbot-worker0"
	tar -x -f /tmp/base.txz -C /usr/jails/buildbot-worker0
	cp /etc/resolv.conf /usr/jails/buildbot-worker0/etc/resolv.conf

	sudo sysrc jail_enable=YES
	service jail start
	jls

	# TODO actual buildbot setup yet missing because I first want to check if jailed poudriere is a strong trigger
	#      for the ZFS interlock issue

	pkg -j buildbot-worker0 install -y poudriere

	mkdir -p \
		/usr/jails/buildbot-worker0/pdr \
		/usr/jails/buildbot-worker0/var/cache/ccache \
		/usr/jails/buildbot-worker0/var/ports/distfiles
	ln -sfh /pdr /usr/jails/buildbot-worker0/usr/local/poudriere

	cat >/usr/jails/buildbot-worker0/usr/local/etc/poudriere.conf <<-EOF
		ZPOOL=zroot
		ZROOTFS=/pdr/w0
		FREEBSD_HOST=ftp://ftp.freebsd.org
		RESOLV_CONF=/etc/resolv.conf
		BASEFS=/pdr
		USE_PORTLINT=no
		USE_TMPFS=no
		DISTFILES_CACHE=/var/ports/distfiles
		PKG_REPO_SIGNING_KEY=
		CCACHE_DIR=/var/cache/ccache
		PARALLEL_JOBS=4
		PREPARE_PARALLEL_JOBS=8
		NOLINUX=yes
		LOIP4=127.0.0.140
		LOIP6=::8c
	EOF

	cat >>/usr/jails/buildbot-worker0/etc/make.conf <<-EOF
		# poudriere
		WRKDIRPREFIX=/var/ports
		DISTDIR=/var/ports/distfiles
		PACKAGES=/var/ports/packages
		INDEXDIR=/var/ports
	EOF

	jexec buildbot-worker0 poudriere jail -c -j 112amd64 -v 11.2-RELEASE -a amd64

	jexec buildbot-worker0 poudriere ports -c -B branches/2018Q3 -m svn+https

	pkg install -y nginx

	cat >/usr/local/etc/nginx/nginx.conf <<-EOF
		worker_processes  1;

		events {
		    worker_connections  1024;
		}

		http {
		    include       mime.types;
		    default_type  application/octet-stream;
		    sendfile        on;
		    keepalive_timeout  65;
		    gzip on;
		    server {
		        listen       80;
		        server_name  localhost;
		        index        index.html;

		        location /pdr {
		            include mime.types;
		            types {
		                text/plain log;
		            }

		            alias /usr/jails/buildbot-worker0/pdr/data/logs/bulk/;
		            index index.html index.htm;
		            autoindex on;
		        }
		        location /packages {
		            alias /usr/jails/buildbot-worker0/pdr/data/packages/;
		            autoindex on;
		        }

		        error_page   500 502 503 504  /50x.html;
		        location = /50x.html {
		            root   /usr/local/www/nginx-dist;
		        }
		    }
		}
	EOF

	# buildbot BEGIN
	pkg -j buildbot-master install -y git-lite py36-buildbot py36-buildbot-www sudo
	jexec buildbot-master sh -e <<-EOF
		pw useradd -n buildbot-master -m -w random
		mkdir /var/buildbot-master
		chown buildbot-master:buildbot-master /var/buildbot-master
		sudo -u buildbot-master buildbot create-master /var/buildbot-master

		# Basic config, will be replaced below
		sudo -u buildbot-master cp /var/buildbot-master/master.cfg.sample /var/buildbot-master/master.cfg
		sed -i '' 's/example-worker/worker0/' /var/buildbot-master/master.cfg

		sysrc buildbot_basedir=/var/buildbot-master
		sysrc buildbot_user=buildbot-master
		# using onestart to reproduce the problem, else it would be: sysrc buildbot_enable=YES
	EOF
	pkg -j buildbot-worker0 install -y git-lite py36-buildbot-worker sudo
	jexec buildbot-worker0 sh -e <<-EOF
		pw useradd -n buildbot-worker -m -w random
		mkdir /var/buildbot-worker
		chown buildbot-worker:buildbot-worker /var/buildbot-worker
		sudo -u buildbot-worker buildbot-worker create-worker /var/buildbot-worker 10.0.0.2 worker0 'pass'
		sysrc buildbot_worker_basedir=/var/buildbot-worker
		sysrc buildbot_worker_uid=buildbot-worker
		sysrc buildbot_worker_gid=buildbot-worker
		sysrc buildbot_worker_enable=YES
		# https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=227675
		sed -i '' 's|command="/usr/local/bin/twistd"|command="/usr/local/bin/twistd-3.6"|' /usr/local/etc/rc.d/buildbot-worker
	EOF

	cat >/usr/jails/buildbot-master/var/buildbot-master/master.cfg <<-EOF
		from buildbot.plugins import *
		c = BuildmasterConfig = {}
		c['workers'] = [worker.Worker('worker0', 'pass')]
		c['protocols'] = {'pb': {'port': 9989}}
		c['change_source'] = []
		c['change_source'].append(changes.GitPoller(
		    'git://github.com/buildbot/hello-world.git',
		    workdir='gitpoller-workdir', branch='master', pollInterval=300))
		c['builders'] = []
		factory = util.BuildFactory()
		factory.addStep(steps.ShellCommand(command=['true']))
		for i in range(500):
		    c['builders'].append(
		        util.BuilderConfig(name=f'runtests-{i}', workernames=['worker0'], factory=factory))
		c['schedulers'] = []
		c['schedulers'].append(
		    schedulers.Nightly(
		        name=f'sched-regular',
		        onlyIfChanged=False,
		        hour='0',
		        minute='0',

		        builderNames=[bldr.name for bldr in c['builders']]))
		c['buildbotNetUsageData'] = None # not representative :D
	EOF

	# buildbot END

	for name in $(jls name); do
		pkg -j "$name" install -y bash screen vim-console
	done

	sysrc nginx_enable=YES
	if [ -z "${AWSPHASE}" ]; then
		service nginx start
		jexec buildbot-master service buildbot start
		jexec buildbot-worker0 service buildbot-worker start
	else
		service jail stop

		for m in \
				/mnt/usr/jails/buildbot-master/dev \
				/mnt/usr/jails/buildbot-master \
				/mnt/usr/jails/buildbot-worker0/dev \
				/mnt/usr/jails/buildbot-worker0 \
		; do
			if mount | grep -qF "$m"; then umount "$m"; fi
		done
	fi

	# buildbot master startup is enough to reproduce ZFS lockup
	sysrc "jail_list-=buildbot-worker0"

else

	>&2 echo "Invalid VARIANT"
	exit 1

fi

# -----------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------

pkg install -y screen vim-console
