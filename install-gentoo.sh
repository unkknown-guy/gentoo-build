#!/usr/bin/env bash
#
# Unattended Gentoo installer for a barebones laptop.
#
# UEFI + GPT, no encryption, OpenRC, NetworkManager + wpa_supplicant, and a
# binary Gentoo kernel. No graphical environment: console, sshd, and doas, so
# you can build up from a known-good base.
#
# Run it from a live Linux environment (any distribution) that can see the
# target disk. It erases the target disk.
#
#   ./install-gentoo.sh --disk /dev/<whole-disk> --dry-run
#   ./install-gentoo.sh --auto
#
# Two hardware profiles:
#   uefi  ThinkPad L14 Gen 2 -- GPT + ESP at /boot/efi + GRUB for x86-64-efi
#   bios  ASUS K53E          -- MBR + FAT32 /boot     + GRUB for i386-pc
# build.sh and build-k53e.sh select one; --profile overrides.
#
set -euo pipefail

# ------------------------------------------------------------------ config ---
PROFILE="23.0"
STAGE3_BASE="releases/amd64/autobuilds/current-stage3-amd64-openrc"
MIRRORS=(
    "https://distfiles.gentoo.org/pub/${STAGE3_BASE}"
    "https://ftp.osuosl.org/pub/gentoo/${STAGE3_BASE}"
)
BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/${PROFILE}/x86-64"
PORTAGE_SNAPSHOT="https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz"

HOSTNAME="gentoo-laptop"
USERNAME="gentoo"
PASSWORD=""
DISK=""
AUTO_DISK=0
SWAP_SIZE="8G"
ESP_SIZE="512M"
# The base profile is resolved at install time from "eselect profile list",
# because the release suffix changes. This is the arch half, for the regex.
PORTAGE_ARCH="default/linux/amd64"
# "uefi" = GPT + ESP at /boot/efi + GRUB for x86-64-efi (ThinkPad L14 Gen 2).
# "bios" = MBR + plain FAT32 /boot + GRUB for i386-pc (ASUS K53E, legacy AMI
# BIOS, no UEFI at all). Every difference between the two lives in here.
HW_PROFILE="uefi"
JOBS=""
PART_TABLE="gpt"
BOOT_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
BOOT_NAME="esp"
BOOT_MOUNT="/boot/efi"
BOOT_FSTYPE="vfat"
GRUB_TARGET="x86-64-efi"
NEED_UEFI=1
NEED_SECUREBOOT=1
BOOTABLE_FLAG=""
DRY_RUN=0
ASSUME_YES=0
USE_BINHOST=1

TARGET="/mnt/gentoo"
MOUNTED=0
TARBALL=""

# ------------------------------------------------------------------ output ---
if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RD=$'\033[31m'
else
    C_B=""; C_R=""; C_G=""; C_Y=""; C_RD=""
fi

info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s%s%s\n' "$C_G" "$*" "$C_R"; }
warn() { printf '  %s%s%s\n' "$C_Y" "$*" "$C_R"; }
die()  {
    printf '\n%serror:%s %s\n' "$C_RD" "$C_R" "$*" >&2
    [[ -n "${LOGFILE:-}" && -f "$LOGFILE" ]] && printf '  (full output: %s)\n' "$LOGFILE" >&2
    exit 1
}
plan() { printf '  %swould:%s %s\n' "$C_Y" "$C_R" "$*"; }
# run() makes the whole script safe to dry-run: it echoes instead of executing.
run()  { if ((DRY_RUN)); then plan "$*"; else "$@"; fi; }

cleanup() {
    local rc=$?
    if ((MOUNTED)); then
        warn "unmounting after an error; the target is probably incomplete"
        sync
        umount -R "$TARGET" 2>/dev/null || true
    fi
    [[ -n "$TARBALL" && -f "$TARBALL" ]] && rm -f "$TARBALL"
    return $rc
}
trap cleanup EXIT
trap 'die "interrupted"' INT TERM

usage() {
    cat <<EOF
Barebones unattended Gentoo installer (UEFI/GPT, OpenRC, no GUI)

  --disk DEVICE     target whole disk, e.g. /dev/nvme0n1 or /dev/sda (erased)
                    run "lsblk" first; partitions and live media are refused
  --auto            pick the largest unmounted non-removable disk
  --hostname NAME   default: $HOSTNAME
  --user NAME       default: $USERNAME
  --password PW     password for the user and root; prompted for if omitted
  --swap SIZE       default: $SWAP_SIZE
  --no-swap         do not create a swap partition
  --no-binhost      compile everything from source (hours instead of ~20 min)
  --profile P       uefi (GPT + ESP + GRUB-UEFI) or bios (MBR + /boot + GRUB-BIOS)
  --jobs N          parallel build jobs (default: nproc; lower it on small RAM)
  --dry-run         print the plan and change nothing
  --yes             skip the destructive confirmation prompt
  -h, --help        this text

Always dry-run first:

  ./install-gentoo.sh --auto --dry-run
EOF
}

# ------------------------------------------------------------------- args ---
while (( $# )); do
    case "$1" in
        --disk)       DISK="${2:?}"; shift 2 ;;
        --auto)       AUTO_DISK=1; shift ;;
        --hostname)   HOSTNAME="${2:?}"; shift 2 ;;
        --user)       USERNAME="${2:?}"; shift 2 ;;
        --password)   PASSWORD="${2:?}"; shift 2 ;;
        --swap)       SWAP_SIZE="${2:?}"; shift 2 ;;
        --no-swap)    SWAP_SIZE=""; shift ;;
        --no-binhost) USE_BINHOST=0; shift ;;
        --profile)    HW_PROFILE="${2:?uefi or bios}"; shift 2 ;;
        --jobs)       JOBS="${2:?parallel build jobs}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1   (see --help)" ;;
    esac
