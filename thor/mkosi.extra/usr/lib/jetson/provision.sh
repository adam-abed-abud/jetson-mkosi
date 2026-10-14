#!/bin/sh
# Apply per-device configuration handed in as systemd credentials.
#
# One image serves many devices: the values arrive as .cred files on the ESP,
# written after flashing, and are never baked into the image. Each is optional,
# and nothing here overwrites a file that already exists, so a device keeps
# whatever it was given on its first boot.

set -eu

# Read the files straight off the ESP rather than through ImportCredential=.
# systemd-stub classes anything it finds there as untrusted, because nothing
# signs or measures it without Secure Boot and a TPM, and a unit importing an
# untrusted credential fails with 243/CREDENTIALS. Revisit if the Jetson ever
# gets its fTPM provisioned.
creds=/efi/loader/credentials
[ -d "$creds" ] || creds="${CREDENTIALS_DIRECTORY:-/nonexistent}"

cred() { printf '%s/%s.cred' "$creds" "$1"; }

if [ -s "$(cred jetson.hostname)" ] && [ ! -e /etc/hostname ]; then
    install -m0644 "$(cred jetson.hostname)" /etc/hostname
    # Also apply it now; systemd read /etc/hostname long before this ran.
    hostname "$(cat /etc/hostname)"
fi

# Sorts before the built-in 10-ethernet.network, and networkd uses the first
# matching file, so this wins where it is supplied.
if [ -s "$(cred jetson.network)" ] && [ ! -e /etc/systemd/network/05-device.network ]; then
    mkdir -p /etc/systemd/network
    install -m0644 "$(cred jetson.network)" /etc/systemd/network/05-device.network
fi

if [ -s "$(cred ssh.authorized_keys.ubuntu)" ]; then
    mkdir -p /home/ubuntu/.ssh
    install -m0600 -o ubuntu -g ubuntu \
        "$(cred ssh.authorized_keys.ubuntu)" /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 0700 /home/ubuntu/.ssh
fi
