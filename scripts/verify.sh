#!/usr/bin/env bash
# Check a built disk image against the things a Jetson AGX Thor needs.
#
# This does not prove the image boots -- only a Thor can do that. What it does
# prove is that every adaptation this repository claims to make is present in
# the artifact: the right drivers in the initramfs, the mandatory kernel
# arguments, the GPU libraries where the linker will find them, NVIDIA's
# unbootable services switched off, and the files an empty /etc is populated
# from.
#
# The layout it reads is ESP + usr + usr-verity. There is no root filesystem in
# the image; the device creates one on first boot. So the checks below open the
# read-only /usr and the vendor copy of /etc inside it, not a root partition.
#
# The argument can be the built image file or the flashed drive itself.
#
# Usage: scripts/verify.sh [path-to-image-or-device]
# Must run as root with loop devices available; `just verify` does that.

set -uo pipefail

IMAGE="${1:-thor/mkosi.output/jetson-thor.raw}"
# Must match the kernel pinned in thor/mkosi.conf.d/20-kernel.conf. If the two
# drift apart these checks fail rather than quietly pass.
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
# the substring.
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
check_contains "an EFI system partition exists" "$table" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
# These two type UUIDs are "Linux /usr (arm64)" and its verity hash partition
# from the Discoverable Partitions Specification. Using the typed UUIDs is what
# lets the kernel find both from the root hash alone.
check_contains "a /usr partition is typed as arm64 usr" "$table" "B0E01050-EE5F-4390-949A-9101B17104E9"
check_contains "and its verity hash partition is present" "$table" "6E11A4E7-FBCA-4DED-B9E9-E1A512BB664E"
# A root partition in the image would mean the device-side repart never ran.
if printf '%s' "$table" | grep -qF "B921B045-1DF0-41C3-AF44-4C6F280D3FAE"; then
    printf '  FAIL  no root partition in the image (the device creates it)\n'
    failed=$((failed + 1))
else
    printf '  ok    no root partition in the image (the device creates it)\n'
    passed=$((passed + 1))
fi
echo