done

# --------------------------------------------------------------- preflight ---
need_tools() {
    local missing=() t
    for t in sfdisk mkfs.ext4 mkfs.vfat mkswap tar xz curl partprobe \
             mount umount chroot lsblk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]})) || return 0
    cat >&2 <<EOF

missing tools: ${missing[*]}

  Gentoo live ISO:  emerge sys-apps/util-linux sys-fs/dosfstools sys-fs/e2fsprogs \\\
                    net-misc/curl app-arch/xz-utils
  Arch:             pacman -S util-linux dosfstools e2fsprogs curl xz
  Debian/Ubuntu:    apt install fdisk util-linux mount dosfstools e2fsprogs \\\
                    curl xz-utils
  Fedora:           dnf install util-linux dosfstools e2fsprogs curl xz
  openSUSE:         zypper install util-linux dosfstools e2fsprogs curl xz

  (mkfs.vfat comes from dosfstools, sfdisk from fdisk/util-linux, xz from
   xz-utils/xz. Every mainstream live ISO already has all of them.)

EOF
    die "install the tools above and re-run"
}

# The live system has to already have working internet: this script downloads
# stage3, the Portage snapshot and every package. It deliberately does not try
# to configure networking for you, because doing it wrong on a live system is
# easy and a half-configured interface mid-install is worse than a clear error.
require_live_network() {
    command -v ip >/dev/null 2>&1 || command -v ifconfig >/dev/null 2>&1 || return 0
    local ifaces up
    ifaces=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true)
    [[ -n "$ifaces" ]] || die "no network interface found, only loopback.
    If this live ISO needs networking configured by hand, do it now, e.g.:
      Gentoo:  ip link set up eth0 && dhcpcd eth0
      Arch:    ip link set up eth0 && dhcpcd
      Debian:  ip link set up eth0 && dhcpcd   (or: ifup eth0)"
    up=""
    local i
    for i in $ifaces; do
        [[ "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" == up ]] && up="$up $i"
    done
    [[ -n "$up" ]] || die "no network interface is up ($ifaces found).
    Bring one up before running, e.g. 'ip link set up eth0 && dhcpcd eth0'."
}

check_uefi() {
    (( NEED_UEFI )) || {
        if [[ -d /sys/firmware/efi ]]; then
            warn "this live system booted in UEFI mode, but --profile=bios
    installs a legacy BIOS bootloader. The installed system must then be
    booted in legacy/CSM-off mode, or it will not find GRUB."
        else
            ok "booted in legacy BIOS mode"
        fi
        return 0
    }
    [[ -d /sys/firmware/efi ]] && { ok "booted in UEFI mode"; return 0; }
    die "this machine booted in legacy BIOS/CSM mode, which this script does not support.
    Reboot into UEFI and try again. On a ThinkPad: press F1 at power-on, then
    Config -> Security -> Secure Boot -> Disabled, and set boot mode to UEFI only."
}

check_secure_boot() {
    (( NEED_SECUREBOOT )) || return 0   # legacy BIOS has no Secure Boot
    command -v efi-readvar >/dev/null 2>&1 || return 0
    if efi-readvar SecureBoot 2>/dev/null | grep -qi enabled; then
        warn "Secure Boot is ENABLED. The kernel installed here is unsigned and will not boot."
        ((ASSUME_YES)) && { warn "continuing because --yes was given"; return 0; }
        die "disable Secure Boot in the firmware setup, then re-run."
    fi
    return 0
}

check_network() {
    local m
    for m in "${MIRRORS[@]}"; do
        if curl -sf --max-time 20 "$m/latest-stage3-amd64-openrc.txt" -o /dev/null 2>&1; then
            ok "mirror reachable: $m"
            return 0
        fi
    done
    die "no mirror reachable. Portage needs the internet; check the connection."
}

# Every whole disk that qualifies as a target: not removable, nothing mounted
# on it. Deliberately works off lsblk's NAME column rather than assuming a
# /dev/nvme0n1 or /dev/sda layout, so it behaves the same on NVMe, SATA, USB
# and eMMC. Ordered largest first.
list_candidate_disks() {
    lsblk -dnpo NAME,TYPE,RM,MOUNTPOINT 2>/dev/null \
        | awk '$2=="disk" && $3=="0" && $4=="" {print $1}' \
        | while read -r dev; do
              printf '%s %s\n' "$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)" "$dev"
          done \
        | sort -rn | cut -d' ' -f2
}

auto_pick_disk() {
    local d
    d=$(list_candidate_disks | head -1 || true)
    [[ -n "$d" ]] || die "--auto found no candidate disk.
    Only unmounted, non-removable whole disks qualify (a live USB is excluded).
    Run 'lsblk' and pass one explicitly with --disk."
    printf '%s' "$d"
}

