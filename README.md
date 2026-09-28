# Barebones unattended Gentoo installer

One script that installs Gentoo on a laptop from a live Linux environment, with
no questions asked and no GUI. UEFI + GPT, no encryption, OpenRC, and a binary
Gentoo kernel, so you end up with a console, `sshd`, and `doas` on a system you
can trust before adding anything to it.

Written for a **ThinkPad L14 Gen 2** (UEFI; MediaTek MT7921 or Intel AX201
wireless).

## Use

```sh
git clone <this repo> && cd gentoo-barebones-installer

# 1. always look before you leap
./install-gentoo.sh --auto --dry-run

# 2. commit
./install-gentoo.sh --auto
```

## What to boot

**Any Linux live ISO.** The script downloads its own stage3, so the ISO's
Gentoo is irrelevant — an Arch or Ubuntu stick works exactly as well as
`install-amd64-minimal.iso`. You need three things:

1. **UEFI boot.** Not CSM/legacy. The script checks `/sys/firmware/efi` and
   stops with an explanation if the firmware booted it the old way.
2. **Root** — `su -` or `sudo -i`.
3. **These tools**, which every mainstream ISO already has:
   `sfdisk mkfs.ext4 mkfs.vfat mkswap tar xz curl partprobe mount umount chroot lsblk`

If something is missing the script tells you the install command for your
distro (Gentoo, Arch, Debian/Ubuntu, Fedora, openSUSE) and stops.

**Bring networking up first.** This is the usual stumbling block: the script
downloads stage3, the Portage snapshot and every package, and it deliberately
does *not* configure networking for you. On an ISO that does it for you, ignore
this. On Gentoo's minimal ISO, Arch, or anything else that starts with no
address, do it first:

```sh
ip link                                  # find the interface name
ip link set up eth0 && dhcpcd eth0       # or: ifup eth0 / udhcpc -i eth0
ping -c1 distfiles.gentoo.org            # sanity check
```

The script refuses to start if nothing is up, and prints that same hint, rather
than failing 20 minutes into a download.

Then, as root:

```sh
./install-gentoo.sh --auto --dry-run     # 1. look before you leap
./install-gentoo.sh --auto               # 2. commit
```

It asks for one password, which is used for both your user and root, and
then it wants you to type the device path to confirm. That is the only
confirmation, and it is the point of no return.

### Options

| Flag | Meaning |
| --- | --- |
| `--disk DEVICE` | target whole disk, e.g. `/dev/nvme0n1` or `/dev/sda` |
| `--auto` | largest unmounted non-removable disk |
| `--hostname NAME` | default `gentoo-laptop` |
| `--user NAME` | default `gentoo` |
| `--password PW` | skip the prompt (visible in your shell history) |
| `--swap SIZE` / `--no-swap` | default `8G` |
| `--no-binhost` | build from source: hours instead of ~20 min |
| `--dry-run` | print everything, change nothing |
| `--yes` | skip the confirmation |

## What you get

```
disk    GPT:  esp 512M (vfat, /boot/efi) | swap 8G | root = rest (ext4, /)
kernel  sys-kernel/gentoo-kernel-bin  (dist kernel, no compiling)
init    OpenRC. systemd is explicitly masked via USE.
boot    GRUB, installed to the ESP, one menu entry "Gentoo"
net     NetworkManager + wpa_supplicant, no wifi powersave
user    gentoo in wheel,audio,video,usb,plugdev, with doas
access  openssh, doas, vim, git, pciutils, usbutils
laptop  acpid (lid/power keys), power-profiles-daemon, chrony
firmware linux-firmware, intel-firmware, mediatek-firmware, sof-firmware
```

`/etc/fstab` refers to partitions by `LABEL`, so the system still boots if disk
enumeration order changes. The root filesystem keeps its journal — do not
disable it, since an unclean shutdown without a journal is a coin flip.

## After the first boot

