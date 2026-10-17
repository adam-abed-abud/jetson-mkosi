#!/usr/bin/env bash
# Boot a built image under an emulated generic arm64 machine, and print what the
# firmware and the kernel say on the way up.
#
# This is not a substitute for booting on a Jetson. QEMU's 'virt' machine has
# none of Thor's hardware: no Tegra PCIe controller, no NVMe behind it, no GPU.
# What it does have is UEFI firmware and a disk, which is enough to answer the
# questions that come before any of that:
#
#   Does the firmware find the EFI system partition and run the boot manager?
#   Does the boot manager find the unified kernel image and start it?
#   Is the unified kernel image well formed -- does its embedded initramfs get
#     handed to the kernel?
#   Does the kernel start, mount the root filesystem, and reach a login prompt?
#
# A failure in any of those would also be a failure on a Thor, and finding one
# here costs five minutes instead of a trip to the bench.
#
# Two notes on what you will see. The kernel prints to ttyAMA0, the serial port
# this emulated machine has; on a Thor it prints to ttyUTC0 instead, and both
# are on the kernel command line for that reason. And the kernel reports
# "Generating empty DTB", because QEMU hands it no device tree; a Thor's
# firmware supplies a real one.
#
# The first argument is usually the built image file, but a block device works
# just as well -- the flashed drive, attached over USB. Booting the drive rather
# than the image answers a question the image cannot: whether the flash actually
# landed. Writes go to a throwaway overlay, so the drive is only ever read.
#
# There are two modes, and they exist for different jobs. By default this is a
# test: the console goes to a logfile, the script watches it for a login prompt,
# and it stops and reports as soon as one appears, so it has an answer and an
# exit status. With --console the same machine boots with its serial port
# attached to your terminal instead, so you can log in and look around; that
# mode never returns on its own, because a session is the point of it.
#
# Usage: scripts/qemu-boot.sh [--console] [image-or-device] [seconds] [logfile]

set -uo pipefail

CONSOLE=0
if [[ ${1:-} == --console ]]; then
    CONSOLE=1
    shift
fi

IMAGE="${1:-thor/mkosi.output/jetson-thor.raw}"
SECONDS_TO_RUN="${2:-600}"
LOG="${3:-thor/mkosi.output/qemu-boot.log}"

if [[ ! -e $IMAGE ]]; then
    echo "qemu-boot.sh: $IMAGE does not exist. Build it first with 'just build'." >&2
    exit 1
fi

# UEFI keeps its variables in a writable firmware volume, so it needs a copy of
# its own rather than the read-only one the package ships.
vars=$(mktemp /tmp/AAVMF_VARS.XXXXXX.fd)
cp /usr/share/AAVMF/AAVMF_VARS.fd "$vars"

# Present a disk larger than the image, the way a flashed drive is. The image
# ends where its last partition does, so booting it directly leaves no free
# space and systemd-repart cannot create the partition it makes on first boot.
# A qcow2 overlay keeps the image itself untouched.
disk=$(mktemp /tmp/qemu-disk.XXXXXX.qcow2)
qemu-img create -q -f qcow2 -b "$(realpath "$IMAGE")" -F raw "$disk" "${QEMU_DISK:-16G}"

trap 'rm -f "$vars" "$disk"' EXIT

# cortex-a72 rather than the newest CPU model: emulating fewer optional
# instruction set features is considerably faster when there is no hardware
# virtualisation to fall back on, which there is not on an x86-64 host.
#
# Both modes boot exactly the same machine. Only the serial port differs, so the
# arguments live in one place rather than in two lists that could drift apart.
# Networking. The image runs sshd and configures DHCP, so a NIC here means the
# emulated machine can be reached over SSH as well as over its serial console --
# which matters because the kernel and the login prompt share that serial port,
# and kernel messages scroll past whatever you are typing. In console mode the
# guest's port 22 is forwarded so you can get a clean shell from another
# terminal. The forward is deliberately not set up in test mode: two test runs
# at once would collide on the same host port.
netdev="user,id=net0"
if [[ $CONSOLE -eq 1 ]]; then
    # 0.0.0.0 rather than an empty host address: this normally runs inside the
    # build container, and a forward bound to the container's loopback cannot be
    # reached from the machine you are sitting at.
    netdev="$netdev,hostfwd=tcp:0.0.0.0:${SSH_PORT:-2222}-:22"
fi

