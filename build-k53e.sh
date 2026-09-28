#!/usr/bin/env bash
# Gentoo for an ASUS K53E.
#
# This machine has no UEFI: legacy AMI BIOS, last firmware update 2012 (v221).
# So everything here differs from the ThinkPad path -- MBR instead of GPT, a
# plain FAT32 /boot instead of an ESP at /boot/efi, and GRUB installed with
# --target=i386-pc into the master boot record instead of to the ESP. There is
# no Secure Boot to worry about either.
#
# --jobs 2 by default: the K53E ships with 4 GB of RAM, and -j$(nproc) on a
# 2c/4t part is enough to OOM the compiler on the heavier packages. Override
# with --jobs N if you have added memory.
#
# Console-only, like the ThinkPad build: the Intel HD 3000 has no usable 3D
# driver, so there is no desktop here by design. See README.md.
exec "$(dirname "$(readlink -f "$0")")/install-gentoo.sh" \
    --profile bios \
    --jobs 2 \
    --swap 4G \
    --hostname gentoo-k53e \
    "$@"
