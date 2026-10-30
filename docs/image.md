# The image

The last three stages of `./build.sh`:

| Stage | Output |
|---|---|
| `rootfs` | Debian trixie arm64 root filesystem in `work/rootfs/` |
| `image` | `out/a7s-debian-trixie-minimal.img` (or `-desktop.img`) + `.sha256` |
| `compress` | `out/…img.xz` + `.sha256` (replaces the raw image) |

## Flashing

Find the target with `lsblk` (check size and model; a wrong device is lost
data), then write the image. `xz -d` is only needed for the compressed copy.

SD card (on your computer):

    xzcat out/a7s-debian-trixie-minimal.img.xz | sudo dd of=/dev/<card> bs=4M conv=fsync status=progress

NVMe drive: the boot ROM does not read NVMe, so the card stays in and carries
the boot chain. Boot the board from an SD card written as above, copy the image
to the board, write it to the drive (`/dev/nvme0n1`) with the same `dd`
command, then remove the card's partition table so that U-Boot no longer finds
a system on the card; the boot chain at 128 KiB stays:

    sudo dd if=/dev/zero of=/dev/mmcblk0 bs=512 count=1 conv=fsync

Check with `lsblk` that `mmcblk0` is the card you booted from. U-Boot boots
the card or eMMC before NVMe, so a card that still carries a system wins.

eMMC: boot the board from an SD card written as above, copy the image (or its
`.xz`) to the board, find the eMMC with `lsblk` (the `mmcblk*` device that is
not the card you booted from), write it with the same `dd` command, power off,
remove the card.

The image is 1.5 GiB; on the first boot the root partition grows to the end of
its disk.

## First login

The image has no password at all. `root` is locked; the user `a7s` (groups
`sudo`, `video`, `render`) has an empty password that must be changed at the
first login. On the screen (tty1) or the serial console (ttyS0, 115200 baud):

    a7s login: a7s
    You are required to change your password immediately (administrator enforced).
    New password:
    Retype new password:

Then use `sudo` as usual.

- **SSH** runs from the first boot, but accepts no login until the account has
  a password (empty passwords are refused, root is locked, no keys installed).
- **Desktop image:** LightDM, no autologin. Enter `a7s`, leave the password
  empty, then set a new one when asked.
- **Lost password:** put the card in another computer and empty the password
  field of the user in `/etc/shadow`.