# Turn a root= token into a real /dev path. lsblk will not resolve "UUID=...",
# and silently returning nothing here would disable the live-system guard
# entirely, which is exactly the case that matters when booted from a USB.
resolve_root_token() {
    local tok="$1" p
    case "$tok" in
        /dev/*)    printf '%s' "$tok"; return 0 ;;
        UUID=*)    p="/dev/disk/by-uuid/${tok#UUID=}" ;;
        LABEL=*)   p="/dev/disk/by-label/${tok#LABEL=}" ;;
        PARTUUID=*) p="/dev/disk/by-partuuid/${tok#PARTUUID=}" ;;
        *)         return 1 ;;
    esac
    [[ -e "$p" ]] || return 1
    readlink -f "$p"
}

# The whole disk the currently running system booted from, or empty if that
# cannot be determined (an overlay-root live system has no backing device).
# Used to refuse to erase the medium the installer is running from.
live_system_disk() {
    local src pk

    # findmnt gives a real path but may carry a btrfs subvolume suffix.
    src=$(findmnt -no SOURCE / 2>/dev/null | head -1 || true)
    src="${src%%[*}"
    if [[ -z "$src" || "$src" == overlay* || ! -e "$src" ]]; then
        src=$(sed -n 's/.*[^a-z]root=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -1)
        src=$(resolve_root_token "$src" 2>/dev/null) || src=""
    fi
    [[ -n "$src" && -e "$src" ]] || return 0

    pk=$(lsblk -nrpo PKNAME "$src" 2>/dev/null | head -1 | tr -d ' ' || true)
    if [[ -n "$pk" ]]; then
        # util-linux >= 2.33 already reports PKNAME as a full path.
        [[ "$pk" == /* ]] || pk="/dev/$pk"
        printf '%s' "$pk"
    elif [[ "$(lsblk -dnpo TYPE "$src" 2>/dev/null | tr -d ' ')" == disk ]]; then
        # root lives directly on a whole disk (no partition table)
        printf '%s' "$src"
    fi
    return 0
}

# Apply a profile. Called once from main, before anything reads these values.
apply_profile() {
    case "$HW_PROFILE" in
        uefi)
            # The raw ESP GUID, not the name "UESP": minimal live ISOs often
            # ship no partition type list, and an unresolvable name makes
            # sfdisk write the GPT and then fail to add partition 1.
            PART_TABLE="gpt";      BOOT_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
            BOOT_NAME="esp"
            BOOT_MOUNT="/boot/efi"; BOOT_FSTYPE="vfat"
            GRUB_TARGET="x86-64-efi"
            NEED_UEFI=1; NEED_SECUREBOOT=1; BOOTABLE_FLAG=""
            ;;
        bios)
            # No UEFI on this machine, so there is no EFI System Partition and
            # nothing to register in NVRAM. /boot is an ordinary FAT32 primary
            # partition of Linux type 83, flagged bootable.
            PART_TABLE="dos";     BOOT_TYPE="83";   BOOT_NAME="boot"
            BOOT_MOUNT="/boot";   BOOT_FSTYPE="vfat"
            GRUB_TARGET="i386-pc"
            NEED_UEFI=0; NEED_SECUREBOOT=0; BOOTABLE_FLAG=", bootable"
            ;;
        *) die "unknown --profile '$HW_PROFILE' (expected: uefi or bios)" ;;
    esac
}

# ------------------------------------------------------------------ layout ---
part_label() {
    lsblk -nrpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk -v w="$1" '$2==w {print $1; exit}' || true
}

show_layout() {
    local swap="${SWAP_SIZE:-none}"
    if [[ "$HW_PROFILE" == uefi ]]; then
        cat <<EOF
  disk    : $DISK
  table   : GPT
  esp     : ${ESP_SIZE}  fat32  -> /boot/efi
  swap    : ${swap}
  root    : remainder ext4  -> /
EOF
    else
        cat <<EOF
  disk    : $DISK
  table   : MBR (msdos)
  boot    : ${ESP_SIZE}  fat32  -> /boot   (type 83, bootable)
  swap    : ${swap}
  root    : remainder ext4  -> /
EOF
    fi
}

# Run the exact partition script against a throwaway sparse image first. This
# costs nothing (sparse files allocate nothing) and catches an entire class of
# failure -- unresolvable type names, geometry that does not fit, a typo in a
# label -- before a single sector of the real disk is touched. Without it, a
# bad script writes the table and then dies, leaving you with a wiped disk and
# no partitions. The scratch image is the size of the real disk, capped, so a
# target that is simply too small fails here too.
validate_partition_script() {
    local script="$1" img sz out rc=0
    sz=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    (( sz > 0 )) || sz=$((32 * 1024 * 1024 * 1024))
    (( sz > 64 * 1024 * 1024 * 1024 )) && sz=$((64 * 1024 * 1024 * 1024))
    img=$(mktemp "${TMPDIR:-/tmp}/gbi-sfdisk-test.XXXXXX") || {
        warn "could not create a scratch file; skipping partition table validation"
        return 0; }
    truncate -s "$sz" "$img" 2>/dev/null || truncate -s 1G "$img"
    rc=0
    out=$(sfdisk --quiet --label "$PART_TABLE" "$img" <<<"$script" 2>&1) || rc=$?
    rm -f "$img"
    if (( rc == 0 )); then
        ok "partition table validated on a ${sz}-byte scratch image"
        return 0
    fi
    printf '%s\n' "$out" >&2
    die "the partition script is not valid for a $((sz / 1024 / 1024 / 1024))G disk.
  Nothing has been written to $DISK. The error from sfdisk is above; if it
  says 'Failed to add #1 partition', the live system has no partition type
  list, which means type= names will not resolve. Use raw type GUIDs."
}

# sfdisk sizes accept suffixes (512M, 8G). The last partition takes the rest.
write_partitions() {
    local script
    if [[ -n "$SWAP_SIZE" ]]; then
        script="label: $PART_TABLE
start=1MiB, size=${ESP_SIZE}, type=$BOOT_TYPE, name=$BOOT_NAME$BOOTABLE_FLAG
size=${SWAP_SIZE}, type=swap, name=swap
type=linux, name=root"
    else
        script="label: $PART_TABLE
start=1MiB, size=${ESP_SIZE}, type=$BOOT_TYPE, name=$BOOT_NAME$BOOTABLE_FLAG
type=linux, name=root"
    fi
    if ((DRY_RUN)); then
        plan "wipe $DISK and write this partition table:"
        printf '%s\n' "$script" | sed 's/^/           /'
    else
        printf '%s\n' "$script" | sed 's/^/           /'
    fi
    validate_partition_script "$script"
    ((DRY_RUN)) && return 0
    sfdisk --wipe always --label "$PART_TABLE" "$DISK" <<<"$script"

    # Make the new partitions actually appear. partprobe alone is not enough:
    # on virtio it usually cannot re-read the table, and on some USB bridges
    # and card readers it returns "device busy". Both leave the partition
    # device nodes missing, which surfaces much later as a confusing
    # "could not find the esp partition". Try each mechanism, then wait.
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    partx --update "$DISK" 2>/dev/null || true
    blockdev --rereadpt "$DISK" 2>/dev/null || true
    udevadm trigger --subsystem-match=block "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    wait_for_partitions
}

# Poll until the boot and root partitions are visible, or give up with enough
# context to diagnose it. Device node creation is async, so a fixed sleep is
# both too slow on a fast disk and too short on a slow one.
wait_for_partitions() {
    local i boot root
    for ((i = 0; i < 30; i++)); do
        boot=$(part_label "$BOOT_NAME")
        root=$(part_label root)
        if [[ -n "$boot" && -n "$root" && -b "$boot" && -b "$root" ]]; then
            ok "partitions visible (${boot}, ${root})"
            return 0
        fi
        sleep 1
    done
    lsblk -o NAME,TYPE,SIZE,FSTYPE,PARTLABEL "$DISK" >&2 || true
    die "the new partitions on $DISK never appeared.
  sfdisk wrote the table (see above), but the kernel has not created the
  partition devices. This usually means the bus cannot re-read the table.
  Try, in order: partx --update $DISK ; blockdev --rereadpt $DISK ;
  or reboot from the live USB again and rerun."
}

format_partitions() {
    local esp root swap
    esp=$(part_label "$BOOT_NAME")
    root=$(part_label root)
    swap=$(part_label swap || true)
    [[ -n "$esp"  ]] || die "could not find the $BOOT_NAME partition (sfdisk did not label it)"
    [[ -n "$root" ]] || die "could not find the root partition"

    info "formatting: $esp (fat32), $root (ext4)${swap:+, $swap (swap)}"
    mkfs.vfat -F32 -n "$BOOT_NAME" "$esp"  >/dev/null
    mkfs.ext4 -q -L root "$root"
    [[ -z "$swap" ]] || mkswap -L swap "$swap" >/dev/null
    ok "formatted"

    mount -t ext4 "$root" "$TARGET"
    MOUNTED=1
    # stage3 is unpacked *before* /boot/efi and the pseudo-filesystems are
    # mounted: extracting over them would write into the ESP and the host's /dev.
    return 0
}

mount_targets() {
    local esp swap
    esp=$(part_label "$BOOT_NAME")
    swap=$(part_label swap || true)
    [[ -n "$esp" ]] || die "could not find the $BOOT_NAME partition"

    mkdir -p "$TARGET$BOOT_MOUNT" "$TARGET/proc" "$TARGET/sys" "$TARGET/dev"
    info "mounting $BOOT_MOUNT and the pseudo-filesystems"
    mount -t vfat "$esp" "$TARGET$BOOT_MOUNT"
    [[ -z "$swap" ]] || swapon "$swap"
    local m
    for m in proc sys dev; do
        mount --rbind "/$m" "$TARGET/$m"
        mount --make-rslave "$TARGET/$m" 2>/dev/null || true
    done
    ok "mounted at $TARGET"
}

# ------------------------------------------------------------------ stage3 ---
fetch_stage3() {
    local m name
    for m in "${MIRRORS[@]}"; do
        if curl -sf --max-time 30 "$m/latest-stage3-amd64-openrc.txt" -o /tmp/.stage3.ptr 2>/dev/null; then
            # The pointer file is PGP-signed; the filename is the first
            # non-comment, non-armour line.
            name=$(awk '/^stage3-amd64-openrc-.*\.tar\.xz/ {print $1; exit}' /tmp/.stage3.ptr)
            if [[ -n "$name" ]]; then
                printf '%s\t%s' "$name" "$m"
                return 0
            fi
        fi
    done
    die "could not determine the current stage3 filename from any mirror"
}

download_and_unpack() {
    local pair name base tarball
    pair=$(fetch_stage3)
    name="${pair%%$'\t'*}"; base="${pair#*$'\t'}"
    tarball="/tmp/$name"
    TARBALL="$tarball"

    info "downloading $name (about 280 MB)"
    if ! run curl -fL --progress-bar -o "$tarball" "$base/$name"; then
        return 0
    fi
    ok "downloaded"

    info "unpacking stage3 into $TARGET"
    # Modern stage3 tarballs extract straight into the target. A few wrap
    # everything in one directory, so handle that shape too.
    if ! run tar -xpf "$tarball" -C "$TARGET" --xattrs --xattrs-include='*' 2>/dev/null; then
        if ! run tar -xpf "$tarball" -C "$TARGET"; then
            die "could not unpack $name"
        fi
    fi
    if [[ ! -d "$TARGET/etc" ]]; then
        local inner
        inner=$(find "$TARGET" -mindepth 1 -maxdepth 1 -type d | head -1)
        [[ -n "$inner" && -d "$inner/etc" ]] || die "unexpected stage3 layout in $TARGET"
        info "stage3 has a wrapping directory: $(basename "$inner")"
        run sh -c "shopt -s dotglob; mv '$inner'/* '$TARGET'/; rmdir '$inner'"
    fi
    ok "stage3 unpacked"
}

# ------------------------------------------------------------------ chroot ---
in_chroot() { chroot "$TARGET" /usr/bin/env bash -c "cd / && $1"; }
# Feed a script (on stdin) into the chroot, with a readable failure message.
in_chroot_script() {
    local script name
    script=$(cat)
    name=$(printf '%s' "$script" | sed -n 's/^# *//p' | head -1)
    if ((DRY_RUN)); then
        plan "chroot step: ${name:-inline script}"
        printf '%s\n' "$script" | sed 's/^/         /' | tail -n +2
        return 0
    fi
    info "${name:-applying configuration}"
    printf '%s\n' "$script" | in_chroot 'bash -s' >/dev/null
}

