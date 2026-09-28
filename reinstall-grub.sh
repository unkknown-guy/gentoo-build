#!/usr/bin/env bash
#
# Re-run the UEFI bootloader step on an install that is already on disk.
#
# Why this exists: an earlier revision of install-gentoo.sh installed
# grubx64.efi but never created a firmware boot entry and never wrote the
# removable fallback at EFI/BOOT/BOOTX64.EFI. On such a system the install
# reports success and the machine then boots to a firmware boot menu, because
# there is nothing registered and nothing at the path the firmware falls back
# to. This script fixes that in place, without re-running the install.
#
# It is deliberately narrow: it mounts an existing target, runs grub-install
# and efibootmgr, and unmounts. It never writes a partition table and never
# formats anything, so it is safe to run against a completed install.
#
# Usage, from a UEFI-booted live environment:
#     ./reinstall-grub.sh [--disk /dev/vda]
#
set -euo pipefail

DISK=""

usage() {
    cat <<'EOS'
Re-run the UEFI bootloader step on an existing Gentoo install.

  --disk DEV   target whole disk (default: autodetect, exactly one candidate)

The ESP and root partitions are found by filesystem type, so the partition
numbers may be anything. Nothing is partitioned or formatted.
EOS
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk) DISK="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# Must be running in EFI mode. Without efivarfs, efibootmgr cannot write the
# boot entry, and that is precisely the thing being fixed here -- so failing
# loudly up front beats a silent no-op.
if ! mountpoint -q /sys/firmware/efi/efivars; then
    cat >&2 <<'EOS'
ERROR: /sys/firmware/efi/efivars is not mounted, so this live environment is
       not booted in UEFI mode. Reboot and choose the UEFI entry for this ISO;
       in QEMU that means the OVMF/SeaBIOS-firmware option, not a legacy one.
EOS
    exit 1
fi

for tool in lsblk blkid mount umount chroot grub-install efibootmgr; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool not found on this live system" >&2; exit 1; }
done

if [[ -z "$DISK" ]]; then
    # An installed system means something is mounted from a real disk, so
    # filtering on mounted partitions is a decent proxy for "the live USB".
    mapfile -t candidates < <(
        lsblk -dnpno NAME,TYPE,TRAN | while read -r d type tran; do
            [[ "$type" == disk ]] || continue
            # A RAM disk also reports TYPE=disk, and live ISOs generally have a
            # zram device. TRAN is empty for it, whereas a real disk always
            # names its transport, so require a known one.
            case "$tran" in
                nvme|sata|scsi|sas|usb|virtio|ata|ide) ;;
                *) continue ;;
            esac
            if ! lsblk -npo MOUNTPOINT "$d" | grep -qE '^(/|/boot|/efi|/home)'; then
                echo "$d"
            fi
        done
    )
    if (( ${#candidates[@]} != 1 )); then
        printf 'ERROR: expected exactly one target disk, found %d:\n' "${#candidates[@]}" >&2
        printf '  %s\n' "${candidates[@]:-none}" >&2
        echo "Pass --disk explicitly." >&2
        exit 1
    fi
    DISK="${candidates[0]}"
fi

[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device" >&2; exit 1; }
[[ "$(lsblk -dnpo TYPE "$DISK")" == disk ]] \
    || { echo "ERROR: $DISK is not a whole disk; pass the device, not a partition" >&2; exit 1; }

# Find the partitions by filesystem type rather than by number: the numbers
# depend on the disk size and on whether swap was created, and guessing wrong
# here means mounting the wrong thing.
# The "|| true" is load-bearing: under `set -e` a failing command substitution
# aborts the script, so a disk with no ext4 would exit silently.
root_part=$(blkid -t TYPE=ext4 -o device "$DISK"* 2>/dev/null | head -1 || true)
esp_part=$(blkid -t TYPE=vfat -o device "$DISK"* 2>/dev/null | head -1 || true)

[[ -n "$root_part" ]] || { echo "ERROR: no ext4 root found on $DISK" >&2; exit 1; }
[[ -n "$esp_part"  ]] || { echo "ERROR: no vfat ESP found on $DISK" >&2; exit 1; }

echo "disk : $DISK"
echo "root : $root_part"
echo "esp  : $esp_part"
echo

TARGET=/mnt/gentoo
MOUNTED=0
cleanup() {
    local rc=$?
    if ((MOUNTED)); then
        sync
        umount -R "$TARGET" 2>/dev/null || true
    fi
    return $rc
}
trap cleanup EXIT

mkdir -p "$TARGET"
mount "$root_part" "$TARGET"
MOUNTED=1
mkdir -p "$TARGET/boot/efi" "$TARGET/proc"
mount "$esp_part" "$TARGET/boot/efi"
mount -t proc none "$TARGET/proc"
mount --rbind /dev "$TARGET/dev"
mount --rbind /sys "$TARGET/sys"
# grub-install probes the network for a key server in some configurations.
cp -f /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

esp_partnum=$(lsblk -npo PARTN "$esp_part" 2>/dev/null | head -1 | tr -d ' ' || true)
[[ -n "$esp_partnum" ]] || { echo "ERROR: could not read the ESP partition number" >&2; exit 1; }
echo "ESP partition number: $esp_partnum"

# The backslashes in the loader path are literal for efibootmgr, so the whole
# block is passed as a single-quoted argument rather than a heredoc.
chroot "$TARGET" /usr/bin/env bash -c "
    set -e
    grub-install --target=x86-64-efi --efi-directory=/boot/efi \
                 --bootloader-id=Gentoo --recheck
    grub-install --target=x86-64-efi --efi-directory=/boot/efi \
                 --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
    efibootmgr --create --disk '$DISK' --part '$esp_partnum' --label Gentoo \
               --loader '\EFI\Gentoo\grubx64.efi'
"

# grub-mkconfig exits 0 even with no kernels installed, which leaves a system
# that boots GRUB and then has nothing to run. Check rather than assume.
if ! chroot "$TARGET" grep -qE '^menuentry' /boot/grub/grub.cfg; then
    echo >&2
    echo "ERROR: /boot/grub/grub.cfg has no menu entries. The kernel is not" >&2
    echo "       installed under /boot, so this system still will not boot." >&2
    exit 1
fi

echo
echo "Loader files on the ESP:"
chroot "$TARGET" find /boot/efi/EFI -name '*.efi' | sed 's/^/  /'
echo
echo "Firmware boot entries:"
chroot "$TARGET" efibootmgr -v | sed 's/^/  /'
echo
echo "Done. Unmounting and rebooting into the new system."
