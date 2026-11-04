# a7s-build

Build your own Debian 13 (trixie, arm64) image for the Radxa Cubie A7S
(Allwinner A733): boot chain and Linux 6.18 with the A733 patch series (each a separate recipe,
pinned to a commit), root filesystem and a flashable image, all from one `./build.sh`, inside a container.
**You build your own image. We ship no image and no blob**: every vendor binary
is downloaded at build time from its public origin and checked against a
sha256 committed here.

## Requirements

- x86_64 or aarch64 Linux host (both tested).
- On an x86_64 host: Linux kernel >= 6.7, or a `qemu-aarch64` binfmt handler
  registered on the host with the `F` flag (the root filesystem is arm64).
- `git`, and **podman >= 4 or docker >= 24**. Tested: rootless podman 5.8,
  docker 29.8 (inside a podman container).
- About 20 GB free disk, 8 GB RAM (lower `A7S_JOBS` if tight).
- Internet access during the build.
- Time: about an hour for the first build on 4 cores with `A7S_KERNEL=build` (the kernel is
  compiled; [docs/building.md](docs/building.md) has the time of the default); later builds reuse the cache.

## Quick start

```sh
git clone https://github.com/DockSeed/a7s-build
cd a7s-build
./build.sh
```

The image lands in `out/`: `a7s-trixie-minimal.img.xz` (about 207 MB;
1.8 GiB unpacked; with `A7S_KERNEL=build`, 155 MB and 1.5 GiB) and its `.sha256`. For the Xfce desktop, build with
`A7S_DESKTOP=1 ./build.sh`; the image is then `a7s-trixie-desktop.img.xz`.
`./build.sh --help` lists stages and switches; details in
[docs/building.md](docs/building.md).

## Flashing

Find the target with `lsblk` first. A wrong device is lost data.

**SD card** (on your computer; replace `<card>` with the device you found):

```sh
xzcat out/a7s-trixie-minimal.img.xz | sudo dd of=/dev/<card> bs=4M conv=fsync status=progress
```

For the desktop image, use its file name instead.

**NVMe drive**: the boot ROM does not read NVMe, so the card stays in and
carries the boot chain. Boot the board from an SD card as above, copy the image
to the board, write it to the drive (`/dev/nvme0n1`) with the same `dd`
command, then remove the card's partition table so that U-Boot no longer finds
a system on the card (the boot chain at 128 KiB stays):

```sh
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=512 count=1 conv=fsync
```

Check with `lsblk` that `mmcblk0` is the card you booted from, then reboot.

**eMMC**: boot the board from an SD card as above, copy the image to the board,
find the eMMC with `lsblk` (the `mmcblk*` device that is not your boot card),
write it with the same `dd` command, power off and remove the card.

On first boot the root partition grows to the end of its disk.
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

## Updates

Debian's packages update as on any Debian install: security updates install
themselves once a day (`unattended-upgrades`), and `sudo apt update && sudo
apt upgrade` brings the rest.

New kernels come as releases of the kernel recipe, the repository
[a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts/releases) with the
scripts and patches that build the kernel; `sudo a7s-kernel-update` installs the
newest. A release has a tag (`v6.18.60-R2`) and the kernel in it has a release
name (`6.18.60-r2`, what `uname -r` prints): both name the same release. There is no guarantee for how long new
releases will be published. Kernel releases follow Linux stable when we get to
it. Whether and how soon a fix from Linux, security fixes included, reaches a
release is not guaranteed. If a board needs kernel fixes on a schedule of its
own, build the kernel with the recipe; the steps are in its README. The kernel, its device tree and the WLAN/BT driver
are not part of `apt upgrade`: there is no apt source for them.

**1. Update the kernel.** The board needs network and the time of a download
(three packages) and of the driver build (DKMS, which builds the WLAN driver for
the new kernel on the board).

    sudo a7s-kernel-update

For a given release: `sudo a7s-kernel-update v6.18.60-R2`. A published test
build (a pre-release, which "latest" leaves out) is named the same way,
`v6.18.60-T1`; the command says that it is a test build.
It downloads the release's packages, checks their sha256 against the release's
`SHA256SUMS` (on a mismatch it removes them and stops), installs them and
removes the download. The last line of its output tells what happens next:

- `kernel 6.18.60-r2 starts at the next boot. Next: sudo reboot`: all is in place.
- `already up to date`: this kernel is installed and set to start; nothing was done.
- `installed but will NOT start at the next boot`: above that line, the
  messages of `a7s-kernel-hook` give the reason and the command to run once the
  cause is gone (usually `sudo dpkg-reconfigure linux-image-<release>`).
- `the installation failed`: for example DKMS could not build the WLAN driver.
  Nothing changed for the next start; it uses the old kernel. To undo what was
  installed: `sudo apt remove linux-image-<release> linux-headers-<release>`,
  then look at `dkms status`. The message names the directory with the
  downloaded packages.
- In safe mode it installs nothing and names the way back (step 4).

**2. Restart.**

    sudo reboot

**3. Check what runs.** `uname -r` prints the release of the running kernel
(`6.18.60-r2`). `grep kernel /boot/extlinux/extlinux.conf` names the kernel
that starts at the next boot, `grep kernel /boot/extlinux/extlinux-fallback.conf`
the one safe mode starts.

