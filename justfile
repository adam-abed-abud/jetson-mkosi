# Developer tasks for jetson-mkosi.
#
# 'just' is a command runner: `just build` runs the recipe named build, and
# `just` on its own lists them all. Every recipe below is one short shell
# command, so if you would rather not install another tool, copy the command.
#
# Two things about these recipes are not obvious:
#
#   Everything runs inside the build container, and with --privileged. mkosi
#   needs to create mount and user namespaces, and on a machine that does not
#   already have an aarch64 emulator registered with the kernel, the container's
#   entrypoint registers one.
#
#   mkosi runs as root inside that container, so everything it writes belongs to
#   root. Recipes that write to or delete the output directory therefore run in
#   the container too, rather than asking for sudo on the host.

# The name given to the build container image.
builder_image := "jetson-mkosi-builder"
# Which image definition to build. There is one today; an Orin variant would be
# a second directory alongside it.
variant := "thor"
# Where the built disk image lands.
image := variant / "mkosi.output/jetson-thor.raw"

# The container, running mkosi.
mkosi := "docker run --rm --privileged --volume \"$PWD:/work\" --workdir /work/" + variant + " " + builder_image
# The same container running a shell instead, for commands that only read or
# move files and so do not need the emulator.
tools := "docker run --rm --privileged --entrypoint bash --volume \"$PWD:/work\" --workdir /work " + builder_image

# List the available recipes.
default:
    @just --list

# Build the container holding mkosi and the tools it drives.
container:
    docker build --tag {{ builder_image }} builder/

# Build the disk image. The first run downloads several gigabytes.
build *args: container
    {{ mkosi }} mkosi --force build {{ args }}

# Print the configuration mkosi will use, with every default filled in.
summary: container
    {{ mkosi }} mkosi summary

# Check the built image against what a Jetson Thor needs.
verify: container
    {{ tools }} scripts/verify.sh {{ image }}

# Check a flashed drive against the same list, to see that the flash landed.
verify-drive device: container
    {{ tools }} scripts/verify.sh {{ device }}

# List the files inside the built image's initramfs.
initrd-contents: container
    {{ tools }} -c "python3 scripts/initrd-contents.py {{ variant }}/mkosi.output/jetson-thor.efi"

# Open a shell in the build container, with the repository mounted.
shell: container
    docker run --rm --privileged --interactive --tty \
        --volume "$PWD:/work" --workdir /work/{{ variant }} \
        --entrypoint bash {{ builder_image }}

# Boot the built image in an emulator and show how far it gets.
vm *args: container
    {{ tools }} -c "scripts/qemu-boot.sh {{ image }} {{ args }}"

# Boot a flashed drive in the emulator, to see it is bootable before fitting it.
vm-drive device *args: container
    {{ tools }} -c "scripts/qemu-boot.sh {{ device }} {{ args }}"

# Boot in the emulator and open its console, to log in and look around inside.
vm-console target=image: container
    docker run --rm --privileged --interactive --tty \
        --volume "$PWD:/work" --workdir /work --publish 2222:2222 \
        --entrypoint bash {{ builder_image }} \
        -c "scripts/qemu-boot.sh --console {{ target }}"

# Write the built image to a USB-attached drive.
flash:
    scripts/flash.sh {{ image }}

# Compress the image and write a checksum beside it, for handing to someone else.
dist: container
    {{ tools }} -c "zstd -T0 --force -o {{ image }}.zst {{ image }} \
        && sha256sum {{ image }}.zst > {{ image }}.zst.sha256"

# Delete build outputs. The downloaded packages are kept.
clean: container
    {{ tools }} -c "rm -rf {{ variant }}/mkosi.output"

# Delete build outputs and the downloaded packages.
clean-all: container
    {{ tools }} -c "rm -rf {{ variant }}/mkosi.output {{ variant }}/mkosi.cache {{ variant }}/mkosi.pkgcache"
