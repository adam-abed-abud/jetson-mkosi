#!/usr/bin/env bash
# Check a built disk image against the things a Jetson AGX Thor needs.
#
# This does not prove the image boots -- only a Thor can do that. What it does
# prove is that every adaptation this repository claims to make is actually
# present in the artifact: the right drivers in the initramfs, the mandatory
# kernel arguments on the command line, the GPU libraries in the right place,
# NVIDIA's unbootable services switched off, and the boot files where the
# firmware will look for them.
#
# It is meant to be run in CI after every build, so that a change that silently
# drops one of them fails loudly.
#
# The argument can be the built image file or the flashed drive itself. Pointing
# it at the drive checks that a flash landed correctly, rather than only that the
# image was built correctly -- the two are not the same claim.
#
# Usage: scripts/verify.sh [path-to-image-or-device]
# Must run as root with loop devices available; `just verify` does that.

set -uo pipefail

IMAGE="${1:-thor/mkosi.output/jetson-thor.raw}"
# The kernel version, which must match the one pinned in
# thor/mkosi.conf.d/20-kernel.conf. If the two drift apart the checks below fail
# rather than quietly pass, which is the right way round: a kernel bump is also
# the moment to re-read Canonical's list of Tegra drivers for the initramfs.
KVER="6.8.0-1035-nvidia-tegra"

passed=0
failed=0

# check <description> <command...> -- runs the command, prints one line.
check() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok    %s\n' "$description"
        passed=$((passed + 1))
    else
        printf '  FAIL  %s\n' "$description"
        failed=$((failed + 1))
    fi
}

# check_contains <description> <text> <substring> -- passes if the text contains
# the substring. Used where the thing being checked is a string we already have,
# such as a line of output, rather than a command to run.
check_contains() {
    local description=$1 haystack=$2 needle=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        printf '  ok    %s\n' "$description"
        passed=$((passed + 1))
    else
        printf '  FAIL  %s (looked for %s)\n' "$description" "$needle"
        failed=$((failed + 1))
    fi
}

[[ -e $IMAGE ]] || { echo "verify.sh: $IMAGE does not exist." >&2; exit 1; }

echo "Verifying $IMAGE"
echo

# --- the partition table ------------------------------------------------------
echo "Partition table"
table=$(sfdisk --json "$IMAGE" 2>/dev/null)
# C12A7328-F81F-11D2-BA4B-00A0C93EC93B is the EFI system partition type.
check_contains "an EFI system partition exists" "$table" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
# B921B045-1DF0-41C3-AF44-4C6F280D3FAE is 'Linux root (arm64)' from the
# Discoverable Partitions Specification. Using the typed UUID rather than the
# generic Linux one is what lets systemd recognise the partition on sight.
check_contains "the root partition is typed as arm64 root" "$table" "B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
echo

