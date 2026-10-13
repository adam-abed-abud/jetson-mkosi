#!/bin/bash
# Make sure this machine's kernel can execute aarch64 binaries, then run
# whatever command the caller asked for.
#
# Why this is needed: we are building an arm64 root filesystem on an x86-64
# machine. Installing a .deb is not just unpacking files -- dpkg runs each
# package's maintainer scripts (preinst, postinst), and for an arm64 package
# those scripts invoke arm64 programs. The kernel's binfmt_misc subsystem can be
# told to hand any arm64 executable to the qemu-aarch64 emulator, which makes
# those scripts run transparently.
#
# binfmt_misc registrations belong to the kernel, so they are shared by the host
# and every container on it. If the host already has one -- Docker Desktop and
# the tonistiigi/binfmt image both install one -- we use it untouched. Otherwise
# we register the emulator shipped in this image, using the registration file
# that the qemu-user package provides.
#
# The "F" flag in that registration is the important part: it tells the kernel
# to open the emulator binary once, at registration time, and hold that open
# file. Without it the emulator binary would have to be present inside every
# chroot that mkosi enters.

set -euo pipefail

readonly BINFMT_DIR=/proc/sys/fs/binfmt_misc
readonly BINFMT_CONF=/usr/share/qemu/binfmt.d/qemu-aarch64.conf

if [[ ! -e $BINFMT_DIR/status ]]; then
    mount -t binfmt_misc binfmt_misc "$BINFMT_DIR" 2>/dev/null || {
        echo "entrypoint: binfmt_misc is unavailable; run this container with --privileged" >&2
        exit 1
    }
fi

if [[ -e $BINFMT_DIR/qemu-aarch64 ]]; then
    echo "entrypoint: using the aarch64 binfmt handler already registered on this machine"
elif [[ -r $BINFMT_CONF ]]; then
    echo "entrypoint: registering an aarch64 binfmt handler"
    tr -d '\n' < "$BINFMT_CONF" > "$BINFMT_DIR/register"
else
    echo "entrypoint: no aarch64 binfmt handler and no registration file to install one" >&2
    exit 1
fi

exec "$@"