# ------------------------------------------------------------------ portage ---
setup_portage() {
    if ((DRY_RUN)); then
        plan "write make.conf and resolve the base Portage profile (binhost=$USE_BINHOST)"
        return 0
    fi
    mkdir -p "$TARGET/etc/portage"
    {
        echo "# Written by install-gentoo.sh"
        echo "MAKEOPTS=\"-j${JOBS:-$(nproc)}\""
        echo "EMERGE_DEFAULT_OPTS=\"--backtrack=5 --autounmask-write\""
        echo "ACCEPT_LICENSE=\"*\""
        # OpenRC, not systemd. -consolekit because OpenRC uses seatd/logind-free
        # sessions and consolekit pulls in a lot of dead machinery.
        echo "USE=\"-systemd -systemd-units -systemd-login-session -systemd-timesyncd -consolekit\""
        if ((USE_BINHOST)); then
            # Prebuilt packages: this is the difference between ~20 minutes and
            # many hours. Get it wrong and everything compiles from source.
            echo "FEATURES=\"getbinpkg binpkg-request-signature\""
            echo "BINHOST=\"$BINHOST\""
        fi
        # grub-install needs to be told which platform to target, and this is a
        # make.conf variable, not a USE flag: the old "bios"/"efi" flags are
        # gone from modern sys-boot/grub, which uses a grub_platforms
        # USE_EXPAND fed by this variable. The amd64 profile does set a
        # default, but a BIOS live environment can build a different one, so
        # set it explicitly rather than inherit and hope.
        if [[ "$HW_PROFILE" == bios ]]; then
            echo 'GRUB_PLATFORMS="pc"'
        else
            echo 'GRUB_PLATFORMS="efi-64"'
        fi
    } > "$TARGET/etc/portage/make.conf"

    # Portage 3.0.8x reads these as single files; a leftover *directory* of the
    # same name is silently ignored, which quietly voids every entry.
    rm -rf "$TARGET/etc/portage/package.use" "$TARGET/etc/portage/package.mask"
    : > "$TARGET/etc/portage/package.use"
    : > "$TARGET/etc/portage/package.mask"
    # installkernel needs dracut to build an initramfs for the binary kernel.
    echo "sys-kernel/installkernel dracut" >> "$TARGET/etc/portage/package.use"
    # wpa_supplicant's dbus support needs a session bus that OpenRC has no
    # equivalent of; NetworkManager talks to it over the socket anyway.
    echo "net-misc/wpa_supplicant -dbus" >> "$TARGET/etc/portage/package.use"
    ok "Portage configured (${USE_BINHOST:+binhost enabled}${USE_BINHOST:-source only})"
}

