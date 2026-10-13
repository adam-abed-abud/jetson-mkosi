#!/usr/bin/env python3
"""List the files inside the initramfs embedded in a unified kernel image.

A unified kernel image is a Windows-style executable (that is the format UEFI
runs) whose sections hold the pieces of a Linux boot: the kernel in .linux, the
kernel command line in .cmdline, and the initramfs in .initrd.

The initramfs itself is a concatenation of cpio archives, each compressed
separately. mkosi builds two: one that does not depend on the kernel version,
holding systemd and the userspace that runs before the real root filesystem is
mounted, and one holding this particular kernel's modules. The kernel
decompresses them in turn and unpacks each over the last.

This script undoes that so the contents can be checked: it pulls out the
.initrd section, decompresses every frame in it, and prints the name of each
file the archives contain.

Usage: initrd-contents.py <unified-kernel-image.efi>

Run it inside the build container, which has the two things it needs: Python
3.14 or newer, for the zstd decompressor in the standard library, and the
pefile module for reading the executable's sections. `just initrd-contents`
does that.
"""

import sys
from compression import zstd

import pefile


def initrd_section(path):
    """Return the raw bytes of the .initrd section of a unified kernel image."""
    image = pefile.PE(path)
    for section in image.sections:
        if section.Name.rstrip(b"\x00") == b".initrd":
            return section.get_data()[: section.Misc_VirtualSize]
    raise SystemExit(f"{path} has no .initrd section; is it a unified kernel image?")


def decompress_all_frames(data):
    """Decompress a run of back-to-back zstd frames into one byte string.

    The usual zstd command line stops at the end of the first frame when
    anything follows it that is not another frame, and the archives are padded
    to an alignment boundary with zero bytes, so it stops here. Decompressing
    one frame at a time and stepping over the padding avoids that.
    """
    out = bytearray()
    position = 0
    while position < len(data):
        decompressor = zstd.ZstdDecompressor()
        out += decompressor.decompress(data[position:])
        if not decompressor.unused_data:
            break
        position = len(data) - len(decompressor.unused_data)
        while position < len(data) and data[position] == 0:
            position += 1
    return bytes(out)


def cpio_filenames(archive):
    """Yield the file names in a run of 'newc' format cpio archives.

    The format is a sequence of records. Each starts with the six characters
    '070701', followed by thirteen eight-character hexadecimal fields, of which
    the last two are the size of the file's contents and the length of its name.
    The name follows the header, then the contents, each padded to a multiple of
    four bytes. A record whose name is 'TRAILER!!!' ends an archive.
    """
    position = 0
    while True:
        position = archive.find(b"070701", position)
        if position < 0:
            return
        header = archive[position : position + 110]
        if len(header) < 110:
            return
        try:
            filesize = int(header[54:62], 16)
            namesize = int(header[94:102], 16)
        except ValueError:
            position += 6
            continue
        name = archive[position + 110 : position + 110 + namesize - 1]
        if name != b"TRAILER!!!":
            yield name.decode("utf-8", "replace")
        # Header plus name, rounded up to four bytes, then contents, likewise.
        position += (110 + namesize + 3) & ~3
        position += (filesize + 3) & ~3


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    for name in cpio_filenames(decompress_all_frames(initrd_section(sys.argv[1]))):
        print(name)


if __name__ == "__main__":
    main()
