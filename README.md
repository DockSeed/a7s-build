# a7s-build

Build your own Debian 13 (trixie, arm64) image for the Radxa Cubie A7S
(Allwinner A733): boot chain, Linux 6.18 with the A733 patch series, root
filesystem and a flashable image, all from one `./build.sh`, inside a container.
**You build your own image. We ship no image and no blob**: every vendor binary
is downloaded at build time from its public origin and checked against a
sha256 committed here.

## Requirements

- x86_64 Linux host (the boot-chain tools are x86_64-only).
- Linux kernel >= 6.7 on the host, or a `qemu-aarch64` binfmt handler
  registered on the host with the `F` flag (the root filesystem is arm64).
- `git`, and **podman >= 4 or docker >= 24**. Tested: rootless podman 5.8,
  docker 29.8 (inside a podman container).
- About 20 GB free disk, 8 GB RAM (lower `A7S_JOBS` if tight).
- Internet access during the build.
- Time: about an hour for the first build on 4 cores; later builds reuse the cache.

## Quick start

```sh
git clone https://github.com/DockSeed/a7s-build
cd a7s-build
./build.sh
```

The image lands in `out/`: `a7s-debian-trixie-minimal.img.xz` (about 130 MB;
1.5 GiB unpacked) and its `.sha256`. For the Xfce desktop, build with
`A7S_DESKTOP=1 ./build.sh`; the image is then `a7s-debian-trixie-desktop.img.xz`.
`./build.sh --help` lists stages and switches; details in
[docs/building.md](docs/building.md).

## Flashing

Find the target with `lsblk` first. A wrong device is lost data.

**SD card** (on your computer; replace `<card>` with the device you found):

```sh
xzcat out/a7s-debian-trixie-minimal.img.xz | sudo dd of=/dev/<card> bs=4M conv=fsync status=progress
```

For the desktop image, use its file name instead.

**eMMC** (boot from eMMC is proven): boot the board from an SD card as above,
copy the image to the board, find the eMMC with `lsblk` (the `mmcblk*` device
that is not your boot card), write it with the same `dd` command, power off and
remove the card.

On first boot the root partition grows to the end of the card or eMMC.
Image layout, safe mode: [docs/image.md](docs/image.md).

## First login

There is no default password. At the first login on the screen (tty1) or the
serial console (ttyS0, 115200 baud) log in as `a7s` with an empty password; you
are forced to set a new one right away. SSH runs from the first boot but
accepts logins only once a password is set. SSH host keys, machine ID and so on
are generated at first boot.

SSH access: from then on `a7s` can log in over SSH with that password from your
network, as on a default Debian install (`PasswordAuthentication` is on).
`a7s` has sudo. `root` is locked and has no password login. For key-only login,
add your key and set `PasswordAuthentication no` in a file under
`/etc/ssh/sshd_config.d/`.

## What runs on the board

Both images run SSH and NetworkManager (which also writes `/etc/resolv.conf`,
as on a Debian install). The desktop image adds Debian's desktop defaults, some
of which talk to the local network:

- `avahi-daemon`: mDNS/DNS-SD, announces and finds services on the local network
- `cups`, `cups-browsed`: printing; CUPS listens on localhost only, cups-browsed
  adds printers it finds on the network
- `exim4`: mail for local delivery only, listens on localhost only
- `packagekit`: package updates for the desktop tools, started on demand

Switch off what you do not need with `sudo systemctl disable --now <name>`.

Language and keyboard: the desktop image uses English (`en_US.UTF-8`) and the
US layout on the consoles, the login screen and the desktop; the minimal image
uses `C.UTF-8` and the US layout. To switch the desktop image's layout, for
example to German, run `sudo dpkg-reconfigure keyboard-configuration` and
reboot (`localectl` does not stick on Debian).

The board has no battery for its clock: after power-on the clock starts at the
time the image was built, and NTP sets it once the network is up.

There is no sound card yet: the board has no analogue audio output, and audio
over DisplayPort is not enabled yet. Bluetooth audio (A2DP) works.

After power-on the kernel may log a few `uncorrectable error in header` lines
from ramoops: its crash-log area in RAM holds random data while the board is
off. They are harmless.

## Switches

Environment variables, defaults in [config/defaults.conf](config/defaults.conf).

| Switch | Default | Effect |
|---|---|---|
| `A7S_DESKTOP` | `0` | `1`: Xfce desktop (LightDM) and patched xfwm4 |
| `A7S_USER` | `a7s` | login user |
| `A7S_HOSTNAME` | `a7s` | host name |
| `A7S_SNAPSHOT` | fixed timestamp | snapshot.debian.org time of the packages; empty = live archive (not reproducible) |
| `A7S_ENGINE` | podman, else docker | container engine |
| `A7S_WORK`, `A7S_OUT`, `A7S_CACHE` | `work`, `out`, `cache` | scratch, output and download-cache directories |
| `A7S_JOBS` | all CPUs | parallel compile jobs |
| `A7S_IMAGE_NAME`, `A7S_IMAGE_SIZE_MB` | derived | image file name and size |
| `A7S_DOWNLOAD_MIRROR` | empty | your own content-addressed mirror; the pinned sha256 still decides |

## What the build downloads

See [docs/blobs.md](docs/blobs.md) for every download, its origin and its
terms. The finished image contains vendor firmware (WLAN, GPU, boot0): it is
for your own use, **do not redistribute it**.

## More

- [docs/building.md](docs/building.md): host, engines, emulation
- [docs/reproducibility.md](docs/reproducibility.md): what is pinned, moving a pin
- [docs/kernel.md](docs/kernel.md), [docs/bootchain.md](docs/bootchain.md), [docs/image.md](docs/image.md), [docs/distro-interface.md](docs/distro-interface.md)
- [docs/how-we-built-it.md](docs/how-we-built-it.md): how this came about
- [docs/benchmarks.md](docs/benchmarks.md): sbc-bench on the board
- [docs/help-wanted.md](docs/help-wanted.md): the A733 is landing in mainline right now, and help is welcome

## Found a problem?

If something does not build, does not boot, or a statement here is wrong,
please open an issue on GitHub. Include the commit you built, your host
(distribution, podman or docker) and the relevant part of the build log
or serial console.

## Licence

Our own files are `GPL-2.0-only OR MIT`. Patches and bundled code keep the
licence of the project they belong to (Linux GPL-2.0-only, U-Boot
GPL-2.0-or-later, TF-A BSD-3-Clause, ORC BSD-2-Clause, xfwm4 GPL-2.0-or-later,
aic8800 GPL-2.0-only). The repository as a whole can be shared under
GPL-2.0 ([LICENSE](LICENSE)). Full texts in [LICENSES/](LICENSES/),
assignments in [REUSE.toml](REUSE.toml); `reuse lint` checks them.