# The profile symlink has to be set inside the target, and only after the tree
# is synced: eselect resolves "default/linux/amd64" against the profiles that
# actually exist, and on a freshly unpacked stage3 that tree is empty.
# Parse the plain base profile out of "eselect profile list". eselect wants a
# concrete profile such as default/linux/amd64/23.0, not the default/linux/amd64
# symlink, and the release suffix moves over time, so ask rather than guess.
# Whole-field anchored, so a desktop variant is never mistaken for the base.
resolve_portage_profile() {
    local arch="${PORTAGE_ARCH:-default/linux/amd64}"
    # Match a whole whitespace-delimited field, anchored at both ends. A
    # substring match would happily return "default/linux/amd64/23.0" out of
    # "default/linux/amd64/23.0/desktop" and select a desktop profile.
    printf '%s\n' "$1" \
        | awk -v a="$arch" '{ for (i=1;i<=NF;i++)
                if ($i ~ "^" a "/[0-9][0-9.]*[0-9]$") { print $i; exit } }' || true
}

select_profile() {
    if ((DRY_RUN)); then
        plan "select the base Portage profile for this release (default/linux/amd64/<release>)"
        return 0
    fi
    local list target
    list=$(in_chroot "eselect profile list 2>/dev/null" || true)
    target=$(resolve_portage_profile "$list")
    if [[ -z "$target" ]]; then
        # Not fatal. stage3 already ships the correct base profile selected, so
        # carrying on is strictly better than dying over a cosmetic step.
        warn "could not resolve a base Portage profile from eselect;
    keeping the one stage3 shipped with"
        return 0
    fi
    if in_chroot "eselect profile set $target"; then
        ok "Portage profile: $target"
    else
        warn "eselect refused profile $target; keeping the stage3 default"
    fi
}

