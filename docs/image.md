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
trixie-backports (PowerVR Vulkan driver), zram swap, nftables, and the usual
tools (`ip`, `iw`, `ethtool`, `lspci`, `lsusb`, `nvme`, `curl`, `nano`, …).
The full list with reasons: `scripts/distro/debian/packages.sh`.

apt points at `deb.debian.org` and `security.debian.org` (`main
non-free-firmware`, as a Debian 13 install writes them), so
`sudo apt update && sudo apt upgrade` brings normal Debian updates. Only
kmscon, libtsm4 and Mesa come from trixie-backports (pinned).

Kernel side: the kernel, device tree and modules of the kernel stage, the GPU
firmware, and the WLAN/BT driver and firmware (aic8800) when the wifi stage
built them.

## Switches

`A7S_DESKTOP`, `A7S_USER`, `A7S_HOSTNAME`, `A7S_SNAPSHOT`, `A7S_ROOTFS_REBUILD`: see [building](building.md#switches). `A7S_DESKTOP=1` adds Xfce with LightDM (no LibreOffice) and the patched xfwm4.

## Layout

| Offset | Content |
|---|---|
| 0 | MBR, disk id `0xa7530001` |
| 128 KiB | `boot0_sdcard.bin` |
| 12 MiB | `boot_package.fex` |
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
