# The build environment for the Jetson Thor image.
#
# Why a container at all? mkosi drives a set of host tools -- systemd-repart to
# lay out the disk image, ukify to assemble the unified kernel image, mtools to
# populate the EFI system partition -- and it wants versions of them newer than
# most distributions ship. It also needs to create mount and user namespaces,
# which Ubuntu's AppArmor policy forbids to unprivileged users. Pinning the
# whole toolchain into one container means the build does not depend on what the
# developer's laptop or the CI runner happens to have installed, and it means
# the build runs the same way in both places.
#
# Ubuntu 26.04 is the base because it ships systemd 259 (mkosi needs at least
# 254 for systemd-repart and ukify) and because it ships ubuntu-keyring, the
# package holding the GPG keys that verify the Ubuntu archive while mkosi
# assembles the target image.

FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7

# The mkosi release this repository is written against. mkosi's configuration
# syntax changes between releases, so this is pinned rather than tracking main.
ARG MKOSI_VERSION=v27.1

ENV DEBIAN_FRONTEND=noninteractive

COPY packages.txt /tmp/packages.txt
RUN apt-get update \
    && sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/packages.txt \
       | xargs apt-get install --no-install-recommends -y \
    && rm -rf /var/lib/apt/lists/ /tmp/packages.txt

# mkosi is not packaged in Ubuntu at a recent enough version, so install the
# pinned upstream release straight from git. --break-system-packages only means
# "yes, write into the system site-packages directory"; this is a throwaway
# container, so there is nothing to break.
RUN pip3 install --break-system-packages --no-cache-dir \
    "git+https://github.com/systemd/mkosi.git@${MKOSI_VERSION}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["mkosi", "--version"]
