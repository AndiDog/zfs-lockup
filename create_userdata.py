#!/usr/bin/env python3
def escape(script):
    return script.replace(b'\\', b'\\\\').replace(b'$', b'\\$').replace(b'`', b'\\`')


with open('ssh/id_rsa_zfslockuptest.pub', 'rb') as f:
    ssh_pubkey = f.read()
with open('http/installerconfig_zfs', 'rb') as f:
    installer_config_script = f.read()
with open('scripts/all.sh', 'rb') as f:
    all_script = f.read()
with open('userdata.sh.template', 'rb') as f:
    tmpl = f.read()

with open('tmp/userdata.sh', 'wb') as out:
    out.write(
        tmpl
            .replace(b'%%SSH_PUBKEY%%', ssh_pubkey)
            .replace(b'%%ZFSINSTALL_SCRIPT%%', escape(installer_config_script))
            .replace(b'%%ALL_SCRIPT%%', escape(all_script))
    )