sync_portage() {
    info "syncing the Portage tree (a few hundred MB)"
    run in_chroot "emerge --sync"
    ok "tree synced"
}

install_packages() {
    local pkgs=(
        # kernel and bootloader
        sys-kernel/gentoo-kernel-bin
        sys-boot/grub
        # networking
        net-misc/networkmanager
        net-misc/wpa_supplicant
        # access
        app-admin/doas
        net-misc/openssh
        # laptop hardware
        sys-apps/acpid                    # lid switch, power button, brightness keys
        app-power/power-profiles-daemon    # on battery vs plugged in
        # firmware: L14 Gen 2 ships MT7921 (MediaTek) or Intel AX201
        sys-firmware/linux-firmware
        sys-firmware/intel-firmware
        sys-firmware/mediatek-firmware
        sys-firmware/sof-firmware          # Intel SoF audio
        # odds and ends
        app-misc/chrony                    # clock; TLS and logs need it right
        app-editors/vim
        dev-vcs/git
        app-misc/pciutils
        sys-apps/usbutils
    )
    if [[ "$HW_PROFILE" == uefi ]]; then
        # UEFI only: this is what writes the boot entry into firmware NVRAM.
        # The BIOS profile writes its boot record straight to the MBR and
        # never consults it.
        pkgs+=(sys-boot/efibootmgr)
    fi
    if ((DRY_RUN)); then
        plan "emerge --update --deep --newuse --autounmask-write @world"
        plan "emerge --oneshot: ${pkgs[*]}"
        return 0
    fi
    info "installing @world (binhost: ~20 min, source: hours)"
    in_chroot "emerge --update --deep --newuse --autounmask-write @world" >/dev/null
    info "installing the laptop package set"
    in_chroot "emerge --oneshot --noreplace --newuse --autounmask-write ${pkgs[*]}" >/dev/null
    ok "packages installed"
}

# ------------------------------------------------------------------- config ---
base_config() {
    if ((DRY_RUN)); then
        plan "write /etc/hostname, /etc/hosts, /etc/fstab (label-based, TRIM weekly)"
        return 0
    fi
    cat > "$TARGET/etc/hostname" <<EOF
$HOSTNAME
EOF
    cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF
    # Referenced by label, so a change in disk enumeration order does not break
    # booting. pass=2 would try to fsck vfat, which is meaningless.
    cat > "$TARGET/etc/fstab" <<EOF
# <file system>   <mount point>  <type>  <options>               <dump> <pass>
LABEL=$BOOT_NAME         $BOOT_MOUNT       $BOOT_FSTYPE   defaults,noatime        0      0
$( [[ -n "$SWAP_SIZE" ]] && echo "LABEL=swap        none            swap   sw,noatime              0      0" )
LABEL=root        /               ext4   defaults,noatime        0      1
tmpfs             /tmp            tmpfs  rw,nosuid,nodev,size=2G  0      0
EOF
    sed -i '/^$/d' "$TARGET/etc/fstab"
    mkdir -p "$TARGET/etc/conf.d"
    cat > "$TARGET/etc/conf.d/fstrim" <<'EOF'
# Periodic SSD TRIM, enabled by the localmount service.
fstrim_enable="yes"
EOF
    ok "base configuration written"
}

make_user() {
    if ((DRY_RUN)); then
        plan "create user '$USERNAME' (wheel,audio,video,usb,plugdev) and set passwords"
        plan "write /etc/doas.conf permitting wheel, and fix doas permissions"
        return 0
    fi
    in_chroot "useradd -m -G wheel,audio,video,usb,plugdev -s /bin/bash '$USERNAME'" >/dev/null

    # Write the password file on the host and chpasswd inside the chroot, so no
    # password ever appears in this script's output or in a log.
    local tmppw
    tmppw=$(mktemp) || die "could not create a temporary file for the password"
    chmod 600 "$tmppw"
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" > "$tmppw"
    printf 'root:%s\n' "$PASSWORD" >> "$tmppw"
    cp "$tmppw" "$TARGET/tmp/.pw"
    chmod 600 "$TARGET/tmp/.pw"
    rm -f "$tmppw"
    in_chroot "chpasswd < /tmp/.pw && rm -f /tmp/.pw" >/dev/null

    # doas ships no config and reads /etc/doas.conf (NOT /etc/doas/doas.conf).
    # It refuses to run if the file is group/other-writable, and the binary must
    # stay setuid AND world-executable (4750 makes it unusable for everyone else).
    cat > "$TARGET/etc/doas.conf" <<EOF
# Written by install-gentoo.sh
#
# "persist" keeps the caller's environment (PATH, DISPLAY, XDG_*). Drop the
# word for a stricter rule that resets the environment instead.
permit persist :wheel
EOF
    chown 0:0 "$TARGET/etc/doas.conf"
    chmod 0600 "$TARGET/etc/doas.conf"
    if [[ -f "$TARGET/usr/bin/doas" ]]; then
        chown 0:0 "$TARGET/usr/bin/doas"
        chmod 4755 "$TARGET/usr/bin/doas"
    fi
    ok "user '$USERNAME' and doas configured"
}