**4. If the new kernel does not start.** After three starts that did not come
up, the board starts safe mode with the kernel that worked before: no desktop,
no WLAN; Ethernet (SSH) and the serial console work. Log in there. `uname -r`
prints the old kernel's release (`dpkg -l 'linux-image-*'` lists all installed
kernels). Then:

    sudo dpkg-reconfigure linux-image-$(uname -r)
    sudo reboot

The first command sets the old kernel as the normal one again and clears the
boot counter (the counter of failed starts; after three, the board starts safe
mode); its output says so. After the restart the old kernel starts
normally.

**Back to the old kernel while the new one runs.** If the new kernel starts but
you want the old one: `sudo dpkg-reconfigure linux-image-<old release>`, then
`sudo reboot`. The old kernel becomes the one that starts; the kernel that runs
now becomes the safe-mode kernel.

**5. Remove a kernel you do not want.**

    sudo apt remove linux-image-6.18.60-r2 linux-headers-6.18.60-r2

`apt` refuses while `extlinux.conf` or `extlinux-fallback.conf` names the
kernel; after step 4 neither names the failed one, so this works. An older kernel
that is fine can be removed once two newer ones have been installed and started.

**Without `a7s-kernel-update`** (a first install of the command, or by hand):
download `linux-image-<release>_….deb`, `linux-headers-<release>_….deb`,
`a7s-kernel-hook_….deb` and `SHA256SUMS` from the release page, check with
`sha256sum -c --ignore-missing SHA256SUMS`, install the hook package first,
`sudo apt install ./a7s-kernel-hook_*.deb` (a board without it, such as one
running an image from before the command existed, needs this so that the hook
files are configured when the kernel arrives), then `sudo apt install
./linux-image-<release>_*.deb ./linux-headers-<release>_*.deb`, and `sudo reboot`.

What the hook does and when it leaves things alone is in
[docs/kernel.md](docs/kernel.md). An image built with `A7S_KERNEL=build` has the
WLAN/BT driver only in its own kernel, so no release kernel becomes the default
there. A newer kernel needs a newly built image, which replaces everything on
the card.

## Switches

Environment variables, defaults in [config/defaults.conf](config/defaults.conf).

| Switch | Default | Effect |
|---|---|---|
| `A7S_DESKTOP` | `0` | `1`: Xfce desktop (LightDM) and patched xfwm4 |
| `A7S_USER` | `a7s` | login user |
| `A7S_HOSTNAME` | `a7s` | host name |
| `A7S_KERNEL` | `release` | `release`: install the Debian packages of a pinned release of the kernel recipe and build the WLAN driver with DKMS; `build`: compile the kernel here ([docs/kernel.md](docs/kernel.md)) |
| `A7S_SNAPSHOT` | fixed timestamp | snapshot.debian.org time of the packages; empty = live archive (not reproducible) |
| `A7S_ENGINE` | podman, else docker | container engine |
| `A7S_WORK`, `A7S_OUT`, `A7S_CACHE` | `work`, `out`, `cache` | scratch, output and download-cache directories |
| `A7S_JOBS` | all CPUs | parallel compile jobs |
| `A7S_IMAGE_NAME`, `A7S_IMAGE_SIZE_MB` | derived | image file name and size |
| `A7S_DOWNLOAD_MIRROR` | empty | your own content-addressed mirror; the pinned sha256 still decides |

## What the build downloads

See [docs/blobs.md](docs/blobs.md) for every download, its origin and its
terms. The finished image contains vendor firmware (WLAN, GPU, DRAM init): it is
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

## Who wrote this

One human and AI coding agents (Claude). The scripts, the container recipe and
the documentation were written by the agents. The decisions were the human's:

- to build a plain Debian on a mainline-based kernel;
- to follow the 6.18 LTS line and take stable releases as separate commits;
- to keep the boot chain, the kernel and the image recipe in three repositories,
  with this one pinning the other two to commits and checking the sha256 of the
  result, no copies;
- to ship Debian as Debian: no project name, logo or login banner in the
  image, nothing that presents Debian's work as ours;
- what counts as proven: a statement about the hardware is made only after it
  was measured on a board, and a change to the recipe is published only after
  the image it builds has booted.

## A note on earlier versions

Earlier versions of this repository described other projects' code, including
Radxa's and Allwinner's, in a tone that was not fair to the people who wrote
it. Those texts were written with AI agents and published without the review
they needed. They have been rewritten, and we apologise to everyone they
concerned. Their work is what made this project possible.

## Licence

a7s-build is unofficial and not affiliated with or authorized by Debian,
Radxa or Allwinner. Debian is a registered trademark owned by Software in the
Public Interest, Inc. Problems with images built from this recipe belong in this
repository, not in Debian's bug tracker.

This project does not distribute images and does not support their
distribution. Anyone who distributes an image built with this recipe does so
on their own responsibility and must meet the licence and trademark terms of
every component in it.

Our own files are `GPL-2.0-only OR MIT`. Patches and bundled code keep the
licence of the project they belong to (ORC BSD-2-Clause, xfwm4
GPL-2.0-or-later). The boot chain and the kernel are not
part of this repository: [a733-bootchain](https://github.com/DockSeed/a733-bootchain)
and [a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts), each pinned to a
commit, have their own licences. The repository as a whole can be shared under
GPL-2.0 ([LICENSE](LICENSE)). Full texts in [LICENSES/](LICENSES/),
assignments in [REUSE.toml](REUSE.toml); `reuse lint` checks them.