machine=(
    -machine virt
    -cpu "${QEMU_CPU:-cortex-a72}"
    -smp "${QEMU_SMP:-4}"
    -m "${QEMU_MEM:-4096}"
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd
    -drive if=pflash,format=raw,file="$vars"
    -drive if=none,id=disk0,format=qcow2,file="$disk"
    -device virtio-blk-pci,drive=disk0,bootindex=0
    -device virtio-rng-pci
    -netdev "$netdev"
    -device virtio-net-pci,netdev=net0
    -display none
)

# The console session. 'mon:stdio' puts the serial port on this terminal and the
# QEMU monitor behind the Ctrl-A escape, which is how you get back out again.
if [[ $CONSOLE -eq 1 ]]; then
    echo "Booting $IMAGE with its console on this terminal."
    echo "Log in as ubuntu / ubuntu. Press Ctrl-A then X to quit."
    echo "This is emulation with no hardware acceleration, so the boot is slow."
    echo
    echo "The kernel writes to this console too, so its messages scroll past the"
    echo "login prompt. They do not eat keystrokes -- log in anyway, then run"
    echo "'sudo dmesg -n 1' to quieten the console; the journal keeps everything."
    echo
    echo "Expect a couple of 'NVRM: No NVIDIA GPU found' lines: this machine has"
    echo "no GPU, so nvidia.ko cannot initialise and nvidia-display-load.service"
    echo "fails. That is correct here. A stream of them rather than a couple is"
    echo "not, and means the modprobe guard in nvidia-display.conf has been lost."
    echo
    echo "Or skip this console altogether -- from another terminal, once the"
    echo "machine is up, 'ssh -p ${SSH_PORT:-2222} ubuntu@localhost' gives you a"
    echo "shell with nothing else writing to it."
    # The image ships no passwords. This hands one to the VM over SMBIOS,
    # which systemd accepts as a trusted credential, so console login works
    # here and nowhere else.
    qemu-system-aarch64 "${machine[@]}" -serial mon:stdio \
        -smbios type=11,value=io.systemd.credential:passwd.plaintext-password.ubuntu=ubuntu
    exit $?
fi

echo "Booting $IMAGE, writing the console to $LOG"
echo "Waiting up to $SECONDS_TO_RUN seconds for a login prompt."
echo "This is emulation with no hardware acceleration, so it is slow."

# Start from no log at all. This matters more than it looks. The check below is
# a grep for a login prompt in this file, and if qemu fails to start -- bad
# arguments, no memory, no KVM where it was expected -- the previous run's log
# is still sitting there with its login prompt in it, and the grep finds that
# and reports a pass for a machine that never booted. Deleting it first means a
# qemu that does not run leaves nothing to find.
rm -f "$LOG"

qemu-system-aarch64 "${machine[@]}" -serial "file:$LOG" < /dev/null &
qemu=$!

# And confirm it is actually running, so that a qemu which died on startup is
# reported as the failure it is rather than as a boot that produced no output.
sleep 2
if ! kill -0 "$qemu" 2>/dev/null; then
    wait "$qemu" 2>/dev/null
    echo "qemu-boot.sh: qemu exited immediately -- see its error above." >&2
    exit 1
fi

# Nothing in the image shuts the machine down, so rather than waiting a fixed
# length of time, watch the console for the login prompt and stop as soon as it
# appears. That makes this a test with an answer rather than a demonstration,
# and it makes a successful run take as long as the boot does instead of as long
# as the timeout.
booted=1
for (( waited = 0; waited < SECONDS_TO_RUN; waited += 5 )); do
    kill -0 "$qemu" 2>/dev/null || break
    if grep -q 'login:' "$LOG" 2>/dev/null; then
        booted=0
        break
    fi
    sleep 5
done
kill "$qemu" 2>/dev/null
wait "$qemu" 2>/dev/null

echo
echo "The milestones, from the console log:"
tr -d '\r' < "$LOG" | sed 's/\x1b\[[0-9;=]*[A-Za-z]//g' | grep -E \
    'UEFI firmware|BdsDxe: starting|EFI stub|Linux version|systemd\[1\]: systemd |Welcome to|Reached target getty|login:' \
    | cut -c1-110 | head -20
echo

if [[ $booted -eq 0 ]]; then
    echo "Reached a login prompt. Full console log in $LOG"
else
    echo "No login prompt after $SECONDS_TO_RUN seconds. Full console log in $LOG" >&2
fi
exit $booted