openrc_services() {
    in_chroot_script <<'EOS'
# OpenRC runlevels
rc-update add hostname boot
rc-update add hwclock boot
rc-update add syslog boot
rc-update add bootmisc boot
rc-update add sysfs boot
rc-update add procfs boot
rc-update add modules boot
rc-update add urandom boot
rc-update add localmount boot
rc-update add device-mapper boot
rc-update add dmesg boot
rc-update add termencoding keymaps consolefont
rc-update add net boot
rc-update add mount-ro remount
rc-update add root remount
rc-update add NetworkManager default
rc-update add sshd default
rc-update add acpid default
rc-update add power-profiles default
rc-update add chronyd default
EOS
}

network_config() {
    in_chroot_script <<'EOS'
# NetworkManager and Wi-Fi
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave.conf <<'CONF'
[connection]
# 2 = never powersave. Both mt7921e and iwlwifi can stall the link after a few
# minutes with powersave on.
wifi.powersave = 2
CONF
cat > /etc/modprobe.d/wifi-powersave.conf <<'CONF'
# Intel AX200/AX201: same stall, and iwlwifi's default power_save=1 triggers it.
options iwlwifi power_save=0 d0_timeout=100
# MediaTek MT7921 (L14 Gen 2, types 20X1/20X2/20X5/20X6)
options mt7921e power_save=0
CONF
# A hand-connect fallback if NetworkManager has not come up yet.
mkdir -p /etc/wpa_supplicant
chmod 700 /etc/wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<'CONF'
# Fill this in on first boot if you need to connect without NetworkManager:
#   wpa_passphrase "YOUR-SSID" >> /etc/wpa_supplicant/wpa_supplicant.conf
# then chmod 600 the file and:  wpa_cli reconfigure
country=US
CONF
chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
EOS
}

install_bootloader() {
    if [[ "$HW_PROFILE" == uefi ]]; then
        # Unquoted heredoc: $DISK has to come from here. Anything meant for the
        # target is escaped, including the loader path, whose backslashes must
        # survive intact.
        in_chroot_script <<EOS
grub-install --target=x86-64-efi --efi-directory=/boot/efi \
             --bootloader-id=Gentoo --recheck
# Register the loader in firmware NVRAM. Without an entry, OVMF and several
# firmwares find nothing bootable and sit at a boot menu instead. efivarfs is
# already there because the live environment is itself UEFI-booted.
esp_part=\$(findmnt -n -o PARTN /boot/efi 2>/dev/null || echo 1)
efibootmgr --create --disk $DISK --part "\$esp_part" --label Gentoo \
           --loader '\EFI\Gentoo\grubx64.efi' \
    || echo "WARNING: could not create the NVRAM boot entry"
# Also write the removable path, EFI/BOOT/BOOTX64.EFI. Cheap insurance for
# firmware that only scans that location. It would clobber a Windows loader,
# but these machines are single-boot, and leaving firmware unable to find GRUB
# is a worse outcome.
grub-install --target=x86-64-efi --efi-directory=/boot/efi --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg
EOS
    else
        # BIOS target. grub-install writes a boot record to the whole disk
        # (the MBR) and stages GRUB under /boot/grub, which is already the
        # FAT32 partition mounted above. No --efi-directory, no NVRAM entry:
        # there is no UEFI firmware to register anything with.
        in_chroot_script <<EOS
grub-install --target=i386-pc --recheck $DISK
grub-mkconfig -o /boot/grub/grub.cfg
EOS
    fi
    # An empty grub.cfg is the silent way to end up unbootable: grub-mkconfig
    # still exits 0 and GRUB still boots, it just has no kernel to run.
    if ! in_chroot "grep -qE '^menuentry' /boot/grub/grub.cfg" 2>/dev/null; then
        warn "grub.cfg contains no menu entries."
        warn "The kernel may not be installed under /boot. Do not reboot until"
        warn "this is resolved, or you will land in a firmware boot menu."
    fi
    ok "GRUB installed ($HW_PROFILE)"
}

