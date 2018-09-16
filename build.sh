#!/usr/bin/env bash
set -e

error() {
	>&2 echo "$@"
	exit 1
}

[ -e build.sh ] || error "ERROR: Wrong directory"

# Allow comments by using YAML format (only JSON without comments supported, see https://github.com/hashicorp/packer/issues/1768)
python3 -c '
import json, os, yaml
cfg = yaml.load(open("Packerfile.yml"))
print(json.dumps(cfg))
' >/tmp/Packerfile

packer fix /tmp/Packerfile >/tmp/Packerfile-fixed
if ! diff -u <(jq -S . /tmp/Packerfile) <(jq -S . /tmp/Packerfile-fixed); then
	error "Found differences from running 'packer fix'. Please first fix them (see diff above)."
fi

if [ -z "$BUILDER" ]; then
	if [ x"$(uname)" = x"Darwin" ]; then
		: "${BUILDER:=vmware-iso}"
	else
		: "${BUILDER:=qemu}"
	fi
fi

mkdir -p tmp
rm -f tmp/userdata.sh
./create_userdata.py

: "${ON_ERROR:=ask}"
packer build -on-error="$ON_ERROR" -only="$BUILDER" /tmp/Packerfile
