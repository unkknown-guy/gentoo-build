#!/usr/bin/env bash
# Gentoo for a ThinkPad L14 Gen 2. UEFI + GPT, Secure Boot off, no GUI.
# See README.md for what the machine needs and what you get.
exec "$(dirname "$(readlink -f "$0")")/install-gentoo.sh" \
    --profile uefi \
    "$@"
