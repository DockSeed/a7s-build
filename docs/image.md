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

eMMC (boot is proven): boot the board from an SD card written as above, copy
the image (or its `.xz`) to the board, find the eMMC with `lsblk` (the
`mmcblk*` device that is not the card you booted from), write it with the same `dd` command, power off, remove
the card.

The image is 1.5 GiB; on the first boot the root partition grows to the end of
the card or eMMC.

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
NVMe host ID, and grows the root partition to the end of the card. The desktop
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
| 0 | MBR, disk id `0xa7530001` |
| 128 KiB | `u-boot-sunxi-with-spl.bin` (boot chain: SPL, BL31, U-Boot) |
| 16 MiB → end | partition 1: ext4 `a7s-root`, `PARTUUID=a7530001-01` |

No boot partition, no initrd: U-Boot reads `/boot/extlinux/extlinux.conf`
from the root filesystem. `/boot/BUILD-ID` and `/boot/bootchain-id` say which
build and which boot chain the card carries.

## Safe mode

U-Boot counts boots; after three that never reached `multi-user.target` it
boots `/boot/extlinux/extlinux-fallback.conf`: same kernel, no desktop, without
the GPU and WLAN drivers (Ethernet and SSH work). The board stays in safe
mode until you clear the counter and reboot:

    sudo busybox devmem 0x0709011C 32 0

Reproducibility: [reproducibility](reproducibility.md). A rootless build needs no loop device and no mount: the ext4 comes from a directory (`mke2fs -d`), the partition table from `sfdisk`, the pieces are placed with `dd`.
