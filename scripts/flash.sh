#!/usr/bin/env bash
# Write a built disk image to an external drive.
#
# This is deliberately dumb. The image mkosi produces is a faithful copy of what
# the Thor's disk should contain, partition table included, so installing it is
# a byte-for-byte copy and nothing more. There is no installer and nothing to
# configure.
#
# The intended workflow is to take the Thor's NVMe drive out, or attach it over
# USB, write the image from a normal Linux machine, and put it back. Writing to
# the drive while the Thor is running from it is not possible.
#
# Usage: scripts/flash.sh [path-to-image]

set -euo pipefail

IMAGE="${1:-thor/mkosi.output/jetson-thor.raw}"

if [[ ! -f $IMAGE ]]; then
    echo "flash.sh: $IMAGE does not exist. Build it first with 'just build'." >&2
    exit 1
fi

# Only offer USB-attached disks. This is the safety net: it is the difference
# between overwriting the drive you meant to and overwriting the one you are
# running from.
mapfile -t devices < <(lsblk --nodeps --noheadings --output PATH,SIZE,MODEL,TRAN | awk '$NF == "usb"')
if [[ ${#devices[@]} -eq 0 ]]; then
    echo "flash.sh: no USB-attached drives found." >&2
    echo "Attach the target drive over USB and try again." >&2
    exit 1
fi

echo "Image:  $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo
PS3="Which drive should it be written to? "
select entry in "${devices[@]}"; do
    [[ -n ${entry:-} ]] && break
done
device=${entry%% *}

echo
echo "About to write $IMAGE to $entry."
echo "Everything currently on that drive will be destroyed."
read -rp "Type 'yes' to continue: " reply
[[ $reply == "yes" ]] || { echo "Cancelled."; exit 1; }

# oflag=direct writes straight to the drive instead of through the page cache.
# Without it the kernel accepts nine gigabytes at memory speed -- the progress
# figure is then the speed of filling RAM, not of writing a disk -- and the
# whole backlog has to drain at the fsync on the last line. USB-attached drives,
# and the Realtek bridges in M.2 enclosures especially, are prone to falling off
# the bus under a flush that large; the symptom is 'dd: fsync failed ...
# Input/output error' after a write that looked fast and fine, and a drive whose
# SCSI device has gone offline. Writing direct keeps the queue short, makes the
# reported speed the real one, and takes longer in wall clock for the good
# reason that it is no longer lying about being finished.
sudo dd if="$IMAGE" of="$device" bs=4M status=progress oflag=direct conv=fsync

# Checking here rather than trusting dd: a failed flush is exactly the case
# where the bytes are not on the drive and nothing else says so.
sync
echo
echo "Done. Check it landed before trusting it:"
echo "    just verify-drive $device"
echo "    just vm-drive $device"
