#!/bin/sh
set -e

# -----------------------------------------------------------------
# Basics
# -----------------------------------------------------------------

# Set the time
ntpdate -v -b de.pool.ntp.org || >&2 echo "Failed to set time, probably already running NTP"

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
hostname=zfslockuptest

# -----------------------------------------------------------------
# poudriere
# -----------------------------------------------------------------

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

cat >/usr/local/etc/nginx/nginx.conf <<EOF
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
service nginx start

# -----------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------

pkg install -y screen vim-console