finalize() {
    in_chroot_script <<'EOS'
# Clean up the build environment
# The installer set a resolver so Portage could reach the mirrors; NetworkManager
# writes this file at runtime, so remove the copy we made.
rm -f /etc/resolv.conf
ecache clean --deep 2>/dev/null || true
rm -rf /var/cache/portage/* 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
EOS
    if ((DRY_RUN)); then
        plan "sync, unmount $TARGET, and remove the installer"
        MOUNTED=0
        return 0
    fi
    sync
    info "unmounting $TARGET"
    umount -R "$TARGET"
    MOUNTED=0
    ok "unmounted"
}

# -------------------------------------------------------------------- main ---
confirm() {
    ((DRY_RUN)) && return 0
    ((ASSUME_YES)) && { warn "skipping confirmation (--yes)"; return 0; }
    cat <<EOF

$(printf '%s' "$C_RD")This ERASES every partition on $DISK.$(printf '%s' "$C_R")

$(show_layout)
$(printf '    Type the device path to continue: %s%s%s' "$C_B" "$DISK" "$C_R")
EOF
    local reply
    read -r -p "    confirm> " reply
    [[ "$reply" == "$DISK" ]] || die "aborted (nothing was changed)"
}

dry_run_report() {
    local partline bootline bl
    if [[ "$HW_PROFILE" == uefi ]]; then
        partline="GPT on $DISK"
        bootline="esp ${ESP_SIZE} -> /boot/efi (vfat)"
        bl="grub-install --target=x86-64-efi --efi-directory=/boot/efi"
    else
        partline="MBR/msdos on $DISK"
        bootline="boot ${ESP_SIZE} -> /boot (fat32, type 83, bootable)"
        bl="grub-install --target=i386-pc $DISK  (writes the master boot record)"
    fi
    cat <<EOF

  plan
  ----
  partition : $partline
              $bootline
              ${SWAP_SIZE:+swap ${SWAP_SIZE}; }root = remainder -> / (ext4)
  stage3    : latest from the first reachable mirror
  portage   : $PORTAGE_ARCH/<release> (resolved from eselect), $( ((USE_BINHOST)) && echo "binary packages (binhost)" || echo "source only, expect hours")
  packages  : @world + kernel/grub/NetworkManager/wpa_supplicant/doas/openssh
              + acpid/power-profiles/chrony + firmware + vim/git/pciutils/usbutils
  services  : net + NetworkManager + sshd + acpid + power-profiles + chronyd
  bootloader: $bl
  user      : $USERNAME (wheel,audio,video,usb,plugdev), root + $USERNAME share a password

EOF
    ok "dry run only; nothing on $DISK was touched"
}

main() {
    local esp root

    # Everything from here on is teed to a log. Without this a failure halfway
    # through an emerge is unrecoverable, because the console scrolled past and
    # the exit code says nothing about which of 200 packages gave up.
    LOGFILE="/tmp/install-gentoo-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1
    ok "logging to $LOGFILE"

    apply_profile
    need_tools
    if (( !DRY_RUN )); then
        (( EUID == 0 )) || die "must run as root (try: sudo ./install-gentoo.sh)"
        [[ -e /run/systemd/container ]] && die "running inside a container; this needs a real live system"
    fi
    check_uefi
    check_secure_boot
    require_live_network

    if [[ -z "$DISK" ]]; then
        if (( !AUTO_DISK )); then
            local hint
            hint=$(list_candidate_disks | head -1 || true)
            die "no target disk. Use --auto, or --disk with a whole device${hint:+ (candidates: $(list_candidate_disks | tr '\n' ' '))}."
        fi
        DISK="$(auto_pick_disk)"
    fi
    # Target validation is read-only, so it runs in --dry-run too: a dry run
    # that green-lit a disk the real run would refuse is worse than no dry run.
    local dtype live
    if [[ ! -b "$DISK" ]]; then
        if (( DRY_RUN )); then
            die "$DISK is not a block device on this machine. Device names vary
    (NVMe /dev/nvme0n1, SATA /dev/sda, eMMC /dev/mmcblk0) -- run 'lsblk'."
        fi
        die "$DISK is not a block device. Run 'lsblk' to see the real device names."
    fi

    # Refuse a partition: a partition table has to go on a whole disk.
    dtype=$(lsblk -dnpo TYPE "$DISK" 2>/dev/null | head -1 | tr -d " " || true)
    [[ "$dtype" == "disk" ]] || die "$DISK is a '$dtype', not a whole disk.
    Install to the whole disk, without a partition suffix (p1, s1, part1, ...)."

    # Refuse the disk this live system is running from.
    live=$(live_system_disk)
    if [[ -n "$live" && "$live" == "$DISK" ]]; then
        die "$DISK is the disk you are booted from.
    Refusing to erase the running system. Boot the live USB from another device,
    or pick a different --disk."
    fi

    if lsblk -nrpo MOUNTPOINT "$DISK" 2>/dev/null | grep -q .; then
        die "$DISK has a mounted partition. Unmount it first."
    fi

    if [[ -z "$PASSWORD" ]]; then
        if ((DRY_RUN)); then
            PASSWORD="(prompted)"
        else
            local p2
            read -r -s -p "  Password for $USERNAME and root: " PASSWORD; echo
            [[ ${#PASSWORD} -ge 8 ]] || die "use at least 8 characters"
            read -r -s -p "  Confirm: " p2; echo
            [[ "$PASSWORD" == "$p2" ]] || die "passwords do not match"
        fi
    fi

    printf '\n%sBarebones Gentoo install%s -> %s\n\n' "$C_B" "$C_R" "$DISK"
    confirm
    check_network
    if ((DRY_RUN)); then
        show_layout; echo
        write_partitions
        echo
        dry_run_report
        exit 0
    fi

    mkdir -p "$TARGET"
    write_partitions
    format_partitions
    download_and_unpack          # before mounting /boot/efi and /dev
    mount_targets
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

    setup_portage
    sync_portage
    select_profile
    install_packages

    base_config
    make_user
    openrc_services
    network_config
    install_bootloader
    finalize

    cat <<EOF

$(printf '%s' "$C_G")Done.$(printf '%s' "$C_R")

  hostname   : $HOSTNAME
  user       : $USERNAME   (also the root password)
  boot menu  : "Gentoo"
  graphics   : none, console login on tty1

On first boot:

  nmcli device wifi list
  nmcli device wifi connect "YOUR-SSID" --ask
  ip -br a                       # find the address
  ssh $USERNAME@<that-address>   # from your phone or another machine

Then delete the installer so it cannot run twice:

  rm -f $(realpath "$0")

EOF
}

main "$@"