On first boot the board also creates its own SSH host keys, machine ID and
NVMe host ID, gives its disk and root filesystem their own IDs
([Disk and filesystem IDs](#disk-and-filesystem-ids)), and grows the root
partition to the end of its disk. The desktop
image also makes its own ssl-cert snakeoil certificate and its icon caches
(none of them ship in the image, as in Debian's live images).

## What is in it

Debian 13 minbase plus: systemd, NetworkManager (Ethernet, WLAN), Bluetooth,
OpenSSH, systemd-timesyncd, kmscon on tty1, Debian's Mesa from
trixie-backports (PowerVR Vulkan driver), zram swap, AppArmor, nftables, and
the usual tools (`ip`, `iw`, `ethtool`, `lspci`, `lsusb`, `nvme`, `curl`,
`nano`, …). The full list with reasons: `scripts/distro/debian/packages.sh`.

AppArmor is the `apparmor` package every Debian install has (Debian's kernel
packages recommend it). `apparmor.service` loads its profiles when the kernel
has AppArmor and is skipped otherwise.

Security updates from Debian install themselves once a day
(`unattended-upgrades`, as in Debian's cloud images; origins Debian and
Debian-Security). This covers Debian's packages, not the kernel: the kernel
is not a Debian package.

## Swap

The image has no swap partition. Swap is `/dev/zram0`, compressed in RAM, as
`systemd-zram-generator` sets it up by default: half of the RAM, at most
4 GiB. To change it, write `/etc/systemd/zram-generator.conf`
(`zram-generator.conf(5)`); to switch it off, link that file to `/dev/null`
or boot with `systemd.zram=0`.

Kubernetes: the kubelet refuses to start with swap unless `failSwapOn: false`;
k3s sets that itself, so `curl -sfL https://get.k3s.io | sh -` installs as
on any Debian system with swap. Pods do not swap (the kubelet's default
`memorySwap.swapBehavior: NoSwap`); other kubelets need `failSwapOn: false`
or swap switched off.

apt points at `deb.debian.org` and `security.debian.org` (`main
non-free-firmware`, as a Debian 13 install writes them), so
`sudo apt update && sudo apt upgrade` brings normal Debian updates. Only
kmscon, libtsm4 and Mesa come from trixie-backports (pinned).

Kernel side: the kernel, device tree and modules of the kernel stage (with the
WLAN/BT driver aic8800), the GPU firmware, and the WLAN/BT firmware when the
wifi stage built it.

With the default `A7S_KERNEL=build` the kernel is not a Debian package: the image
stage copies it to `/boot/Image` and `/usr/lib/modules`, and U-Boot boots it
without an initrd. The package `a7s-kernel` holds no files; it tells apt what
that kernel provides (`wireguard-modules`, as Debian's kernel packages do), so
installing `wireguard-tools` or `wireguard` brings no Debian kernel and no
`initramfs-tools`. A Debian kernel installed by name (`linux-image-arm64`)
lands in `/boot` but is not booted: `extlinux.conf` names only the image's
kernel.

With `A7S_KERNEL=release` the kernel is the pair of packages
`linux-image-<release>` and `linux-headers-<release>` of a release of the
kernel recipe ([kernel](kernel.md)), installed with dpkg: `dpkg -l | grep linux-`
lists them. `extlinux.conf` boots `/boot/vmlinuz-<release>` with the device tree
from `/usr/lib/linux-image-<release>/allwinner/`. `a7s-kernel` stays, with
the same job. The WLAN/BT driver is the DKMS package `a7s-aic8800-dkms`, built
for the kernel when the image is made; `dkms`, `gcc`, `make` and `dpkg-dev` (with perl and binutils, 40 packages)
are in the image for it: about 230 MiB installed, plus the headers (56 MiB).
The raw image grows from 1.5 GiB to 1.8 GiB, the `.xz` from 154 MB to 207 MB
(measured with the minimal image). There is no initrd in either case.

## Switches

`A7S_DESKTOP`, `A7S_USER`, `A7S_HOSTNAME`, `A7S_SNAPSHOT`, `A7S_ROOTFS_REBUILD`: see [building](building.md#switches). `A7S_DESKTOP=1` adds Xfce with LightDM (no LibreOffice) and the patched xfwm4.

## Layout

| Offset | Content |
|---|---|
| 0 | MBR, disk id `0xa7530001` (replaced on first boot) |
| 128 KiB | `u-boot-sunxi-with-spl.bin` (boot chain: SPL, BL31, U-Boot) |
| 16 MiB → end | partition 1: ext4 `a7s-root`, `PARTUUID=a7530001-01` |

No boot partition, no initrd: U-Boot reads `/boot/extlinux/extlinux.conf`
from the root filesystem. `/boot/BUILD-ID` and `/boot/bootchain-id` say which
build and which boot chain the card carries.

## Disk and filesystem IDs

Every image is written with the same MBR disk ID (`0xa7530001`, so the root
partition is `PARTUUID=a7530001-01`) and the same ext4 UUID; `/boot/BUILD-ID`
records both (`disk_id=`, `root_uuid=`). The kernel finds its root by
`root=PARTUUID=` in `extlinux.conf`, so with the same image on two disks of
one board (an SD card and an NVMe drive, say) the root would be ambiguous.

On the first boot `a7s-root-identity.service` replaces both, as Raspberry Pi OS
does with the disk ID and Fedora CoreOS with the filesystem UUID: a random disk
ID, written with `sfdisk --disk-id`, and the new partition ID in `root=` of
`extlinux.conf` and `extlinux-fallback.conf` and in `/etc/fstab`; a random ext4
UUID, set on the mounted root with `tune2fs -U random`. Each is replaced only
while it is still the build's value. The unit stops running once
`/var/lib/a7s/root-identity.done` exists.

The files are switched in an order that keeps the board bootable if the power
fails halfway: `extlinux-fallback.conf` (safe mode) gets the new ID before the
disk does, `fstab` and `extlinux.conf` right after it. If the power fails after
the disk has its new ID and before `extlinux.conf` names it, the normal boot
cannot find its root, the watchdog resets it, and after three such boots
U-Boot boots safe mode, which finishes the change; the board then stays in
safe mode until the counter is cleared ([Safe mode](#safe-mode)).

This holds in a safe-mode boot as well, because that boot never starts a
change: with `a7s.fallback` on the kernel command line the script only
finishes the second half of a run that was cut short. If the disk still has
the build's ID (a first boot that already comes up in safe mode, for instance
a disk flashed from a system that stood in safe mode), the script logs that and
exits 0 without writing `root-identity.done`. The unit is not failed and runs
again at the next normal boot, which gives the IDs. Starting the change in safe
mode would not be safe: U-Boot keeps booting `extlinux-fallback.conf` until the
counter is cleared, and a power cut after that file got the new ID and before
the disk did would leave the only file that boots naming an ID the disk does
not have.

The very first boot is ambiguous when the same image sits unbooted on two
disks of one board. U-Boot takes the kernel and the device tree from the first
disk in its boot order (an SD card or eMMC before NVMe), and the kernel mounts
the partition it finds first with that `PARTUUID`; these need not be the same
disk, and which one the kernel finds is the kernel's behaviour, not something
this image controls or that was measured here. The script gives only the
mounted disk its own ID. After at most two boots each disk has an ID of its
own. Do not put the same image, unbooted, on two disks of one board.

A copy of a disk made after its first boot (with `dd`, for instance) has that
disk's IDs again; give the copy new ones before both are in one board.

## Safe mode

U-Boot counts boots; after three that were not marked good it boots
`/boot/extlinux/extlinux-fallback.conf` from the disk it would boot normally
(card, eMMC or NVMe): same kernel, no desktop, without the GPU and WLAN
drivers (Ethernet and SSH work). The board stays in safe mode
until you clear the counter and reboot:

    sudo busybox devmem 0x0709011C 32 0

A boot is marked good as in systemd's
[Automatic Boot Assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/):
`a7s-boot-good.service` clears the counter only once `boot-complete.target`
is reached, and that target waits for its checks. The image ships one,
`a7s-boot-check-no-oops.service`, which runs after `default.target` and fails
if the kernel has oopsed since it booted (taint flag `D`). To add your own
check, give its unit `Before=boot-complete.target` and
`RequiredBy=boot-complete.target` (`man systemd.special`).

A boot that fails a check keeps running; it is only not marked good, and
`systemctl --failed` lists the check that failed. Nothing reboots the board
for it: the counter counts on at the next boot, whatever starts that boot
(reboot, watchdog reset, power cut).

A kernel oops does reboot the board: `/etc/sysctl.d/60-a7s-panic-on-oops.conf`
sets `kernel.panic_on_oops = 1`, so the oops ends in a panic and the panic
reboots after the kernel's panic timeout. That boot was not marked good, so
U-Boot counts it. A file that sorts after it, such as
`/etc/sysctl.d/90-local.conf`, can set `kernel.panic_on_oops = 0` instead.

Reproducibility: [reproducibility](reproducibility.md). A rootless build needs no loop device and no mount: the ext4 comes from a directory (`mke2fs -d`), the partition table from `sfdisk`, the pieces are placed with `dd`.
