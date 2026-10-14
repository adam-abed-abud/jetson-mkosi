# Configuring a device

One image is flashed to every device. Nothing in it is device-specific. What
differs per device is supplied afterwards, as small text files written onto the
boot partition of that device's drive.

The device reads them once, on its first boot, and configures itself. Later
boots leave the settings alone.

## The files

They live in `loader/credentials/` on the boot partition, which is the first
partition of the drive and is plain FAT. The directory already exists on a
freshly flashed drive.

Each file is named after what it configures, with a `.cred` suffix. All are
optional; leave one out and the built-in default applies.

| File | Contents | Default if absent |
|---|---|---|
| `jetson.hostname.cred` | a hostname, no trailing newline | `jetson-thor` |
| `jetson.network.cred` | a systemd `.network` file | DHCP on every Ethernet port |
| `ssh.authorized_keys.ubuntu.cred` | one or more SSH public keys | no key; password login only |

## Writing them

With the drive attached to your machine:

```sh
sudo mount /dev/sda1 /mnt

printf 'rack-07-thor' | sudo tee /mnt/loader/credentials/jetson.hostname.cred
sudo cp ~/.ssh/id_ed25519.pub /mnt/loader/credentials/ssh.authorized_keys.ubuntu.cred

sudo tee /mnt/loader/credentials/jetson.network.cred <<'EOF'
[Match]
Name=e*

[Network]
Address=10.42.0.7/24
Gateway=10.42.0.1
DNS=10.42.0.1
EOF

sudo umount /mnt
```

Use `printf` rather than `echo` for the hostname: a trailing newline becomes
part of the value.

The network file is ordinary `systemd.network(5)` syntax. It is installed as
`/etc/systemd/network/05-device.network`, which sorts ahead of the built-in
`10-ethernet.network`, and networkd uses the first file that matches.

## What happens on first boot

`systemd-repart` creates the writable partition and grows it to fill the drive.
`systemd-sysusers` creates the accounts. `ssh-keygen` generates this device's
own SSH host keys. Then `jetson-provision.service` reads the files above and
applies them, before networkd, avahi and sshd start, so each sees the final
values.

Check it took:

```sh
hostname
systemctl status jetson-provision
ip -4 addr show scope global
cat /home/ubuntu/.ssh/authorized_keys
```

## Changing the settings later

Nothing here overwrites a file that already exists, so editing a `.cred` file
and rebooting does not change a device that has already been provisioned. This
is deliberate: a stale boot partition should not silently reconfigure a working
machine.

To re-provision, remove what was written and reboot. For the hostname that is
`/etc/hostname`; for the network, `/etc/systemd/network/05-device.network`.
A factory reset wipes the writable partition entirely and the device
provisions itself again from whatever is on the boot partition at that point.

## What not to put there

The boot partition is unencrypted FAT, readable by anyone holding the drive,
and writable by them too. An SSH public key is fine. A password or a private
key is not.

Until Secure Boot is enabled, someone with physical access can also *add*
files there. Treat the boot partition as untrusted input, not as a secret
store.

## Why not systemd credentials

systemd has a credential mechanism that reads this same directory, and it is
the obvious thing to use. It does not work here. Anything `systemd-stub` finds
on the boot partition arrives classed as untrusted, because nothing signs or
measures it without Secure Boot and a TPM, and a unit that declares
`ImportCredential=` for such a value fails with `243/CREDENTIALS` and
`Failed to set up credentials: Protocol error`. That is also what stops
`systemd-sysusers` from reading a root password that way.

So `jetson-provision.service` reads the files directly instead. If the Jetson's
firmware TPM is ever provisioned, which needs an OP-TEE rebuild and a fuse
burn, the credential mechanism becomes available and encrypted per-device
secrets with it.
