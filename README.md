# jetson-mkosi

Build a root filesystem for the NVIDIA Jetson AGX Thor with
[mkosi](https://github.com/systemd/mkosi), systemd's image builder.

The output is one disk image holding an EFI system partition and an immutable
Ubuntu 24.04 arm64 operating system, with Canonical's Jetson kernel and
NVIDIA's JetPack userspace. The build runs on an ordinary x86-64 Linux machine
with nothing installed but Docker.

> ### Work in progress
>
> This is active development, not a finished product. The image boots, the
> operating system is immutable, and the GPU works on hardware
>
> Expect things to change.

## What it builds

One file, `thor/mkosi.output/jetson-thor.raw`, about 1.3 GB, holding three
partitions:

an EFI system partition with systemd-boot and a single unified kernel image;
a `/usr` partition holding the whole operating system as a read-only squashfs;
and a hash partition carrying a dm-verity tree covering every block of it.

There is deliberately no root filesystem in the image. The device creates its
own writable partition on first boot and grows it to fill the drive, and `/etc`
is populated from a vendor copy kept inside the read-only `/usr`. So the
operating system cannot be modified, while configuration, logs and home
directories are ordinary writable files.

Inside it is Ubuntu 24.04 for arm64, with Canonical's Jetson kernel
(`6.8.0-1035-nvidia-tegra`) and NVIDIA's JetPack 7.2 userspace: the CUDA driver,
the camera and multimedia stacks, the power and fan daemons. Networking comes up
over DHCP, SSH is enabled with host keys generated per device on first boot, and
there is an `ubuntu` user whose password is `ubuntu`. The locale is `C.UTF-8`,
so number formatting and text sorting behave the same way on every device.

Writing the image to a drive is a byte for byte copy. There is no installer.

## What you need

A Linux machine with Docker, and nothing else: no arm64 hardware, no mkosi, no
Jetson tooling. Everything the build uses lives inside a container defined in
`builder/`. Allow roughly 12 GB of disk, and a good network connection for the
first build. [just](https://github.com/casey/just) is optional and runs the
recipes in `justfile`; each one is a single `docker run` you can copy instead.

The image is arm64 and your machine almost certainly is not. Installing an arm64
package runs that package's own arm64 scripts, so the kernel needs a binfmt
handler for arm64. The builder container installs one if the machine lacks it,
which is why it runs with `--privileged`. To set it up yourself instead:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Building it

```sh
just build     # build the disk image
just verify    # check the result against what a Thor needs
just vm        # boot it in an emulator and watch it come up
just flash     # write it to a USB-attached drive
```

A build takes about four and a half minutes on a laptop. Almost all of that is
emulating an arm64 machine so that package scripts can run, not downloading.

Once a drive has been written, the same two checks can be pointed at the drive
instead of at the image. That is a different question, and one that has silently
failed before:

```sh
just verify-drive /dev/sdX   # the same checks, against the drive
just vm-drive /dev/sdX       # boot the drive itself, before fitting it
```

To look around inside rather than watch it boot:

```sh
just vm-console              # a login prompt on your terminal, ubuntu / ubuntu
```

That one also forwards the guest's SSH port, so `ssh -p 2222 ubuntu@localhost`
from another terminal gives you a shell without kernel messages scrolling
through it.

Without `just`:

```sh
docker build --tag jetson-mkosi-builder builder/
docker run --rm --privileged --volume "$PWD:/work" --workdir /work/thor \
    jetson-mkosi-builder mkosi --force build
```

## Installing it on a Thor

> The device's boot firmware must already be at JetPack 7.2 (Jetson Linux
> r39.2). This image is the root filesystem and nothing else. The firmware in
> the module's flash chip, meaning the early boot stages and the UEFI
> implementation that starts this image, is flashed separately with NVIDIA's own
> tools, as described in the
> [AGX Thor developer kit guide](https://docs.nvidia.com/jetson/agx-thor-devkit/user-guide/latest/setup_bsp.html).
> The build explicitly stops NVIDIA's packages from touching it; see
> `thor/mkosi.skeleton/opt/nvidia/l4t-packages/`.

1. Take the Thor's NVMe drive out, or attach it to your machine over USB.
2. Run `just flash`, and pick the drive from the menu.
3. Put it back and power on.

The firmware finds the EFI system partition, runs systemd-boot from it, and
systemd-boot starts the kernel. Watch it on a serial console attached to the
USB-C debug port at 115200 baud. The debug connector enumerates as several
serial devices and the boot is split across two of them, the UEFI firmware on
one and the kernel on another, so capture both or most of the boot will look
silent. `scripts/connect.sh` opens one from a menu.

If it dies before the kernel says anything, that is the one case where it is
worth building a one-off image with an early console. It is left out of the
normal image for reasons `thor/mkosi.conf.d/40-boot.conf` explains:

```sh
just build --kernel-command-line="earlycon=tegra_utc,mmio32,0xc4e0000"
```

## Configuring a device

Every device gets the same image. What differs is written afterwards, as small
text files on the boot partition of that device's drive:

```sh
sudo mount /dev/sda1 /mnt
printf 'rack-07-thor' | sudo tee /mnt/loader/credentials/jetson.hostname.cred
sudo cp ~/.ssh/id_ed25519.pub /mnt/loader/credentials/ssh.authorized_keys.ubuntu.cred
sudo umount /mnt
```

On first boot the device applies them, before the network and SSH come up. A
static address can be supplied the same way. All of it is optional; without
any of these files the device uses DHCP and the built-in hostname.

[docs/provisioning.md](docs/provisioning.md) covers the file formats, what
happens on first boot, how to re-provision a device, and what must not be put
on an unencrypted boot partition.

## Checking that it is immutable

The operating system cannot be written to, even by root:

```sh
touch /usr/bin/x              # Read-only file system
mount -o remount,rw /usr      # fails: the block device itself is read-only
```

That is stronger than a read-only mount, which root can lift. Every block of
`/usr` is checked against a dm-verity hash tree whose root value is baked into
the unified kernel image, so a modification made with the device switched off
is detected on the next read:

```sh
findmnt /usr                          # /dev/mapper/usr, squashfs, ro
grep -o 'usrhash=[a-f0-9]*' /proc/cmdline
dd if=/dev/dm-0 of=/dev/null bs=1M    # silent: every block matches the hash
```

Flip one byte in the `/usr` partition of a copy and that last command stops
with an I/O error at the corrupted block, and `dmesg` names it. Note the image
still boots: verity checks each block when it is read, not all at once.

## How it is put together

mkosi is configured by files whose names tell it what they are for:

| Path | What mkosi does with it |
|---|---|
| `thor/mkosi.conf` | Base settings: distribution, release, architecture, output and cache locations. |
| `thor/mkosi.conf.d/` | The rest of the settings, split by subject, read in filename order. |
| `thor/mkosi.sandbox/` | Configuration for apt itself, not for the image. mkosi runs apt from outside the image, so NVIDIA's repositories and the package pin go here. |
| `thor/mkosi.skeleton/` | Files copied in before any package is installed, for the workarounds that must exist before NVIDIA's package scripts run. |
| `thor/mkosi.extra/` | Files copied in after every package is installed. The configuration overlay. |
| `thor/mkosi.postinst.chroot` | A script run inside the image once everything is installed. |
| `thor/mkosi.repart/` | The partition layout, handed to systemd-repart. |

The rest of the repository is not mkosi's:

| Path | What it is |
|---|---|
| `builder/` | The container holding mkosi and the tools it drives, pinned to exact versions. |
| `scripts/verify.sh` | Opens a built image, or a flashed drive, and checks it against what a Thor needs. |
| `scripts/qemu-boot.sh` | Boots the image, or a flashed drive, on an emulated generic arm64 machine. |
| `scripts/initrd-contents.py` | Lists what is inside the initramfs. |
| `scripts/flash.sh` | Writes an image to a drive, bypassing the page cache so that a failure is reported rather than cached. |
| `scripts/connect.sh` | Opens a serial console on an attached Jetson, chosen from a menu. |

Every file carries a comment explaining what it is for and why. Start with
`thor/mkosi.conf.d/40-boot.conf`, where the Thor-specific knowledge is densest.
Running `just summary` prints the configuration with every default filled in,
which is the quickest way to check that an edit landed where you meant it to.

## TODO

The login passwords are on the kernel command line, where any user can read
them in `/proc/cmdline`. That is a development convenience, and the mechanism
to replace it exists: supply an SSH key per device and drop the password
credentials.

There is no update mechanism. How an image reaches a device in the field, which
covers over-the-air delivery, A/B slots, rollback and NVIDIA's `nvbootctrl`, is
a separate workstream. The partition layout does not foreclose one.

Nothing is signed. The unified kernel image carries no signature, and on a
Jetson enrolling keys is a flash-time operation with NVIDIA's tools rather than
a property of the image, so Secure Boot is scoped separately.

There is no Orin variant. This builds for Thor only. Orin needs the `nvgpu` GPU
driver where Thor needs `openrm`, and a different serial console.

## Inspiration

This project is inspired by the following:

[ParticleOS](https://github.com/systemd/particleos) is an immutable distribution
built with mkosi, and the model for the immutable work: a verity-protected
`/usr`, a hermetic `/etc`, and `systemd-repart` running on the device

[bootc-jetson](https://github.com/yeetypete/bootc-jetson) builds a Thor root
filesystem as a container image

## License

`jetson-mkosi` is released under the [MIT License](LICENSE).