```sh
nmcli device wifi list
nmcli device wifi connect "YOUR-SSID" --ask
ip -br a                              # address
ssh gentoo@<address>                  # from a phone or another machine
rm -f /path/to/install-gentoo.sh      # so it cannot run twice
```

## What is verified, and what is not

Being straight about this, because you are about to erase a laptop:

**Finding the right disk.** Run `lsblk` first. Names differ by machine —
`/dev/nvme0n1` (NVMe), `/dev/sda` (SATA), `/dev/mmcblk0` (eMMC) — so the script
reads the device list out of `lsblk` instead of assuming any of them, and
`--auto` shows you the candidates it considered. It refuses a partition (you
would be writing a partition table into a slice of a disk) and refuses the disk
the live system is currently booted from, so pointing it at the wrong machine
or the wrong drive fails instead of erasing something.

**Tested.** `bash -n` syntax. `--help`. A full `--dry-run` against a machine with
a real NVMe: it correctly selected the largest unmounted non-removable disk,
checked UEFI, found a mirror, printed the partition table, and touched nothing.
The `doas` configuration, `fstab`, `OpenRC` service lists, and Portage config
are all ports of code that is running on the Gentoo VM this was extracted from,
where those parts *are* verified.

**Not tested.** Everything that needs root and a real disk: `sfdisk`,
`mkfs`, `grub-install`, the stage3 download and unpack, and `emerge`. The
partition-table script is standard `sfdisk` input (ESP by size, swap by size,
last partition takes the rest) but has not been run against a disk.

So: run `--dry-run` first, and have a live USB ready to boot back into if
anything goes wrong. If it fails, the log is at the path printed at the end, and
`/tmp/install-gentoo-*.log` from the run.

## Notes for this hardware

- **Secure Boot must be off.** The kernel installed here is unsigned. On a
  ThinkPad: F1 at power-on, then Config → Security → Secure Boot → Disabled. The
  script refuses to continue if it detects Secure Boot on, unless you pass
  `--yes`.
- **Both wireless chips are handled.** L14 Gen 2 (types 20X1/20X2/20X5/20X6)
  ships the MediaTek MT7921; some units have Intel AX200/AX201. The script sets
  `power_save=0` for both `mt7921e` and `iwlwifi`, because both are known to
  drop the link after a few minutes otherwise, and pulls in the matching
  firmware packages.
- **CSM/legacy BIOS is refused.** The `grub` package is installed for UEFI
  only; booting the live USB in CSM mode will fail the preflight check.
- **The dist kernel is deliberate.** Building a kernel with the modules this
  laptop needs is a long detour, and the point here is a working base quickly.
  Move to a custom kernel later if you want one.

## Design notes

- `run()` is the only thing that touches the system. In `--dry-run` it prints
  `would: ...` instead of executing, so the dry run exercises the real code path
  rather than a parallel one that can drift.
- Stage3 is resolved by fetching `latest-stage3-amd64-openrc.txt` and parsing
  the first `stage3-...tar.xz` line out of it, so it does not pin a filename
  that will 404 in a month. Two mirrors are tried.
- `package.use` and `package.mask` are written as files, and any pre-existing
  *directory* of the same name is removed first. Portage 3.0.8x reads them as
  single files and silently ignores a directory, so a leftover one voids every
  entry without any warning.
- `installkernel` gets `USE=dracut` explicitly, because the dist kernel has no
  initramfs otherwise and will not boot.
- `doas` needs three separate things to work, and ships with none of them: a
  config at `/etc/doas.conf` (not `/etc/doas/doas.conf`), mode `0600` on that
  file, and mode `4755` on the binary. `4750` looks tidier and makes doas
  completely unusable for non-root users.
- No password is ever passed on a command line or echoed: the password is
  written to a `0600` temp file and consumed by `chpasswd` inside the chroot,
  then removed. The VM installer that this came from had a bug where `passwd`
  printed a suggested password into the serial log; avoid that by not running
  `passwd` non-interactively at all.