# --- mount both partitions ----------------------------------------------------
#
# The image is a file, not a disk, so each partition is attached as its own loop
# device at the byte offset where it starts. (Attaching the whole image and
# asking the kernel to scan its partition table is the more usual approach, but
# inside a container the resulting partition device nodes do not appear.) The
# offsets come from the table printed above; sfdisk reports them in 512-byte
# sectors.
offset_of() { printf '%s' "$table" | python3 -c '
import json, sys
table = json.load(sys.stdin)["partitiontable"]
index = int(sys.argv[1])
part = table["partitions"][index]
print(part["start"] * 512, part["size"] * 512)
' "$1"; }

read -r esp_offset esp_size < <(offset_of 0)
read -r root_offset root_size < <(offset_of 1)

# losetup picks the next free loop device, but inside a container the matching
# node under /dev may not have been created, so create it if it is missing. The
# major number of a loop device is always 7 and the minor is its index.
attach() {
    local offset=$1 size=$2 device
    device=$(losetup --find) || return 1
    [[ -e $device ]] || mknod "$device" b 7 "${device##*/loop}"
    losetup --read-only --offset "$offset" --sizelimit "$size" "$device" "$IMAGE" || return 1
    printf '%s' "$device"
}

# Clean up on the way out however we leave, including when one of the steps
# below fails partway through. A loop device left attached holds the image file
# open and the next run cannot replace it.
esp_loop=""; root_loop=""; esp=""; root=""
cleanup() {
    [[ -n $esp ]] && umount -q "$esp" 2>/dev/null
    [[ -n $root ]] && umount -q "$root" 2>/dev/null
    [[ -n $esp_loop ]] && losetup -d "$esp_loop" 2>/dev/null
    [[ -n $root_loop ]] && losetup -d "$root_loop" 2>/dev/null
    return 0
}
trap cleanup EXIT

esp_loop=$(attach "$esp_offset" "$esp_size") || { echo "could not attach the EFI system partition" >&2; exit 1; }
root_loop=$(attach "$root_offset" "$root_size") || { echo "could not attach the root filesystem" >&2; exit 1; }
esp=$(mktemp -d); root=$(mktemp -d)

mount -o ro "$esp_loop" "$esp" || { echo "could not mount the EFI system partition" >&2; exit 1; }
mount -o ro "$root_loop" "$root" || { echo "could not mount the root filesystem" >&2; exit 1; }

# --- the boot files -----------------------------------------------------------
echo "Boot files on the EFI system partition"
# The firmware boots this path when it has not been told about a specific boot
# entry, which is the case for a disk it has never seen.
check "systemd-boot is at the default path EFI/BOOT/BOOTAA64.EFI" \
      test -f "$esp/EFI/BOOT/BOOTAA64.EFI"
check "systemd-boot is also at EFI/systemd/systemd-bootaa64.efi" \
      test -f "$esp/EFI/systemd/systemd-bootaa64.efi"
uki=$(find "$esp/EFI/Linux" -name '*.efi' 2>/dev/null | head -1)
check "a unified kernel image exists in EFI/Linux" test -n "$uki"
echo

# --- the kernel command line --------------------------------------------------
echo "Kernel command line, read back out of the unified kernel image"
if [[ -n $uki ]]; then
    cmdline=$(python3 -c '
import pefile, sys
pe = pefile.PE(sys.argv[1])
for section in pe.sections:
    if section.Name.rstrip(b"\x00") == b".cmdline":
        # The section is padded with null bytes, which the shell cannot hold
        # in a variable, so strip them here.
        text = section.get_data()[:section.Misc_VirtualSize].decode("utf-8", "replace")
        sys.stdout.write(text.replace("\x00", ""))
' "$uki" 2>/dev/null)
    for arg in nvme.use_threaded_interrupts=1 tegra_keep_boot_clocks clk_ignore_unused \
               pci=pcie_bus_perf console=ttyUTC0,115200 console=ttyAMA0,115200 root=PARTUUID=; do
        check_contains "$arg" "$cmdline" "$arg"
    done
    # An earlycon names a physical address to write to before the kernel knows
    # what machine it is on. If the address is wrong the kernel dies silently,
    # so the default image must not carry one. See thor/mkosi.conf.d/40-boot.conf.
    if printf '%s' "$cmdline" | grep -q 'earlycon'; then
        printf '  FAIL  %s\n' "the command line carries an earlycon"
        failed=$((failed + 1))
    else
        printf '  ok    %s\n' "the command line carries no earlycon"
        passed=$((passed + 1))
    fi
else
    echo "  skipped: no unified kernel image to read"
fi
echo

# --- the kernel itself --------------------------------------------------------
echo "Drivers built into the kernel"
# The serial console is the only way to watch this board boot, and the device it
# uses is Thor-specific. Canonical's kernel configuration file does not mention
# it by name, so the only way to be sure the driver is there is to look inside
# the kernel. It sits in the unified kernel image's .linux section; searching
# that for the driver's strings settles the question.
#
# Ubuntu ships its arm64 kernel wrapped in a self-decompressing container called
# EFI zboot. ukify unwraps it when it assembles the unified kernel image, so the
# section holds the plain kernel. The gzip branch below is for the case where
# some future kernel package is not unwrapped.
if [[ -n $uki ]]; then
    kernel_strings=$(python3 -c '
import gzip, sys, pefile
pe = pefile.PE(sys.argv[1])
for section in pe.sections:
    if section.Name.rstrip(b"\x00") == b".linux":
        raw = section.get_data()[: section.Misc_VirtualSize]
        start = raw.find(b"\x1f\x8b\x08")
        if start >= 0:
            raw = gzip.decompress(raw[start:])
        for needle in (b"ttyUTC", b"tegra_utc"):
            if needle in raw:
                print(needle.decode())
' "$uki" 2>/dev/null)
    check_contains "the Thor serial console driver (ttyUTC) is built in" \
          "$kernel_strings" "ttyUTC"
    check_contains "and so is its early-boot variant (tegra_utc)" \
          "$kernel_strings" "tegra_utc"
else
    echo "  skipped: no unified kernel image to read"
fi
echo

# --- the initramfs ------------------------------------------------------------
echo "Drivers in the initramfs"
# initrd-contents.py unpacks the initramfs out of the unified kernel image and
# lists what is in it; see that script for how.
if [[ -n $uki ]]; then
    names=$(python3 "$(dirname "$0")/initrd-contents.py" "$uki" 2>/dev/null)
    # Without the PCIe controller driver the kernel never sees the disk the root
    # filesystem is on, and without the NVMe driver it cannot talk to it.
    for driver in pcie-tegra264.ko nvme.ko ufs-tegra.ko nvethernet.ko; do
        check_contains "$driver is present" "$names" "$driver"
    done
    # Having the driver file is not enough. Nothing in the initramfs loads these
    # by name: udev notices the hardware appear, asks which module claims it,
    # and loads that. The answer comes from modules.alias, so if that index is
    # missing the drivers sit there unused and the boot stops with no root
    # filesystem.
    check_contains "the module index (modules.alias) is present" \
          "$names" "modules.alias"
else
    echo "  skipped: no unified kernel image to read"
fi
echo

# --- the root filesystem ------------------------------------------------------
echo "Root filesystem"
check "the Tegra out-of-tree drivers are installed" \
      test -f "$root/usr/lib/modules/$KVER/updates/tegra-oot-jetson/pcie-tegra264.ko"
check "the openrm GPU kernel driver is installed" \
      test -f "$root/usr/lib/modules/$KVER/updates/tegra-igpu-openrm-jetson/nvidia.ko"

# The CUDA driver library. NVIDIA installs it under /opt and a boot-time service
# normally links it into place; that service cannot run here, so the link is
# made at build time instead.
check "libcuda.so.1 is linked into the system library path" \
      test -L "$root/usr/lib/aarch64-linux-gnu/libcuda.so.1"
# Read the link's target as text rather than resolving it: the target is an
# absolute path inside the image, which would resolve against this machine's
# own root directory and find nothing.
check_contains "and it points at the openrm build, not nvgpu" \
      "$(readlink "$root/usr/lib/aarch64-linux-gnu/libcuda.so.1" 2>/dev/null)" "/openrm/"

# NVIDIA's services that cannot work on this image. 'Masked' means the unit is
# a symlink to /dev/null, which makes it impossible to start.
for unit in nvpmodel nv-l4t-bootloader-config nv-load-gpu-libs nv-load-display-modules nv-graphics; do
    check_contains "$unit.service is masked" \
        "$(readlink "$root/etc/systemd/system/$unit.service" 2>/dev/null)" "/dev/null"
done

# Canonical blacklists the GPU modules by default, leaving them to the NVIDIA
# services that are masked above. If the blacklist survived, nothing loads them.
check "Canonical's GPU blacklist has been removed" \
      test ! -e "$root/etc/modprobe.d/tegra-igpu-jetson-defaults_nvidia-display_nvidia-tegra.conf"

# Our own replacements for what those services did.
check "the GPU loader service is installed" \
      test -f "$root/usr/lib/systemd/system/nvidia-display-load.service"
check "and it is enabled" \
      test -L "$root/etc/systemd/system/multi-user.target.wants/nvidia-display-load.service"

# initramfs-tools would install hooks that rebuild the initramfs on the device,
# which cannot work on a read-only image. Note that the test is on the package
# database: the directory /usr/share/initramfs-tools exists either way, because
# several other packages drop hook scripts into it. Those scripts are inert
# while the package that would run them is absent.
check "initramfs-tools is not installed" \
      bash -c "! grep -q '^Package: initramfs-tools$' '$root/var/lib/dpkg/status'"

# nvidia-l4t-init's post-installation script rewrites both of these whenever it
# sees the flag that stops the bootloader package flashing firmware, which this
# build always sets. The versions here must be ours.
check "our /etc/fstab replaced NVIDIA's" \
      bash -c "! grep -q '^/dev/root' '$root/etc/fstab'"
check "our /etc/hosts replaced NVIDIA's" \
      grep -q '127.0.1.1' "$root/etc/hosts"

# systemd-resolved answers DNS queries through a stub file under /run. If
# /etc/resolv.conf is a plain file instead of a link to it, name resolution
# silently does not work on the device.
check_contains "/etc/resolv.conf points at systemd-resolved" \
      "$(readlink "$root/etc/resolv.conf" 2>/dev/null)" "systemd/resolve"

# Two files name the locale, read by different software: systemd reads
# /etc/locale.conf, Debian's login machinery reads /etc/default/locale. One of
# NVIDIA's packages writes en_US.UTF-8 into them during the build, and no en_US
# locale is generated here, so both have to have been put back.
for locale_file in etc/locale.conf etc/default/locale; do
    check_contains "$locale_file asks for a locale that exists" \
          "$(cat "$root/$locale_file" 2>/dev/null)" "C.UTF-8"
done
check "and that locale is present in the image" \
      test -d "$root/usr/lib/locale/C.utf8"

check "the ubuntu user exists" grep -q '^ubuntu:' "$root/etc/passwd"
check "the hostname is set" test -s "$root/etc/hostname"
echo

echo "$passed checks passed, $failed failed."
[[ $failed -eq 0 ]]