# --- attach the partitions ----------------------------------------------------
#
# Each partition is attached as its own loop device at the byte offset where it
# starts, because inside a container the partition device nodes of a whole-disk
# loop do not appear.
offset_of() { printf '%s' "$table" | python3 -c '
import json, sys
table = json.load(sys.stdin)["partitiontable"]
want = sys.argv[1]
for part in table["partitions"]:
    if part.get("name") == want:
        print(part["start"] * 512, part["size"] * 512)
        break
' "$1"; }

read -r esp_offset esp_size < <(offset_of esp)
read -r usr_offset usr_size < <(offset_of usr-arm64)

# losetup picks the next free loop device, but inside a container the matching
# node under /dev may not have been created, so create it if it is missing. The
# major number of a loop device is always 7 and the minor is its index.
#
# A just-allocated device is reported as "/dev/loopN (lost)", so trim the
# annotation before using the name as a path.
attach() {
    local offset=$1 size=$2 device
    device=$(losetup --find) || return 1
    device=${device%% *}
    [[ -e $device ]] || mknod "$device" b 7 "${device##*/loop}"
    losetup --read-only --offset "$offset" --sizelimit "$size" "$device" "$IMAGE" || return 1
    printf '%s' "$device"
}

esp_loop=""; usr_loop=""; esp=""; usr=""
cleanup() {
    [[ -n $esp ]] && umount -q "$esp" 2>/dev/null
    [[ -n $usr ]] && umount -q "$usr" 2>/dev/null
    [[ -n $esp_loop ]] && losetup -d "$esp_loop" 2>/dev/null
    [[ -n $usr_loop ]] && losetup -d "$usr_loop" 2>/dev/null
    return 0
}
trap cleanup EXIT

esp_loop=$(attach "$esp_offset" "$esp_size") || { echo "could not attach the EFI system partition" >&2; exit 1; }
usr_loop=$(attach "$usr_offset" "$usr_size") || { echo "could not attach /usr" >&2; exit 1; }

esp=$(mktemp -d); usr=$(mktemp -d)
mount -o ro "$esp_loop" "$esp" || { echo "could not mount the ESP" >&2; exit 1; }
mount -t squashfs -o ro "$usr_loop" "$usr" || { echo "could not mount /usr as squashfs" >&2; exit 1; }

factory="$usr/share/factory/etc"

# --- the EFI system partition -------------------------------------------------
echo "EFI system partition"
check "systemd-boot is at the default path EFI/BOOT/BOOTAA64.EFI" test -f "$esp/EFI/BOOT/BOOTAA64.EFI"
check "systemd-boot is also at EFI/systemd/systemd-bootaa64.efi" test -f "$esp/EFI/systemd/systemd-bootaa64.efi"
uki=$(find "$esp/EFI/Linux" -name '*.efi' 2>/dev/null | head -1)
check "a unified kernel image exists in EFI/Linux" test -n "$uki"
check "the boot menu is reachable for recovery" grep -q "^timeout" "$esp/loader/loader.conf"
check "and the command line can be edited there" grep -q "^editor yes" "$esp/loader/loader.conf"
echo

# --- the kernel command line --------------------------------------------------
#
# Read straight out of the unified kernel image, which is where it is baked.
echo "Kernel command line"
cmdline=$(python3 - "$uki" <<'PY'
import sys
try:
    import pefile
    pe = pefile.PE(sys.argv[1], fast_load=True)
    for section in pe.sections:
        if section.Name.rstrip(b"\x00") == b".cmdline":
            print(section.get_data()[:section.Misc_VirtualSize].decode("utf-8", "replace").strip("\x00"))
            break
except Exception:
    pass
PY
)
for arg in nvme.use_threaded_interrupts=1 tegra_keep_boot_clocks clk_ignore_unused \
           pci=pcie_bus_perf console=ttyUTC0,115200 usrhash= mount.usr=/dev/mapper/usr \
           systemd.firstboot=off; do
    check_contains "$arg" "$cmdline" "$arg"
done
# The placeholder mkosi only substitutes when there is no verity hash. Left in,
# it reaches the kernel verbatim and the boot fails.
if printf '%s' "$cmdline" | grep -qF "root=PARTUUID\b"; then
    printf '  FAIL  no unsubstituted root=PARTUUID placeholder\n'; failed=$((failed + 1))
else
    printf '  ok    no unsubstituted root=PARTUUID placeholder\n'; passed=$((passed + 1))
fi
echo

# --- the kernel and its drivers -----------------------------------------------
echo "Kernel"
check "the pinned kernel $KVER is installed" test -f "$usr/lib/modules/$KVER/vmlinuz"
# The packaged vmlinuz is compressed; the copy inside the unified kernel image
# is not, because UEFI cannot load a compressed one.
vmlinuz=$(mktemp)
python3 -c '
import sys, pefile
pe = pefile.PE(sys.argv[1], fast_load=True)
for s in pe.sections:
    if s.Name.rstrip(b"\x00") == b".linux":
        open(sys.argv[2], "wb").write(s.get_data()[:s.Misc_VirtualSize]); break
' "$uki" "$vmlinuz"
check "the Thor serial console driver (ttyUTC) is built in" grep -qa "ttyUTC" "$vmlinuz"
check "and so is its early-boot variant (tegra_utc)" grep -qa "tegra_utc" "$vmlinuz"
check "the module index (modules.alias) is present" test -s "$usr/lib/modules/$KVER/modules.alias"
for driver in pcie-tegra264 nvethernet tegra-xudc; do
    check "$driver is present" find "$usr/lib/modules/$KVER" -name "$driver.ko*" -print -quit
done
check "the Tegra out-of-tree drivers are installed" test -d "$usr/lib/modules/$KVER/updates/tegra-oot-jetson"
check "the openrm GPU kernel driver is installed" find "$usr/lib/modules/$KVER" -name "nvidia.ko*" -print -quit
echo

# --- the GPU userspace --------------------------------------------------------
echo "GPU userspace"
check "libcuda.so.1 is linked into the system library path" test -L "$usr/lib/aarch64-linux-gnu/libcuda.so.1"
target=$(readlink "$usr/lib/aarch64-linux-gnu/libcuda.so.1" 2>/dev/null)
check_contains "and it points at the openrm build, not nvgpu" "$target" "openrm"
# /opt is outside /usr, so the tree is moved in at build time.
check "the NVIDIA /opt tree moved into /usr" test -d "$usr/lib/nvidia-opt/l4t-gpu-libs/openrm"
check "and libcuda is really there" test -f "$usr/lib/nvidia-opt/l4t-gpu-libs/openrm/libcuda.so.1"
# Without the cache the linker searches only its default directories, so the
# GPU libraries outside them stop resolving and CUDA fails.
check "ld.so.cache is captured for the device" test -s "$factory/ld.so.cache"
check "and it names the NVIDIA library directory" grep -qa "nvidia-opt" "$factory/ld.so.cache"
check "Canonical's GPU blacklist has been removed" test ! -e "$factory/modprobe.d/tegra-igpu-jetson-defaults_nvidia-display_nvidia-tegra.conf"
check "the GPU loader service is installed" test -f "$usr/lib/systemd/system/nvidia-display-load.service"
echo

# --- NVIDIA services ----------------------------------------------------------
#
# These units ship as real files in /etc/systemd/system, which an image carrying
# only /usr would discard, so the build moves them.
echo "NVIDIA services"
for unit in nvfancontrol nvargus-daemon nv_nvsciipc_init nvpower; do
    check "$unit.service moved into /usr" test -f "$usr/lib/systemd/system/$unit.service"
done
for unit in nv-graphics nv-l4t-bootloader-config nv-load-display-modules \
            nv-load-gpu-libs nvpmodel nv-rootfs-validation-config; do
    check "$unit.service is masked in /usr" test "$(readlink "$usr/lib/systemd/system/$unit.service")" = /dev/null
done
echo

# --- what an empty /etc is populated from -------------------------------------
echo "Vendor /etc"
check "a factory copy of /etc exists" test -d "$factory"
check "the tmpfiles rules that link it back are installed" test -f "$usr/lib/tmpfiles.d/etc-jetson.conf"
check "PAM moved into /usr, so login can authenticate" test -f "$usr/lib/pam.d/login"
check "sshd configuration is captured" test -f "$factory/ssh/sshd_config"
# Shared host keys would make every device the same host to an SSH client.
check "no SSH host keys are shipped" test -z "$(find "$factory/ssh" -name 'ssh_host_*' 2>/dev/null)"
check "the sudo rule for the operator is captured" test -f "$factory/sudoers.d/ubuntu"
check "host keys are generated on the device instead" test -f "$usr/lib/systemd/system/ssh-keygen.service"
check "the console setup tree is captured" test -d "$factory/console-setup"
# A symlink into /etc/alternatives, so test for the link, not the target.
check "setvtrgb's palette file is captured" test -L "$factory/vtrgb"
check "and the alternatives tree it points into is linked" grep -q "^L /etc/alternatives" "$usr/lib/tmpfiles.d/etc-jetson.conf"
# These read configuration that tmpfiles links in at boot, so they must not run
# before it. keyboard-setup ships Before=local-fs-pre.target, far too early.
for unit in console-setup keyboard-setup setvtrgb; do
    check "$unit runs after tmpfiles" test -f "$usr/lib/systemd/system/$unit.service.d/after-tmpfiles.conf"
done
# systemd 255 has no "?" modifier; such a line is rejected and the link never
# made, silently, which is how avahi and console-setup came to fail.
check "no tmpfiles line uses an unsupported modifier" bash -c "! grep -qE '^[A-Za-z]\\?' '$usr/lib/tmpfiles.d/etc-jetson.conf'"
check "our /etc/fstab replaced NVIDIA's" grep -q "Nothing is mounted from this file" "$factory/fstab"
check "our /etc/hosts replaced NVIDIA's" grep -q "127.0.1.1" "$factory/hosts"
check "the dpkg database is kept, so dpkg -l works" test -f "$usr/share/factory/var/lib/dpkg/status"
check "NVIDIA's camera tuning data is kept" test -d "$usr/share/factory/var/nvidia/nvcam/settings"
echo

# --- accounts -----------------------------------------------------------------
#
# /etc/passwd is created on the device, so the accounts have to be declared.
echo "Accounts"
check "the operator account is declared" grep -qE "^u +ubuntu" "$usr/lib/sysusers.d/jetson.conf"
# Without render, cuInit returns 801 from an unprivileged account.
check "and it is in the render group" grep -qE "^m +ubuntu +render" "$usr/lib/sysusers.d/jetson.conf"
check "the debug group NVIDIA's udev rules need is declared" grep -qE "^g +debug" "$usr/lib/sysusers.d/jetson.conf"
for user in sshd avahi uuidd; do
    check "$user is declared, so its service can start" grep -qE "^u +$user" "$usr/lib/sysusers.d/jetson.conf"
done
check "a password credential for the operator is accepted" test -f "$usr/lib/systemd/system/systemd-sysusers.service.d/operator-password.conf"
echo

# --- the device-side partitioning ---------------------------------------------
echo "First boot"
check "a repart definition for the writable partition ships" test -f "$usr/lib/repart.d/50-root.conf"
check "and it has no maximum size, so it fills the drive" bash -c "! grep -q SizeMaxBytes '$usr/lib/repart.d/50-root.conf'"
check "the journal directory is created with it" grep -q "MakeDirectories=/var/log/journal" "$usr/lib/repart.d/50-root.conf"
check "a recovery shell needs no password" test -f "$usr/lib/systemd/system/emergency.service.d/sulogin-force.conf"
check "per-device provisioning is installed" test -x "$usr/lib/jetson/provision.sh"
check "and it runs before what consumes the values" grep -q "Before=systemd-networkd.service" "$usr/lib/systemd/system/jetson-provision.service"
check "and waits for the ESP it reads them from" grep -q "RequiresMountsFor=/efi" "$usr/lib/systemd/system/jetson-provision.service"
for cred in jetson.hostname jetson.network ssh.authorized_keys.ubuntu; do
    check "it handles the $cred credential" grep -q "$cred" "$usr/lib/jetson/provision.sh"
done
# ImportCredential= fails with 243/CREDENTIALS on anything systemd-stub reads
# from the ESP, because nothing signs it and there is no TPM to decrypt with.
check "no unit imports an ESP credential" bash -c "! grep -rq 'ImportCredential=jetson' '$usr/lib/systemd/system/'"
check "initramfs-tools is not installed" test ! -e "$usr/share/initramfs-tools/hooks/btrfs"
echo

printf '%d checks passed, %d failed.\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
